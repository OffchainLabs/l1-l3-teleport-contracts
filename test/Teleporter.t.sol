// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {Teleporter} from "../contracts/Teleporter.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2ForwarderPredictor} from "../contracts/L2ForwarderPredictor.sol";
import {MockToken} from "../contracts/mocks/MockToken.sol";
import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {L1ArbitrumGateway} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol";
import {Bridge} from "@arbitrum/nitro-contracts/src/bridge/Bridge.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {L1ArbitrumGateway} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkTest} from "./Fork.t.sol";


contract TeleporterTest is ForkTest {
    address immutable l2l3Router = vm.addr(0x10);

    Teleporter teleporter;
    IERC20 l1Token;

    address constant l2ForwarderFactory = address(0x1100);
    address constant l2ForwarderImpl = address(0x2200);

    address constant receiver = address(0x3300);
    uint256 constant amount = 1 ether;

    function setUp() public {
        teleporter = new Teleporter(l2ForwarderFactory, l2ForwarderImpl);
        l1Token = IERC20(new MockToken("MOCK", "MOCK", 100 ether, address(this)));
        // l1Token.transfer(address(teleporter), 1);
        vm.deal(address(this), 100 ether);
    }

    function testTeleportValueCheck() public {
        (Teleporter.RetryableGasParams memory params, Teleporter.RetryableGasCosts memory costs) =
            _defaultParamsAndCosts();

        vm.expectRevert(abi.encodeWithSelector(Teleporter.InsufficientValue.selector, costs.total, costs.total - 1));
        teleporter.teleport{value: costs.total - 1}(Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l1l2Router: address(l1l2Router),
            l2l3Router: l2l3Router,
            to: receiver,
            amount: 10 ether,
            gasParams: params,
            randomNonce: 1
        }));
    }

    function testRetryableCreation() public {
        l1Token.transfer(address(this), amount);

        l1Token.approve(address(teleporter), amount);

        (Teleporter.RetryableGasParams memory params, Teleporter.RetryableGasCosts memory costs) =
            _defaultParamsAndCosts();

        _expectEvents();
        teleporter.teleport{value: costs.total}(Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l1l2Router: address(l1l2Router),
            l2l3Router: l2l3Router,
            to: receiver,
            amount: amount,
            gasParams: params,
            randomNonce: 1
        }));
    }

    function _expectEvents() internal {
        (Teleporter.RetryableGasParams memory params, Teleporter.RetryableGasCosts memory costs) =
            _defaultParamsAndCosts();
        
        L2ForwarderPredictor.L2ForwarderParams memory l2ForwarderParams = L2ForwarderPredictor.L2ForwarderParams({
            owner: AddressAliasHelper.applyL1ToL2Alias(address(this)),
            token: l1l2Router.calculateL2TokenAddress(address(l1Token)),
            router: l2l3Router,
            to: receiver,
            amount: amount - 1, // since this is the first transfer, 1 wei will be kept by the teleporter
            gasLimit: params.l2l3TokenBridgeGasLimit,
            gasPrice: params.l3GasPrice,
            relayerPayment: 0,
            randomNonce: 1
        });

        uint256 msgCount = bridge.delayedMessageCount();
        address l2Forwarder = teleporter.l2ForwarderAddress(l2ForwarderParams);
        address counterpartGateway = defaultGateway.counterpartGateway();

        bytes memory calldataToFactory = abi.encodeCall(
            L2ForwarderFactory.callForwarder,
            (l2ForwarderParams)
        );

        // token bridge retryable
        _expectRetryable(
            msgCount,
            counterpartGateway,
            0, // l2 call value
            costs.total - costs.l2ForwarderFactoryGasCost - costs.l2ForwarderFactorySubmissionCost, // msg.value
            costs.total - costs.l2ForwarderFactoryGasCost - costs.l2ForwarderFactorySubmissionCost - costs.l1l2TokenBridgeGasCost, // maxSubmissionCost
            l2Forwarder, // excessFeeRefundAddress
            AddressAliasHelper.applyL1ToL2Alias(address(teleporter)), // callValueRefundAddress
            params.l1l2TokenBridgeGasLimit, // gasLimit
            params.l2GasPrice, // maxFeePerGas
            _getTokenBridgeRetryableCalldata(l2Forwarder) // data
        );

        // token bridge, indicating an actual bridge tx has been initiated
        vm.expectEmit(address(defaultGateway));
        emit DepositInitiated({
            l1Token: address(l1Token),
            _from: address(teleporter),
            _to: l2Forwarder,
            _sequenceNumber: msgCount,
            _amount: amount - 1 // since this is the first transfer, 1 wei will be kept by the teleporter
        });

        // call to the factory
        _expectRetryable(
            msgCount + 1,
            l2ForwarderFactory, // to
            0, // l2 call value
            costs.l2ForwarderFactoryGasCost + costs.l2ForwarderFactorySubmissionCost, // msg.value
            costs.l2ForwarderFactorySubmissionCost, // maxSubmissionCost
            l2Forwarder, // excessFeeRefundAddress
            l2Forwarder, // callValueRefundAddress
            params.l2ForwarderFactoryGasLimit, // gasLimit
            params.l2GasPrice, // maxFeePerGas
            calldataToFactory // data
        );
    }

    function _getTokenBridgeRetryableCalldata(address l2Forwarder) internal view returns (bytes memory) {
        address l1Gateway = l1l2Router.getGateway(address(l1Token));
        bytes memory l1l2TokenBridgeRetryableCalldata = L1ArbitrumGateway(l1Gateway).getOutboundCalldata({
            _l1Token: address(l1Token),
            _from: address(teleporter),
            _to: l2Forwarder,
            _amount: amount - 1, // since this is the first transfer, 1 wei will be kept by the teleporter
            _data: ""
        });
        return l1l2TokenBridgeRetryableCalldata;
    }
    
    function _defaultParams() internal pure returns (Teleporter.RetryableGasParams memory) {
        return Teleporter.RetryableGasParams({
            l2GasPrice: 0.1 gwei,
            l3GasPrice: 0.1 gwei,
            l2ForwarderFactoryGasLimit: 1_000_000,
            l1l2TokenBridgeGasLimit: 1_000_000,
            l2l3TokenBridgeGasLimit: 1_000_000,
            l1l2TokenBridgeRetryableSize: 1000,
            l2l3TokenBridgeRetryableSize: 1000
        });
    }

    function _defaultParamsAndCosts()
        internal
        view
        returns (Teleporter.RetryableGasParams memory, Teleporter.RetryableGasCosts memory)
    {
        Teleporter.RetryableGasParams memory params = _defaultParams();
        Teleporter.RetryableGasCosts memory costs = teleporter.calculateRetryableGasCosts(l1l2Router.inbox(), 0, params);
        return (params, costs);
    }
}
