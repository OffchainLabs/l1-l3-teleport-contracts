// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {IL2Forwarder} from "./IL2Forwarder.sol";
import {IL2ForwarderPredictor} from "./IL2ForwarderPredictor.sol";
import {TeleportationType} from "../lib/TeleportationType.sol";

/// @title  L1Teleporter
/// @notice Initiates L1 -> L3 transfers.
///         Creates 2 (or 3) retryables: one to bridge tokens (one to bridge the L3's fee token) to an L2Forwarder,
///         and one to call the L2ForwarderFactory.
interface IL1Teleporter is IL2ForwarderPredictor {
    /// @notice Parameters for teleport()
    /// @param  l1Token           L1 token being teleported
    /// @param  l3FeeTokenL1Addr  L1 address of the L3's fee token, or 0x00 for ETH
    /// @param  l1l2Router        L1 to L2 token bridge router
    /// @param  l2l3Router        L2 to L3 token bridge router
    /// @param  to                L3 address that will receive the tokens
    /// @param  amount            Amount of tokens being teleported
    /// @param  gasParams         Gas parameters for each retryable ticket
    struct TeleportParams {
        address l1Token;
        address l3FeeTokenL1Addr;
        address l1l2Router;
        address l2l3RouterOrInbox;
        address to;
        uint256 amount;
        RetryableGasParams gasParams;
    }

    /// @notice Gas parameters for each retryable ticket.
    struct RetryableGasParams {
        uint256 l2GasPriceBid;
        uint256 l3GasPriceBid;
        uint64 l2ForwarderFactoryGasLimit;
        uint64 l1l2FeeTokenBridgeGasLimit;
        uint64 l1l2TokenBridgeGasLimit;
        uint64 l2l3TokenBridgeGasLimit;
        uint256 l2ForwarderFactoryMaxSubmissionCost;
        uint256 l1l2FeeTokenBridgeMaxSubmissionCost;
        uint256 l1l2TokenBridgeMaxSubmissionCost;
        uint256 l2l3TokenBridgeMaxSubmissionCost;
    }

    /// @notice Total cost for each retryable ticket.
    struct RetryableGasCosts {
        uint256 l1l2FeeTokenBridgeCost;
        uint256 l1l2TokenBridgeCost;
        uint256 l2ForwarderFactoryCost;
        uint256 l2l3TokenBridgeCost;
    }

    /// @notice Emitted when a teleportation is initiated.
    /// @param  sender              L1 address that initiated the teleportation
    /// @param  l1Token             L1 token being teleported
    /// @param  l3FeeTokenL1Addr          L1 address of the L3's fee token, or 0x00 for ETH
    /// @param  l1l2Router          L1 to L2 token bridge router
    /// @param  l2l3RouterOrInbox   L2 to L3 token bridge router or Inbox
    /// @param  to                  L3 address that will receive the tokens
    /// @param  amount              Amount of tokens being teleported
    event Teleported(
        address indexed sender,
        address l1Token,
        address l3FeeTokenL1Addr,
        address l1l2Router,
        address l2l3RouterOrInbox,
        address to,
        uint256 amount
    );

    /// @notice Thrown when the ETH value sent to teleport() is less than the total ETH cost of retryables
    error IncorrectValue(uint256 required, uint256 provided);
    /// @notice Thrown when TeleportationType is OnlyCustomFee and the amount of fee tokens to send is less than the cost of the retryable to L3
    error InsufficientFeeToken(uint256 required, uint256 provided);

    /// @notice Start an L1 -> L3 transfer. msg.value sent must be >= the total cost of all retryables.
    ///         Call `determineTypeAndFees` to calculate the total cost of retryables in ETH and the L3's fee token.
    ///         Any extra ETH will be sent to the receiver on L3.
    ///         If called by an EOA or contract during construction, the L2Forwarder will be owned by the caller's address,
    ///         otherwise the L2Forwarder will be owned by the caller's alias.
    /// @dev    2 retryables will be created: one to send tokens and ETH to the L2Forwarder, and one to call the L2ForwarderFactory.
    ///         If TeleportationType is NonFeeTokenToCustomFeeL3, a third retryable will be created to send the L3's fee token to the L2Forwarder.
    ///         Extra ETH is sent through the l2CallValue of the call to the L2ForwarderFactory.
    function teleport(TeleportParams calldata params) external payable;

    /// @notice Given some teleportation parameters, calculate the total cost of retryables in ETH and the L3's fee token.
    function determineTypeAndFees(TeleportParams calldata params)
        external
        view
        returns (
            uint256 ethAmount,
            uint256 feeTokenAmount,
            TeleportationType teleportationType,
            RetryableGasCosts memory costs
        );

    /// @notice Given some teleportation parameters, build the L2ForwarderParams for the L2ForwarderFactory.
    function buildL2ForwarderParams(TeleportParams calldata params, address l2Owner)
        external
        view
        returns (IL2Forwarder.L2ForwarderParams memory);
}
