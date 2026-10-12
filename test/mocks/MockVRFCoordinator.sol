// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

interface IRawFulfill {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @dev Minimal VRF v2.5 coordinator stand-in. Records requests; tests fulfill them in any order,
///      optionally with a tight gas limit to simulate a callback that cannot finalize inline.
contract MockVRFCoordinator {
    struct Req {
        address consumer;
        uint32 callbackGasLimit;
        bool fulfilled;
        bytes32 keyHash;
        uint256 subId;
        uint16 confirmations;
        bool nativePayment;
    }

    uint256 public nextRequestId = 1000;
    mapping(uint256 => Req) public requests;
    bool public rejectRequests;
    mapping(bytes32 => bool) private _unregisteredLane;

    /// @dev Test lanes are registered by default; requests intentionally accept invalid lanes,
    ///      like Mainnet's coordinator. The consumer must check this getter itself.
    function s_provingKeys(bytes32 key) external view virtual returns (bool, uint64) {
        return (key != bytes32(0) && !_unregisteredLane[key], uint64(500 gwei));
    }

    function setLaneRegistered(bytes32 key, bool registered) external {
        _unregisteredLane[key] = !registered;
    }

    function setRejectRequests(bool v) external {
        rejectRequests = v;
    }

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req) external returns (uint256 id) {
        require(!rejectRequests, "mock: subscription not funded");
        id = nextRequestId++;
        VRFV2PlusClient.ExtraArgsV1 memory ea = abi.decode(_stripSelector(req.extraArgs), (VRFV2PlusClient.ExtraArgsV1));
        requests[id] = Req({
            consumer: msg.sender,
            callbackGasLimit: req.callbackGasLimit,
            fulfilled: false,
            keyHash: req.keyHash,
            subId: req.subId,
            confirmations: req.requestConfirmations,
            nativePayment: ea.nativePayment
        });
    }

    /// @dev Fulfil using the request's own callback gas limit, like the real coordinator.
    function fulfill(uint256 requestId, uint256 word) external returns (bool ok) {
        return fulfillWithGas(requestId, word, requests[requestId].callbackGasLimit);
    }

    function fulfillWithGas(uint256 requestId, uint256 word, uint256 gas) public returns (bool ok) {
        Req storage r = requests[requestId];
        require(r.consumer != address(0), "mock: unknown request");
        require(!r.fulfilled, "mock: already fulfilled");
        r.fulfilled = true;
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        (ok,) = r.consumer.call{gas: gas}(abi.encodeCall(IRawFulfill.rawFulfillRandomWords, (requestId, words)));
    }

    /// @dev Re-deliver an already fulfilled request (should be ignored by the consumer).
    function redeliver(uint256 requestId, uint256 word) external returns (bool ok) {
        Req storage r = requests[requestId];
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        (ok,) = r.consumer.call(abi.encodeCall(IRawFulfill.rawFulfillRandomWords, (requestId, words)));
    }

    function _stripSelector(bytes calldata data) private pure returns (bytes memory) {
        return data[4:];
    }
}
