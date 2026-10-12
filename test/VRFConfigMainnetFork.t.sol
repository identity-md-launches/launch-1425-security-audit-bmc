// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BMCIlluminatiPass} from "../src/BMCIlluminatiPass.sol";
import {IBMCToken} from "../src/interfaces/IBMCToken.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

interface ILiveLaneRegistry {
    function s_provingKeys(bytes32 key) external view returns (bool, uint64);
    function s_requestCommitments(uint256 id) external view returns (bytes32);
}

/// @dev Deliberately omits lane validation to demonstrate the coordinator's request behavior.
///      Test-only probe on a local fork; never a deployment candidate or broadcast.
contract UncheckedLaneRequestProbe {
    function request(IVRFCoordinatorV2Plus coord, uint256 sub, bytes32 key) external returns (uint256) {
        return coord.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: key,
                subId: sub,
                requestConfirmations: 3,
                callbackGasLimit: 500_000,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
            })
        );
    }
}

contract VRFConfigMainnetForkTest is Test {
    address constant BMC = 0x38224239f2BDae357D47cb864BC533d7f72dF961;
    address constant COORDINATOR = 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a;
    bytes32 constant KEY = 0x3fd2fec10d06ee8f65e7f2e95f5c56511359ece3f33960ad8a866ae24a8ff10b;
    bytes32 constant BAD_KEY = keccak256("not a registered mainnet lane");
    IVRFCoordinatorV2Plus coord = IVRFCoordinatorV2Plus(COORDINATOR);
    IBMCToken bmc = IBMCToken(BMC);
    address buyer = makeAddr("isolated revision real BMC buyer 2026-10-12");
    uint256 sub;
    BMCIlluminatiPass pass;

    function setUp() public {
        if (block.chainid != 1) {
            vm.skip(true);
            return;
        }
        require(BMC.code.length != 0 && COORDINATOR.code.length != 0, "mainnet state required");
        require(buyer.code.length == 0, "buyer must be isolated");
        sub = coord.createSubscription();
        (bool exists,) = ILiveLaneRegistry(COORDINATOR).s_provingKeys(BAD_KEY);
        assertFalse(exists);
    }

    function _deployAndMintGenesis(bytes32 lane) internal {
        pass = new BMCIlluminatiPass(address(this), BMC, COORDINATOR, sub, lane, 500_000, 3, true);
        coord.addConsumer(sub, address(pass));
        deal(BMC, buyer, 40_700_000 ether, true);
        vm.startPrank(buyer);
        bmc.approve(address(pass), 40_700_000 ether);
        for (uint256 i; i < 40; ++i) {
            pass.mintGenesis();
        }
        vm.stopPrank();
    }

    function _fund() internal {
        vm.deal(address(this), 1 ether);
        coord.fundSubscriptionWithNative{value: 1 ether}(sub);
    }

    function _assertBadLaneMintRollsBack() internal {
        uint256 balance = bmc.balanceOf(buyer);
        uint256 supply = bmc.totalSupply();
        uint256 allowance = bmc.allowance(buyer, address(pass));
        uint256 count = pass.totalMinted();
        uint256 burned = pass.totalBurned();
        vm.prank(buyer);
        vm.expectRevert(bytes("unregistered gas lane"));
        pass.mintMystery();
        assertEq(bmc.balanceOf(buyer), balance);
        assertEq(bmc.totalSupply(), supply);
        assertEq(bmc.allowance(buyer, address(pass)), allowance);
        assertEq(pass.totalMinted(), count);
        assertEq(pass.totalBurned(), burned);
        assertEq(pass.requestIdOf(count + 1), 0);
    }

    function test_LiveCoordinatorStillAcceptsUnregisteredLaneWithoutConsumerGuard() public {
        UncheckedLaneRequestProbe probe = new UncheckedLaneRequestProbe();
        coord.addConsumer(sub, address(probe));
        _fund();
        uint256 req = probe.request(coord, sub, BAD_KEY);
        assertTrue(req != 0);
        assertTrue(ILiveLaneRegistry(COORDINATOR).s_requestCommitments(req) != bytes32(0));
        assertTrue(coord.pendingRequestExists(sub));
        // No real oracle proof or off-chain fulfillment is claimed.
    }

    function test_UnregisteredConstructorLaneRollsBackRealBMCBurn() public {
        _deployAndMintGenesis(BAD_KEY);
        _fund();
        _assertBadLaneMintRollsBack();
        assertFalse(coord.pendingRequestExists(sub));
        pass.setVRFConfig(sub, KEY, 500_000, 3, true);
        vm.prank(buyer);
        (uint256 id, uint256 req) = pass.mintMystery();
        assertEq(id, 41);
        assertTrue(ILiveLaneRegistry(COORDINATOR).s_requestCommitments(req) != bytes32(0));
        assertEq(bmc.balanceOf(buyer), 350_000 ether);
    }

    function test_BadSetterLaneRefusesRealMintAndRetryUntilRepair() public {
        _deployAndMintGenesis(KEY);
        _fund();
        vm.prank(buyer);
        (uint256 id, uint256 first) = pass.mintMystery();
        pass.setVRFConfig(sub, BAD_KEY, 500_000, 3, true);
        _assertBadLaneMintRollsBack();
        uint256 requestedAt = pass.lastRequestAt(id);
        vm.warp(requestedAt + 1 days);
        vm.expectRevert(bytes("unregistered gas lane"));
        pass.rerequestRandomness(id);
        assertEq(pass.lastRequestAt(id), requestedAt);
        assertEq(pass.requestIdOf(id), first);
        assertEq(pass.tokenIdOfRequest(first), id);
        pass.setVRFConfig(sub, KEY, 500_000, 3, true);
        uint256 supply = bmc.totalSupply();
        uint256 retry = pass.rerequestRandomness(id);
        assertTrue(retry != first);
        assertTrue(ILiveLaneRegistry(COORDINATOR).s_requestCommitments(retry) != bytes32(0));
        assertEq(bmc.totalSupply(), supply);
        assertEq(bmc.balanceOf(buyer), 350_000 ether);
        assertEq(pass.totalBurned(), 40_350_000 ether);
    }

    function test_ZeroNativeFundingStillAcceptsRequestAndCommitsBurn() public {
        _deployAndMintGenesis(KEY);
        (uint96 link, uint96 nativeBalance,,,) = coord.getSubscription(sub);
        assertEq(link, 0);
        assertEq(nativeBalance, 0);
        uint256 supply = bmc.totalSupply();
        vm.prank(buyer);
        (uint256 id, uint256 req) = pass.mintMystery();
        assertTrue(ILiveLaneRegistry(COORDINATOR).s_requestCommitments(req) != bytes32(0));
        assertEq(bmc.totalSupply(), supply - 350_000 ether);
        assertEq(bmc.balanceOf(buyer), 350_000 ether);
        assertEq(uint256(pass.revealStatusOf(id)), uint256(BMCIlluminatiPass.RevealStatus.AwaitingRandomness));
    }
}
