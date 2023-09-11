// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {
    ProxySetter,
    ClonableBeaconProxy
} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/libraries/ClonableBeaconProxy.sol";
import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {L2Forwarder} from "./L2Forwarder.sol";

/// @notice Creates and calls L2Forwarders. L2Forwarder instances are created as ClonableBeaconProxy contracts.
///         Creation of L2Forwarders is permissionless. Only the L1Teleporter can call L2Forwarders through this contract.
contract L2ForwarderFactory is ProxySetter {
    bytes32 constant cloneableProxyHash = keccak256(type(ClonableBeaconProxy).creationCode);

    /// @notice Beacon setting the L2Forwarder implementation for all proxy instances
    address public immutable override beacon;
    /// @notice Teleporter contract on L1
    address public immutable l1Teleporter;

    /// @notice Emitted when a new L2Forwarder is created
    /// @param  l1Owner     L2Forwarder's owner's address on L1
    /// @param  l2Forwarder Address of the new L2Forwarder
    event CreatedL2Forwarder(address indexed l1Owner, address l2Forwarder);

    /// @notice Emitted when an L2Forwarder is called to bridge tokens to L3
    /// @param  l1Owner         L2Forwarder's owner's address on L1
    /// @param  l2Forwarder     L2Forwarder
    /// @param  router          Token bridge router to L3
    /// @param  token           Token being bridged
    /// @param  to              Recipient on L3
    /// @param  amount          Amount of tokens being bridged
    /// @param  gasLimit        Gas limit for the token bridge retryable to L3
    /// @param  gasPrice        Gas price for the token bridge retryable to L3
    event CalledL2Forwarder(
        address indexed l1Owner,
        address l2Forwarder,
        address router,
        address token,
        address to,
        uint256 amount,
        uint256 gasLimit,
        uint256 gasPrice
    );

    /// @notice Thrown when non-teleporter attempts to call callForwarder
    error OnlyL1Teleporter();

    /// @param _beacon         Beacon setting the L2Forwarder implementation for all proxy instances
    /// @param _l1Teleporter   Teleporter contract on L1
    constructor(address _beacon, address _l1Teleporter) {
        beacon = _beacon;
        l1Teleporter = _l1Teleporter;
    }

    /// @notice Calls an L2Forwarder to bridge tokens to L3. Will create the L2Forwarder first if it doesn't exist.
    ///         Can only be called via retryable from the Teleporter on L1.
    /// @param  l1Owner     Address bridging tokens to L3
    /// @param  token       Token being bridged
    /// @param  router      Token bridge router to L3
    /// @param  to          Recipient on L3
    /// @param  amount      Amount of tokens being bridged
    /// @param  gasLimit    Gas limit for the token bridge retryable to L3
    /// @param  gasPrice    Gas price for the token bridge retryable to L3
    function callForwarder(
        address l1Owner,
        address token,
        address router,
        address to,
        uint256 amount,
        uint256 gasLimit,
        uint256 gasPrice
    ) external payable {
        if (msg.sender != AddressAliasHelper.applyL1ToL2Alias(l1Teleporter)) revert OnlyL1Teleporter();

        L2Forwarder l2Forwarder = _tryCreateL2Forwarder(l1Owner);

        l2Forwarder.bridgeToL3{value: msg.value}(token, router, to, amount, gasLimit, gasPrice);
    }

    /// @notice Creates an L2Forwarder for the given L1 owner. There is no access control.
    /// @param  l1Owner L2Forwarder's owner's address on L1
    function createL2Forwarder(address l1Owner) public returns (L2Forwarder) {
        L2Forwarder l2Forwarder = L2Forwarder(address(new ClonableBeaconProxy{ salt: bytes20(l1Owner) }()));
        l2Forwarder.initialize(l1Owner);

        emit CreatedL2Forwarder(l1Owner, address(l2Forwarder));

        return l2Forwarder;
    }

    /// @notice Calculates the address of the L2Forwarder for the given L1 owner.
    ///         The L2Forwarder may or may not exist.
    function l2ForwarderAddress(address l1Owner) public view returns (address) {
        return Create2.computeAddress(bytes20(l1Owner), cloneableProxyHash, address(this));
    }

    /// @dev Create an L2Forwarder if it doesn't exist, otherwise return the existing one.
    function _tryCreateL2Forwarder(address l1Owner) internal returns (L2Forwarder) {
        address calculatedAddress = l2ForwarderAddress(l1Owner);

        uint256 size;
        assembly {
            size := extcodesize(calculatedAddress)
        }
        if (size > 0) {
            // contract already exists
            return L2Forwarder(calculatedAddress);
        }

        // contract doesn't exist, create it
        return createL2Forwarder(l1Owner);
    }
}
