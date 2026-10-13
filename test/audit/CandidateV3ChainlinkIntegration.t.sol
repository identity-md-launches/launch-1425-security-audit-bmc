// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {SubscriptionAPI} from "@chainlink/contracts/src/v0.8/vrf/dev/SubscriptionAPI.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {BMCIlluminatiPassCandidateV3 as V3} from "./fixtures/BMCIlluminatiPassCandidateV3.sol";
import {MockBMC} from "../mocks/MockBMC.sol";
import {RegisteredChainlinkMock} from "./helpers/V3SecurityMocks.sol";

/// @notice Offline ABI, subscription and billing checks. This mock does not prove oracle
/// availability, service expiry, valid VRF proofs, gas-lane pricing or Mainnet acceptance.
contract CandidateV3ChainlinkIntegrationTest is Test {
    MockBMC bmc;
    RegisteredChainlinkMock coord;
    V3 pass;
    uint256 sub;
    address buyer = makeAddr("V3 official mock buyer");
    address subOwner = makeAddr("V3 official mock subscription admin");

    function setUp() public {
        vm.warp(1_800_000_000);
        bmc = new MockBMC();
        coord = new RegisteredChainlinkMock();
        vm.prank(subOwner);
        sub = coord.createSubscription();
    }

    function _setupSale(bool nativePayment) internal {
        pass = new V3(
            address(this),
            address(bmc),
            address(coord),
            uint64(block.timestamp + 30 days),
            sub,
            coord.KEY(),
            150_000,
            3,
            nativePayment,
            "bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u"
        );
        bmc.mint(buyer, 40_350_000 ether);
        vm.startPrank(buyer);
        bmc.approve(address(pass), 40_350_000 ether);
        for (uint256 i; i < 40; ++i) {
            pass.mintGenesis();
        }
        pass.mintMystery();
        vm.stopPrank();
        vm.warp(pass.saleDeadline());
    }

    function _fundAndRegister(bool nativePayment) internal {
        vm.prank(subOwner);
        coord.addConsumer(sub, address(pass));
        if (nativePayment) {
            vm.deal(address(this), 1 ether);
            coord.fundSubscriptionWithNative{value: 1 ether}(sub);
        } else {
            coord.fundSubscription(sub, 100 ether);
        }
    }

    function _checkRequestEvent(Vm.Log[] memory entries, uint256 req, bool nativePayment) internal view {
        bytes32 signature =
            keccak256("RandomWordsRequested(bytes32,uint256,uint256,uint256,uint16,uint32,uint32,bytes,address)");
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter != address(coord) || entries[i].topics[0] != signature) continue;
            found = true;
            assertEq(entries[i].topics[1], coord.KEY());
            assertEq(uint256(entries[i].topics[2]), sub);
            assertEq(address(uint160(uint256(entries[i].topics[3]))), address(pass));
            (uint256 id,, uint16 conf, uint32 gasLimit, uint32 numWords, bytes memory extra) =
                abi.decode(entries[i].data, (uint256, uint256, uint16, uint32, uint32, bytes));
            assertEq(id, req);
            assertEq(conf, 3);
            assertEq(gasLimit, 150_000);
            assertEq(numWords, 1);
            assertEq(extra, VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1(nativePayment)));
        }
        assertTrue(found, "real mock must emit the expected request ABI");
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_V25RequestAndBillingUsesConfiguredCurrency(bool nativePayment) public {
        _setupSale(nativePayment);
        _fundAndRegister(nativePayment);
        (uint96 linkBefore, uint96 nativeBefore,,,) = coord.getSubscription(sub);
        vm.recordLogs();
        uint256 req = pass.requestSeed();
        _checkRequestEvent(vm.getRecordedLogs(), req, nativePayment);
        uint256[] memory words = new uint256[](1); // A zero word is a valid result.
        coord.fulfillRandomWordsWithOverride(req, address(pass), words);
        assertTrue(pass.seedReceived());
        assertEq(pass.globalSeed(), 0);
        assertEq(pass.finalizeReveals(500), 1);
        assertEq(pass.pendingReveals(), 0);
        assertEq(pass.totalBurned(), 40_350_000 ether);
        (uint96 linkAfter, uint96 nativeAfter,,,) = coord.getSubscription(sub);
        if (nativePayment) {
            assertLt(nativeAfter, nativeBefore);
            assertEq(linkAfter, linkBefore);
        } else {
            assertLt(linkAfter, linkBefore);
            assertEq(nativeAfter, nativeBefore);
        }
        vm.expectRevert(VRFCoordinatorV2_5Mock.InvalidRequest.selector);
        coord.fulfillRandomWords(req, address(pass));
    }

    function test_MissingConsumerSubmissionCanRecoverByRegistration() public {
        _setupSale(true);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionAPI.InvalidConsumer.selector, sub, address(pass)));
        pass.requestSeed();
        assertEq(pass.seedRequestId(), 0);
        assertFalse(pass.saleClosed());
        _fundAndRegister(true);
        uint256 req = pass.requestSeed();
        coord.fulfillRandomWords(req, address(pass));
        assertEq(pass.finalizeReveals(500), 1);
        assertEq(pass.pendingReveals(), 0);
    }

    function test_ImmediateFundingAfterInsufficientBalanceRecoversWithinMock() public {
        _setupSale(true);
        vm.prank(subOwner);
        coord.addConsumer(sub, address(pass));
        uint256 req = pass.requestSeed();
        vm.expectRevert(SubscriptionAPI.InsufficientBalance.selector);
        coord.fulfillRandomWords(req, address(pass));
        assertFalse(pass.seedReceived(), "failed billing reverts callback state too");
        vm.deal(address(this), 1 ether);
        coord.fundSubscriptionWithNative{value: 1 ether}(sub);
        // No warp here: funding this mock immediately proves nothing about service expiry.
        coord.fulfillRandomWords(req, address(pass));
        assertEq(pass.finalizeReveals(1), 1);
    }

    function test_UnregisteredLaneSubmissionIsAtomicThenWorksWhenLaneReturns() public {
        _setupSale(true);
        _fundAndRegister(true);
        coord.setRegistered(false);
        vm.expectRevert(bytes("unregistered gas lane"));
        pass.requestSeed();
        assertEq(pass.seedRequestId(), 0);
        assertFalse(pass.saleClosed());
        coord.setRegistered(true);
        uint256 req = pass.requestSeed();
        coord.fulfillRandomWords(req, address(pass));
        assertEq(pass.finalizeReveals(1), 1);
    }
}
