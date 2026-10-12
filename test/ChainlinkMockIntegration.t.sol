// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {SubscriptionAPI} from "@chainlink/contracts/src/v0.8/vrf/dev/SubscriptionAPI.sol";
import {BMCIlluminatiPass} from "../src/BMCIlluminatiPass.sol";
import {MockBMC} from "./mocks/MockBMC.sol";
import {LaneAwareVRFCoordinatorV2_5Mock} from "./mocks/LaneAwareVRFCoordinatorV2_5Mock.sol";

/// @notice End-to-end check against Chainlink's own VRF v2.5 coordinator mock: subscription
///         creation, consumer registration, request ABI, fulfillment callback and the "unfunded
///         subscription" failure path.
contract ChainlinkMockIntegrationTest is Test {
    MockBMC bmc;
    VRFCoordinatorV2_5Mock coordinator;
    BMCIlluminatiPass pass;
    uint256 subId;

    address owner = makeAddr("owner");
    address subOwner = makeAddr("subscriptionOwner");
    address alice = makeAddr("alice");

    function setUp() public {
        bmc = new MockBMC();
        // base fee 0.1 LINK, gas price 1 gwei, 4e15 wei per LINK
        coordinator = new LaneAwareVRFCoordinatorV2_5Mock();

        vm.startPrank(subOwner);
        subId = coordinator.createSubscription();
        vm.stopPrank();
        pass = new BMCIlluminatiPass(
            owner, address(bmc), address(coordinator), subId, keccak256("lane"), 500_000, 3, false
        );
        vm.prank(subOwner);
        coordinator.addConsumer(subId, address(pass));

        for (uint256 i = 0; i < 40; i++) {
            address who = address(uint160(0x7000 + i));
            bmc.mint(who, 1_000_000e18);
            vm.startPrank(who);
            bmc.approve(address(pass), 1_000_000e18);
            pass.mintGenesis();
            vm.stopPrank();
        }
    }

    function _mystery() internal returns (uint256 id, uint256 req) {
        bmc.mint(alice, 350_000e18);
        vm.startPrank(alice);
        bmc.approve(address(pass), 350_000e18);
        (id, req) = pass.mintMystery();
        vm.stopPrank();
    }

    /// @dev Exercises immediate funding only. This official mock does not model the oracle's
    ///      24-hour request expiry. Expiry and recovery are covered in VRFRecovery.t.sol.
    function test_ImmediateFundingAllowsMockFulfillment() public {
        (uint256 id, uint256 req) = _mystery();
        assertEq(uint8(pass.revealStatusOf(id)), uint8(BMCIlluminatiPass.RevealStatus.AwaitingRandomness));
        vm.expectRevert(SubscriptionAPI.InsufficientBalance.selector);
        coordinator.fulfillRandomWords(req, address(pass));
        assertEq(uint8(pass.tierOf(id)), uint8(BMCIlluminatiPass.Tier.Pending));
        assertEq(pass.finalizeReveals(5), 0);
        // Fund immediately, before any service expiry; then deliver the original request.
        coordinator.fundSubscription(subId, 100 ether);
        coordinator.fulfillRandomWords(req, address(pass));
        assertEq(uint8(pass.revealStatusOf(id)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
    }

    function test_NotAConsumerReverts() public {
        vm.prank(subOwner);
        coordinator.removeConsumer(subId, address(pass));
        coordinator.fundSubscription(subId, 100 ether);
        bmc.mint(alice, 350_000e18);
        vm.startPrank(alice);
        bmc.approve(address(pass), 350_000e18);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionAPI.InvalidConsumer.selector, subId, address(pass)));
        pass.mintMystery();
        vm.stopPrank();
        assertEq(bmc.balanceOf(alice), 350_000e18, "burn rolled back");
        assertEq(pass.totalMinted(), 40);
    }

    /// @dev Accepted recovery trade-off: the coordinator bills both valid requests even when
    ///      the consumer ignores the late word. Amounts are mock pricing, not Mainnet estimates.
    function test_UnfundedMintAndPermissionlessRetryCanChargeForIgnoredDelivery() public {
        bmc.mint(alice, 350_000 ether);
        uint256 balance = bmc.balanceOf(alice);
        uint256 supply = bmc.totalSupply();
        vm.startPrank(alice);
        bmc.approve(address(pass), 350_000 ether);
        (uint256 id, uint256 first) = pass.mintMystery();
        vm.stopPrank();
        assertEq(bmc.balanceOf(alice), balance - 350_000 ether);
        assertEq(bmc.totalSupply(), supply - 350_000 ether);
        assertEq(pass.totalBurned(), 40_350_000 ether);
        vm.expectRevert(SubscriptionAPI.InsufficientBalance.selector);
        coordinator.fulfillRandomWords(first, address(pass));
        vm.warp(block.timestamp + 1 days);
        address unrelatedCaller = makeAddr("unrelated retry sponsor");
        vm.prank(unrelatedCaller);
        uint256 retry = pass.rerequestRandomness(id);
        assertTrue(retry != first);
        assertEq(pass.lastRequestAt(id), block.timestamp);
        vm.expectRevert(SubscriptionAPI.InsufficientBalance.selector);
        coordinator.fulfillRandomWords(retry, address(pass));
        coordinator.fundSubscription(subId, 100 ether);
        (uint96 before,,,,) = coordinator.getSubscription(subId);
        coordinator.fulfillRandomWords(first, address(pass));
        (uint96 afterFirst,,,,) = coordinator.getSubscription(subId);
        uint16 artwork = pass.artworkIdOf(id);
        coordinator.fulfillRandomWords(retry, address(pass));
        (uint96 afterRetry,,,,) = coordinator.getSubscription(subId);
        assertLt(afterFirst, before);
        assertLt(afterRetry, afterFirst, "ignored delivery still charged");
        assertEq(pass.revealedCount(), 1);
        assertEq(pass.artworkIdOf(id), artwork);
        assertEq(pass.totalBurned(), 40_350_000 ether);
    }

    function test_RequestAndFulfilThroughChainlinkMock() public {
        coordinator.fundSubscription(subId, 100 ether);
        (uint256 id, uint256 req) = _mystery();
        assertEq(uint8(pass.revealStatusOf(id)), uint8(BMCIlluminatiPass.RevealStatus.AwaitingRandomness));

        coordinator.fulfillRandomWords(req, address(pass));
        assertEq(uint8(pass.revealStatusOf(id)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
        assertTrue(pass.tierOf(id) != BMCIlluminatiPass.Tier.Pending);

        // The mock refuses to fulfil the same request twice: no reroll path exists.
        vm.expectRevert(VRFCoordinatorV2_5Mock.InvalidRequest.selector);
        coordinator.fulfillRandomWords(req, address(pass));
    }

    function test_SeveralRequestsOutOfOrderThroughChainlinkMock() public {
        coordinator.fundSubscription(subId, 100 ether);
        (uint256 a, uint256 ra) = _mystery();
        (uint256 b, uint256 rb) = _mystery();
        (uint256 c, uint256 rc) = _mystery();
        uint256[] memory w = new uint256[](1);
        w[0] = 31337;
        coordinator.fulfillRandomWordsWithOverride(rc, address(pass), w);
        assertEq(uint8(pass.revealStatusOf(c)), uint8(BMCIlluminatiPass.RevealStatus.RandomnessStored));
        w[0] = 4242;
        coordinator.fulfillRandomWordsWithOverride(rb, address(pass), w);
        assertEq(uint8(pass.revealStatusOf(b)), uint8(BMCIlluminatiPass.RevealStatus.RandomnessStored));
        w[0] = 7;
        coordinator.fulfillRandomWordsWithOverride(ra, address(pass), w);
        assertEq(uint8(pass.revealStatusOf(a)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
        assertEq(uint8(pass.revealStatusOf(b)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
        assertEq(uint8(pass.revealStatusOf(c)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
        assertEq(pass.revealedCount(), 3);
    }
}
