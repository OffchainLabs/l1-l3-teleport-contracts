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

// deploy one of these on L1 for each L2
// user calls teleport:
// - pulls in tokens and sends them over the bridge to user's L2Forwarder
// - tells the L2ForwarderFactory (via retryable) to create a forwarder and bridge for user
contract Teleporter is L1ArbitrumMessenger {
    struct RetryableGasParams {
        uint256 l2GasPrice;
        uint256 l3GasPrice;
        // gas limit for retryable calling L2ForwarderFactory.bridgeToL3
        uint256 l2ForwarderFactoryGasLimit;
        // gas limit for l1 to l2 token bridge retryable
        uint256 l1l2TokenBridgeGasLimit;
        // gas limit for l2 to l3 token bridge retryable
        uint256 l2l3TokenBridgeGasLimit;
        uint256 l1l2TokenBridgeRetryableSize;
        uint256 l2l3TokenBridgeRetryableSize;
    }

    // todo: needs a better name
    struct RetryableGasResults {
        uint256 l1l2TokenBridgeSubmissionCost;
        uint256 l2ForwarderFactorySubmissionCost;
        uint256 l2l3TokenBridgeSubmissionCost;
        uint256 l1l2TokenBridgeGasCost;
        uint256 l2ForwarderFactoryGasCost;
        uint256 l2l3TokenBridgeGasCost;
        uint256 total;
    }

    bytes32 constant cloneableProxyHash = keccak256(type(ClonableBeaconProxy).creationCode);

    uint256 public constant l2ForwarderFactoryCalldataSize = 4 + 7 * 32; // selector + 7 args

    // address is the same on each L2, deployed with CREATE2
    address public immutable l2ForwarderFactory;

    event Teleported(
        address indexed l1Owner,
        address l1Token,
        address l1l2Router,
        address l2l3Router,
        address to,
        uint256 amount
    );

    error InsufficientValue(uint256 required, uint256 provided);

    constructor(address _l2ForwarderFactory) {
        l2ForwarderFactory = _l2ForwarderFactory;
    }

    function calculateRetryableGasResults(
        IInbox inbox,
        uint256 l1BaseFee,
        RetryableGasParams calldata gasParams
    ) public view returns (RetryableGasResults memory results) {
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
            inbox.calculateRetryableSubmissionFee(gasParams.l1l2TokenBridgeRetryableSize, l1BaseFee);
        results.l2ForwarderFactorySubmissionCost =
            inbox.calculateRetryableSubmissionFee(l2ForwarderFactoryCalldataSize, l1BaseFee);
        results.l2l3TokenBridgeSubmissionCost =
            inbox.calculateRetryableSubmissionFee(gasParams.l2l3TokenBridgeRetryableSize, gasParams.l2GasPrice);

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

    // todo: maybe this should take the l1Gateway as param instead of using the router?
    function teleport(
        IERC20 l1Token,
        address to,
        uint256 amount,
        L1GatewayRouter l1l2Router,
        address l2l3Router,
        RetryableGasParams calldata gasParams
    ) external payable {
        address l2Forwarder = predictForwarderAddress(msg.sender);

        // get gateway
        IL1ArbitrumGateway l1Gateway = IL1ArbitrumGateway(l1l2Router.getGateway(address(l1Token)));

        // get l2 token
        address l2Token = l1Gateway.calculateL2TokenAddress(address(l1Token));

        // get inbox
        IInbox inbox = IInbox(l1Gateway.inbox());

        // msg.value accounting checks
        RetryableGasResults memory gasResults =
            calculateRetryableGasResults(inbox, block.basefee, gasParams);

        if (msg.value < gasResults.total) revert InsufficientValue(gasResults.total, msg.value);

        // pull in tokens from user
        l1Token.transferFrom(msg.sender, address(this), amount);

        // approve gateway
        l1Token.approve(address(l1Gateway), amount);

        // send tokens through the bridge to predicted forwarder
        l1l2Router.outboundTransferCustomRefund{
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

        // tell the L2ForwarderFactory to create a forwarder and bridge for user
        bytes memory l2ForwarderFactoryCalldata = abi.encodeWithSelector(
            L2ForwarderFactory.callForwarder.selector,
            msg.sender,
            l2l3Router,
            l2Token,
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

    function predictForwarderAddress(address l1Owner) public view returns (address) {
        return Create2.computeAddress(bytes20(l1Owner), cloneableProxyHash, l2ForwarderFactory);
    }
}
