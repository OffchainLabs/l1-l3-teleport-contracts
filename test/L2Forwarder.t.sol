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
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";

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
        ERC20PresetMinterPauser(address(l2Token)).mint(address(this), 1_000_000 ether);

        vm.label(address(l2Token), "l2Token");

        vm.deal(aliasedL1Teleporter, 1_000_000 ether);
    }

    function testAlreadyInitialized() public {
        vm.expectRevert(IL2Forwarder.AlreadyInitialized.selector);
        vm.prank(address(factory));
        implementation.initialize(owner);
    }

    function testOnlyL2ForwarderFactory() public {
        L2Forwarder.L2ForwarderParams memory params;
        IL2Forwarder forwarder = factory.createL2Forwarder(params.owner, params.routerOrInbox, params.to);
        vm.expectRevert(IL2Forwarder.OnlyL2ForwarderFactory.selector);
        forwarder.bridgeToL3(params);
        vm.expectRevert(IL2Forwarder.OnlyL2ForwarderFactory.selector);
        implementation.initialize(owner);
    }

    // simulating A1, B1, A2, B2
    // B2 should revert because of zero TOKEN balance
    function testStandardHappyCase(
        uint256 tokenAmount,
        uint256 tokenBridgeEthRefunds,
        uint256 factoryCallMsgValue,
        uint256 gasLimit,
        uint256 gasPriceBid
    ) public {
        address l2ForwarderAddress = factory.l2ForwarderAddress(owner, address(ethGatewayRouter), l3Recipient);
        {
            tokenAmount = bound(tokenAmount, 2, 10 ether);
            uint256 expectedSubmissionCost = _getExpectedTokenBridgeSubmissionCost(
                ethInbox, address(ethGatewayRouter), l2ForwarderAddress, tokenAmount
            );
            tokenBridgeEthRefunds = bound(tokenBridgeEthRefunds, 0, 0.01 ether);
            gasLimit = bound(gasLimit, 21000, 1_000_000);
            gasPriceBid = bound(gasPriceBid, 0.1 gwei, 0.2 gwei);
            factoryCallMsgValue =
                expectedSubmissionCost + gasLimit * gasPriceBid + bound(factoryCallMsgValue, 0, 0.001 ether);
        }

        IL2Forwarder.L2ForwarderParams memory params = IL2Forwarder.L2ForwarderParams({
            owner: owner,
            l2Token: address(l2Token),
            l3FeeTokenL2Addr: address(0),
            routerOrInbox: address(ethGatewayRouter),
            to: l3Recipient,
            gasLimit: gasLimit,
            gasPriceBid: gasPriceBid,
            maxSubmissionCost: 0,
            l3Calldata: ""
        });

        // simulate A1 and B1 (bridging TOKEN to L2)
        // tokenAmount includes both A1 and B1
        l2Token.transfer(l2ForwarderAddress, tokenAmount);
        vm.deal(l2ForwarderAddress, tokenBridgeEthRefunds);

        // simulate A2 (calling the factory)
        _expectStandardEvents(params, tokenBridgeEthRefunds, factoryCallMsgValue, tokenAmount);
        vm.prank(aliasedL1Teleporter);
        factory.callForwarder{value: factoryCallMsgValue}(params);

        // simulate B2 (calling the factory)
        // should revert because of zero TOKEN balance
        vm.expectRevert(abi.encodeWithSelector(IL2Forwarder.ZeroTokenBalance.selector, l2Token));
        vm.prank(aliasedL1Teleporter);
        factory.callForwarder{value: factoryCallMsgValue}(params);
    }

    // simulating A1, B1, A2, B2
    // B2 should revert because of zero TOKEN balance
    function testOnlyCustomFeeHappyCase(
        uint256 tokenAmount,
        uint256 tokenBridgeEthRefunds,
        uint256 factoryCallMsgValue,
        uint256 gasLimit,
        uint256 gasPriceBid
    ) public {
        address l2ForwarderAddress = factory.l2ForwarderAddress(owner, address(erc20Inbox), l3Recipient);
        uint256 expectedSubmissionCost = erc20Inbox.calculateRetryableSubmissionFee(0, 0);
        {
            tokenBridgeEthRefunds = bound(tokenBridgeEthRefunds, 0, 0.01 ether);
            gasLimit = bound(gasLimit, 21000, 1_000_000);
            gasPriceBid = bound(gasPriceBid, 0.1 gwei, 0.2 gwei);
            tokenAmount = bound(tokenAmount, expectedSubmissionCost + gasLimit * gasPriceBid, 100 ether);
            factoryCallMsgValue = bound(factoryCallMsgValue, 0, 0.001 ether);
        }

        IL2Forwarder.L2ForwarderParams memory params = IL2Forwarder.L2ForwarderParams({
            owner: owner,
            l2Token: address(nativeToken),
            l3FeeTokenL2Addr: address(nativeToken),
            routerOrInbox: address(erc20Inbox),
            to: l3Recipient,
            gasLimit: gasLimit,
            gasPriceBid: gasPriceBid,
            maxSubmissionCost: 0,
            l3Calldata: ""
        });

        // simulate A1 and B1 (bridging TOKEN to L2)
        vm.deal(l2ForwarderAddress, tokenBridgeEthRefunds);
        nativeToken.transfer(l2ForwarderAddress, tokenAmount);

        uint256 msgCount = erc20Bridge.delayedMessageCount();
        _expectRetryable({
            inbox: address(erc20Inbox),
            msgCount: msgCount,
            to: params.to,
            l2CallValue: tokenAmount - expectedSubmissionCost - params.gasLimit * params.gasPriceBid,
            msgValue: tokenAmount,
            maxSubmissionCost: expectedSubmissionCost,
            excessFeeRefundAddress: params.to,
            callValueRefundAddress: params.to,
            gasLimit: params.gasLimit,
            maxFeePerGas: params.gasPriceBid,
            data: ""
        });
        vm.prank(aliasedL1Teleporter);
        factory.callForwarder{value: factoryCallMsgValue}(params);

        // make sure the forwarder has not moved its ETH
        assertEq(l2ForwarderAddress.balance, tokenBridgeEthRefunds + factoryCallMsgValue);

        // make sure B2 reverts because of zero TOKEN balance
        vm.expectRevert(abi.encodeWithSelector(IL2Forwarder.ZeroTokenBalance.selector, nativeToken));
        vm.prank(aliasedL1Teleporter);
        factory.callForwarder{value: factoryCallMsgValue}(params);
    }

    // simulating A1, A2, B1, B2, A3
    // - All TOKEN from A2 and B2 are sent to L3 by A3
    // - Some FEETOKEN may be left in the forwarder
    // - B3 cannot redeem because of zero TOKEN balance
    function _testNonFeeTokenToCustomFeeHappyCase(
        IERC20 _nativeToken,
        uint256 tokenAmount,
        uint256 feeTokenAmount,
        uint256 tokenBridgeEthRefunds,
        uint256 factoryCallMsgValue,
        uint256 gasLimit,
        uint256 gasPriceBid
    ) internal {
        address l2ForwarderAddress = factory.l2ForwarderAddress(owner, address(erc20GatewayRouter), l3Recipient);
        uint256 expectedSubmissionCost = _getExpectedTokenBridgeSubmissionCost(
            IInbox(address(erc20Inbox)), address(erc20GatewayRouter), l2ForwarderAddress, tokenAmount
        );
        {
            tokenAmount = bound(tokenAmount, 2, 10 ether);
            tokenBridgeEthRefunds = bound(tokenBridgeEthRefunds, 0, 0.01 ether);
            factoryCallMsgValue = bound(factoryCallMsgValue, 0, 0.001 ether);
            if (gasPriceBid != 0 || gasLimit != 0) {
                gasLimit = bound(gasLimit, 21000, 1_000_000);
                gasPriceBid = bound(gasPriceBid, 0.1 gwei, 0.2 gwei);
            }
            feeTokenAmount = expectedSubmissionCost + gasLimit * gasPriceBid + bound(feeTokenAmount, 0, 0.001 ether);
        }

        IL2Forwarder.L2ForwarderParams memory params = IL2Forwarder.L2ForwarderParams({
            owner: owner,
            l2Token: address(l2Token),
            l3FeeTokenL2Addr: address(nativeToken),
            routerOrInbox: address(erc20GatewayRouter),
            to: l3Recipient,
            gasLimit: gasLimit,
            gasPriceBid: gasPriceBid,
            maxSubmissionCost: expectedSubmissionCost,
            l3Calldata: ""
        });

        // simulate ETH refunds from A1, A2, B1, B2
        vm.deal(l2ForwarderAddress, tokenBridgeEthRefunds);

        // simulate A1 and B1
        if (feeTokenAmount > 0) _nativeToken.transfer(l2ForwarderAddress, feeTokenAmount);

        // simulate A2 and B2
        l2Token.transfer(l2ForwarderAddress, tokenAmount);

        // A3
        _expectNonFeeTokenToCustomFeeEvents(params, tokenAmount);
        vm.prank(aliasedL1Teleporter);
        factory.callForwarder{value: factoryCallMsgValue}(params);

        // make sure the forwarder has not moved any ETH
        assertEq(l2ForwarderAddress.balance, factoryCallMsgValue + tokenBridgeEthRefunds);

        // B3
        // should revert because of zero TOKEN balance
        vm.expectRevert(abi.encodeWithSelector(IL2Forwarder.ZeroTokenBalance.selector, l2Token));
        vm.prank(aliasedL1Teleporter);
        factory.callForwarder{value: factoryCallMsgValue}(params);
    }

    function testNonFeeTokenToCustomFeeHappyCase(
        uint256 tokenAmount,
        uint256 feeTokenAmount,
        uint256 tokenBridgeEthRefunds,
        uint256 factoryCallMsgValue,
        uint256 gasLimit,
        uint256 gasPriceBid
    ) public {
        _testNonFeeTokenToCustomFeeHappyCase(
            nativeToken, tokenAmount, feeTokenAmount, tokenBridgeEthRefunds, factoryCallMsgValue, gasLimit, gasPriceBid
        );
    }

    function testNonFeeTokenToCustomFeeSkipFeeToken(
        uint256 tokenAmount,
        uint256 tokenBridgeEthRefunds,
        uint256 factoryCallMsgValue
    ) public {
        _testNonFeeTokenToCustomFeeHappyCase(
            IERC20(address(0x345678901)), tokenAmount, 0, tokenBridgeEthRefunds, factoryCallMsgValue, 0, 0
        );
    }

    // NonFeeTokenToCustomFee
    // simulating A1, A2, B1, A3, B2, B3
    // - All TOKEN from A2 is forwarded by A3
    // - All TOKEN from B2 is forwarded by B3
    function testOutOfOrder1(
        uint256 tokenAmountA,
        uint256 tokenAmountB,
        uint256 gasLimitA,
        uint256 gasPriceBidA,
        uint256 gasLimitB,
        uint256 gasPriceBidB
    ) public {
        address l2ForwarderAddress = factory.l2ForwarderAddress(owner, address(erc20GatewayRouter), l3Recipient);
        uint256 expectedSubmissionCostA = _getExpectedTokenBridgeSubmissionCost(
            IInbox(address(erc20Inbox)), address(erc20GatewayRouter), l2ForwarderAddress, tokenAmountA
        );
        uint256 expectedSubmissionCostB = _getExpectedTokenBridgeSubmissionCost(
            IInbox(address(erc20Inbox)), address(erc20GatewayRouter), l2ForwarderAddress, tokenAmountB
        );
        {
            tokenAmountA = bound(tokenAmountA, 2, 10 ether);
            tokenAmountB = bound(tokenAmountB, 2, 10 ether);
            gasLimitA = bound(gasLimitA, 21000, 1_000_000);
            gasPriceBidA = bound(gasPriceBidA, 0.1 gwei, 0.2 gwei);
            gasLimitB = bound(gasLimitB, 21000, 1_000_000);
            gasPriceBidB = bound(gasPriceBidB, 0.1 gwei, 0.2 gwei);
        }

        IL2Forwarder.L2ForwarderParams memory paramsA = IL2Forwarder.L2ForwarderParams({
            owner: owner,
            l2Token: address(l2Token),
            l3FeeTokenL2Addr: address(nativeToken),
            routerOrInbox: address(erc20GatewayRouter),
            to: l3Recipient,
            gasLimit: gasLimitA,
            gasPriceBid: gasPriceBidA,
            maxSubmissionCost: expectedSubmissionCostA,
            l3Calldata: ""
        });

        // skip simulating ETH refunds from A1, A2, B1

        // simulate A1 and B1
        nativeToken.transfer(
            l2ForwarderAddress,
            gasLimitA * gasPriceBidA + gasLimitB * gasPriceBidB + expectedSubmissionCostA + expectedSubmissionCostB
        );

        // simulate A2
        l2Token.transfer(l2ForwarderAddress, tokenAmountA);

        // A3
        _expectNonFeeTokenToCustomFeeEvents(paramsA, tokenAmountA);
        vm.prank(aliasedL1Teleporter);
        factory.callForwarder(paramsA);

        // simulate B2
        l2Token.transfer(l2ForwarderAddress, tokenAmountB);

        // B3
        IL2Forwarder.L2ForwarderParams memory paramsB = IL2Forwarder.L2ForwarderParams({
            owner: owner,
            l2Token: address(l2Token),
            l3FeeTokenL2Addr: address(nativeToken),
            routerOrInbox: address(erc20GatewayRouter),
            to: l3Recipient,
            gasLimit: gasLimitB,
            gasPriceBid: gasPriceBidB,
            maxSubmissionCost: expectedSubmissionCostB,
            l3Calldata: ""
        });
        _expectNonFeeTokenToCustomFeeEvents(paramsB, tokenAmountB);
        vm.prank(aliasedL1Teleporter);
        factory.callForwarder(paramsB);
    }

    function testRescue() public {
        IL2Forwarder.L2ForwarderParams memory params;
        params.owner = owner;

        // create the forwarder
        IL2Forwarder forwarder = factory.createL2Forwarder(params.owner, params.routerOrInbox, params.to);

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

    function _expectStandardEvents(
        IL2Forwarder.L2ForwarderParams memory params,
        uint256 forwarderETHBalance,
        uint256 msgValue,
        uint256 tokenAmount
    ) internal {
        address forwarder = factory.l2ForwarderAddress(params.owner, params.routerOrInbox, params.to);

        uint256 msgCount = erc20Bridge.delayedMessageCount();
        {
            uint256 gasLimit = params.gasLimit;
            uint256 gasPriceBid = params.gasPriceBid;
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
        }

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

    function _expectNonFeeTokenToCustomFeeEvents(IL2Forwarder.L2ForwarderParams memory params, uint256 tokenAmount)
        internal
    {
        address forwarder = factory.l2ForwarderAddress(params.owner, params.routerOrInbox, params.to);
        uint256 msgCount = erc20Bridge.delayedMessageCount();
        {
            bytes memory data = _getTokenBridgeRetryableCalldata(address(erc20GatewayRouter), forwarder, tokenAmount);
            _expectRetryable({
                inbox: address(erc20Inbox),
                msgCount: msgCount,
                to: childDefaultGateway, // counterpart gateway
                l2CallValue: 0,
                msgValue: params.gasLimit * params.gasPriceBid,
                maxSubmissionCost: params.maxSubmissionCost,
                excessFeeRefundAddress: params.to,
                callValueRefundAddress: AddressAliasHelper.applyL1ToL2Alias(forwarder),
                gasLimit: params.gasLimit,
                maxFeePerGas: params.gasPriceBid,
                data: data
            });
        }
        vm.expectEmit(address(erc20DefaultGateway));
        emit DepositInitiated({
            l1Token: address(l2Token),
            _from: forwarder,
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

    function _getExpectedTokenBridgeSubmissionCost(
        IInbox inbox,
        address gatewayRouter,
        address l2Forwarder,
        uint256 tokenAmount
    ) internal view returns (uint256) {
        uint256 len = _getTokenBridgeRetryableCalldata(gatewayRouter, l2Forwarder, tokenAmount).length;
        return inbox.calculateRetryableSubmissionFee(len, 0);
    }
}
