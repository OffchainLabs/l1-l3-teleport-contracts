// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L1Teleporter} from "../contracts/L1Teleporter.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2ForwarderPredictor} from "../contracts/L2ForwarderPredictor.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {L1ArbitrumGateway} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20PresetMinterPauser} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import {BaseTest} from "./Base.t.sol";

contract L1TeleporterTest is BaseTest {
    address immutable l2l3RouterOrInbox = vm.addr(0x10);

    L1Teleporter teleporter;
    IERC20 l1Token;

    address constant l2ForwarderFactory = address(0x1100);
    address constant l2ForwarderImpl = address(0x2200);

    // address constant receiver = address(0x3300);
    // uint256 constant amount = 1 ether;

    function setUp() public override {
        super.setUp();

        teleporter = new L1Teleporter(l2ForwarderFactory, l2ForwarderImpl);
        l1Token = new ERC20PresetMinterPauser("TOKEN", "TOKEN");
        ERC20PresetMinterPauser(address(l1Token)).mint(address(this), 100 ether);

        vm.deal(address(this), 10000 ether);
    }

    function _boundGasParams(L1Teleporter.RetryableGasParams memory gasParams)
        internal
        view
        returns (L1Teleporter.RetryableGasParams memory newGasParams)
    {
        newGasParams.l2GasPrice = bound(gasParams.l2GasPrice, 0.01 gwei, 100 gwei);
        newGasParams.l3GasPrice = bound(gasParams.l3GasPrice, 0.01 gwei, 100 gwei);

        newGasParams.l2ForwarderFactoryGasLimit = bound(gasParams.l2ForwarderFactoryGasLimit, 100_000, 100_000_000);
        newGasParams.l1l2FeeTokenBridgeGasLimit = bound(gasParams.l1l2FeeTokenBridgeGasLimit, 100_000, 100_000_000);
        newGasParams.l1l2TokenBridgeGasLimit = bound(gasParams.l1l2TokenBridgeGasLimit, 100_000, 100_000_000);
        newGasParams.l2l3TokenBridgeGasLimit = bound(gasParams.l2l3TokenBridgeGasLimit, 100_000, 100_000_000);

        newGasParams.l1l2FeeTokenBridgeSubmissionCost = bound(gasParams.l1l2FeeTokenBridgeSubmissionCost, 100, 100_000);
        newGasParams.l1l2TokenBridgeSubmissionCost = bound(gasParams.l1l2TokenBridgeSubmissionCost, 100, 100_000);
        newGasParams.l2l3TokenBridgeSubmissionCost = bound(gasParams.l2l3TokenBridgeSubmissionCost, 100, 100_000);
    }

    function testCalculateRequiredEthAndFeeToken(L1Teleporter.RetryableGasParams memory gasParams, uint256 baseFee)
        public
    {
        // bound parameters to reasonable values to avoid overflow
        baseFee = bound(baseFee, 0.1 gwei, 1_000 gwei);

        gasParams = _boundGasParams(gasParams);

        gasParams = _boundGasParams(gasParams);

        {
            // test standard mode
            L1Teleporter.TeleportParams memory standardParams = L1Teleporter.TeleportParams({
                l1Token: address(l1Token),
                l1FeeToken: address(0),
                l1l2Router: address(ethGatewayRouter),
                l2l3RouterOrInbox: l2l3RouterOrInbox,
                to: address(1),
                amount: 10,
                gasParams: gasParams
            });
            (
                uint256 standardEth,
                uint256 standardFeeToken,
                L1Teleporter.RetryableGasCosts memory standardCosts
            ) = teleporter.determineTypeAndFees(standardParams, baseFee);
            assertEq(standardFeeToken, 0, "standardFeeToken");
            assertEq(
                standardEth,
                standardCosts.l1l2TokenBridgeCost + standardCosts.l2ForwarderFactoryCost
                    + standardCosts.l2l3TokenBridgeCost,
                "standardEth"
            );

            // we only check RetryableGasCosts once because it'll be the same for all modes
            assertEq(
                standardCosts.l1l2FeeTokenBridgeCost,
                gasParams.l1l2FeeTokenBridgeGasLimit * gasParams.l2GasPrice + gasParams.l1l2FeeTokenBridgeSubmissionCost,
                "l1l2FeeTokenBridgeCost"
            );
            assertEq(
                standardCosts.l1l2TokenBridgeCost,
                gasParams.l1l2TokenBridgeGasLimit * gasParams.l2GasPrice + gasParams.l1l2TokenBridgeSubmissionCost,
                "l1l2TokenBridgeCost"
            );
            L1Teleporter.L2ForwarderParams memory _x;
            uint256 factorySubmissionFee = ethInbox.calculateRetryableSubmissionFee(
                abi.encodeCall(L2ForwarderFactory.callForwarder, _x).length, baseFee
            );
            assertEq(
                standardCosts.l2ForwarderFactorySubmissionCost, factorySubmissionFee, "l2ForwarderFactorySubmissionCost"
            );
            assertEq(
                standardCosts.l2ForwarderFactoryCost,
                gasParams.l2ForwarderFactoryGasLimit * gasParams.l2GasPrice + factorySubmissionFee,
                "l2ForwarderFactoryCost"
            );
            assertEq(
                standardCosts.l2l3TokenBridgeCost,
                gasParams.l2l3TokenBridgeGasLimit * gasParams.l3GasPrice + gasParams.l2l3TokenBridgeSubmissionCost,
                "l2l3TokenBridgeCost"
            );
        }

        // test fee token mode
        L1Teleporter.TeleportParams memory feeTokenParams = L1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l1FeeToken: address(l1Token),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: address(1),
            amount: 10,
            gasParams: gasParams
        });
        (
            uint256 feeTokenEth,
            uint256 feeTokenFeeToken,
            L1Teleporter.RetryableGasCosts memory feeTokenGasCosts
        ) = teleporter.determineTypeAndFees(feeTokenParams, baseFee);
        assertEq(feeTokenFeeToken, feeTokenGasCosts.l2l3TokenBridgeCost, "feeTokenFeeToken");
        assertEq(
            feeTokenEth, feeTokenGasCosts.l1l2TokenBridgeCost + feeTokenGasCosts.l2ForwarderFactoryCost, "feeTokenEth"
        );

        // test fee token mode with fee token != l1 token
        L1Teleporter.TeleportParams memory feeTokenParams2 = L1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l1FeeToken: address(0x1234),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: address(1),
            amount: 10,
            gasParams: gasParams
        });
        (
            uint256 feeTokenEth2,
            uint256 feeTokenFeeToken2,
            L1Teleporter.RetryableGasCosts memory feeTokenGasCosts2
        ) = teleporter.determineTypeAndFees(feeTokenParams2, baseFee);
        assertEq(feeTokenFeeToken2, feeTokenGasCosts2.l2l3TokenBridgeCost, "feeTokenFeeToken2");
        assertEq(
            feeTokenEth2,
            feeTokenGasCosts2.l1l2FeeTokenBridgeCost + feeTokenGasCosts2.l1l2TokenBridgeCost
                + feeTokenGasCosts2.l2ForwarderFactoryCost,
            "feeTokenEth2"
        );
    }

    function testStandardTeleport(
        L1Teleporter.RetryableGasParams memory gasParams,
        uint256 extraEth,
        address receiver,
        uint256 amount
    ) public {
        gasParams = _boundGasParams(gasParams);
        amount = bound(amount, 1, 100 ether);
        extraEth = bound(extraEth, 0, 10000);

        L1Teleporter.TeleportParams memory params = L1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l1FeeToken: address(0),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: receiver,
            amount: amount,
            gasParams: gasParams
        });

        (uint256 requiredEth,, L1Teleporter.RetryableGasCosts memory retryableCosts) =
            teleporter.determineTypeAndFees(params, block.basefee);
        L1Teleporter.L2ForwarderParams memory l2ForwarderParams =
            teleporter.buildL2ForwarderParams(params, AddressAliasHelper.applyL1ToL2Alias(address(this)));
        address l2Forwarder = teleporter.l2ForwarderAddress(l2ForwarderParams.owner);

        l1Token.approve(address(teleporter), amount);

        // make sure it checks msg.value properly
        vm.expectRevert(abi.encodeWithSelector(L1Teleporter.InsufficientValue.selector, requiredEth, requiredEth - 1));
        teleporter.teleport{value: requiredEth - 1}(params);

        // token bridge, indicating an actual bridge tx has been initiated
        uint256 msgCount = ethBridge.delayedMessageCount();
        bytes memory l1l2TokenBridgeRetryableCalldata = ethDefaultGateway.getOutboundCalldata({
            _token: address(l1Token),
            _from: address(teleporter),
            _to: l2Forwarder,
            _amount: amount,
            _data: ""
        });
        _expectTokenBridgeRetryable(msgCount, params, retryableCosts, l2Forwarder, l1l2TokenBridgeRetryableCalldata);
        _expectFactoryRetryable(
            msgCount + 1,
            params,
            retryableCosts,
            l2ForwarderParams,
            l2Forwarder,
            retryableCosts.l2l3TokenBridgeCost + extraEth
        );
        teleporter.teleport{value: requiredEth + extraEth}(params);
    }

    function testFeeTokenOnlyTeleport(
        L1Teleporter.RetryableGasParams memory gasParams,
        uint256 extraEth,
        address receiver,
        uint256 amount
    ) public {
        gasParams = _boundGasParams(gasParams);
        extraEth = bound(extraEth, 0, 10000);

        L1Teleporter.TeleportParams memory params = L1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l1FeeToken: address(l1Token),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: receiver,
            amount: amount,
            gasParams: gasParams
        });

        (uint256 requiredEth, uint256 requiredFeeTokenAmount, L1Teleporter.RetryableGasCosts memory retryableCosts) =
            teleporter.determineTypeAndFees(params, block.basefee);

        // make sure it checks msg.value properly
        vm.expectRevert(abi.encodeWithSelector(L1Teleporter.InsufficientValue.selector, requiredEth, requiredEth - 1));
        teleporter.teleport{value: requiredEth - 1}(params);

        // make sure it checks fee token amount properly
        // since token is fee token, params.amount must be greater than retryable costs
        params.amount = requiredFeeTokenAmount - 1;
        vm.expectRevert(
            abi.encodeWithSelector(L1Teleporter.InsufficientFeeToken.selector, requiredFeeTokenAmount, params.amount)
        );
        teleporter.teleport{value: requiredEth}(params);

        params.amount = bound(amount, requiredFeeTokenAmount, 100 ether);
        l1Token.approve(address(teleporter), params.amount);

        L1Teleporter.L2ForwarderParams memory l2ForwarderParams =
            teleporter.buildL2ForwarderParams(params, AddressAliasHelper.applyL1ToL2Alias(address(this)));
        address l2Forwarder = teleporter.l2ForwarderAddress(l2ForwarderParams.owner);

        // token bridge, indicating an actual bridge tx has been initiated
        uint256 msgCount = ethBridge.delayedMessageCount();
        {
            bytes memory l1l2TokenBridgeRetryableCalldata = ethDefaultGateway.getOutboundCalldata({
                _token: address(l1Token),
                _from: address(teleporter),
                _to: l2Forwarder,
                _amount: params.amount,
                _data: ""
            });
            _expectTokenBridgeRetryable(msgCount, params, retryableCosts, l2Forwarder, l1l2TokenBridgeRetryableCalldata);
        }
        _expectFactoryRetryable(msgCount + 1, params, retryableCosts, l2ForwarderParams, l2Forwarder, extraEth);
        teleporter.teleport{value: requiredEth + extraEth}(params);
    }

    function testNonFeeTokenTeleport(
        L1Teleporter.RetryableGasParams memory gasParams,
        uint256 extraEth,
        address receiver,
        uint256 amount
    ) public {
        gasParams = _boundGasParams(gasParams);
        extraEth = bound(extraEth, 0, 10000);
        amount = bound(amount, 1, 100 ether);

        L1Teleporter.TeleportParams memory params = L1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l1FeeToken: address(nativeToken),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: receiver,
            amount: amount,
            gasParams: gasParams
        });

        (uint256 requiredEth, uint256 requiredFeeTokenAmount, L1Teleporter.RetryableGasCosts memory retryableCosts) =
            teleporter.determineTypeAndFees(params, block.basefee);

        // make sure it checks msg.value properly
        vm.expectRevert(abi.encodeWithSelector(L1Teleporter.InsufficientValue.selector, requiredEth, requiredEth - 1));
        teleporter.teleport{value: requiredEth - 1}(params);

        l1Token.approve(address(teleporter), params.amount);
        nativeToken.approve(address(teleporter), requiredFeeTokenAmount);

        L1Teleporter.L2ForwarderParams memory l2ForwarderParams =
            teleporter.buildL2ForwarderParams(params, AddressAliasHelper.applyL1ToL2Alias(address(this)));
        address l2Forwarder = teleporter.l2ForwarderAddress(l2ForwarderParams.owner);

        // token bridge, indicating an actual bridge tx has been initiated
        uint256 msgCount = ethBridge.delayedMessageCount();
        {
            bytes memory l1l2FeeTokenBridgeRetryableCalldata = ethDefaultGateway.getOutboundCalldata({
                _token: address(nativeToken),
                _from: address(teleporter),
                _to: l2Forwarder,
                _amount: requiredFeeTokenAmount,
                _data: ""
            });
            bytes memory l1l2TokenBridgeRetryableCalldata = ethDefaultGateway.getOutboundCalldata({
                _token: address(l1Token),
                _from: address(teleporter),
                _to: l2Forwarder,
                _amount: params.amount,
                _data: ""
            });
            _expectFeeTokenBridgeRetryable(
                msgCount, params, retryableCosts, l2Forwarder, l1l2FeeTokenBridgeRetryableCalldata
            );
            _expectTokenBridgeRetryable(
                msgCount + 1, params, retryableCosts, l2Forwarder, l1l2TokenBridgeRetryableCalldata
            );
        }
        _expectFactoryRetryable(msgCount + 2, params, retryableCosts, l2ForwarderParams, l2Forwarder, extraEth);
        teleporter.teleport{value: requiredEth + extraEth}(params);
    }

    function _expectFeeTokenBridgeRetryable(
        uint256 msgCount,
        L1Teleporter.TeleportParams memory params,
        L1Teleporter.RetryableGasCosts memory retryableCosts,
        address l2Forwarder,
        bytes memory l1l2FeeTokenBridgeRetryableCalldata
    ) internal {
        _expectRetryable({
            inbox: address(ethInbox),
            msgCount: msgCount,
            to: childDefaultGateway,
            l2CallValue: 0,
            msgValue: retryableCosts.l1l2FeeTokenBridgeCost,
            maxSubmissionCost: retryableCosts.l1l2FeeTokenBridgeCost
                - params.gasParams.l1l2FeeTokenBridgeGasLimit * params.gasParams.l2GasPrice,
            excessFeeRefundAddress: l2Forwarder,
            callValueRefundAddress: AddressAliasHelper.applyL1ToL2Alias(address(teleporter)),
            gasLimit: params.gasParams.l1l2FeeTokenBridgeGasLimit,
            maxFeePerGas: params.gasParams.l2GasPrice,
            data: l1l2FeeTokenBridgeRetryableCalldata
        });
    }

    function _expectTokenBridgeRetryable(
        uint256 msgCount,
        L1Teleporter.TeleportParams memory params,
        L1Teleporter.RetryableGasCosts memory retryableCosts,
        address l2Forwarder,
        bytes memory l1l2TokenBridgeRetryableCalldata
    ) internal {
        _expectRetryable({
            inbox: address(ethInbox),
            msgCount: msgCount,
            to: childDefaultGateway,
            l2CallValue: 0,
            msgValue: retryableCosts.l1l2TokenBridgeCost,
            maxSubmissionCost: retryableCosts.l1l2TokenBridgeCost
                - params.gasParams.l1l2TokenBridgeGasLimit * params.gasParams.l2GasPrice,
            excessFeeRefundAddress: l2Forwarder,
            callValueRefundAddress: AddressAliasHelper.applyL1ToL2Alias(address(teleporter)),
            gasLimit: params.gasParams.l1l2TokenBridgeGasLimit,
            maxFeePerGas: params.gasParams.l2GasPrice,
            data: l1l2TokenBridgeRetryableCalldata
        });
    }

    function _expectFactoryRetryable(
        uint256 msgCount,
        L1Teleporter.TeleportParams memory params,
        L1Teleporter.RetryableGasCosts memory retryableCosts,
        L1Teleporter.L2ForwarderParams memory l2ForwarderParams,
        address l2Forwarder,
        uint256 l2CallValue
    ) internal {
        _expectRetryable({
            inbox: address(ethInbox),
            msgCount: msgCount,
            to: l2ForwarderFactory,
            l2CallValue: l2CallValue,
            msgValue: retryableCosts.l2ForwarderFactoryCost + l2CallValue,
            maxSubmissionCost: retryableCosts.l2ForwarderFactoryCost
                - params.gasParams.l2ForwarderFactoryGasLimit * params.gasParams.l2GasPrice,
            excessFeeRefundAddress: l2Forwarder,
            callValueRefundAddress: l2Forwarder,
            gasLimit: params.gasParams.l2ForwarderFactoryGasLimit,
            maxFeePerGas: params.gasParams.l2GasPrice,
            data: abi.encodeCall(L2ForwarderFactory.callForwarder, l2ForwarderParams)
        });
    }
}
