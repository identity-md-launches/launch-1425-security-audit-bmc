// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BMCIlluminatiPassCandidateV3 as V3} from "./fixtures/BMCIlluminatiPassCandidateV3.sol";
import {MockBMC} from "../mocks/MockBMC.sol";
import {SequenceCoordinator} from "./helpers/V3SecurityMocks.sol";

/// @dev Ghosts describe successful economic operations, not a copy of the draw algorithm.
/// All deliberate failures are checked explicitly; unexpected handler reverts fail the campaign.
contract V3SequenceHandler is Test {
    V3 public immutable pass;
    MockBMC public immutable bmc;
    SequenceCoordinator public immutable coord;
    address[4] public actors;
    uint256[4] public expectedBMC;
    uint256[4] public paidBy;
    uint256 public ghostMinted;
    uint256 public ghostBurned;
    uint256 public donated;
    uint256 public firstSeed;
    bool public received;
    bool public closed;
    uint256 public mintedAtClose;
    uint256 public trackedReveals;
    uint256 public successfulTransfers;
    uint256 public rejectedCalls;
    mapping(uint256 => address) public expectedOwner;
    mapping(uint256 => bytes32) public permanentOutcome;
    uint256 constant INITIAL_BALANCE = 202_000_000 ether;

    constructor(V3 target, MockBMC token, SequenceCoordinator coordinator) {
        pass = target;
        bmc = token;
        coord = coordinator;
        for (uint256 i; i < 4; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("V3 sequence actor", i)))));
            bmc.mint(actors[i], INITIAL_BALANCE);
            expectedBMC[i] = INITIAL_BALANCE;
            vm.prank(actors[i]);
            bmc.approve(address(pass), type(uint256).max);
        }
    }

    function _outcome(uint256 id) internal view returns (bytes32) {
        return keccak256(abi.encode(pass.tierOf(id), pass.artworkIdOf(id), pass.revealStatusOf(id)));
    }

    function _rememberClosure() internal {
        if (pass.saleClosed() && !closed) {
            closed = true;
            mintedAtClose = ghostMinted;
        }
        if (closed) {
            assertTrue(pass.saleClosed(), "closed sale reopened");
            assertEq(pass.totalMinted(), mintedAtClose, "mint after closure");
        }
    }

    function _rememberReveals() internal {
        uint256 n = pass.revealedCount();
        assertGe(n, trackedReveals, "reveal count decreased");
        for (uint256 id = 41 + trackedReveals; id <= 40 + n; ++id) {
            assertEq(permanentOutcome[id], bytes32(0));
            permanentOutcome[id] = _outcome(id);
        }
        trackedReveals = n;
    }

    function mintBatch(uint256 actorSeed, uint256 countSeed) public {
        uint256 actorIndex = bound(actorSeed, 0, 3);
        uint256 count = bound(countSeed, 1, 25);
        for (uint256 i; i < count; ++i) {
            if (pass.saleClosed() || block.timestamp >= pass.saleDeadline() || ghostMinted == 500) {
                uint256 supply = bmc.totalSupply();
                vm.prank(actors[actorIndex]);
                vm.expectRevert(ghostMinted < 40 ? V3.GenesisPhaseOver.selector : V3.SoldOut.selector);
                if (ghostMinted < 40) pass.mintGenesis();
                else pass.mintMystery();
                assertEq(bmc.totalSupply(), supply);
                ++rejectedCalls;
                break;
            }
            uint256 price = ghostMinted < 40 ? 1_000_000 ether : 350_000 ether;
            if (expectedBMC[actorIndex] < price) break;
            vm.prank(actors[actorIndex]);
            uint256 id;
            if (ghostMinted < 40) id = pass.mintGenesis();
            else (id,) = pass.mintMystery();
            ++ghostMinted;
            assertEq(id, ghostMinted);
            ghostBurned += price;
            paidBy[actorIndex] += price;
            expectedBMC[actorIndex] -= price;
            expectedOwner[id] = actors[actorIndex];
            if (id <= 40) permanentOutcome[id] = _outcome(id);
        }
        _rememberClosure();
    }

    function transferNFT(uint256 idSeed, uint256 recipientSeed, bool delegated) external {
        if (ghostMinted == 0) return;
        uint256 id = bound(idSeed, 1, ghostMinted);
        address from = expectedOwner[id];
        address to = actors[bound(recipientSeed, 0, 3)];
        bytes32 metadata = keccak256(bytes(pass.tokenURI(id)));
        if (delegated) {
            vm.prank(from);
            pass.approve(address(this), id);
            pass.transferFrom(from, to, id);
        } else {
            vm.prank(from);
            pass.safeTransferFrom(from, to, id);
        }
        expectedOwner[id] = to;
        assertEq(pass.getApproved(id), address(0));
        assertEq(keccak256(bytes(pass.tokenURI(id))), metadata, "transfer changed metadata");
        ++successfulTransfers;
    }

    function rejectUnauthorizedTransfer(uint256 idSeed, uint256 actorSeed) external {
        if (ghostMinted == 0) return;
        uint256 id = bound(idSeed, 1, ghostMinted);
        uint256 index = bound(actorSeed, 0, 3);
        if (actors[index] == expectedOwner[id]) index = (index + 1) % 4;
        vm.prank(actors[index]);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, actors[index], id));
        pass.transferFrom(expectedOwner[id], actors[index], id);
        assertEq(pass.ownerOf(id), expectedOwner[id]);
        ++rejectedCalls;
    }

    function moveBMC(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 from = bound(fromSeed, 0, 3);
        uint256 to = bound(toSeed, 0, 3);
        uint256 amount = bound(amountSeed, 0, expectedBMC[from]);
        vm.prank(actors[from]);
        bmc.transfer(actors[to], amount);
        expectedBMC[from] -= amount;
        expectedBMC[to] += amount;
    }

    function donateBMC(uint256 actorSeed, uint256 amountSeed) external {
        uint256 i = bound(actorSeed, 0, 3);
        uint256 amount = bound(amountSeed, 0, expectedBMC[i]);
        vm.prank(actors[i]);
        bmc.transfer(address(pass), amount);
        expectedBMC[i] -= amount;
        donated += amount;
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 2 days));
    }

    function closeOrRequest(bool reachDeadline) public {
        if (reachDeadline && ghostMinted > 40 && block.timestamp < pass.saleDeadline()) vm.warp(pass.saleDeadline());
        if (ghostMinted != 500 && block.timestamp < pass.saleDeadline()) {
            vm.expectRevert(bytes("not closed yet"));
            pass.closeSale();
            ++rejectedCalls;
            return;
        }
        if (!pass.saleClosed()) pass.closeSale();
        // Empty/Genesis-only seed spending is an open reported defect; no test blesses it.
        if (ghostMinted > 40 && pass.seedRequestId() == 0) pass.requestSeed();
        _rememberClosure();
    }

    function deliver(uint256 word) public {
        uint256 req = pass.seedRequestId();
        if (req == 0) return;
        if (received) {
            assertTrue(coord.redeliver(req, word));
            assertEq(pass.globalSeed(), firstSeed, "duplicate delivery rerolled seed");
        } else {
            assertTrue(coord.fulfill(req, word));
            received = true;
            firstSeed = word;
        }
        assertTrue(pass.seedReceived());
    }

    function rejectForgedDelivery(uint256 word, uint256 actorSeed) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        uint256 req = pass.seedRequestId();
        vm.prank(actors[bound(actorSeed, 0, 3)]);
        vm.expectRevert(V3.OnlyCoordinator.selector);
        pass.rawFulfillRandomWords(req, words);
        assertEq(pass.seedReceived(), received);
        if (received) assertEq(pass.globalSeed(), firstSeed);
        ++rejectedCalls;
    }

    function finalize(uint256 countSeed) public {
        uint256 count =
            countSeed == type(uint256).max || countSeed % 8 == 0 ? type(uint256).max : bound(countSeed, 0, 75);
        if (!received) {
            vm.expectRevert(bytes("seed pending"));
            pass.finalizeReveals(count);
            ++rejectedCalls;
            return;
        }
        uint256 pending = ghostMinted - 40 - trackedReveals;
        uint256 done = pass.finalizeReveals(count);
        assertEq(done, count < pending ? count : pending);
        _rememberReveals();
    }

    /// @dev End-of-sequence settlement only assumes the requested oracle word is delivered.
    /// It deliberately does not claim recovery when the sole request disappears (finding H-1).
    function settle() external {
        if (block.timestamp < pass.saleDeadline()) vm.warp(pass.saleDeadline());
        closeOrRequest(false);
        if (ghostMinted > 40) {
            deliver(0);
            finalize(type(uint256).max);
            assertEq(pass.pendingReveals(), 0);
            assertEq(pass.revealedCount(), ghostMinted - 40);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 32
/// forge-config: default.invariant.fail-on-revert = true
abstract contract CandidateV3InvariantBase is StdInvariant, Test {
    V3 pass;
    MockBMC bmc;
    SequenceCoordinator coord;
    V3SequenceHandler handler;

    function _setup(uint256 initialMints) internal {
        vm.warp(1_800_000_000);
        bmc = new MockBMC();
        coord = new SequenceCoordinator();
        pass = new V3(
            makeAddr("sequence owner"),
            address(bmc),
            address(coord),
            uint64(block.timestamp + 30 days),
            123,
            coord.KEY(),
            150_000,
            3,
            true,
            "bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u"
        );
        handler = new V3SequenceHandler(pass, bmc, coord);
        while (initialMints != 0) {
            uint256 batch = initialMints > 25 ? 25 : initialMints;
            handler.mintBatch(initialMints % 4, batch);
            initialMints -= batch;
        }
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.mintBatch.selector;
        selectors[1] = handler.transferNFT.selector;
        selectors[2] = handler.rejectUnauthorizedTransfer.selector;
        selectors[3] = handler.moveBMC.selector;
        selectors[4] = handler.donateBMC.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.closeOrRequest.selector;
        selectors[7] = handler.deliver.selector;
        selectors[8] = handler.rejectForgedDelivery.selector;
        selectors[9] = handler.finalize.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @notice Economic identities and uniqueness constrain results without reimplementing the shuffle.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function _assertBurnOwnershipInventoryAndFinality() internal view {
        uint256 minted = handler.ghostMinted();
        uint256 burned = handler.ghostBurned();
        assertEq(pass.totalMinted(), minted);
        assertEq(pass.totalSupply(), minted);
        assertLe(minted, 500);
        assertEq(pass.totalBurned(), burned);
        assertEq(
            burned, (minted < 40 ? minted : 40) * 1_000_000 ether + (minted > 40 ? minted - 40 : 0) * 350_000 ether
        );
        assertEq(bmc.totalSupply() + burned, 4 * 202_000_000 ether);
        assertEq(bmc.balanceOf(address(pass)), handler.donated());
        uint256 sumBMC = handler.donated();
        uint256 sumPaid;
        uint256 sumNFT;
        for (uint256 i; i < 4; ++i) {
            assertEq(bmc.balanceOf(handler.actors(i)), handler.expectedBMC(i));
            sumBMC += bmc.balanceOf(handler.actors(i));
            sumPaid += handler.paidBy(i);
            sumNFT += pass.balanceOf(handler.actors(i));
        }
        assertEq(sumBMC, bmc.totalSupply());
        assertEq(sumPaid, burned);
        assertEq(sumNFT, minted);
        _inventory(minted);
        assertEq(pass.seedReceived(), handler.received());
        if (handler.received()) {
            assertEq(pass.globalSeed(), handler.firstSeed());
            assertTrue(pass.saleClosed());
        }
        if (handler.closed()) {
            assertTrue(pass.saleClosed());
            assertEq(minted, handler.mintedAtClose());
            assertEq(pass.currentPrice(), 0);
            assertFalse(pass.genesisPhaseActive());
        }
    }

    function _inventory(uint256 minted) internal view {
        bool[78] memory genesis;
        bool[424] memory standard;
        uint256 mysteryGenesis;
        uint256 standards;
        uint256 pending;
        uint256[4] memory owners;
        address[4] memory actors;
        for (uint256 i; i < 4; ++i) {
            actors[i] = handler.actors(i);
        }
        uint256 revealed = pass.revealedCount();
        for (uint256 id = 1; id <= minted; ++id) {
            address holder = pass.ownerOf(id);
            assertEq(holder, handler.expectedOwner(id));
            for (uint256 i; i < 4; ++i) {
                if (holder == actors[i]) ++owners[i];
            }
            V3.Tier tier = pass.tierOf(id);
            uint256 art = pass.artworkIdOf(id);
            V3.RevealStatus status = pass.revealStatusOf(id);
            if (id <= 40) {
                assertEq(uint256(tier), id == 1 ? uint256(V3.Tier.LegendaryGenesis) : uint256(V3.Tier.Genesis));
                assertEq(art, id);
                genesis[art] = true;
            } else if (tier == V3.Tier.Pending) {
                assertEq(art, 0);
                assertEq(uint256(status), uint256(V3.RevealStatus.AwaitingRandomness));
                assertGt(id, 40 + revealed, "reveal skipped a predecessor");
                ++pending;
            } else if (tier == V3.Tier.Genesis) {
                assertGe(art, 41);
                assertLe(art, 77);
                assertFalse(genesis[art], "duplicate Genesis artwork");
                genesis[art] = true;
                ++mysteryGenesis;
            } else {
                assertEq(uint256(tier), uint256(V3.Tier.Standard));
                assertGe(art, 1);
                assertLe(art, 423);
                assertFalse(standard[art], "duplicate Standard artwork");
                standard[art] = true;
                ++standards;
            }
            if (tier != V3.Tier.Pending) {
                assertEq(uint256(status), uint256(V3.RevealStatus.Revealed));
                assertEq(
                    keccak256(abi.encode(tier, uint16(art), status)),
                    handler.permanentOutcome(id),
                    "assigned outcome changed"
                );
            }
        }
        for (uint256 i; i < 4; ++i) {
            assertEq(pass.balanceOf(actors[i]), owners[i]);
        }
        assertEq(pass.mysteryGenesisRevealed(), mysteryGenesis);
        assertEq(pass.revealedCount(), mysteryGenesis + standards);
        assertEq(pass.pendingReveals(), pending);
        assertEq(pass.remainingMysteryGenesis() + mysteryGenesis, 37);
        assertEq(pass.remainingMysteryStandard() + standards, 423);
        assertEq(pass.remainingSupply() + minted, 500);
    }

    function afterInvariant() public {
        handler.settle();
        _assertBurnOwnershipInventoryAndFinality();
    }
}

contract CandidateV3SaleInvariantTest is CandidateV3InvariantBase {
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.shrink-run-limit = 256
    function invariant_BurnOwnershipInventoryAndFinality() public view {
        _assertBurnOwnershipInventoryAndFinality();
    }

    function setUp() public {
        _setup(0);
    }

    function test_HandlerExercisesBothPhasesRejectionsTransfersAndSettlement() public {
        handler.mintBatch(0, 25);
        handler.mintBatch(1, 17);
        handler.transferNFT(41, 2, true);
        handler.rejectUnauthorizedTransfer(41, 3);
        handler.rejectForgedDelivery(999, 3);
        handler.finalize(1);
        handler.closeOrRequest(true);
        handler.deliver(0);
        handler.finalize(1);
        handler.deliver(type(uint256).max);
        handler.mintBatch(0, 1);
        handler.settle();
        _assertBurnOwnershipInventoryAndFinality();
        assertEq(handler.successfulTransfers(), 1);
        assertEq(handler.rejectedCalls(), 4);
        assertEq(pass.totalMinted(), 42);
        assertEq(pass.revealedCount(), 2);
    }
}

contract CandidateV3PendingInvariantTest is CandidateV3InvariantBase {
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.shrink-run-limit = 256
    function invariant_BurnOwnershipInventoryAndFinality() public view {
        _assertBurnOwnershipInventoryAndFinality();
    }

    function setUp() public {
        _setup(41);
    }
}

contract CandidateV3SelloutInvariantTest is CandidateV3InvariantBase {
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.shrink-run-limit = 256
    function invariant_BurnOwnershipInventoryAndFinality() public view {
        _assertBurnOwnershipInventoryAndFinality();
    }

    function setUp() public {
        _setup(499);
    }
}
