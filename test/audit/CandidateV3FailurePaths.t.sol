// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BMCIlluminatiPassCandidateV3 as V3} from "./fixtures/BMCIlluminatiPassCandidateV3.sol";
import {MockBMC} from "../mocks/MockBMC.sol";
import {SequenceCoordinator, AdversarialBurnToken, MalformedLaneCoordinator} from "./helpers/V3SecurityMocks.sol";

contract RejectMysteryReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("receiver refuses mint");
    }
}

contract CandidateV3FailurePathsTest is Test {
    string constant CID = "bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u";
    uint256 constant GENESIS_PRICE = 1_000_000 ether;
    uint256 constant MYSTERY_PRICE = 350_000 ether;
    MockBMC bmc;
    SequenceCoordinator coord;
    V3 pass;
    address owner = makeAddr("failure-path owner");
    address buyer = makeAddr("failure-path buyer");
    uint64 deadline;

    function setUp() public {
        vm.warp(1_800_000_000);
        deadline = uint64(block.timestamp + 30 days);
        bmc = new MockBMC();
        coord = new SequenceCoordinator();
        pass = _deploy(address(bmc), address(coord));
        bmc.mint(buyer, 202_000_000 ether);
        vm.prank(buyer);
        bmc.approve(address(pass), type(uint256).max);
    }

    function _deploy(address token, address coordinator) internal returns (V3) {
        return new V3(owner, token, coordinator, deadline, 123, coord.KEY(), 150_000, 3, true, CID);
    }

    function _phase1() internal {
        vm.startPrank(buyer);
        for (uint256 i; i < 40; ++i) {
            pass.mintGenesis();
        }
        vm.stopPrank();
    }

    function _oneMystery() internal {
        _phase1();
        vm.prank(buyer);
        pass.mintMystery();
    }

    function _assertAccounting(uint256 minted, uint256 burned, uint256 supply, uint256 balance, uint256 allowance_)
        internal
        view
    {
        assertEq(pass.totalMinted(), minted);
        assertEq(pass.totalBurned(), burned);
        assertEq(bmc.totalSupply(), supply);
        assertEq(bmc.balanceOf(buyer), balance);
        assertEq(bmc.allowance(buyer, address(pass)), allowance_);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_InsufficientAllowanceRollsBackBothPhases(bool mystery, uint256 allowance_) public {
        if (mystery) _phase1();
        uint256 price = mystery ? MYSTERY_PRICE : GENESIS_PRICE;
        allowance_ = bound(allowance_, 0, price - 1);
        uint256 supply = bmc.totalSupply();
        uint256 balance = bmc.balanceOf(buyer);
        vm.startPrank(buyer);
        bmc.approve(address(pass), allowance_);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pass), allowance_, price)
        );
        if (mystery) pass.mintMystery();
        else pass.mintGenesis();
        vm.stopPrank();
        _assertAccounting(mystery ? 40 : 0, mystery ? 40 * GENESIS_PRICE : 0, supply, balance, allowance_);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_InsufficientBalanceRestoresSpentAllowance(bool mystery, uint256 balance) public {
        if (mystery) _phase1();
        uint256 price = mystery ? MYSTERY_PRICE : GENESIS_PRICE;
        balance = bound(balance, 0, price - 1);
        vm.startPrank(buyer);
        bmc.burn(bmc.balanceOf(buyer) - balance);
        bmc.approve(address(pass), price);
        uint256 supply = bmc.totalSupply();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, buyer, balance, price));
        if (mystery) pass.mintMystery();
        else pass.mintGenesis();
        vm.stopPrank();
        _assertAccounting(mystery ? 40 : 0, mystery ? 40 * GENESIS_PRICE : 0, supply, balance, price);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_BurnMismatchCannotConsumeBalanceAllowanceOrInventory(uint8 modeInput, bool mystery) public {
        AdversarialBurnToken bad = new AdversarialBurnToken(makeAddr("burn reserve"));
        bmc = bad;
        pass = _deploy(address(bad), address(coord));
        bad.mint(buyer, 100_000_000 ether);
        bad.mint(bad.reserve(), 10_000_000 ether);
        vm.prank(buyer);
        bad.approve(address(pass), 100_000_000 ether);
        if (mystery) _phase1();
        AdversarialBurnToken.Mode mode = AdversarialBurnToken.Mode(bound(modeInput, 1, 7));
        bad.setMode(mode);
        uint256 price = mystery ? MYSTERY_PRICE : GENESIS_PRICE;
        uint256 supply = bad.totalSupply();
        uint256 balance = bad.balanceOf(buyer);
        uint256 allowance_ = bad.allowance(buyer, address(pass));
        uint256 reserveBalance = bad.balanceOf(bad.reserve());
        if (mode == AdversarialBurnToken.Mode.IncreaseSupply) {
            vm.expectRevert(stdError.arithmeticError);
        } else if (mode == AdversarialBurnToken.Mode.RevertBurn) {
            vm.expectRevert(bytes("burn unavailable"));
        } else {
            uint256 delta;
            if (mode == AdversarialBurnToken.Mode.ShortBurn) delta = price - 1;
            if (mode == AdversarialBurnToken.Mode.OverBurn) delta = price + 1;
            if (mode == AdversarialBurnToken.Mode.SupplyOnly) delta = price;
            vm.expectRevert(abi.encodeWithSelector(V3.BurnMismatch.selector, price, delta));
        }
        vm.prank(buyer);
        if (mystery) pass.mintMystery();
        else pass.mintGenesis();
        _assertAccounting(mystery ? 40 : 0, mystery ? 40 * GENESIS_PRICE : 0, supply, balance, allowance_);
        assertEq(bad.balanceOf(bad.reserve()), reserveBalance);
    }

    function test_ZeroAllowanceRejectedBeforeBurn() public {
        testFuzz_InsufficientAllowanceRollsBackBothPhases(false, 0);
    }

    function test_OneWeiShortMysteryAllowanceRejectedBeforeBurn() public {
        testFuzz_InsufficientAllowanceRollsBackBothPhases(true, MYSTERY_PRICE - 1);
    }

    function test_OneWeiShortBalanceRestoresExactAllowance() public {
        testFuzz_InsufficientBalanceRestoresSpentAllowance(false, GENESIS_PRICE - 1);
    }

    function _assignmentDigest() internal view returns (bytes32 digest) {
        for (uint256 id = 41; id <= pass.totalMinted(); ++id) {
            digest = keccak256(abi.encode(digest, id, pass.tierOf(id), pass.artworkIdOf(id)));
        }
    }

    /// @notice Metamorphic property: replay the same delivered seed with different batch boundaries,
    /// caller, time and NFT holder. This oracle does not reimplement the shuffle.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_RevealPartitionAndTransfersDoNotAffectAssignment(uint256 seed, uint16 soldSeed, uint8 batchSeed)
        public
    {
        _phase1();
        uint256 sold = bound(soldSeed, 1, 460);
        uint256 batch = bound(batchSeed, 1, 100);
        vm.startPrank(buyer);
        for (uint256 i; i < sold; ++i) {
            pass.mintMystery();
        }
        vm.stopPrank();
        vm.warp(deadline);
        uint256 req = pass.requestSeed();
        assertTrue(coord.fulfill(req, seed));
        uint256 snapshot = vm.snapshotState();
        assertEq(pass.finalizeReveals(type(uint256).max), sold);
        bytes32 expected = _assignmentDigest();
        bytes32 uri = keccak256(bytes(pass.tokenURI(40 + sold)));
        assertTrue(vm.revertToState(snapshot));
        address recipient = makeAddr("partition secondary holder");
        vm.prank(buyer);
        pass.transferFrom(buyer, recipient, 40 + sold);
        vm.warp(deadline + 100 days);
        vm.startPrank(recipient);
        assertEq(pass.finalizeReveals(0), 0);
        while (pass.pendingReveals() != 0) pass.finalizeReveals(batch);
        vm.stopPrank();
        assertEq(_assignmentDigest(), expected);
        assertEq(keccak256(bytes(pass.tokenURI(40 + sold))), uri);
        assertEq(pass.finalizeReveals(type(uint256).max), 0);
        assertEq(pass.totalBurned(), 40_000_000 ether + sold * MYSTERY_PRICE);
        assertEq(pass.ownerOf(40 + sold), recipient);
    }

    function test_OneMysteryWithZeroSeedIsIndependentOfBatching() public {
        testFuzz_RevealPartitionAndTransfersDoNotAffectAssignment(0, 1, 1);
    }

    function test_FullSupplyAndMaximumSeedAreIndependentOfBatching() public {
        testFuzz_RevealPartitionAndTransfersDoNotAffectAssignment(type(uint256).max, 460, 100);
        uint256 supply = bmc.totalSupply();
        vm.prank(buyer);
        vm.expectRevert(V3.SoldOut.selector);
        pass.mintMystery();
        assertEq(pass.totalMinted(), 500);
        assertEq(pass.totalBurned(), 201_000_000 ether);
        assertEq(bmc.totalSupply(), supply);
        assertEq(pass.mysteryGenesisRevealed(), 37);
        assertEq(pass.remainingMysteryStandard(), 0);
    }

    function test_MysteryReceiverRejectionRestoresBurnAndDoesNotConsumePosition() public {
        _phase1();
        RejectMysteryReceiver receiver = new RejectMysteryReceiver();
        bmc.mint(address(receiver), MYSTERY_PRICE);
        uint256 supply = bmc.totalSupply();
        vm.startPrank(address(receiver));
        bmc.approve(address(pass), MYSTERY_PRICE);
        vm.expectRevert(bytes("receiver refuses mint"));
        pass.mintMystery();
        vm.stopPrank();
        assertEq(pass.totalMinted(), 40);
        assertEq(pass.totalBurned(), 40 * GENESIS_PRICE);
        assertEq(bmc.totalSupply(), supply);
        assertEq(bmc.balanceOf(address(receiver)), MYSTERY_PRICE);
        assertEq(bmc.allowance(address(receiver), address(pass)), MYSTERY_PRICE);
        assertEq(pass.pendingReveals(), 0);
        vm.prank(buyer);
        (uint256 id,) = pass.mintMystery();
        assertEq(id, 41);
    }

    function test_GenesisDeadlineBoundaryRollsBackWithoutExplicitClosure() public {
        vm.warp(deadline - 1);
        vm.prank(buyer);
        pass.mintGenesis();
        uint256 supply = bmc.totalSupply();
        vm.warp(deadline);
        vm.prank(buyer);
        vm.expectRevert(V3.GenesisPhaseOver.selector);
        pass.mintGenesis();
        assertEq(pass.totalMinted(), 1);
        assertEq(bmc.totalSupply(), supply);
        assertEq(pass.currentPrice(), 0);
        assertFalse(pass.genesisPhaseActive());
        pass.closeSale();
        vm.expectRevert(bytes("already closed"));
        pass.closeSale();
    }

    function test_PrematureMysteryAndSeedRequestsCannotSpendBMC() public {
        uint256 supply = bmc.totalSupply();
        vm.prank(buyer);
        vm.expectRevert(V3.GenesisPhaseNotOver.selector);
        pass.mintMystery();
        vm.expectRevert(bytes("not closed yet"));
        pass.requestSeed();
        vm.expectRevert(bytes("seed pending"));
        pass.finalizeReveals(type(uint256).max);
        assertEq(pass.totalBurned(), 0);
        assertEq(bmc.totalSupply(), supply);
        assertFalse(pass.saleClosed());
    }

    function test_FailedSeedSubmissionRollsBackAutomaticCloseAndCanBeResubmitted() public {
        _oneMystery();
        vm.warp(deadline);
        coord.setRejectRequests(true);
        vm.expectRevert(bytes("mock: subscription not funded"));
        pass.requestSeed();
        assertFalse(pass.saleClosed());
        assertEq(pass.seedRequestId(), 0);
        coord.setRejectRequests(false);
        uint256 req = pass.requestSeed();
        assertTrue(coord.fulfill(req, 0));
        assertEq(pass.finalizeReveals(1), 1);
        assertEq(pass.pendingReveals(), 0);
    }

    function test_ZeroRequestIdRevertsCoordinatorStateAndAllowsCleanSubmission() public {
        MalformedLaneCoordinator malformed = new MalformedLaneCoordinator();
        pass = _deploy(address(bmc), address(malformed));
        vm.prank(buyer);
        bmc.approve(address(pass), type(uint256).max);
        _oneMystery();
        vm.warp(deadline);
        malformed.setRequestResult(0);
        vm.expectRevert(bytes("invalid request id"));
        pass.requestSeed();
        assertEq(malformed.requests(), 0, "external coordinator changes must roll back too");
        assertEq(pass.seedRequestId(), 0);
        assertFalse(pass.saleClosed());
        malformed.setRequestResult(1);
        assertEq(pass.requestSeed(), 1);
    }

    function test_MalformedLaneRepliesFailClosedWithoutClosingSale() public {
        MalformedLaneCoordinator malformed = new MalformedLaneCoordinator();
        pass = _deploy(address(bmc), address(malformed));
        vm.prank(buyer);
        bmc.approve(address(pass), type(uint256).max);
        _oneMystery();
        vm.warp(deadline);
        for (uint256 i = 1; i <= 5; ++i) {
            malformed.setReply(MalformedLaneCoordinator.Reply(i));
            // Malformed ABI replies may revert in Solidity's decoder without a reason string.
            (bool ok,) = address(pass).call(abi.encodeCall(pass.requestSeed, ()));
            assertFalse(ok);
            assertFalse(pass.saleClosed());
            assertEq(pass.seedRequestId(), 0);
            assertEq(malformed.requests(), 0);
        }
        malformed.setReply(MalformedLaneCoordinator.Reply.Valid);
        assertEq(pass.requestSeed(), 1);
    }

    function test_EmptyAndUnknownCallbacksDoNotPoisonLaterValidDelivery() public {
        _oneMystery();
        vm.warp(deadline);
        uint256 req = pass.requestSeed();
        uint256[] memory words = new uint256[](0);
        vm.prank(address(coord));
        vm.expectRevert(V3.NoRandomWords.selector);
        pass.rawFulfillRandomWords(req, words);
        assertFalse(pass.seedReceived());
        words = new uint256[](1);
        vm.prank(address(coord));
        vm.expectRevert(abi.encodeWithSelector(V3.UnknownRequest.selector, 0));
        pass.rawFulfillRandomWords(0, words);
        assertTrue(coord.fulfill(req, type(uint256).max));
        assertEq(pass.globalSeed(), type(uint256).max);
        assertEq(pass.finalizeReveals(type(uint256).max), 1);
        vm.expectRevert(bytes("seed already received"));
        pass.requestSeed();
    }

    function test_GenesisArtworkAndMetadataSurviveTransferAndOwnershipRenunciation() public {
        vm.prank(buyer);
        pass.mintGenesis();
        bytes32 metadata = keccak256(bytes(pass.tokenURI(1)));
        address recipient = makeAddr("genesis secondary holder");
        vm.prank(buyer);
        pass.safeTransferFrom(buyer, recipient, 1);
        vm.prank(owner);
        pass.renounceOwnership();
        assertEq(pass.ownerOf(1), recipient);
        assertEq(pass.artworkIdOf(1), 1);
        assertEq(keccak256(bytes(pass.tokenURI(1))), metadata);
        assertEq(pass.genesisImagesCID(), CID);
    }

    function test_PendingTransferCannotChangeFinalOutcomeOrChargeNewHolder() public {
        _oneMystery();
        address recipient = makeAddr("pending secondary holder");
        vm.prank(buyer);
        pass.approve(owner, 41);
        vm.prank(owner);
        pass.transferFrom(buyer, recipient, 41);
        uint256 supply = bmc.totalSupply();
        vm.warp(deadline);
        uint256 req = pass.requestSeed();
        assertTrue(coord.fulfill(req, 123));
        vm.prank(recipient);
        assertEq(pass.finalizeReveals(type(uint256).max), 1);
        assertEq(pass.ownerOf(41), recipient);
        assertEq(bmc.totalSupply(), supply);
        assertEq(bmc.balanceOf(recipient), 0);
        assertEq(pass.getApproved(41), address(0));
        bytes32 metadata = keccak256(bytes(pass.tokenURI(41)));
        assertTrue(coord.redeliver(req, 456));
        assertEq(pass.finalizeReveals(1), 0);
        assertEq(keccak256(bytes(pass.tokenURI(41))), metadata);
    }

    function test_NonexistentAndWrongTierViewsRejectZeroAndMaximum() public {
        uint256[2] memory ids = [uint256(0), type(uint256).max];
        for (uint256 i; i < ids.length; ++i) {
            bytes memory reason = abi.encodeWithSelector(V3.NonexistentToken.selector, ids[i]);
            vm.expectRevert(reason);
            pass.tierOf(ids[i]);
            vm.expectRevert(reason);
            pass.artworkIdOf(ids[i]);
            vm.expectRevert(reason);
            pass.revealStatusOf(ids[i]);
            vm.expectRevert(reason);
            pass.tokenURI(ids[i]);
            vm.expectRevert(reason);
            pass.standardSVG(ids[i]);
        }
        _oneMystery();
        vm.expectRevert(bytes("not standard"));
        pass.standardSVG(1);
        vm.expectRevert(bytes("not standard"));
        pass.standardSVG(41);
    }

    function test_CannotPayETHInsteadOfBurningOrReopenClosedSale() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        (bool ok,) = address(pass).call{value: 1 ether}(abi.encodeCall(pass.mintGenesis, ()));
        assertFalse(ok);
        assertEq(pass.totalMinted(), 0);
        assertEq(pass.totalBurned(), 0);
        assertEq(address(pass).balance, 0);
        _oneMystery();
        vm.warp(deadline);
        pass.closeSale();
        vm.prank(owner);
        (ok,) = address(pass).call(abi.encodeWithSignature("setSaleDeadline(uint64)", deadline + 30 days));
        assertFalse(ok);
        vm.prank(buyer);
        vm.expectRevert(V3.SoldOut.selector);
        pass.mintMystery();
    }
}

contract CandidateV3ConstructorBoundsTest is Test {
    string constant CID = "bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u";
    address owner = makeAddr("constructor owner");
    address token = makeAddr("constructor codeless token");
    address coordinator = makeAddr("constructor codeless coordinator");
    bytes32 constant KEY = keccak256("constructor lane");

    function _new(uint256 sub, bytes32 key, uint32 gasLimit, uint16 confirmations) internal returns (V3) {
        return
            new V3(owner, token, coordinator, uint64(block.timestamp + 1), sub, key, gasLimit, confirmations, true, CID);
    }

    function test_RejectsEachInvalidVRFBoundary() public {
        vm.expectRevert(V3.InvalidVRFConfig.selector);
        _new(0, KEY, 150_000, 3);
        vm.expectRevert(V3.InvalidVRFConfig.selector);
        _new(1, bytes32(0), 150_000, 3);
        vm.expectRevert(V3.InvalidVRFConfig.selector);
        _new(1, KEY, 149_999, 3);
        vm.expectRevert(V3.InvalidVRFConfig.selector);
        _new(1, KEY, 2_500_001, 3);
        vm.expectRevert(V3.InvalidVRFConfig.selector);
        _new(1, KEY, type(uint32).max, 3);
        vm.expectRevert(V3.InvalidVRFConfig.selector);
        _new(1, KEY, 150_000, 2);
        vm.expectRevert(V3.InvalidVRFConfig.selector);
        _new(1, KEY, 150_000, 201);
        vm.expectRevert(V3.InvalidVRFConfig.selector);
        _new(1, KEY, 150_000, type(uint16).max);
    }

    function test_RejectsZeroOwnerDependencyAndEmptyCID() public {
        uint64 end = uint64(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new V3(address(0), token, coordinator, end, 1, KEY, 150_000, 3, true, CID);
        vm.expectRevert(bytes("zero address"));
        new V3(owner, address(0), coordinator, end, 1, KEY, 150_000, 3, true, CID);
        vm.expectRevert(bytes("zero address"));
        new V3(owner, token, address(0), end, 1, KEY, 150_000, 3, true, CID);
        vm.expectRevert(V3.EmptyCID.selector);
        new V3(owner, token, coordinator, end, 1, KEY, 150_000, 3, true, "");
    }

    function test_AcceptsExactConfigurationBoundsWithoutDependencyCalls() public {
        V3 low = _new(1, KEY, 150_000, 3);
        V3 high = _new(type(uint256).max, KEY, 2_500_000, 200);
        assertEq(low.owner(), owner, "constructor caller must not receive ownership");
        assertEq(high.owner(), owner);
        assertEq(address(low.BMC()), token);
        assertEq(address(low.VRF_COORDINATOR()), coordinator);
        assertEq(token.code.length, 0);
        assertEq(coordinator.code.length, 0);
        assertLe(address(low).code.length, 24_576);
    }

    function test_RejectsPresentAndPastDeadlines() public {
        vm.warp(100);
        vm.expectRevert(bytes("deadline must be future"));
        new V3(owner, token, coordinator, 100, 1, KEY, 150_000, 3, true, CID);
        vm.expectRevert(bytes("deadline must be future"));
        new V3(owner, token, coordinator, 99, 1, KEY, 150_000, 3, true, CID);
    }
}

contract CandidateV3DeploymentEncodingTest is Test {
    string constant CID = "bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u";
    uint256 constant GENESIS_PRICE = 1_000_000 ether;
    MockBMC bmc;
    SequenceCoordinator coord;
    address owner = makeAddr("encoding owner");
    address buyer = makeAddr("encoding buyer");
    uint64 deadline;

    function setUp() public {
        vm.warp(1_800_000_000);
        deadline = uint64(block.timestamp + 30 days);
        bmc = new MockBMC();
        coord = new SequenceCoordinator();
        bmc.mint(buyer, 2_000_000 ether);
    }

    /// M-1: the deadline is an absolute timestamp chosen before the deployment transaction lands.
    /// The same constructor words either revert (landing at or after the deadline) or silently
    /// produce a sale whose window is already gone, with nothing sold and nothing recoverable.
    function test_PrecomputedDeadlineLandingLateLeavesNoSaleWindow() public {
        uint64 closingTime = uint64(block.timestamp + 1);
        V3 late = new V3(owner, address(bmc), address(coord), closingTime, 123, coord.KEY(), 150_000, 3, true, CID);
        assertEq(late.currentPrice(), GENESIS_PRICE, "window open for the single remaining second");

        vm.warp(closingTime);
        assertEq(late.currentPrice(), 0, "window closed one second after landing");
        vm.prank(buyer);
        bmc.approve(address(late), type(uint256).max);
        vm.prank(buyer);
        vm.expectRevert(V3.GenesisPhaseOver.selector);
        late.mintGenesis();
        vm.prank(buyer);
        vm.expectRevert(V3.GenesisPhaseNotOver.selector);
        late.mintMystery();
        assertEq(late.totalMinted(), 0);
        assertEq(late.totalBurned(), 0);

        // Nothing can reopen or extend the sale: it closes with every position unsold.
        late.closeSale();
        assertTrue(late.saleClosed());
        assertEq(late.remainingSupply(), 500);
        vm.prank(owner);
        vm.expectRevert(bytes("already closed"));
        late.closeSale();

        // One second later the identical words no longer deploy at all.
        bytes32 key = coord.KEY();
        vm.expectRevert(bytes("deadline must be future"));
        new V3(owner, address(bmc), address(coord), closingTime, 123, key, 150_000, 3, true, CID);
    }

    /// M-1: the constructor ABI carries a dynamic `string` (parameter 10). A factory that can only
    /// append one static 32-byte word per parameter cannot produce valid initcode for V3.
    function test_ConstructorABIHasDynamicArgumentStaticWordsCannotEncode() public {
        bytes memory encoded = abi.encode(
            owner,
            address(bmc),
            address(coord),
            deadline,
            uint256(123),
            coord.KEY(),
            uint32(150_000),
            uint16(3),
            true,
            CID
        );
        // 10 head words + string length word + 2 data words for a 59-byte CID.
        assertEq(encoded.length, 13 * 32, "argument block is not ten static words");
        bytes memory head = new bytes(10 * 32);
        for (uint256 i; i < head.length; ++i) {
            head[i] = encoded[i];
        }
        (,,,,,,,,, uint256 offset) =
            abi.decode(head, (address, address, address, uint64, uint256, bytes32, uint32, uint16, bool, uint256));
        assertEq(offset, 10 * 32, "tenth word is an offset into the tail, not the CID");

        // Ten static words with the CID packed into the tenth word: construction reverts, so a
        // static-word factory has no way to instantiate V3.
        bytes memory cidBytes = bytes(CID);
        bytes32 cidWord;
        assembly ("memory-safe") {
            cidWord := mload(add(cidBytes, 32))
        }
        bytes memory staticWords = abi.encode(
            owner,
            address(bmc),
            address(coord),
            deadline,
            uint256(123),
            coord.KEY(),
            uint32(150_000),
            uint16(3),
            true,
            cidWord
        );
        assertEq(staticWords.length, 10 * 32);
        bytes memory initcode = abi.encodePacked(type(V3).creationCode, staticWords);
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 32), mload(initcode))
        }
        assertEq(deployed, address(0), "static-word encoding must not produce a V3 instance");

        // The full dynamic encoding deploys, confirming the words themselves are valid.
        initcode = abi.encodePacked(type(V3).creationCode, encoded);
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 32), mload(initcode))
        }
        assertTrue(deployed != address(0));
        assertEq(V3(deployed).genesisImagesCID(), CID);
    }
}
