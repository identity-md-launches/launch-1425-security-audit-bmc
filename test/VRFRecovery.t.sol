// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BMCIlluminatiPass} from "../src/BMCIlluminatiPass.sol";
import {MockBMC} from "./mocks/MockBMC.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @dev Models an oracle dropping an underfunded request after 24h, NOT an on-chain
/// coordinator expiry rule. Unlike the official mock, funding cannot revive a dropped request.
contract ExpiringCoordinator {
    function s_provingKeys(bytes32 key) external view virtual returns (bool, uint64) {
        return (key != bytes32(0), uint64(500 gwei));
    }

    uint256 public nextRequestId = 1000;
    mapping(uint256 => address) public consumerOf;
    mapping(uint256 => uint256) public requestedAt;
    mapping(uint256 => bool) public expired;
    bool public rejectRequests;
    uint256 public lastSubscription;
    bytes32 public lastKey;
    uint256 public reenterToken;
    bytes public reentryFailure;

    function setRejectRequests(bool reject) external {
        rejectRequests = reject;
    }

    function setReenterToken(uint256 tokenId) external {
        reenterToken = tokenId;
    }

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req) external returns (uint256 id) {
        require(!rejectRequests, "subscription unavailable");
        if (reenterToken != 0) {
            (bool ok, bytes memory reason) =
                msg.sender.call(abi.encodeWithSignature("rerequestRandomness(uint256)", reenterToken));
            require(!ok, "reentry succeeded");
            reentryFailure = reason;
        }
        id = nextRequestId++;
        consumerOf[id] = msg.sender;
        requestedAt[id] = block.timestamp;
        lastSubscription = req.subId;
        lastKey = req.keyHash;
    }

    function expire(uint256 id) external {
        require(block.timestamp >= requestedAt[id] + 1 days, "not expired");
        expired[id] = true;
    }

    function fulfill(uint256 id, uint256 word) external returns (bool) {
        return fulfillWithGas(id, word, 500_000);
    }

    function fulfillWithGas(uint256 id, uint256 word, uint256 gasLimit) public returns (bool ok) {
        require(consumerOf[id] != address(0), "unknown request");
        if (expired[id]) return false;
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        (ok,) = consumerOf[id].call{gas: gasLimit}(
            abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", id, words)
        );
    }
}

contract MalformedCoordinator {
    function s_provingKeys(bytes32 key) external pure returns (bool, uint64) {
        return (key != bytes32(0), uint64(500 gwei));
    }

    uint256 public requestId;

    function setRequestId(uint256 value) external {
        requestId = value;
    }

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external view returns (uint256) {
        return requestId;
    }
}

contract VRFRecoveryTest is Test {
    MockBMC bmc;
    ExpiringCoordinator coord;
    BMCIlluminatiPass pass;
    address owner = makeAddr("recovery owner");
    address alice = makeAddr("recovery buyer");
    address keeper = makeAddr("unprivileged recovery keeper");
    bytes32 constant KEY = keccak256("test lane");

    function setUp() public {
        vm.warp(1_800_000_000);
        bmc = new MockBMC();
        coord = new ExpiringCoordinator();
        pass = new BMCIlluminatiPass(owner, address(bmc), address(coord), 123, KEY, 500_000, 3, true);
        bmc.mint(alice, pass.MAX_TOTAL_BURN());
        vm.startPrank(alice);
        bmc.approve(address(pass), pass.MAX_TOTAL_BURN());
        for (uint256 i; i < 40; ++i) {
            pass.mintGenesis();
        }
        vm.stopPrank();
    }

    function _mint() internal returns (uint256 id, uint256 req) {
        vm.prank(alice);
        return pass.mintMystery();
    }

    function _retry(uint256 id) internal returns (uint256) {
        vm.warp(pass.lastRequestAt(id) + pass.RETRY_DELAY());
        vm.prank(keeper);
        return pass.rerequestRandomness(id);
    }

    function test_ExpiredRequestRecoveryUnblocksSuccessorsWithoutAnotherBurn() public {
        (uint256 id, uint256 first) = _mint();
        (, uint256 successor) = _mint();
        assertTrue(coord.fulfill(successor, 7));
        assertEq(pass.revealedCount(), 0, "strict mint order");
        uint256 supply = bmc.totalSupply();
        uint256 balance = bmc.balanceOf(alice);
        uint256 allowance = bmc.allowance(alice, address(pass));
        uint256 burned = pass.totalBurned();
        vm.warp(block.timestamp + 1 days);
        coord.expire(first);
        assertFalse(coord.fulfill(first, 1));
        vm.prank(keeper);
        uint256 second = pass.rerequestRandomness(id);
        assertTrue(second != first);
        assertEq(pass.tokenIdOfRequest(first), id, "old ids remain recognized");
        assertEq(pass.tokenIdOfRequest(second), id);
        assertEq(pass.requestIdOf(id), second);
        assertTrue(coord.fulfill(second, 42));
        assertEq(pass.revealedCount(), 2);
        assertEq(pass.pendingReveals(), 0);
        assertEq(pass.ownerOf(id), alice);
        assertEq(pass.totalMinted(), 42);
        assertEq(pass.totalBurned(), burned);
        assertEq(bmc.totalSupply(), supply);
        assertEq(bmc.balanceOf(alice), balance);
        assertEq(bmc.allowance(alice, address(pass)), allowance);
        assertFalse(coord.fulfill(first, 999), "funding cannot revive a dropped request");
    }

    function test_RetryDelayBoundaryAndReset() public {
        (uint256 id,) = _mint();
        uint256 start = block.timestamp;
        vm.warp(start + pass.RETRY_DELAY() - 1);
        vm.expectRevert(BMCIlluminatiPass.RetryUnavailable.selector);
        pass.rerequestRandomness(id);
        uint256 second = _retry(id);
        assertEq(pass.lastRequestAt(id), block.timestamp);
        vm.expectRevert(BMCIlluminatiPass.RetryUnavailable.selector);
        pass.rerequestRandomness(id);
        uint256 third = _retry(id);
        assertTrue(third != second);
    }

    function test_RetryRejectsGenesisAndNonexistentTokens() public {
        vm.expectRevert(BMCIlluminatiPass.RetryUnavailable.selector);
        pass.rerequestRandomness(1);
        vm.expectRevert(abi.encodeWithSelector(BMCIlluminatiPass.NonexistentToken.selector, 0));
        pass.rerequestRandomness(0);
        vm.expectRevert(abi.encodeWithSelector(BMCIlluminatiPass.NonexistentToken.selector, 41));
        pass.rerequestRandomness(41);
    }

    function test_StoredSuccessorCannotBeRerequested() public {
        _mint();
        (uint256 id, uint256 req) = _mint();
        assertTrue(coord.fulfill(req, 123));
        vm.warp(block.timestamp + 2 days);
        assertEq(uint256(pass.revealStatusOf(id)), uint256(BMCIlluminatiPass.RevealStatus.RandomnessStored));
        vm.expectRevert(BMCIlluminatiPass.RetryUnavailable.selector);
        pass.rerequestRandomness(id);
    }

    function testFuzz_FirstDeliveredWordWins(bool originalFirst, uint256 word) public {
        (uint256 id, uint256 first) = _mint();
        uint256 second = _retry(id);
        uint256 delivered = originalFirst ? first : second;
        uint256 late = originalFirst ? second : first;
        assertTrue(coord.fulfill(delivered, word));
        uint256 slot = uint256(keccak256(abi.encode(word, id))) % 460;
        assertEq(pass.artworkIdOf(id), slot < 37 ? 41 + slot : slot - 36);
        assertEq(uint256(pass.tierOf(id)), slot < 37 ? 2 : 3);
        bytes32 metadata = keccak256(bytes(pass.tokenURI(id)));
        assertTrue(coord.fulfill(late, word ^ type(uint256).max));
        assertEq(keccak256(bytes(pass.tokenURI(id))), metadata);
        assertEq(pass.revealedCount(), 1);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(BMCIlluminatiPass.RetryUnavailable.selector);
        pass.rerequestRandomness(id);
    }

    function test_ZeroRandomWordIsAcceptedAfterRetry() public {
        (uint256 id,) = _mint();
        assertTrue(coord.fulfill(_retry(id), 0));
        assertEq(pass.revealedCount(), 1);
    }

    function test_FailedRetryPreservesOriginalAndTimestamp() public {
        (uint256 id, uint256 first) = _mint();
        uint256 originalTime = pass.lastRequestAt(id);
        vm.warp(originalTime + 1 days);
        coord.setRejectRequests(true);
        vm.expectRevert(bytes("subscription unavailable"));
        pass.rerequestRandomness(id);
        assertEq(pass.lastRequestAt(id), originalTime);
        assertEq(pass.requestIdOf(id), first);
        assertEq(coord.nextRequestId(), first + 1);
        assertTrue(coord.fulfill(first, 55));
        assertEq(pass.revealedCount(), 1);
    }

    function test_OwnerCanRepairSubscriptionAndLaneForPermissionlessRetry() public {
        (uint256 id, uint256 first) = _mint();
        bytes32 replacementKey = keccak256("replacement test lane");
        vm.prank(owner);
        pass.setVRFConfig(456, replacementKey, 500_000, 7, false);
        uint256 second = _retry(id);
        assertEq(coord.lastSubscription(), 456);
        assertEq(coord.lastKey(), replacementKey);
        // Original remains valid even across configuration changes.
        assertTrue(coord.fulfill(first, 11));
        uint16 art = pass.artworkIdOf(id);
        assertTrue(coord.fulfill(second, 12));
        assertEq(pass.artworkIdOf(id), art);
    }

    function test_CallbackFailureCanRecover() public {
        (uint256 id, uint256 first) = _mint();
        assertFalse(coord.fulfillWithGas(first, 9, 1_000));
        assertEq(uint256(pass.revealStatusOf(id)), uint256(BMCIlluminatiPass.RevealStatus.AwaitingRandomness));
        assertTrue(coord.fulfill(_retry(id), 9));
        assertEq(pass.revealedCount(), 1);
    }

    function test_CoordinatorCannotReenterRetry() public {
        (uint256 id,) = _mint();
        coord.setReenterToken(id);
        _retry(id);
        assertEq(coord.reentryFailure(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        assertEq(coord.nextRequestId(), 1002);
    }

    function test_InvalidCoordinatorIdsRevertAndRollBackBurnOrRetry() public {
        MalformedCoordinator malformed = new MalformedCoordinator();
        pass = new BMCIlluminatiPass(owner, address(bmc), address(malformed), 123, KEY, 500_000, 3, true);
        bmc.mint(alice, 201_000_000 ether);
        vm.startPrank(alice);
        bmc.approve(address(pass), 201_000_000 ether);
        for (uint256 i; i < 40; ++i) {
            pass.mintGenesis();
        }
        uint256 before = bmc.totalSupply();
        vm.expectRevert(bytes("invalid request id"));
        pass.mintMystery();
        assertEq(bmc.totalSupply(), before);
        assertEq(pass.totalMinted(), 40);
        malformed.setRequestId(1);
        pass.mintMystery();
        vm.stopPrank();
        uint256 requested = pass.lastRequestAt(41);
        vm.warp(requested + 1 days);
        vm.expectRevert(bytes("invalid request id"));
        pass.rerequestRandomness(41);
        assertEq(pass.lastRequestAt(41), requested);
        assertEq(pass.requestIdOf(41), 1);
        assertEq(pass.totalBurned(), 40_350_000 ether);
    }
}
