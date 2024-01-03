// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L2ForwarderContractsDeployer} from "../contracts/L2ForwarderContractsDeployer.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2Forwarder} from "../contracts/L2Forwarder.sol";
import {L2ForwarderPredictor} from "../contracts/L2ForwarderPredictor.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {ForkTest} from "./Fork.t.sol";
import {BaseTest} from "./Base.t.sol";
import {L1ArbitrumGateway} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol";
import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";

contract NewL2ForwarderTest is BaseTest {
    L2ForwarderFactory factory;
    L2Forwarder implementation;

    address owner = address(0x1111);
    address l3Recipient = address(0x2222);

    MockToken l2Token;

    function setUp() public override {
        super.setUp();
        L2ForwarderContractsDeployer deployer = new L2ForwarderContractsDeployer();
        factory = L2ForwarderFactory(deployer.factory());
        implementation = L2Forwarder(payable(deployer.implementation()));
        l2Token = new MockToken("MOCK", "MOCK", 100 ether, address(this));
    }

    function testNativeTokenHappyCase() public {
        _bridgeNativeTokenHappyCase(1 ether, 1_000_000, 0.1 gwei, 0.1 ether, 2 ether);
    }

    function testEthFeesHappyCase() public {
        _bridgeTokenEthFeesHappyCase(1 ether, 1_000_000, 0.1 gwei, 0.1 ether, 2 ether);
    }

    function testNonFeeTokenHappyCase() public {
        _bridgeNonFeeTokenHappyCase(1 ether, 1_000_000, 0.1 gwei, 0.1 ether, 2 ether, 3 ether);
    }

    function testRescue() public {
        L2ForwarderPredictor.L2ForwarderParams memory params;
        params.owner = owner;

        // create the forwarder
        L2Forwarder forwarder = factory.createL2Forwarder(params);

        // create rescue params
        address[] memory targets = new address[](1);
        targets[0] = address(0x9999);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        datas[0] = hex"12345678";

        // test access control
        vm.expectRevert(L2Forwarder.OnlyOwner.selector);
        forwarder.rescue(targets, values, datas);

        // test length mismatch
        vm.prank(owner);
        vm.expectRevert(L2Forwarder.LengthMismatch.selector);
        forwarder.rescue(targets, values, new bytes[](0));

        // test call failure
        values[0] = 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(L2Forwarder.CallFailed.selector, targets[0], values[0], datas[0], ""));
        forwarder.rescue(targets, values, datas);
        values[0] = 0;

        // happy case
        vm.prank(owner);
        vm.expectCall(targets[0], datas[0]);
        forwarder.rescue(targets, values, datas);
    }

    function _bridgeNonFeeTokenHappyCase(
        uint256 tokenAmount,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 relayerPayment,
        uint256 forwarderETHBalance,
        uint256 forwarderNativeBalance
    ) internal {
        L2ForwarderPredictor.L2ForwarderParams memory params = L2ForwarderPredictor.L2ForwarderParams({
            owner: owner,
            token: address(l2Token),
            l2FeeToken: address(nativeToken),
            routerOrInbox: address(erc20GatewayRouter),
            to: l3Recipient,
            gasLimit: gasLimit,
            gasPrice: gasPrice,
            relayerPayment: relayerPayment
        });

        address forwarder = factory.l2ForwarderAddress(params);

        // give the forwarder some ETH, the first leg retryable would do this in practice
        vm.deal(forwarder, forwarderETHBalance);

        // give the forwarder some tokens, the first leg retryable would do this in practice
        l2Token.transfer(forwarder, tokenAmount);

        // give the forwarder some native token, the first leg retryable would do this in practice
        nativeToken.transfer(forwarder, forwarderNativeBalance);

        uint256 relayerBalanceBefore = tx.origin.balance;

        bytes memory data = _getTokenBridgeRetryableCalldata(address(erc20GatewayRouter), forwarder, tokenAmount);
        uint256 msgCount = erc20Bridge.delayedMessageCount();
        _expectRetryable({
            inbox: address(erc20Inbox),
            msgCount: msgCount,
            to: l2DefaultGateway, // counterpart gateway
            l2CallValue: 0,
            msgValue: forwarderNativeBalance,
            maxSubmissionCost: forwarderNativeBalance - params.gasLimit * params.gasPrice,
            excessFeeRefundAddress: params.to,
            callValueRefundAddress: AddressAliasHelper.applyL1ToL2Alias(forwarder),
            gasLimit: params.gasLimit,
            maxFeePerGas: params.gasPrice,
            data: data
        });
        vm.expectEmit(address(erc20DefaultGateway));
        emit DepositInitiated({
            l1Token: address(l2Token),
            _from: address(forwarder),
            _to: l3Recipient,
            _sequenceNumber: msgCount,
            _amount: tokenAmount
        });
        factory.callForwarder(params);

        // make sure the relayer was paid
        assertEq(tx.origin.balance, relayerBalanceBefore + relayerPayment);

        // make sure the forwarder has forwarderETHBalance - relayerPayment ETH left
        assertEq(address(forwarder).balance, forwarderETHBalance - relayerPayment);
    }

    function _bridgeNativeTokenHappyCase(
        uint256 tokenAmount,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 relayerPayment,
        uint256 forwarderETHBalance
    ) internal {
        L2ForwarderPredictor.L2ForwarderParams memory params = L2ForwarderPredictor.L2ForwarderParams({
            owner: owner,
            token: address(nativeToken),
            l2FeeToken: address(nativeToken),
            routerOrInbox: address(erc20Inbox),
            to: l3Recipient,
            gasLimit: gasLimit,
            gasPrice: gasPrice,
            relayerPayment: relayerPayment
        });

        address forwarder = factory.l2ForwarderAddress(params);

        // give the forwarder some ETH, the first leg retryable would do this in practice
        vm.deal(forwarder, forwarderETHBalance);

        // give the forwarder some native token, the first leg retryable would do this in practice
        nativeToken.transfer(forwarder, tokenAmount);

        uint256 relayerBalanceBefore = tx.origin.balance;

        uint256 msgCount = erc20Bridge.delayedMessageCount();
        _expectRetryable({
            inbox: address(erc20Inbox),
            msgCount: msgCount,
            to: params.to,
            l2CallValue: tokenAmount - erc20Inbox.calculateRetryableSubmissionFee(0,0) - params.gasLimit * params.gasPrice,
            msgValue: tokenAmount,
            maxSubmissionCost: erc20Inbox.calculateRetryableSubmissionFee(0,0),
            excessFeeRefundAddress: params.to,
            callValueRefundAddress: params.to,
            gasLimit: params.gasLimit,
            maxFeePerGas: params.gasPrice,
            data: ""
        });
        factory.callForwarder(params);

        // make sure the relayer was paid
        assertEq(tx.origin.balance, relayerBalanceBefore + relayerPayment);

        // make sure the forwarder has forwarderETHBalance - relayerPayment ETH left
        assertEq(address(forwarder).balance, forwarderETHBalance - relayerPayment);
    }

    function _bridgeTokenEthFeesHappyCase(
        uint256 tokenAmount,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 relayerPayment,
        uint256 forwarderETHBalance
    ) internal {
        L2ForwarderPredictor.L2ForwarderParams memory params = L2ForwarderPredictor.L2ForwarderParams({
            owner: owner,
            token: address(l2Token),
            l2FeeToken: address(0),
            routerOrInbox: address(ethGatewayRouter),
            to: l3Recipient,
            gasLimit: gasLimit,
            gasPrice: gasPrice,
            relayerPayment: relayerPayment
        });

        address forwarder = factory.l2ForwarderAddress(params);

        // give the forwarder some ETH, the first leg retryable would do this in practice
        vm.deal(forwarder, forwarderETHBalance);

        // give the forwarder some tokens, the first leg retryable would do this in practice
        l2Token.transfer(forwarder, tokenAmount);

        uint256 relayerBalanceBefore = tx.origin.balance;

        _expectBridgeTokenEthFeesHappyCaseEvents(params, forwarderETHBalance, gasLimit, gasPrice, tokenAmount);
        factory.callForwarder(params);

        // make sure the relayer was paid
        assertEq(tx.origin.balance, relayerBalanceBefore + relayerPayment);

        // make sure the forwarder has 0 ETH left
        assertEq(address(forwarder).balance, 0);
    }

    function _expectBridgeTokenEthFeesHappyCaseEvents(
        L2ForwarderPredictor.L2ForwarderParams memory params,
        uint256 forwarderETHBalance,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 tokenAmount
    ) internal {
        address forwarder = factory.l2ForwarderAddress(params);

        uint256 msgCount = erc20Bridge.delayedMessageCount();
        bytes memory data = _getTokenBridgeRetryableCalldata(address(ethGatewayRouter), forwarder, tokenAmount);
        _expectRetryable({
            inbox: address(ethInbox),
            msgCount: msgCount,
            to: ethDefaultGateway.counterpartGateway(),
            l2CallValue: 0,
            msgValue: forwarderETHBalance - params.relayerPayment,
            maxSubmissionCost: forwarderETHBalance - gasLimit * gasPrice - params.relayerPayment,
            excessFeeRefundAddress: l3Recipient,
            callValueRefundAddress: AddressAliasHelper.applyL1ToL2Alias(forwarder),
            gasLimit: gasLimit,
            maxFeePerGas: gasPrice,
            data: data
        });

        // token bridge, indicating an actual bridge tx has been initiated
        vm.expectEmit(address(ethDefaultGateway));
        emit DepositInitiated({
            l1Token: address(l2Token),
            _from: address(forwarder),
            _to: l3Recipient,
            _sequenceNumber: msgCount,
            _amount: tokenAmount
        });
    }

    function _getTokenBridgeRetryableCalldata(address gatewayRouter, address l2Forwarder, uint256 tokenAmount)
        internal
        view
        returns (bytes memory)
    {
        address l1Gateway = L1GatewayRouter(gatewayRouter).getGateway(address(l2Token));
        bytes memory l1l2TokenBridgeRetryableCalldata = L1ArbitrumGateway(l1Gateway).getOutboundCalldata({
            _l1Token: address(l2Token),
            _from: address(l2Forwarder),
            _to: l3Recipient,
            _amount: tokenAmount,
            _data: ""
        });
        return l1l2TokenBridgeRetryableCalldata;
    }
}
