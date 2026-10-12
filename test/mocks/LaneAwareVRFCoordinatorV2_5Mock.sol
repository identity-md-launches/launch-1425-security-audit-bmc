// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

/// @dev The official mock omits the live coordinator's proving-key getter. This test-only
///      extension supplies registered test lanes; subscription, request and billing logic
///      remain the official mock's. It does not model oracle-service expiry or real pricing.
contract LaneAwareVRFCoordinatorV2_5Mock is VRFCoordinatorV2_5Mock {
    constructor() VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15) {}

    function s_provingKeys(bytes32 key) external pure returns (bool, uint64) {
        return (key != bytes32(0), uint64(500 gwei));
    }
}
