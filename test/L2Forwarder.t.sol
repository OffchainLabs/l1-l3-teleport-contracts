// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L2ForwarderContractsDeployer} from "../contracts/L2ForwarderContractsDeployer.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2Forwarder} from "../contracts/L2Forwarder.sol";
import {L2ForwarderPredictor} from "../contracts/L2ForwarderPredictor.sol";
import {BaseTest} from "./Base.t.sol";
import {L1ArbitrumGateway} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol";
import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {IL2Forwarder} from "../contracts/interfaces/IL2Forwarder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20PresetMinterPauser} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

contract L2ForwarderTest is BaseTest {
    L2ForwarderFactory factory;
    L2Forwarder implementation;

    address owner = address(0x1111);
    address l3Recipient = address(0x2222);

    address aliasedL1Teleporter = address(0x2211);

    IERC20 l2Token;

    function setUp() public override {
        super.setUp();
        L2ForwarderContractsDeployer deployer = new L2ForwarderContractsDeployer(aliasedL1Teleporter, 1);
        factory = L2ForwarderFactory(deployer.factory());
        implementation = L2Forwarder(payable(deployer.implementation()));
        l2Token = IERC20(new ERC20PresetMinterPauser("MOCK", "MOCK"));
        ERC20PresetMinterPauser(address(l2Token)).mint(address(this), 10000 ether);

        vm.deal(aliasedL1Teleporter, 10000 ether);
    }

    function testOnlyL2ForwarderFactory() public {
        L2Forwarder.L2ForwarderParams memory params;
        IL2Forwarder forwarder = factory.createL2Forwarder(params);
        vm.expectRevert(IL2Forwarder.OnlyL2ForwarderFactory.selector);
        forwarder.bridgeToL3(params);
    }

    function testNativeTokenHappyCase() public {
        _bridgeNativeTokenHappyCase({
            tokenAmount: 1 ether,
            gasLimit: 1_000_000,
            gasPriceBid: 0.1 gwei,
            forwarderETHBalance: 2 ether,
            msgValue: 3 ether
        });
    }

    function testEthFeesHappyCase() public {
        _bridgeTokenEthFeesHappyCase({
            tokenAmount: 1 ether,
            gasLimit: 1_000_000,
            gasPriceBid: 0.1 gwei,
            forwarderETHBalance: 0.01 ether,
            msgValue: 0.1 ether
        });
    }

    function testNonFeeTokenHappyCase() public {
        _bridgeNonFeeTokenHappyCase({
            tokenAmount: 1 ether,
            gasLimit: 1_000_000,
            gasPriceBid: 0.1 gwei,
            forwarderETHBalance: 0.1 ether,
            msgValue: 0.2 ether,
            forwarderNativeBalance: 3 ether
        });
    }

    function testRescue() public {
        IL2Forwarder.L2ForwarderParams memory params;
        params.owner = owner;

        // create the forwarder
        IL2Forwarder forwarder = factory.createL2Forwarder(params);

        // create rescue params
        address[] memory targets = new address[](1);
        targets[0] = address(0x9999);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        datas[0] = hex"12345678";

        // test access control
        vm.expectRevert(IL2Forwarder.OnlyOwner.selector);
        forwarder.rescue(targets, values, datas);

        // test length mismatch
        vm.prank(owner);
        vm.expectRevert(IL2Forwarder.LengthMismatch.selector);
        forwarder.rescue(targets, values, new bytes[](0));

        // test call failure
        values[0] = 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IL2Forwarder.CallFailed.selector, targets[0], values[0], datas[0], ""));
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
        uint256 gasPriceBid,
        uint256 forwarderETHBalance,
        uint256 msgValue,
        uint256 forwarderNativeBalance
    ) internal {
        IL2Forwarder.L2ForwarderParams memory params = IL2Forwarder.L2ForwarderParams({
            owner: owner,
            l2Token: address(l2Token),
            l2FeeToken: address(nativeToken),
            routerOrInbox: address(erc20GatewayRouter),
            to: l3Recipient,
            gasLimit: gasLimit,
            gasPriceBid: gasPriceBid
        });

        address forwarder = factory.l2ForwarderAddress(params.owner);

        // give the forwarder some ETH, the first leg retryable would do this in practice
        vm.deal(forwarder, forwarderETHBalance);

        // give the forwarder some tokens, the first leg retryable would do this in practice
        l2Token.transfer(forwarder, tokenAmount);

        // give the forwarder some native token, the first leg retryable would do this in practice
        nativeToken.transfer(forwarder, forwarderNativeBalance);

        bytes memory data = _getTokenBridgeRetryableCalldata(address(erc20GatewayRouter), forwarder, tokenAmount);
        uint256 msgCount = erc20Bridge.delayedMessageCount();
        _expectRetryable({
            inbox: address(erc20Inbox),
            msgCount: msgCount,
            to: childDefaultGateway, // counterpart gateway
            l2CallValue: 0,
            msgValue: forwarderNativeBalance,
            maxSubmissionCost: forwarderNativeBalance - params.gasLimit * params.gasPriceBid,
            excessFeeRefundAddress: params.to,
            callValueRefundAddress: AddressAliasHelper.applyL1ToL2Alias(forwarder),
            gasLimit: params.gasLimit,
            maxFeePerGas: params.gasPriceBid,
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
        vm.prank(aliasedL1Teleporter);
        factory.callForwarder{value: msgValue}(params);

        // make sure the forwarder has not moved any ETH
        assertEq(address(forwarder).balance, forwarderETHBalance + msgValue);
    }

    function _bridgeNativeTokenHappyCase(
        uint256 tokenAmount,
        uint256 gasLimit,
        uint256 gasPriceBid,
        uint256 forwarderETHBalance,
        uint256 msgValue
    ) internal {
        IL2Forwarder.L2ForwarderParams memory params = IL2Forwarder.L2ForwarderParams({
            owner: owner,
            l2Token: address(nativeToken),
            l2FeeToken: address(nativeToken),
            routerOrInbox: address(erc20Inbox),
            to: l3Recipient,
            gasLimit: gasLimit,
            gasPriceBid: gasPriceBid
        });

        address forwarder = factory.l2ForwarderAddress(params.owner);

        // give the forwarder some ETH, the first leg retryable would do this in practice
        vm.deal(forwarder, forwarderETHBalance);

        // give the forwarder some native token, the first leg retryable would do this in practice
        nativeToken.transfer(forwarder, tokenAmount);

        uint256 msgCount = erc20Bridge.delayedMessageCount();
        _expectRetryable({
            inbox: address(erc20Inbox),
            msgCount: msgCount,
            to: params.to,
            l2CallValue: tokenAmount - erc20Inbox.calculateRetryableSubmissionFee(0, 0) - params.gasLimit * params.gasPriceBid,
            msgValue: tokenAmount,
            maxSubmissionCost: erc20Inbox.calculateRetryableSubmissionFee(0, 0),
            excessFeeRefundAddress: params.to,
            callValueRefundAddress: params.to,
            gasLimit: params.gasLimit,
            maxFeePerGas: params.gasPriceBid,
            data: ""
        });
        vm.prank(aliasedL1Teleporter);
        factory.callForwarder{value: msgValue}(params);

        // make sure the forwarder has not moved its ETH
        assertEq(address(forwarder).balance, forwarderETHBalance + msgValue);
    }

    function _bridgeTokenEthFeesHappyCase(
        uint256 tokenAmount,
        uint256 gasLimit,
        uint256 gasPriceBid,
        uint256 forwarderETHBalance,
        uint256 msgValue
    ) internal {
        IL2Forwarder.L2ForwarderParams memory params = IL2Forwarder.L2ForwarderParams({
            owner: owner,
            l2Token: address(l2Token),
            l2FeeToken: address(0),
            routerOrInbox: address(ethGatewayRouter),
            to: l3Recipient,
            gasLimit: gasLimit,
            gasPriceBid: gasPriceBid
        });

        address forwarder = factory.l2ForwarderAddress(params.owner);

        // give the forwarder some ETH, the first leg retryable would do this in practice
        vm.deal(forwarder, forwarderETHBalance);

        // give the forwarder some tokens, the first leg retryable would do this in practice
        l2Token.transfer(forwarder, tokenAmount);

        _expectBridgeTokenEthFeesHappyCaseEvents(params, forwarderETHBalance, msgValue, gasLimit, gasPriceBid, tokenAmount);
        vm.prank(aliasedL1Teleporter);
        factory.callForwarder{value: msgValue}(params);

        // make sure the forwarder has 0 ETH left
        assertEq(address(forwarder).balance, 0);
    }

    function _expectBridgeTokenEthFeesHappyCaseEvents(
        IL2Forwarder.L2ForwarderParams memory params,
        uint256 forwarderETHBalance,
        uint256 msgValue,
        uint256 gasLimit,
        uint256 gasPriceBid,
        uint256 tokenAmount
    ) internal {
        address forwarder = factory.l2ForwarderAddress(params.owner);

        uint256 msgCount = erc20Bridge.delayedMessageCount();
        bytes memory data = _getTokenBridgeRetryableCalldata(address(ethGatewayRouter), forwarder, tokenAmount);
        _expectRetryable({
            inbox: address(ethInbox),
            msgCount: msgCount,
            to: ethDefaultGateway.counterpartGateway(),
            l2CallValue: 0,
            msgValue: forwarderETHBalance + msgValue,
            maxSubmissionCost: forwarderETHBalance + msgValue - gasLimit * gasPriceBid,
            excessFeeRefundAddress: l3Recipient,
            callValueRefundAddress: AddressAliasHelper.applyL1ToL2Alias(forwarder),
            gasLimit: gasLimit,
            maxFeePerGas: gasPriceBid,
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
