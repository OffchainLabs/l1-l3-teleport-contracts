// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {L1ArbitrumMessenger} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/L1ArbitrumMessenger.sol";
import {ClonableBeaconProxy} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/libraries/ClonableBeaconProxy.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IL1ArbitrumGateway} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/IL1ArbitrumGateway.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {L2ForwarderFactory} from "./L2ForwarderFactory.sol";

/// @notice Teleports tokens from L1 to L3.
contract Teleporter is L1ArbitrumMessenger {
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

    bytes32 constant cloneableProxyHash = keccak256(type(ClonableBeaconProxy).creationCode);

    /// @dev Calldata size of L2ForwarderFactory.callForwarder (selector + 7 args).
    ///      Necessary to calculate the submission cost of the retryable ticket to L2ForwarderFactory.
    uint256 constant l2ForwarderFactoryCalldataSize = 4 + 7 * 32;

    /// @notice Address of the L2ForwarderFactory. It is the same on all L2s.
    address public immutable l2ForwarderFactory;

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

    constructor(address _l2ForwarderFactory) {
        l2ForwarderFactory = _l2ForwarderFactory;
    }

    /// @notice Start a teleportation. Value sent must be >= the total cost of all retryables. 
    ///         Any extra ETH will be sent to the receiver on L3.
    /// @param  l1Token     L1 token being teleported
    /// @param  l1l2Router  L1 to L2 token bridge router
    /// @param  l2l3Router  L2 to L3 token bridge router
    /// @param  to          L3 address that will receive the tokens
    /// @param  amount      Amount of tokens being teleported
    /// @param  gasParams   Gas parameters for each retryable ticket
    /// @dev    2 retryables will be created: one to bridge tokens to the L2Forwarder, and one to call the L2ForwarderFactory.
    ///         Extra ETH is sent as l2CallValue to the L2ForwarderFactory, which will be sent through the L2Forwarder to L3.
    function teleport(
        address l1Token,
        address l1l2Router,
        address l2l3Router,
        address to,
        uint256 amount,
        RetryableGasParams calldata gasParams
    ) external payable {
        // get inbox
        address inbox = L1GatewayRouter(l1l2Router).inbox();

        // msg.value accounting checks
        RetryableGasCosts memory gasResults = calculateRetryableGasCosts(inbox, block.basefee, gasParams);

        if (msg.value < gasResults.total) revert InsufficientValue(gasResults.total, msg.value);

        // pull in tokens from caller
        IERC20(l1Token).transferFrom(msg.sender, address(this), amount);

        // approve gateway
        IERC20(l1Token).approve(L1GatewayRouter(l1l2Router).getGateway(l1Token), amount);

        // calculate forwarder address of caller
        address l2Forwarder = l2ForwarderAddress(msg.sender);

        // send tokens through the bridge to predicted forwarder
        L1GatewayRouter(l1l2Router).outboundTransferCustomRefund{
            value: gasResults.l1l2TokenBridgeGasCost + gasResults.l1l2TokenBridgeSubmissionCost
        }(
            address(l1Token),
            l2Forwarder,
            l2Forwarder,
            amount,
            gasParams.l1l2TokenBridgeGasLimit,
            gasParams.l2GasPrice,
            abi.encode(gasResults.l1l2TokenBridgeSubmissionCost, bytes(""))
        );

        // call the L2ForwarderFactory
        bytes memory l2ForwarderFactoryCalldata = abi.encodeWithSelector(
            L2ForwarderFactory.callForwarder.selector,
            msg.sender,
            L1GatewayRouter(l1l2Router).calculateL2TokenAddress(l1Token),
            l2l3Router,
            to,
            amount,
            gasParams.l2l3TokenBridgeGasLimit,
            gasParams.l3GasPrice
        );
        sendTxToL2CustomRefund({
            _inbox: address(inbox),
            _to: l2ForwarderFactory,
            _refundTo: l2Forwarder,
            _user: l2Forwarder,
            _l1CallValue: address(this).balance, // send everything left
            _l2CallValue: address(this).balance - gasResults.l2ForwarderFactorySubmissionCost
                - gasResults.l2ForwarderFactoryGasCost,
            _maxSubmissionCost: gasResults.l2ForwarderFactorySubmissionCost,
            _maxGas: gasParams.l2ForwarderFactoryGasLimit,
            _gasPriceBid: gasParams.l2GasPrice,
            _data: l2ForwarderFactoryCalldata
        });

        emit Teleported({
            l1Owner: msg.sender,
            l1Token: address(l1Token),
            l1l2Router: address(l1l2Router),
            l2l3Router: l2l3Router,
            to: to,
            amount: amount
        });
    }

    /// @notice Given some gas parameters, calculate the gas and submission costs for each retryable ticket.
    /// @param  inbox       L2's Inbox
    /// @param  l1BaseFee   L1's base fee
    /// @param  gasParams   Gas parameters for each retryable ticket
    function calculateRetryableGasCosts(address inbox, uint256 l1BaseFee, RetryableGasParams calldata gasParams)
        public
        view
        returns (RetryableGasCosts memory results)
    {
        // submission costs:
        // on L1: l1l2TokenBridgeSubmissionCost, l2ForwarderFactorySubmissionCost
        // on L2: l2l3TokenBridgeSubmissionCost

        // gas costs:
        // on L1: none
        // on L2: l1l2TokenBridgeGasCost, l2ForwarderFactoryGasCost
        // on L3: l2l3TokenBridgeGasCost

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

    /// @notice Calculate the address of the L2Forwarder for the given L1 owner.
    function l2ForwarderAddress(address l1Owner) public view returns (address) {
        return Create2.computeAddress(bytes20(l1Owner), cloneableProxyHash, l2ForwarderFactory);
    }
}
