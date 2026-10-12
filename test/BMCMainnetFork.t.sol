// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BMCIlluminatiPass} from "../src/BMCIlluminatiPass.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";

interface IRealBMC {
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract BMCMainnetForkTest is Test {
    address constant BMC = 0x38224239f2BDae357D47cb864BC533d7f72dF961;

    address constant VRF = 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a;

    uint256 constant PRICE = 1_000_000e18;

    address buyer = address(0xBEEF);

    function test_RealBMCGenesisMint() public {
        // Offline CI skips this integration check explicitly; run with --fork-url to exercise it.
        if (block.chainid != 1) {
            vm.skip(true);
            return;
        }
        require(BMC.code.length > 0, "BMC contract missing");
        require(VRF.code.length > 0, "VRF coordinator missing");

        IRealBMC token = IRealBMC(BMC);
        assertEq(token.decimals(), 18);

        BMCIlluminatiPass pass = new BMCIlluminatiPass(
            address(this),
            BMC,
            VRF,
            27852459484169864437638942739291618120641810244677084392617474192083559562985,
            0x3fd2fec10d06ee8f65e7f2e95f5c56511359ece3f33960ad8a866ae24a8ff10b,
            500_000,
            3,
            true
        );

        // Test-only balance adjustment on the local fork.
        deal(BMC, buyer, PRICE, true);

        assertEq(token.balanceOf(buyer), PRICE);

        uint256 supplyBefore = token.totalSupply();

        vm.startPrank(buyer);
        token.approve(address(pass), PRICE);
        uint256 tokenId = pass.mintGenesis();
        vm.stopPrank();

        assertEq(tokenId, 1);
        assertEq(pass.ownerOf(1), buyer);
        assertEq(pass.totalBurned(), PRICE);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.totalSupply(), supplyBefore - PRICE);
    }

    function test_RealBMCMysteryMintAndRetryWithoutAnotherBurn() public {
        if (block.chainid != 1) {
            vm.skip(true);
            return;
        }
        require(BMC.code.length > 0 && VRF.code.length > 0, "mainnet state required");
        uint256 sub = 27852459484169864437638942739291618120641810244677084392617474192083559562985;
        bytes32 key = 0x3fd2fec10d06ee8f65e7f2e95f5c56511359ece3f33960ad8a866ae24a8ff10b;
        BMCIlluminatiPass pass = new BMCIlluminatiPass(address(this), BMC, VRF, sub, key, 500_000, 3, true);
        IVRFCoordinatorV2Plus coordinator = IVRFCoordinatorV2Plus(VRF);
        (,,, address subOwner,) = coordinator.getSubscription(sub);
        vm.prank(subOwner);
        coordinator.addConsumer(sub, address(pass));
        vm.deal(address(this), 1 ether);
        coordinator.fundSubscriptionWithNative{value: 1 ether}(sub);
        IRealBMC token = IRealBMC(BMC);
        deal(BMC, buyer, 40_350_000 ether, true);
        vm.startPrank(buyer);
        token.approve(address(pass), 40_350_000 ether);
        for (uint256 i; i < 40; ++i) {
            pass.mintGenesis();
        }
        (uint256 id, uint256 original) = pass.mintMystery();
        vm.stopPrank();
        uint256 supply = token.totalSupply();
        assertEq(id, 41);
        assertEq(token.balanceOf(buyer), 0);
        vm.warp(block.timestamp + pass.RETRY_DELAY());
        uint256 retry = pass.rerequestRandomness(id);
        assertTrue(retry != original);
        assertEq(pass.tokenIdOfRequest(original), id);
        assertEq(pass.tokenIdOfRequest(retry), id);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(pass.totalBurned(), 40_350_000 ether);
    }
}
