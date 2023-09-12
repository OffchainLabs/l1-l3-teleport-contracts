// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {Teleporter} from "../contracts/Teleporter.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {MockToken} from "../contracts/mocks/MockToken.sol";
import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {L1ArbitrumGateway} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol";
import {Bridge} from "@arbitrum/nitro-contracts/src/bridge/Bridge.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract TeleporterTest is Test {
    L1GatewayRouter l1l2Router = L1GatewayRouter(0x72Ce9c846789fdB6fC1f34aC4AD25Dd9ef7031ef);
    IInbox inbox = IInbox(l1l2Router.inbox());
    L1ArbitrumGateway defaultGateway = L1ArbitrumGateway(l1l2Router.defaultGateway());
    Bridge bridge = Bridge(address(inbox.bridge()));

    address l2l3Router = vm.addr(0x10);

    Teleporter teleporter;
    IERC20 l1Token;
    address l2ForwarderFactory = address(0x1100);
    address receiver = address(0x2200);

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
        teleporter = new Teleporter(l2ForwarderFactory);
        l1Token = IERC20(new MockToken("MOCK", "MOCK", 100 ether, address(this)));

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

        uint256 msgCount = bridge.delayedMessageCount();
        address l2Forwarder = teleporter.l2ForwarderAddress(address(this));

        bytes memory calldataToFactory = abi.encodeCall(
            L2ForwarderFactory.callForwarder,
            (
                address(this),
                l1l2Router.calculateL2TokenAddress(address(l1Token)),
                l2l3Router,
                receiver,
                amount,
                params.l2l3TokenBridgeGasLimit,
                params.l3GasPrice
            )
        );

        // vm.expectEmit(address(defaultGateway));
        vm.expectEmit(address(defaultGateway));
        emit DepositInitiated({
            l1Token: address(l1Token),
            _from: address(teleporter),
            _to: l2Forwarder,
            _sequenceNumber: msgCount,
            _amount: amount
        });
        vm.expectEmit(address(inbox));
        emit InboxMessageDelivered(msgCount+1, abi.encodePacked(
            uint256(uint160(l2ForwarderFactory)),
            valueToSend - costs.l1l2TokenBridgeGasCost - costs.l1l2TokenBridgeSubmissionCost - costs.l2ForwarderFactoryGasCost - costs.l2ForwarderFactorySubmissionCost,
            valueToSend - costs.l1l2TokenBridgeGasCost - costs.l1l2TokenBridgeSubmissionCost,
            costs.l2ForwarderFactorySubmissionCost,
            uint256(uint160(l2Forwarder)),
            uint256(uint160(l2Forwarder)),
            params.l2ForwarderFactoryGasLimit,
            params.l2GasPrice,
            calldataToFactory.length,
            calldataToFactory          
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
