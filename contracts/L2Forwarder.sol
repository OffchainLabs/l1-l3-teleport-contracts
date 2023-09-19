// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {L2ForwarderPredictor} from "./L2ForwarderPredictor.sol";

contract L2Forwarder is L2ForwarderPredictor {
    using SafeERC20 for IERC20;

    /// @notice L1 address that owns this L2Forwarder
    address public l1Owner;

    /// @notice Emitted after a successful call to rescue
    /// @param  targets Addresses that were called
    /// @param  values  Values that were sent
    /// @param  datas   Calldata that was sent
    event Rescued(address[] targets, uint256[] values, bytes[] datas);

    /// @notice Thrown when initialize is called after initialization
    error AlreadyInitialized();
    /// @notice Thrown when a non-owner calls rescue
    error OnlyL1Owner();
    /// @notice Thrown when the length of targets, values, and datas are not equal in a call to rescue
    error LengthMismatch();
    /// @notice Thrown when an external call in rescue fails
    error CallFailed(address to, uint256 value, bytes data, bytes returnData);
    /// @notice Thrown when the relayer payment fails
    error RelayerPaymentFailed();
    /// @notice Thrown when bridgeToL3 is called with incorrect parameters
    error IncorrectParams();

    constructor(address _factory) L2ForwarderPredictor(_factory) {}

    /// @notice Initialize this L2Forwarder
    /// @param  _l1Owner The L1 address that owns this L2Forwarder
    /// @dev    Can only be called once.
    function initialize(address _l1Owner) external {
        if (l1Owner != address(0)) revert AlreadyInitialized();
        l1Owner = _l1Owner;
    }

    function bridgeToL3(L2ForwarderParams memory params) external {
        if (address(this) != l2ForwarderAddress(params)) revert IncorrectParams();

        // get gateway
        address l2l3Gateway = L1GatewayRouter(params.router).getGateway(params.token);

        // approve gateway
        IERC20(params.token).safeApprove(l2l3Gateway, params.amount);

        // send tokens through the bridge to intended recipient
        // (send all the ETH we have too, we could have more than msg.value b/c of fee refunds)
        // overestimate submission cost to ensure all ETH is sent through
        uint256 balanceSubRelayerPayment = address(this).balance - params.relayerPayment;
        uint256 submissionCost = balanceSubRelayerPayment - params.gasLimit * params.gasPrice;
        L1GatewayRouter(params.router).outboundTransferCustomRefund{value: balanceSubRelayerPayment}(
            params.token, params.to, params.to, params.amount, params.gasLimit, params.gasPrice, abi.encode(submissionCost, bytes(""))
        );
        
        if (params.relayerPayment > 0) {
            (bool paymentSuccess,) = tx.origin.call{value: params.relayerPayment}("");

            if (!paymentSuccess) revert RelayerPaymentFailed();
        }
    }

    /// @notice Allows the L1 owner of this L2Forwarder to make arbitrary calls.
    ///         If the second leg of a teleportation fails, the L1 owner can call this to rescue their tokens.
    ///         When transferring tokens, failing second leg retryables should be cancelled to avoid race conditions and retreive any ETH.
    /// @param  targets Addresses to call
    /// @param  values  Values to send
    /// @param  datas   Calldata to send
    function rescue(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas) external {
        if (msg.sender != AddressAliasHelper.applyL1ToL2Alias(l1Owner)) revert OnlyL1Owner();
        if (targets.length != values.length || values.length != datas.length) revert LengthMismatch();

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, bytes memory retData) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert CallFailed(targets[i], values[i], datas[i], retData);
        }

        emit Rescued(targets, values, datas);
    }
}