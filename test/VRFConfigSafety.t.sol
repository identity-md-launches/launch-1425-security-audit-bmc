// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BMCIlluminatiPass} from "../src/BMCIlluminatiPass.sol";
import {MockBMC} from "./mocks/MockBMC.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

contract VRFConfigSafetyTest is Test {
    MockBMC bmc;
    MockVRFCoordinator coord;
    BMCIlluminatiPass pass;
    address owner = makeAddr("configuration safety owner");
    address buyer = makeAddr("configuration safety buyer");
    bytes32 constant KEY = keccak256("registered safety lane");
    bytes32 constant BAD_KEY = keccak256("unregistered safety lane");

    function setUp() public {
        bmc = new MockBMC();
        coord = new MockVRFCoordinator();
        coord.setLaneRegistered(BAD_KEY, false);
        pass = new BMCIlluminatiPass(owner, address(bmc), address(coord), 123, KEY, 500_000, 3, true);
        _phase1();
    }

    function _phase1() internal {
        bmc.mint(buyer, 201_000_000 ether);
        vm.startPrank(buyer);
        bmc.approve(address(pass), 201_000_000 ether);
        for (uint256 i; i < 40; ++i) {
            pass.mintGenesis();
        }
        vm.stopPrank();
    }

    function _assertMintRolledBack() internal {
        uint256 supply = bmc.totalSupply();
        uint256 balance = bmc.balanceOf(buyer);
        uint256 allowance = bmc.allowance(buyer, address(pass));
        uint256 count = pass.totalMinted();
        uint256 burned = pass.totalBurned();
        uint256 nextReq = coord.nextRequestId();
        vm.prank(buyer);
        vm.expectRevert();
        pass.mintMystery();
        assertEq(bmc.totalSupply(), supply);
        assertEq(bmc.balanceOf(buyer), balance);
        assertEq(bmc.allowance(buyer, address(pass)), allowance);
        assertEq(pass.totalMinted(), count);
        assertEq(pass.totalBurned(), burned);
        assertEq(pass.requestIdOf(count + 1), 0);
        assertEq(pass.lastRequestAt(count + 1), 0);
        assertEq(coord.nextRequestId(), nextReq);
    }

    function test_UnregisteredConstructorLaneRefusesMintAndRollsBackBurn() public {
        // No coordinator query is needed to deploy, even with an unregistered constructor word.
        pass = new BMCIlluminatiPass(owner, address(bmc), address(coord), 123, BAD_KEY, 500_000, 3, true);
        _phase1();
        _assertMintRolledBack();
    }

    function test_OwnerTypoRefusesMintUntilLaneRepaired() public {
        vm.prank(owner);
        pass.setVRFConfig(123, BAD_KEY, 500_000, 3, true);
        _assertMintRolledBack();
        vm.prank(owner);
        pass.setVRFConfig(123, KEY, 500_000, 3, true);
        vm.prank(buyer);
        (uint256 id, uint256 req) = pass.mintMystery();
        assertEq(id, 41);
        assertTrue(coord.fulfill(req, 7));
        assertEq(pass.revealedCount(), 1);
    }

    function test_RetiredLaneRefusesMintAndRetryWithoutLosingOriginalRequest() public {
        vm.prank(buyer);
        (uint256 id, uint256 original) = pass.mintMystery();
        coord.setLaneRegistered(KEY, false);
        _assertMintRolledBack();
        uint256 timestamp = pass.lastRequestAt(id);
        uint256 nextReq = coord.nextRequestId();
        vm.warp(timestamp + 1 days);
        vm.expectRevert(bytes("unregistered gas lane"));
        pass.rerequestRandomness(id);
        assertEq(pass.lastRequestAt(id), timestamp);
        assertEq(pass.requestIdOf(id), original);
        assertEq(pass.tokenIdOfRequest(original), id);
        assertEq(coord.nextRequestId(), nextReq);
        coord.setLaneRegistered(BAD_KEY, true);
        vm.prank(owner);
        pass.setVRFConfig(456, BAD_KEY, 500_000, 3, true);
        uint256 retry = pass.rerequestRandomness(id);
        assertTrue(retry != original);
        assertTrue(coord.fulfill(original, 9));
        uint16 artwork = pass.artworkIdOf(id);
        assertTrue(coord.fulfill(retry, 10));
        assertEq(pass.artworkIdOf(id), artwork);
        assertEq(pass.totalBurned(), 40_350_000 ether);
    }

    function test_RevertingLaneLookupRollsBackMint() public {
        vm.mockCallRevert(
            address(coord), abi.encodeWithSignature("s_provingKeys(bytes32)", KEY), bytes("lookup failed")
        );
        _assertMintRolledBack();
    }

    function test_EmptyOrShortLaneLookupRollsBackMint() public {
        bytes memory lookup = abi.encodeWithSignature("s_provingKeys(bytes32)", KEY);
        vm.mockCall(address(coord), lookup, bytes(""));
        _assertMintRolledBack();
        vm.mockCall(address(coord), lookup, abi.encode(true));
        _assertMintRolledBack();
    }

    function test_MalformedLaneTupleRollsBackMint() public {
        bytes memory lookup = abi.encodeWithSignature("s_provingKeys(bytes32)", KEY);
        vm.mockCall(address(coord), lookup, abi.encode(uint256(2), uint256(500 gwei)));
        _assertMintRolledBack();
        vm.mockCall(address(coord), lookup, abi.encode(true, type(uint256).max));
        _assertMintRolledBack();
    }

    function test_MissingCoordinatorCodeRefusesMysteryMintAfterEmptyChainDeployment() public {
        pass = new BMCIlluminatiPass(owner, address(bmc), makeAddr("codeless coordinator"), 123, KEY, 500_000, 3, true);
        _phase1();
        _assertMintRolledBack();
    }

    function test_TwoStepHandoffKeepsRepairWithCurrentOwnerUntilAcceptance() public {
        address recipient = makeAddr("proposed owner");
        address outsider = makeAddr("outsider");
        vm.prank(owner);
        pass.transferOwnership(recipient);
        assertEq(pass.owner(), owner);
        assertEq(pass.pendingOwner(), recipient);
        vm.prank(owner);
        pass.setVRFConfig(456, KEY, 500_000, 3, false);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, recipient));
        pass.setVRFConfig(789, KEY, 500_000, 3, true);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        pass.acceptOwnership();
        vm.prank(recipient);
        pass.acceptOwnership();
        assertEq(pass.owner(), recipient);
        assertEq(pass.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        pass.setVRFConfig(789, KEY, 500_000, 3, true);
        vm.prank(recipient);
        pass.setVRFConfig(789, KEY, 500_000, 3, true);
    }

    function test_MistypedHandoffCanBeCancelledOrReplacedWithoutLosingRepair() public {
        address unintended = makeAddr("mistyped proposed owner");
        address correct = makeAddr("correct proposed owner");
        vm.startPrank(owner);
        pass.transferOwnership(unintended);
        assertEq(pass.owner(), owner);
        pass.setVRFConfig(456, KEY, 500_000, 3, true);
        pass.transferOwnership(address(0)); // Ownable2Step cancels a proposal, never the owner.
        assertEq(pass.owner(), owner);
        assertEq(pass.pendingOwner(), address(0));
        pass.transferOwnership(correct);
        vm.stopPrank();
        vm.prank(unintended);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unintended));
        pass.acceptOwnership();
        assertEq(pass.owner(), owner);
    }

    function test_RenounceCannotRemoveRecoveryRole() public {
        vm.prank(owner);
        vm.expectRevert(BMCIlluminatiPass.OwnershipRenunciationDisabled.selector);
        pass.renounceOwnership();
        assertEq(pass.owner(), owner);
        vm.prank(owner);
        pass.setVRFConfig(456, KEY, 500_000, 3, true);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        pass.renounceOwnership();
        assertEq(pass.owner(), owner);
    }
}
