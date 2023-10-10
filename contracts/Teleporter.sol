// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {L1ArbitrumMessenger} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/L1ArbitrumMessenger.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IL1ArbitrumGateway} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/IL1ArbitrumGateway.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {L2ForwarderFactory} from "./L2ForwarderFactory.sol";
import {L2ForwarderPredictor} from "./L2ForwarderPredictor.sol";

/// @title  Teleporter
/// @notice Initiates L1 -> L3 transfers. 
///         Creates 2 retryables: one to transfer tokens and ETH to an L2Forwarder, and one to call the L2ForwarderFactory.
contract Teleporter is L2ForwarderPredictor {
    using SafeERC20 for IERC20;

    /// @notice Parameters for teleport()
    /// @param  l1Token     L1 token being teleported
    /// @param  l1l2Router  L1 to L2 token bridge router
    /// @param  l2l3Router  L2 to L3 token bridge router
    /// @param  to          L3 address that will receive the tokens
    /// @param  amount      Amount of tokens being teleported
    /// @param  gasParams   Gas parameters for each retryable ticket
    /// @param  randomNonce Nonce to ensure the L2Forwarder address is unique
    struct TeleportParams {
        address l1Token;
        address l1l2Router;
        address l2l3Router;
        address to;
        uint256 amount;
        RetryableGasParams gasParams;
        uint256 randomNonce;    
    }

    /// @notice Gas parameters for each retryable ticket.
    struct RetryableGasParams {
        uint256 l2GasPrice;
        uint256 l3GasPrice;
        uint256 l2ForwarderFactoryGasLimit;
        uint256 l1l2TokenBridgeGasLimit;
        uint256 l2l3TokenBridgeGasLimit;
        uint256 l1l2TokenBridgeRetryableSize;
        uint256 l2l3TokenBridgeRetryableSize;
    }

    /// @notice Gas and submission costs for each retryable ticket.
    struct RetryableGasCosts {
        uint256 l1l2TokenBridgeSubmissionCost;
        uint256 l2ForwarderFactorySubmissionCost;
        uint256 l2l3TokenBridgeSubmissionCost;
        uint256 l1l2TokenBridgeGasCost;
        uint256 l2ForwarderFactoryGasCost;
        uint256 l2l3TokenBridgeGasCost;
        uint256 total;
    }

    /// @dev Calldata size of L2ForwarderFactory.callForwarder (selector + 9 args).
    ///      Necessary to calculate the submission cost of the retryable ticket to L2ForwarderFactory.
    uint256 constant l2ForwarderFactoryCalldataSize = 4 + 9 * 32;

    /// @notice Emitted when a teleportation is initiated.
    /// @param  l1Owner     L1 address that initiated the teleportation
    /// @param  l1Token     L1 token being teleported
    /// @param  l1l2Router  L1 to L2 token bridge router
    /// @param  l2l3Router  L2 to L3 token bridge router
    /// @param  to          L3 address that will receive the tokens
    /// @param  amount      Amount of tokens being teleported
    event Teleported(
        address indexed l1Owner, address l1Token, address l1l2Router, address l2l3Router, address to, uint256 amount
    );

    /// @notice Thrown when the value sent to teleport() is less than the total cost of all retryables.
    error InsufficientValue(uint256 required, uint256 provided);

    constructor(address _l2ForwarderFactory, address _l2ForwarderImplementation) 
        L2ForwarderPredictor(_l2ForwarderFactory, _l2ForwarderImplementation) {}

    /// @notice Start an L1 -> L3 transfer. msg.value sent must be >= the total cost of all retryables.
    ///         Any extra ETH will be sent to the receiver on L3.
    /// @dev    2 retryables will be created: one to send tokens and ETH to the L2Forwarder, and one to call the L2ForwarderFactory.
    ///         Extra ETH is sent through the first retryable as an overestimated submission fee.
    function teleport(
        TeleportParams memory params
    ) external payable {
        // get inbox
        address inbox = L1GatewayRouter(params.l1l2Router).inbox();

        // msg.value accounting checks
        RetryableGasCosts memory gasResults = calculateRetryableGasCosts(inbox, block.basefee, params.gasParams);

        if (msg.value < gasResults.total) revert InsufficientValue(gasResults.total, msg.value);

        // pull in tokens from caller
        IERC20(params.l1Token).safeTransferFrom(msg.sender, address(this), params.amount);

        // if we don't already have an extra wei of token, keep it for gas optimization
        if (IERC20(params.l1Token).balanceOf(address(this)) == params.amount) {
            params.amount--;
        }

        // approve gateway
        address gateway = L1GatewayRouter(params.l1l2Router).getGateway(params.l1Token);
        if (IERC20(params.l1Token).allowance(address(this), gateway) == 0) {
            IERC20(params.l1Token).safeApprove(gateway, type(uint256).max);
        }

        // create L2ForwarderParams
        L2ForwarderParams memory l2ForwarderParams;
        {
            address l2Token = L1GatewayRouter(params.l1l2Router).calculateL2TokenAddress(params.l1Token);
            l2ForwarderParams = L2ForwarderParams({
                // set owner to the aliased msg.sender. 
                // As long as msg.sender can create retryables, they will be able to recover in case of failure
                owner: AddressAliasHelper.applyL1ToL2Alias(msg.sender),
                token: l2Token,
                router: params.l2l3Router,
                to: params.to,
                amount: params.amount,
                gasLimit: params.gasParams.l2l3TokenBridgeGasLimit,
                gasPrice: params.gasParams.l3GasPrice,
                relayerPayment: 0, // we aren't using a relayer, so no payment
                randomNonce: params.randomNonce
            });
        }

        // calculate forwarder address of caller
        address l2Forwarder = l2ForwarderAddress(l2ForwarderParams);
        
        {
            // total second retryable cost
            uint256 l2ForwarderFactoryCost = gasResults.l2ForwarderFactorySubmissionCost + gasResults.l2ForwarderFactoryGasCost;

            // submission cost for first retryable
            uint256 overestimatedL1L2TokenBridgeSubmissionCost = address(this).balance - l2ForwarderFactoryCost - gasResults.l1l2TokenBridgeGasCost;

            // send tokens through the bridge to predicted forwarder
            L1GatewayRouter(params.l1l2Router).outboundTransferCustomRefund{
                value: address(this).balance - l2ForwarderFactoryCost
            }({
                _token: address(params.l1Token),
                _refundTo: l2Forwarder,
                _to: l2Forwarder,
                _amount: params.amount,
                _maxGas: params.gasParams.l1l2TokenBridgeGasLimit,
                _gasPriceBid: params.gasParams.l2GasPrice,
                _data: abi.encode(overestimatedL1L2TokenBridgeSubmissionCost, bytes(""))
            });
        }

        // call the L2ForwarderFactory
        bytes memory l2ForwarderFactoryCalldata = abi.encodeCall(
            L2ForwarderFactory.callForwarder,
            (l2ForwarderParams)
        );

        IInbox(inbox).createRetryableTicket{value: address(this).balance}({
            to: l2ForwarderFactory,
            l2CallValue: 0,
            maxSubmissionCost: gasResults.l2ForwarderFactorySubmissionCost,
            excessFeeRefundAddress: l2Forwarder,
            callValueRefundAddress: l2Forwarder,
            gasLimit: params.gasParams.l2ForwarderFactoryGasLimit,
            maxFeePerGas: params.gasParams.l2GasPrice,
            data: l2ForwarderFactoryCalldata
        });

        emit Teleported({
            l1Owner: msg.sender,
            l1Token: address(params.l1Token),
            l1l2Router: address(params.l1l2Router),
            l2l3Router: params.l2l3Router,
            to: params.to,
            amount: params.amount
        });
    }

    /// @notice Given some gas parameters, calculate the gas and submission costs for each retryable ticket.
    /// @param  inbox       L2's Inbox
    /// @param  l1BaseFee   L1's base fee
    /// @param  gasParams   Gas parameters for each retryable ticket
    function calculateRetryableGasCosts(address inbox, uint256 l1BaseFee, RetryableGasParams memory gasParams)
        public
        view
        returns (RetryableGasCosts memory results)
    {
        // msg.value >= l2GasPrice * (l1l2TokenBridgeGasLimit + l2ForwarderFactoryGasLimit)
        //            + l3GasPrice * (l2l3TokenBridgeGasLimit)
        //            + l1l2TokenBridgeSubmissionCost + l2l3TokenBridgeSubmissionCost + l2ForwarderFactorySubmissionCost

        // calculate submission costs
        results.l1l2TokenBridgeSubmissionCost =
            IInbox(inbox).calculateRetryableSubmissionFee(gasParams.l1l2TokenBridgeRetryableSize, l1BaseFee);
        results.l2ForwarderFactorySubmissionCost =
            IInbox(inbox).calculateRetryableSubmissionFee(l2ForwarderFactoryCalldataSize, l1BaseFee);
        results.l2l3TokenBridgeSubmissionCost =
            IInbox(inbox).calculateRetryableSubmissionFee(gasParams.l2l3TokenBridgeRetryableSize, gasParams.l2GasPrice);

        // calculate gas cost for ticket #1 (the l1-l2 token bridge retryable)
        results.l1l2TokenBridgeGasCost = gasParams.l2GasPrice * gasParams.l1l2TokenBridgeGasLimit;

        // calculate gas cost for ticket #2 (call to L2ForwarderFactory.bridgeToL3)
        results.l2ForwarderFactoryGasCost = gasParams.l2GasPrice * gasParams.l2ForwarderFactoryGasLimit;

        // calculate gas cost for ticket #3 (the l2-l3 token bridge retryable)
        results.l2l3TokenBridgeGasCost = gasParams.l3GasPrice * gasParams.l2l3TokenBridgeGasLimit;

        results.total = results.l1l2TokenBridgeSubmissionCost + results.l2ForwarderFactorySubmissionCost
            + results.l2l3TokenBridgeSubmissionCost + results.l1l2TokenBridgeGasCost + results.l2ForwarderFactoryGasCost
            + results.l2l3TokenBridgeGasCost;
    }
}
