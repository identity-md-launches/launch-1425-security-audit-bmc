// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BMCIlluminatiPassCandidateV3 as V3} from "./fixtures/BMCIlluminatiPassCandidateV3.sol";
import {IBMCToken} from "../../src/interfaces/IBMCToken.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {SubscriptionAPI} from "@chainlink/contracts/src/v0.8/vrf/dev/SubscriptionAPI.sol";

interface IMainnetVRFLane {
    function s_provingKeys(bytes32 key) external view returns (bool, uint64);
    function LINK() external view returns (address);
}

/// @notice Fork simulation only. No keys, broadcasts or RPC writes. Use the report's pinned block.
contract CandidateV3MainnetForkTest is Test {
    address constant BMC = 0x38224239f2BDae357D47cb864BC533d7f72dF961;
    address constant COORDINATOR = 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a;
    address constant OWNER = 0x83027AD9d0D5374335086c539dADD1db983441B0;
    bytes32 constant KEY = 0x3fd2fec10d06ee8f65e7f2e95f5c56511359ece3f33960ad8a866ae24a8ff10b;
    uint256 constant SUB = 27852459484169864437638942739291618120641810244677084392617474192083559562985;
    IBMCToken token = IBMCToken(BMC);
    IVRFCoordinatorV2Plus vrf = IVRFCoordinatorV2Plus(COORDINATOR);
    address buyer = makeAddr("IdentityMD isolated V3 fork buyer 2026-10-12");
    V3 pass;

    function setUp() public {
        if (block.chainid != 1) {
            vm.skip(true);
            return;
        }
        require(BMC.code.length != 0 && COORDINATOR.code.length != 0, "mainnet state required");
        require(buyer.code.length == 0, "fork test buyer must have no code");
        pass = new V3(
            OWNER,
            BMC,
            COORDINATOR,
            uint64(block.timestamp + 30 days),
            SUB,
            KEY,
            500_000,
            3,
            true,
            "bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u"
        );
    }

    function _mint41() internal {
        // Only balances on the local fork are changed; live bytecode executes burnFrom.
        deal(BMC, buyer, 40_350_000 ether, true);
        uint256 supply = token.totalSupply();
        vm.startPrank(buyer);
        token.approve(address(pass), 40_350_000 ether);
        for (uint256 i; i < 40; ++i) {
            pass.mintGenesis();
        }
        pass.mintMystery();
        vm.stopPrank();
        assertEq(token.totalSupply(), supply - 40_350_000 ether);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.allowance(buyer, address(pass)), 0);
        assertEq(pass.totalBurned(), 40_350_000 ether);
    }

    function test_LiveCoordinatorLaneAndSubscription() public {
        assertEq(token.decimals(), 18);
        assertEq(IMainnetVRFLane(COORDINATOR).LINK(), 0x514910771AF9Ca656af840dff83E8264EcF986CA);
        (bool exists, uint64 maxGas) = IMainnetVRFLane(COORDINATOR).s_provingKeys(KEY);
        assertTrue(exists);
        assertEq(maxGas, 500 gwei);
        (uint96 linkBalance, uint96 nativeBalance,, address subOwner, address[] memory consumers) =
            vrf.getSubscription(SUB);
        assertEq(subOwner, OWNER);
        emit log_named_uint("LINK balance", linkBalance);
        emit log_named_uint("Native balance", nativeBalance);
        emit log_named_uint("Consumers", consumers.length);
    }

    function test_BurnsPersistWhenUnregisteredConsumerCannotRequestSeed() public {
        _mint41();
        vm.warp(pass.saleDeadline());
        vm.expectRevert(abi.encodeWithSelector(SubscriptionAPI.InvalidConsumer.selector, SUB, address(pass)));
        pass.requestSeed();
        assertEq(pass.totalBurned(), 40_350_000 ether);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(pass.seedRequestId(), 0);
        assertEq(uint256(pass.tierOf(41)), uint256(V3.Tier.Pending));
    }

    function test_LiveCoordinatorAcceptsV25RequestAfterLocalRegistrationAndFunding() public {
        _mint41();
        (,,, address subOwner,) = vrf.getSubscription(SUB);
        vm.prank(subOwner);
        vrf.addConsumer(SUB, address(pass));
        vm.deal(address(this), 1 ether);
        vrf.fundSubscriptionWithNative{value: 1 ether}(SUB);
        vm.warp(pass.saleDeadline());
        uint256 req = pass.requestSeed();
        assertTrue(req != 0);
        assertEq(pass.seedRequestId(), req);
        assertFalse(pass.seedReceived()); // No oracle fulfillment is simulated or claimed here.
    }

    function test_CancelledSubscriptionCannotBeReplacedInV3() public {
        _mint41();
        (,,, address subOwner,) = vrf.getSubscription(SUB);
        vm.prank(subOwner);
        vrf.cancelSubscription(SUB, subOwner);
        vm.warp(pass.saleDeadline());
        vm.expectRevert(SubscriptionAPI.InvalidSubscription.selector);
        pass.requestSeed();
        vm.prank(OWNER);
        (bool ok,) = address(pass)
            .call(
                abi.encodeWithSignature(
                    "setVRFConfig(uint256,bytes32,uint32,uint16,bool)", SUB, KEY, uint32(150_000), uint16(3), true
                )
            );
        assertFalse(ok);
        assertFalse(pass.seedReceived());
    }
}
