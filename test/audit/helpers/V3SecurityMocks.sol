// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {MockVRFCoordinator} from "../../mocks/MockVRFCoordinator.sol";
import {MockBMC} from "../../mocks/MockBMC.sol";

/// @dev The official mock has no proving-key getter. Only that registry surface is added;
/// subscription authorization, request encoding, billing and callback behavior remain upstream's.
contract RegisteredChainlinkMock is VRFCoordinatorV2_5Mock {
    bytes32 public constant KEY = keccak256("V3 registered test lane");
    bool public registered = true;

    constructor() VRFCoordinatorV2_5Mock(0.001 ether, 1 gwei, 4e15) {}

    function setRegistered(bool value) external {
        registered = value;
    }

    function s_provingKeys(bytes32 key) external view returns (bool, uint64) {
        return (registered && key == KEY, 500 gwei);
    }
}

/// @dev Lightweight request model for sequence testing. Uses the existing single-use callback mock.
/// Does not model subscription fees, oracle availability, confirmations or cryptographic VRF proofs.
contract SequenceCoordinator is MockVRFCoordinator {
    bytes32 public constant KEY = keccak256("V3 sequence lane");

    function s_provingKeys(bytes32 key) external pure override returns (bool, uint64) {
        return (key == KEY, 500 gwei);
    }
}

/// @dev Mutates one accounting dimension at a time so both burn deltas are tested independently.
contract AdversarialBurnToken is MockBMC {
    enum Mode {
        Exact,
        NoBurn,
        ShortBurn,
        OverBurn,
        BalanceOnly,
        SupplyOnly,
        IncreaseSupply,
        RevertBurn
    }
    Mode public mode;
    address public immutable reserve;

    constructor(address reserve_) {
        reserve = reserve_;
    }

    function setMode(Mode value) external {
        mode = value;
    }

    function burnFrom(address account, uint256 amount) public override {
        if (mode == Mode.Exact) {
            super.burnFrom(account, amount);
            return;
        }
        if (mode == Mode.RevertBurn) revert("burn unavailable");
        _spendAllowance(account, msg.sender, amount);
        if (mode == Mode.NoBurn) return;
        if (mode == Mode.ShortBurn) _burn(account, amount - 1);
        if (mode == Mode.OverBurn) _burn(account, amount + 1);
        if (mode == Mode.BalanceOnly) _transfer(account, reserve, amount);
        if (mode == Mode.SupplyOnly) _burn(reserve, amount);
        if (mode == Mode.IncreaseSupply) _mint(account, 1);
    }
}

/// @dev Intentionally malformed dependency replies, never a production coordinator model.
contract MalformedLaneCoordinator {
    enum Reply {
        Valid,
        Missing,
        Short,
        InvalidBool,
        InvalidGasWidth,
        RevertLookup
    }
    Reply public reply;
    uint256 public requestResult = 1;
    uint256 public requests;

    function setReply(Reply value) external {
        reply = value;
    }

    function setRequestResult(uint256 value) external {
        requestResult = value;
    }

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256) {
        ++requests;
        return requestResult;
    }

    fallback() external {
        Reply value = reply;
        if (value == Reply.RevertLookup) revert("lookup unavailable");
        if (value == Reply.Missing) {
            assembly { return(0, 0) }
        }
        if (value == Reply.Short) {
            assembly {
                mstore(0, 1)
                return(0, 32)
            }
        }
        if (value == Reply.InvalidBool) {
            assembly {
                mstore(0, 2)
                mstore(32, 1)
                return(0, 64)
            }
        }
        if (value == Reply.InvalidGasWidth) {
            assembly {
                mstore(0, 1)
                mstore(32, shl(64, 1))
                return(0, 64)
            }
        }
        assembly {
            mstore(0, 1)
            mstore(32, 500000000000)
            return(0, 64)
        }
    }
}
