// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {L2ForwarderFactory} from "./L2ForwarderFactory.sol";
import {L2ForwarderPredictor} from "./L2ForwarderPredictor.sol";

/// @title  L1Teleporter
/// @notice Initiates L1 -> L3 transfers.
///         Creates 2 retryables: one to transfer tokens and ETH to an L2Forwarder, and one to call the L2ForwarderFactory.
contract L1Teleporter is L2ForwarderPredictor {
    using SafeERC20 for IERC20;

    /// @notice Parameters for teleport()
    /// @param  l1Token     L1 token being teleported
    /// @param  l1l2Router  L1 to L2 token bridge router
    /// @param  l2l3Router  L2 to L3 token bridge router
    /// @param  to          L3 address that will receive the tokens
    /// @param  amount      Amount of tokens being teleported
    /// @param  gasParams   Gas parameters for each retryable ticket
    struct TeleportParams {
        address l1Token; // todo: new naming convention, l1Token, l2Token, l1FeeToken, l2FeeToken. they refer to the same asset's address on each layer. with feeToken obviously being the l3 custom fee asset
        address l1FeeToken; // address of the L3 fee token on L1
        address l1l2Router;
        address l2l3RouterOrInbox;
        address to;
        uint256 amount;
        RetryableGasParams gasParams;
    }

    /// @notice Gas parameters for each retryable ticket.
    struct RetryableGasParams {
        uint256 l2GasPrice;
        uint256 l3GasPrice;
        uint256 l2ForwarderFactoryGasLimit;
        uint256 l1l2FeeTokenBridgeGasLimit;
        uint256 l1l2TokenBridgeGasLimit;
        uint256 l2l3TokenBridgeGasLimit;
        uint256 l1l2FeeTokenBridgeSubmissionCost;
        uint256 l1l2TokenBridgeSubmissionCost;
        uint256 l2l3TokenBridgeSubmissionCost;
    }

    /// @notice Total cost for each retryable ticket.
    struct RetryableGasCosts {
        uint256 l1l2FeeTokenBridgeCost;
        uint256 l1l2TokenBridgeCost;
        uint256 l2ForwarderFactoryCost;
        uint256 l2l3TokenBridgeCost;
        uint256 l2ForwarderFactorySubmissionCost;
    }

    /// @dev Calldata size of L2ForwarderFactory.callForwarder (selector + 7 args).
    ///      Necessary to calculate the submission cost of the retryable ticket to L2ForwarderFactory.
    uint256 immutable l2ForwarderFactoryCalldataSize;

    /// @notice Emitted when a teleportation is initiated.
    /// @param  sender      L1 address that initiated the teleportation
    /// @param  l1Token     L1 token being teleported
    /// @param  l1l2Router  L1 to L2 token bridge router
    /// @param  l2l3Router  L2 to L3 token bridge router
    /// @param  to          L3 address that will receive the tokens
    /// @param  amount      Amount of tokens being teleported
    event Teleported(
        address indexed sender, address l1Token, address l1l2Router, address l2l3Router, address to, uint256 amount
    );

    /// @notice Thrown when the value sent to teleport() is less than the total cost of all retryables.
    error InsufficientValue(uint256 required, uint256 provided);

    constructor(address _l2ForwarderFactory, address _l2ForwarderImplementation)
        L2ForwarderPredictor(_l2ForwarderFactory, _l2ForwarderImplementation)
    {
        L2ForwarderParams memory _x;
        l2ForwarderFactoryCalldataSize = abi.encodeCall(L2ForwarderFactory.callForwarder, (_x)).length;
    }

    /*
    normal:
        - msg.value check
        - pull tokens from caller
        - approve gateway
        - send through bridge
        - call factory
    custom fee + other token:
        - msg.value check (plus extra bridge retryable minus l3 retryable)
        - pull tokens from caller
        - pull fee tokens from caller
        - approve gateway for both
        - send both through bridge
        - call factory
    only custom fee:
        - msg.value check (minus l3 retryable)
        - pull fee tokens from caller
        - approve gateway
        - send fee through bridge
        - call factory
    */

    function _bridgeToken(
        address router,
        address token,
        address to,
        uint256 amount,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 submissionCost
    ) internal {
        L1GatewayRouter(router).outboundTransferCustomRefund{value: gasLimit * gasPrice + submissionCost}({
            _token: address(token),
            _refundTo: to,
            _to: to,
            _amount: amount,
            _maxGas: gasLimit,
            _gasPriceBid: gasPrice,
            _data: abi.encode(submissionCost, bytes(""))
        });
    }

    function buildL2ForwarderParams(TeleportParams memory params, address msgSender)
        public
        view
        returns (L2ForwarderParams memory)
    {
        address l2Token = L1GatewayRouter(params.l1l2Router).calculateL2TokenAddress(params.l1Token);
        address l2FeeToken = params.l1FeeToken == address(0)
            ? address(0)
            : L1GatewayRouter(params.l1l2Router).calculateL2TokenAddress(params.l1FeeToken);
        return L2ForwarderParams({
            // set owner to the aliased msg.sender.
            // As long as msg.sender can create retryables, they will be able to recover in case of failure
            owner: AddressAliasHelper.applyL1ToL2Alias(msgSender),
            l2Token: l2Token,
            l2FeeToken: l2FeeToken,
            routerOrInbox: params.l2l3RouterOrInbox,
            to: params.to,
            gasLimit: params.gasParams.l2l3TokenBridgeGasLimit,
            gasPrice: params.gasParams.l3GasPrice
        });
    }

    function _teleportCommon(
        TeleportParams memory params,
        RetryableGasCosts memory retryableCosts,
        L2ForwarderParams memory l2ForwarderParams,
        address l2Forwarder,
        address inbox
    ) internal {
        // pull in tokens from caller
        IERC20(params.l1Token).safeTransferFrom(msg.sender, address(this), params.amount);

        // approve gateway
        address gateway = L1GatewayRouter(params.l1l2Router).getGateway(params.l1Token);
        if (IERC20(params.l1Token).allowance(address(this), gateway) == 0) {
            IERC20(params.l1Token).safeApprove(gateway, type(uint256).max);
        }

        {
            // send tokens through the bridge to predicted forwarder
            // also send extra ETH as an overestimated submission fee
            _bridgeToken({
                router: params.l1l2Router,
                token: params.l1Token,
                to: l2Forwarder,
                amount: params.amount,
                gasLimit: params.gasParams.l1l2TokenBridgeGasLimit,
                gasPrice: params.gasParams.l2GasPrice,
                submissionCost: params.gasParams.l1l2TokenBridgeSubmissionCost
            });
        }

        // call the L2ForwarderFactory
        IInbox(inbox).createRetryableTicket{value: address(this).balance}({
            to: l2ForwarderFactory,
            l2CallValue: address(this).balance - retryableCosts.l2ForwarderFactoryCost,
            maxSubmissionCost: retryableCosts.l2ForwarderFactorySubmissionCost,
            excessFeeRefundAddress: l2Forwarder,
            callValueRefundAddress: l2Forwarder,
            gasLimit: params.gasParams.l2ForwarderFactoryGasLimit,
            maxFeePerGas: params.gasParams.l2GasPrice,
            data: abi.encodeCall(L2ForwarderFactory.callForwarder, (l2ForwarderParams))
        });
    }

    error InsufficientFeeToken(uint256 required, uint256 provided);

    /// @notice Start an L1 -> L3 transfer. msg.value sent must be >= the total cost of all retryables.
    ///         Any extra ETH will be sent to the receiver on L3.
    /// @dev    2 retryables will be created: one to send tokens and ETH to the L2Forwarder, and one to call the L2ForwarderFactory.
    ///         Extra ETH is sent through the first retryable as an overestimated submission fee.
    function teleport(TeleportParams memory params) external payable {
        // ensure we have enough msg.value
        (uint256 requiredEth, uint256 requiredFeeToken, RetryableGasCosts memory retryableCosts) =
            calculateRequiredEthAndFeeToken(params, block.basefee);
        if (msg.value < requiredEth) revert InsufficientValue(requiredEth, msg.value);

        // get inbox
        address inbox = L1GatewayRouter(params.l1l2Router).inbox();

        // create L2ForwarderParams
        L2ForwarderParams memory l2ForwarderParams = buildL2ForwarderParams(params, msg.sender);

        // calculate forwarder address
        address l2Forwarder = l2ForwarderAddress(l2ForwarderParams);

        // determine teleportation type
        TeleportationType _teleportationType = teleportationType(params);

        if (_teleportationType == TeleportationType.Standard) {
            // we are teleporting a token to an ETH fee L3
            _teleportCommon(params, retryableCosts, l2ForwarderParams, l2Forwarder, inbox);
        } else if (_teleportationType == TeleportationType.OnlyCustomFee) {
            // we are teleporting an L3's fee token

            // we have to make sure that the amount specified is enough to cover the retryable costs from L2 -> L3
            if (params.amount < requiredFeeToken) revert InsufficientFeeToken(requiredFeeToken, params.amount);

            // teleportation flow is identical to standard
            _teleportCommon(params, retryableCosts, l2ForwarderParams, l2Forwarder, inbox);
        } else {
            // we are teleporting a non-fee token to a custom fee L3
            // the flow is identical to standard,
            // except we have to send the appropriate amount of fee token through the bridge as well

            {
                // pull in fee tokens from caller
                IERC20(params.l1FeeToken).safeTransferFrom(msg.sender, address(this), requiredFeeToken);

                // approve gateway
                address gateway = L1GatewayRouter(params.l1l2Router).getGateway(params.l1FeeToken);
                if (IERC20(params.l1FeeToken).allowance(address(this), gateway) == 0) {
                    IERC20(params.l1FeeToken).safeApprove(gateway, type(uint256).max);
                }
            }

            // send fee tokens through the bridge to predicted forwarder
            _bridgeToken({
                router: params.l1l2Router,
                token: params.l1FeeToken,
                to: l2Forwarder,
                amount: requiredFeeToken,
                gasLimit: params.gasParams.l1l2FeeTokenBridgeGasLimit,
                gasPrice: params.gasParams.l2GasPrice,
                submissionCost: params.gasParams.l1l2FeeTokenBridgeSubmissionCost
            });

            // the rest of the flow is identical to standard
            _teleportCommon(params, retryableCosts, l2ForwarderParams, l2Forwarder, inbox);
        }
    }

    function calculateRequiredEthAndFeeToken(TeleportParams memory params, uint256 l1BaseFee)
        public
        view
        returns (uint256 ethAmount, uint256 feeTokenAmount, RetryableGasCosts memory costs)
    {
        // todo: optimize out redundant call to inbox() via a new internal function
        costs = _calculateRetryableGasCosts(L1GatewayRouter(params.l1l2Router).inbox(), l1BaseFee, params.gasParams);

        TeleportationType _teleportationType = teleportationType(params);
        if (_teleportationType == TeleportationType.NonFeeTokenToCustomFeeL3) {
            ethAmount = costs.l1l2TokenBridgeCost + costs.l1l2FeeTokenBridgeCost + costs.l2ForwarderFactoryCost;
            feeTokenAmount = costs.l2l3TokenBridgeCost;
        } else if (_teleportationType == TeleportationType.OnlyCustomFee) {
            ethAmount = costs.l1l2TokenBridgeCost + costs.l2ForwarderFactoryCost;
            feeTokenAmount = costs.l2l3TokenBridgeCost;
        } else {
            ethAmount = costs.l1l2TokenBridgeCost + costs.l2ForwarderFactoryCost + costs.l2l3TokenBridgeCost;
            feeTokenAmount = 0;
        }
    }

    function teleportationType(TeleportParams memory params) public pure returns (TeleportationType) {
        if (params.l1FeeToken == address(0)) {
            return TeleportationType.Standard;
        } else if (params.l1FeeToken == params.l1Token) {
            return TeleportationType.OnlyCustomFee;
        } else {
            return TeleportationType.NonFeeTokenToCustomFeeL3;
        }
    }

    enum TeleportationType {
        Standard,
        NonFeeTokenToCustomFeeL3,
        OnlyCustomFee
    }

    /// @notice Given some gas parameters, calculate the gas and submission costs for each retryable ticket.
    /// @param  inbox       L2's Inbox
    /// @param  l1BaseFee   L1's base fee
    /// @param  gasParams   Gas parameters for each retryable ticket
    function _calculateRetryableGasCosts(address inbox, uint256 l1BaseFee, RetryableGasParams memory gasParams)
        internal
        view
        returns (RetryableGasCosts memory results)
    {
        results.l2ForwarderFactorySubmissionCost =
            IInbox(inbox).calculateRetryableSubmissionFee(l2ForwarderFactoryCalldataSize, l1BaseFee);

        results.l1l2FeeTokenBridgeCost =
            gasParams.l1l2FeeTokenBridgeSubmissionCost + gasParams.l1l2FeeTokenBridgeGasLimit * gasParams.l2GasPrice;
        results.l1l2TokenBridgeCost =
            gasParams.l1l2TokenBridgeSubmissionCost + gasParams.l1l2TokenBridgeGasLimit * gasParams.l2GasPrice;
        results.l2ForwarderFactoryCost =
            results.l2ForwarderFactorySubmissionCost + gasParams.l2ForwarderFactoryGasLimit * gasParams.l2GasPrice;
        results.l2l3TokenBridgeCost =
            gasParams.l2l3TokenBridgeSubmissionCost + gasParams.l2l3TokenBridgeGasLimit * gasParams.l3GasPrice;
    }
}
