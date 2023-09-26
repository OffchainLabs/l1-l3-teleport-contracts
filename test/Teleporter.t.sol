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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkTest} from "./Fork.t.sol";


contract TeleporterTest is ForkTest {
    address l2l3Router = vm.addr(0x10);

    Teleporter teleporter;
    IERC20 l1Token;

    address l2ForwarderFactory = address(0x1100);
    address l2ForwarderImpl = address(0x2200);

    address receiver = address(0x3300);

    // from the default gateway
    event DepositInitiated(
        address l1Token,
        address indexed _from,
        address indexed _to,
        uint256 indexed _sequenceNumber,
        uint256 _amount
    );

    // from inbox
    event InboxMessageDelivered(uint256 indexed messageNum, bytes data);

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
        teleporter.teleport{value: costs.total - 1}({
            l1Token: address(l1Token),
            l1l2Router: address(l1l2Router),
            l2l3Router: l2l3Router,
            to: receiver,
            amount: 10 ether,
            gasParams: params
        });
    }

    function testRetryableCreation() public {
        uint256 amount = 1 ether;

        l1Token.transfer(address(this), amount);

        l1Token.approve(address(teleporter), amount);

        (Teleporter.RetryableGasParams memory params, Teleporter.RetryableGasCosts memory costs) =
            _defaultParamsAndCosts();

        uint256 valueToSend = 1 ether + costs.total;

        L2ForwarderPredictor.L2ForwarderParams memory l2ForwarderParams = L2ForwarderPredictor.L2ForwarderParams({
            owner: AddressAliasHelper.applyL1ToL2Alias(address(this)),
            token: l1l2Router.calculateL2TokenAddress(address(l1Token)),
            router: l2l3Router,
            to: receiver,
            amount: amount - 1, // since this is the first transfer, 1 wei will be kept by the teleporter
            gasLimit: params.l2l3TokenBridgeGasLimit,
            gasPrice: params.l3GasPrice,
            relayerPayment: 0
        });

        uint256 msgCount = bridge.delayedMessageCount();
        address l2Forwarder = teleporter.l2ForwarderAddress(l2ForwarderParams);

        bytes memory calldataToFactory = abi.encodeCall(
            L2ForwarderFactory.callForwarder,
            (l2ForwarderParams)
        );

        vm.expectEmit(address(defaultGateway));
        // token bridge
        emit DepositInitiated({
            l1Token: address(l1Token),
            _from: address(teleporter),
            _to: l2Forwarder,
            _sequenceNumber: msgCount,
            _amount: amount - 1 // since this is the first transfer, 1 wei will be kept by the teleporter
        });
        vm.expectEmit(address(inbox));
        // call to L2ForwarderFactory
        emit InboxMessageDelivered(msgCount+1, abi.encodePacked(
            uint256(uint160(l2ForwarderFactory)), // to
            uint256(0), // l2 call value
            costs.l2ForwarderFactoryGasCost + costs.l2ForwarderFactorySubmissionCost, // msg.value
            costs.l2ForwarderFactorySubmissionCost, // maxSubmissionCost
            uint256(uint160(l2Forwarder)), // excessFeeRefundAddress
            uint256(uint160(l2Forwarder)), // callValueRefundAddress
            params.l2ForwarderFactoryGasLimit, // gasLimit
            params.l2GasPrice, // maxFeePerGas
            calldataToFactory.length, // data.length
            calldataToFactory // data
        ));
        teleporter.teleport{value: valueToSend}({
            l1Token: address(l1Token),
            l1l2Router: address(l1l2Router),
            l2l3Router: l2l3Router,
            to: receiver,
            amount: amount,
            gasParams: params
        });
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
