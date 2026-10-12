// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {BMCIlluminatiPassCandidateV3 as V3} from "./fixtures/BMCIlluminatiPassCandidateV3.sol";
import {MockBMC, FakeBurnBMC, SixDecimalBMC} from "../mocks/MockBMC.sol";
import {ExpiringCoordinator} from "../VRFRecovery.t.sol";

contract V3AuditCoordinator is ExpiringCoordinator {
    bytes32 public constant KEY = keccak256("audit registered lane");
    bool public registered = true;

    function setRegistered(bool value) external {
        registered = value;
    }

    function s_provingKeys(bytes32 key) external view override returns (bool, uint64) {
        return (registered && key == KEY, 500 gwei);
    }
}

contract V3RejectingReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("reject NFT");
    }
}

contract V3ReenteringReceiver is IERC721Receiver {
    V3 public pass;
    MockBMC public bmc;
    bool public mystery;
    bool public blocked;

    constructor(V3 target, MockBMC token) {
        pass = target;
        bmc = token;
    }

    function buy(bool isMystery) external {
        mystery = isMystery;
        bmc.approve(address(pass), 2_000_000 ether);
        if (mystery) pass.mintMystery();
        else pass.mintGenesis();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        bytes memory callData = mystery ? abi.encodeCall(pass.mintMystery, ()) : abi.encodeCall(pass.mintGenesis, ());
        (bool ok, bytes memory reason) = address(pass).call(callData);
        blocked = !ok && keccak256(reason) == keccak256(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract V3ReentrantBurnBMC is MockBMC {
    bytes public reentry;
    bytes public failure;

    function setReentry(bytes calldata payload) external {
        reentry = payload;
    }

    function burnFrom(address account, uint256 amount) public override {
        (bool ok, bytes memory reason) = msg.sender.call(reentry);
        require(!ok, "reentry succeeded");
        failure = reason;
        super.burnFrom(account, amount);
    }
}

/// @notice Adversarial review of the UNMODIFIED V3 branch baseline. Tests named Finding
/// assert the documented defect exists; they are not claims that V3 has been repaired.
contract CandidateV3AuditTest is Test {
    string constant CID = "bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u";
    MockBMC bmc;
    V3AuditCoordinator coord;
    V3 pass;
    address owner = makeAddr("V3 audit owner");
    address buyer = makeAddr("V3 audit buyer");
    uint64 deadline;

    function setUp() public {
        vm.warp(1_800_000_000);
        deadline = uint64(block.timestamp + 30 days);
        bmc = new MockBMC();
        coord = new V3AuditCoordinator();
        pass = _deploy(address(bmc), deadline, 500_000, CID);
        bmc.mint(buyer, 201_000_000 ether);
        vm.prank(buyer);
        bmc.approve(address(pass), 201_000_000 ether);
    }

    function _deploy(address token, uint64 end, uint32 gasLimit, string memory cid) internal returns (V3) {
        return new V3(owner, token, address(coord), end, 123, coord.KEY(), gasLimit, 3, true, cid);
    }

    function _phase1() internal {
        vm.startPrank(buyer);
        for (uint256 i; i < 40; ++i) {
            pass.mintGenesis();
        }
        vm.stopPrank();
    }

    function _mystery(uint256 count) internal {
        vm.startPrank(buyer);
        for (uint256 i; i < count; ++i) {
            pass.mintMystery();
        }
        vm.stopPrank();
    }

    function _seed(uint256 word) internal returns (uint256 req) {
        vm.warp(deadline);
        req = pass.requestSeed();
        assertTrue(coord.fulfill(req, word));
    }

    function test_FindingExpiredSingleRequestPermanentlyStalls() public {
        _phase1();
        _mystery(1);
        vm.warp(deadline);
        uint256 req = pass.requestSeed();
        vm.warp(deadline + 8 days);
        coord.expire(req);
        assertFalse(coord.fulfill(req, 42));
        vm.expectRevert(bytes("seed already requested"));
        pass.requestSeed();
        vm.expectRevert(bytes("seed pending"));
        pass.finalizeReveals(10);
        assertFalse(pass.seedReceived());
        assertEq(pass.totalBurned(), 40_350_000 ether);
        assertEq(uint256(pass.tierOf(41)), uint256(V3.Tier.Pending));
    }

    function test_FindingFailedCallbackHasNoRecovery() public {
        _phase1();
        _mystery(1);
        vm.warp(deadline);
        uint256 req = pass.requestSeed();
        assertFalse(coord.fulfillWithGas(req, 42, 1_000));
        vm.warp(deadline + 8 days);
        vm.expectRevert(bytes("seed already requested"));
        pass.requestSeed();
        assertFalse(pass.seedReceived());
    }

    function test_FindingRemovedLaneCannotBeReconfigured() public {
        _phase1();
        _mystery(1);
        coord.setRegistered(false);
        vm.warp(deadline);
        vm.expectRevert(bytes("unregistered gas lane"));
        pass.requestSeed();
        vm.prank(owner);
        (bool ok,) = address(pass)
            .call(
                abi.encodeWithSignature(
                    "setVRFConfig(uint256,bytes32,uint32,uint16,bool)",
                    456,
                    keccak256("replacement"),
                    uint32(150_000),
                    uint16(3),
                    true
                )
            );
        assertFalse(ok);
        assertEq(pass.seedRequestId(), 0);
        assertEq(pass.totalBurned(), 40_350_000 ether);
    }

    function test_FindingUselessRequestWithNoMysteryTokens() public {
        vm.warp(deadline);
        uint256 before = coord.nextRequestId();
        uint256 req = pass.requestSeed();
        assertEq(coord.nextRequestId(), before + 1);
        assertTrue(coord.fulfill(req, 42));
        assertEq(pass.totalMinted(), 0);
        assertEq(pass.finalizeReveals(500), 0);
    }

    function test_FindingOutcomePublicWhileMetadataRemainsPending() public {
        _phase1();
        _mystery(1);
        // Find a seed whose first outcome is Genesis, then predict it without any finalization.
        uint256 word;
        while (uint256(keccak256(abi.encode(word, uint256(41)))) % 460 >= 37) ++word;
        bytes32 pendingURI = keccak256(bytes(pass.tokenURI(41)));
        _seed(word);
        uint256 expectedArt = 41 + uint256(keccak256(abi.encode(pass.globalSeed(), uint256(41)))) % 460;
        assertEq(keccak256(bytes(pass.tokenURI(41))), pendingURI);
        assertEq(uint256(pass.tierOf(41)), uint256(V3.Tier.Pending));
        assertEq(pass.artworkIdOf(41), 0);
        pass.finalizeReveals(1);
        assertEq(uint256(pass.tierOf(41)), uint256(V3.Tier.Genesis));
        assertEq(pass.artworkIdOf(41), expectedArt);
        assertTrue(keccak256(bytes(pass.tokenURI(41))) != pendingURI);
    }

    function test_CallbackFits150kWithStorageMargin() public {
        pass = _deploy(address(bmc), deadline, 150_000, CID);
        vm.prank(buyer);
        bmc.approve(address(pass), 201_000_000 ether);
        _phase1();
        _mystery(1);
        vm.warp(deadline);
        uint256 req = pass.requestSeed();
        // Measures the callback plus coordinator wrapper. Even adding cold-access costs
        // for all callback slots leaves substantial headroom below 150k.
        uint256 gasBefore = gasleft();
        assertTrue(coord.fulfillWithGas(req, type(uint256).max, 150_000));
        emit log_named_uint("Coordinator call including callback gas", gasBefore - gasleft());
        assertEq(pass.globalSeed(), type(uint256).max);
        assertTrue(pass.seedReceived());
    }

    function test_DeadlineBoundaryAndUnsoldSupply() public {
        _phase1();
        vm.warp(deadline - 1);
        _mystery(1);
        vm.expectRevert(bytes("not closed yet"));
        pass.closeSale();
        vm.warp(deadline);
        vm.prank(buyer);
        vm.expectRevert(V3.SoldOut.selector);
        pass.mintMystery();
        pass.closeSale();
        assertEq(pass.currentPrice(), 0);
        _seed(42);
        assertEq(pass.finalizeReveals(460), 1);
        assertEq(pass.totalMinted(), 41);
        assertEq(pass.remainingSupply(), 459);
        assertEq(pass.pendingReveals(), 0);
        assertEq(pass.remainingMysteryGenesis() + pass.remainingMysteryStandard(), 459);
        vm.prank(owner);
        vm.expectRevert(V3.SoldOut.selector);
        pass.mintMystery();
    }

    function test_NoEarlyOwnerClosure() public {
        vm.prank(owner);
        vm.expectRevert(bytes("not closed yet"));
        pass.closeSale();
        vm.expectRevert(bytes("not closed yet"));
        pass.requestSeed();
        assertFalse(pass.saleClosed());
    }

    function test_FindingAbsoluteDeadlineCanExpireBeforeDeployment() public {
        bytes32 key = coord.KEY();
        vm.warp(deadline);
        vm.expectRevert(bytes("deadline must be future"));
        new V3(owner, address(bmc), address(coord), deadline, 123, key, 500_000, 3, true, CID);
    }

    function test_OnlyCoordinatorAndKnownRequestCanDeliver() public {
        _phase1();
        _mystery(1);
        vm.warp(deadline);
        uint256 req = pass.requestSeed();
        uint256[] memory words = new uint256[](1);
        vm.expectRevert(V3.OnlyCoordinator.selector);
        pass.rawFulfillRandomWords(req, words);
        vm.prank(address(coord));
        vm.expectRevert(abi.encodeWithSelector(V3.UnknownRequest.selector, req + 1));
        pass.rawFulfillRandomWords(req + 1, words);
        assertFalse(pass.seedReceived());
    }

    function test_ZeroSeedAndDuplicateDeliveryAreSafe() public {
        _phase1();
        _mystery(1);
        uint256 req = _seed(0);
        assertTrue(coord.fulfill(req, 123));
        assertEq(pass.globalSeed(), 0);
        assertTrue(pass.seedReceived());
        assertEq(pass.finalizeReveals(0), 0);
        assertEq(pass.finalizeReveals(1), 1);
        assertEq(pass.finalizeReveals(1), 0);
        bytes32 metadata = keccak256(bytes(pass.tokenURI(41)));
        assertTrue(coord.fulfill(req, 999));
        assertEq(keccak256(bytes(pass.tokenURI(41))), metadata);
    }

    function testFuzz_FullInventoryUniqueAndBatchIndependent(uint256 word, uint16 batchInput) public {
        _phase1(); // Selling out permits closure before the deadline.
        _mystery(460);
        uint256 req = pass.requestSeed();
        assertTrue(coord.fulfill(req, word));
        uint256 batch = bound(uint256(batchInput), 1, 100);
        uint256[460] memory pool;
        for (uint256 i; i < 460; ++i) {
            pool[i] = i;
        }
        bool[460] memory seen;
        while (pass.finalizeReveals(batch) != 0) {}
        for (uint256 i; i < 460; ++i) {
            uint256 n = 460 - i;
            uint256 r = uint256(keccak256(abi.encode(word, i + 41))) % n;
            uint256 chosen = pool[r];
            pool[r] = pool[n - 1];
            assertFalse(seen[chosen]);
            seen[chosen] = true;
            assertEq(pass.artworkIdOf(i + 41), chosen < 37 ? chosen + 41 : chosen - 36);
            assertEq(uint256(pass.tierOf(i + 41)), chosen < 37 ? uint256(V3.Tier.Genesis) : uint256(V3.Tier.Standard));
        }
        assertEq(pass.mysteryGenesisRevealed(), 37);
        assertEq(pass.revealedCount(), 460);
        assertEq(pass.remainingMysteryStandard(), 0);
        assertEq(pass.totalBurned(), 201_000_000 ether);
        assertEq(bmc.totalSupply(), 0);
    }

    function test_ReceiverRejectionRollsBackIrreversibleBurn() public {
        V3RejectingReceiver receiver = new V3RejectingReceiver();
        bmc.mint(address(receiver), 1_000_000 ether);
        uint256 supply = bmc.totalSupply();
        vm.startPrank(address(receiver));
        bmc.approve(address(pass), 1_000_000 ether);
        vm.expectRevert(bytes("reject NFT"));
        pass.mintGenesis();
        vm.stopPrank();
        assertEq(bmc.totalSupply(), supply);
        assertEq(bmc.balanceOf(address(receiver)), 1_000_000 ether);
        assertEq(bmc.allowance(address(receiver), address(pass)), 1_000_000 ether);
        assertEq(pass.totalMinted(), 0);
        assertEq(pass.totalBurned(), 0);
    }

    function test_GenesisReceiverReentrancyIsBlocked() public {
        V3ReenteringReceiver receiver = new V3ReenteringReceiver(pass, bmc);
        bmc.mint(address(receiver), 2_000_000 ether);
        receiver.buy(false);
        assertTrue(receiver.blocked());
        assertEq(pass.totalMinted(), 1);
        assertEq(pass.totalBurned(), 1_000_000 ether);
    }

    function test_MysteryReceiverReentrancyIsBlocked() public {
        _phase1();
        V3ReenteringReceiver receiver = new V3ReenteringReceiver(pass, bmc);
        bmc.mint(address(receiver), 2_000_000 ether);
        receiver.buy(true);
        assertTrue(receiver.blocked());
        assertEq(pass.totalMinted(), 41);
        assertEq(pass.totalBurned(), 40_350_000 ether);
    }

    function test_FakeBurnAndWrongDecimalsRejected() public {
        FakeBurnBMC fake = new FakeBurnBMC();
        V3 wrong = _deploy(address(fake), deadline, 500_000, CID);
        fake.mint(buyer, 1_000_000 ether);
        vm.startPrank(buyer);
        fake.approve(address(wrong), 1_000_000 ether);
        vm.expectRevert(abi.encodeWithSelector(V3.BurnMismatch.selector, 1_000_000 ether, 0));
        wrong.mintGenesis();
        vm.stopPrank();
        SixDecimalBMC six = new SixDecimalBMC();
        wrong = _deploy(address(six), deadline, 500_000, CID);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(V3.UnexpectedTokenDecimals.selector, uint8(6)));
        wrong.mintGenesis();
    }

    function test_BurnFromReentrancyIsBlockedInBothPhases() public {
        V3ReentrantBurnBMC reentrant = new V3ReentrantBurnBMC();
        pass = _deploy(address(reentrant), deadline, 500_000, CID);
        reentrant.mint(buyer, 40_350_000 ether);
        reentrant.setReentry(abi.encodeCall(pass.mintGenesis, ()));
        vm.startPrank(buyer);
        reentrant.approve(address(pass), 40_350_000 ether);
        for (uint256 i; i < 40; ++i) {
            pass.mintGenesis();
        }
        vm.stopPrank();
        assertEq(reentrant.failure(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        reentrant.setReentry(abi.encodeCall(pass.mintMystery, ()));
        vm.prank(buyer);
        pass.mintMystery();
        assertEq(reentrant.failure(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        assertEq(pass.totalMinted(), 41);
        assertEq(pass.totalBurned(), 40_350_000 ether);
        assertEq(reentrant.totalSupply(), 0);
    }

    function test_CIDHasNoSetterAndOwnerCannotChangeSeed() public {
        vm.prank(owner);
        (bool ok,) = address(pass).call(abi.encodeWithSignature("setGenesisImagesCID(string)", "replacement"));
        assertFalse(ok);
        assertEq(pass.genesisImagesCID(), CID);
        assertTrue(pass.genesisCIDLocked());
        _phase1();
        _mystery(1);
        assertEq(pass.requestIdOf(41), 0, "vestigial per-token request mapping");
        _seed(42);
        vm.prank(owner);
        (ok,) = address(pass).call(abi.encodeWithSignature("setGlobalSeed(uint256)", 777));
        assertFalse(ok);
        assertEq(pass.globalSeed(), 42);
    }
}
