// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BMCIlluminatiPass} from "../src/BMCIlluminatiPass.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ApplicationFactoryProbe {
    function deploy(bytes memory initcode) external returns (address application) {
        assembly ("memory-safe") { application := create2(0, add(initcode, 32), mload(initcode), 1) }
        require(application != address(0), "constructor failed");
    }
}

contract FactoryDeploymentTest is Test {
    address owner = makeAddr("factory nominated owner");
    address bmc = makeAddr("dependency without code: BMC");
    address coordinator = makeAddr("dependency without code: VRF");
    bytes32 constant KEY = keccak256("test lane");

    function test_FactoryDeploysWithEightStaticArgumentsAndNoDependencyCalls() public {
        assertEq(bmc.code.length, 0);
        assertEq(coordinator.code.length, 0);
        ApplicationFactoryProbe factory = new ApplicationFactoryProbe();
        BMCIlluminatiPass pass = BMCIlluminatiPass(
            factory.deploy(
                abi.encodePacked(
                    type(BMCIlluminatiPass).creationCode,
                    abi.encode(owner, bmc, coordinator, uint256(123), KEY, uint32(500_000), uint16(3), true)
                )
            )
        );
        assertEq(pass.owner(), owner);
        assertTrue(pass.owner() != address(factory));
        assertEq(address(pass.BMC()), bmc);
        assertEq(address(pass.VRF_COORDINATOR()), coordinator);
        assertTrue(pass.genesisCIDLocked());
        (uint256 sub, bytes32 key, uint32 gasLimit, uint16 confirmations, bool nativePayment, bool configured) =
            pass.vrfConfig();
        assertEq(sub, 123);
        assertEq(key, KEY);
        assertEq(gasLimit, 500_000);
        assertEq(confirmations, 3);
        assertTrue(nativePayment && configured);
        bytes memory code = address(pass).code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }

    function test_ConstructorRejectsMissingOwnerOrDependencies() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BMCIlluminatiPass(address(0), bmc, coordinator, 123, KEY, 500_000, 3, true);
        vm.expectRevert(bytes("zero address"));
        new BMCIlluminatiPass(owner, address(0), coordinator, 123, KEY, 500_000, 3, true);
        vm.expectRevert(bytes("zero address"));
        new BMCIlluminatiPass(owner, bmc, address(0), 123, KEY, 500_000, 3, true);
    }

    function test_ConstructorRejectsInvalidVRFWords() public {
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        new BMCIlluminatiPass(owner, bmc, coordinator, 0, KEY, 500_000, 3, true);
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        new BMCIlluminatiPass(owner, bmc, coordinator, 123, bytes32(0), 500_000, 3, true);
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        new BMCIlluminatiPass(owner, bmc, coordinator, 123, KEY, 149_999, 3, true);
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        new BMCIlluminatiPass(owner, bmc, coordinator, 123, KEY, 2_500_001, 3, true);
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        new BMCIlluminatiPass(owner, bmc, coordinator, 123, KEY, 500_000, 2, true);
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        new BMCIlluminatiPass(owner, bmc, coordinator, 123, KEY, 500_000, 201, true);
    }
}
