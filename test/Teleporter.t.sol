// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L1Teleporter} from "../contracts/L1Teleporter.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2ForwarderPredictor} from "../contracts/L2ForwarderPredictor.sol";
import {MockToken} from "./mocks/MockToken.sol";
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

        vm.deal(address(this), 100 ether);
    }

    // todo: test mode

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
            (uint256 standardEth, uint256 standardFeeToken, L1Teleporter.RetryableGasCosts memory standardCosts) =
                teleporter.calculateRequiredEthAndFeeToken(standardParams, baseFee);
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
            assertEq(
                standardCosts.l2ForwarderFactoryCost,
                gasParams.l2ForwarderFactoryGasLimit * gasParams.l2GasPrice
                    + ethInbox.calculateRetryableSubmissionFee(4 + 8 * 32, baseFee),
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
        (uint256 feeTokenEth, uint256 feeTokenFeeToken, L1Teleporter.RetryableGasCosts memory feeTokenGasCosts) =
            teleporter.calculateRequiredEthAndFeeToken(feeTokenParams, baseFee);
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
        (uint256 feeTokenEth2, uint256 feeTokenFeeToken2, L1Teleporter.RetryableGasCosts memory feeTokenGasCosts2) =
            teleporter.calculateRequiredEthAndFeeToken(feeTokenParams2, baseFee);
        assertEq(feeTokenFeeToken2, feeTokenGasCosts2.l2l3TokenBridgeCost, "feeTokenFeeToken2");
        assertEq(
            feeTokenEth2,
            feeTokenGasCosts2.l1l2FeeTokenBridgeCost + feeTokenGasCosts2.l1l2TokenBridgeCost
                + feeTokenGasCosts2.l2ForwarderFactoryCost,
            "feeTokenEth2"
        );
    }

    function testStandardTeleport(L1Teleporter.RetryableGasParams memory gasParams, uint256 extraEth, address receiver, uint256 amount)
        public
    {
        gasParams = _boundGasParams(gasParams);
        amount = bound(amount, 1, 100 ether);
        extraEth = bound(extraEth, 1, 10000);

        L1Teleporter.TeleportParams memory params = L1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l1FeeToken: address(0),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: receiver,
            amount: amount,
            gasParams: gasParams
        });

        (uint256 eth,, L1Teleporter.RetryableGasCosts memory retryableCosts) = teleporter.calculateRequiredEthAndFeeToken(params, block.basefee);
        L1Teleporter.L2ForwarderParams memory l2ForwarderParams = teleporter.buildL2ForwarderParams(params, address(this));
        address l2Forwarder = teleporter.l2ForwarderAddress(l2ForwarderParams);

        l1Token.approve(address(teleporter), amount);

        // token bridge, indicating an actual bridge tx has been initiated
        uint256 msgCount = ethBridge.delayedMessageCount();
        vm.expectEmit(address(ethDefaultGateway));
        emit DepositInitiated({
            l1Token: address(l1Token),
            _from: address(teleporter),
            _to: l2Forwarder,
            _sequenceNumber: msgCount,
            _amount: amount
        });
        // call to L2ForwarderFactory
        _expectRetryable({
            inbox: address(ethInbox),
            msgCount: msgCount + 1,
            to: l2ForwarderFactory,
            l2CallValue: 0,
            msgValue: retryableCosts.l2ForwarderFactoryCost,
            maxSubmissionCost: retryableCosts.l2ForwarderFactoryCost - params.gasParams.l2ForwarderFactoryGasLimit * params.gasParams.l2GasPrice,
            excessFeeRefundAddress: l2Forwarder,
            callValueRefundAddress: l2Forwarder,
            gasLimit: params.gasParams.l2ForwarderFactoryGasLimit,
            maxFeePerGas: params.gasParams.l2GasPrice,
            data: abi.encodeCall(
                L2ForwarderFactory.callForwarder,
                l2ForwarderParams
            )
        });
        teleporter.teleport{value: eth + extraEth}(params);
    }

    // function _expectTeleporterRetryable(L1Teleporter.TeleportParams memory params) internal {
    //     _expectRetryable({
    //         inbox: address(ethInbox),
    //         msgCount: ethBridge.delayedMessageCount(),
    //         to: l2ForwarderFactory,
    //         l2CallValue: 0,
    //         msgValue: retryableCosts.l1l2TokenBridgeCost + extraEth,
    //         maxSubmissionCost: retryableCosts.l1l2TokenBridgeCost + extraEth - params.gasParams.l1l2TokenBridgeGasLimit * params.gasParams.l2GasPrice,
    //         excessFeeRefundAddress: l2Forwarder,
    //         callValueRefundAddress: l2Forwarder,
    //         gasLimit: params.gasParams.l1l2TokenBridgeGasLimit,
    //         maxFeePerGas: params.gasParams.l2GasPrice,
    //         data: abi.encodeCall(
    //             L2ForwarderFactory.callForwarder,
    //             l2ForwarderParams
    //         )
    //     });
    // }
}

// contract L1TeleporterTest is BaseTest {
//     address immutable l2l3Router = vm.addr(0x10);

//     L1Teleporter teleporter;
//     IERC20 l1Token;

//     address constant l2ForwarderFactory = address(0x1100);
//     address constant l2ForwarderImpl = address(0x2200);

//     address constant receiver = address(0x3300);
//     uint256 constant amount = 1 ether;

//     function setUp() public override {
//         super.setUp();
//         teleporter = new L1Teleporter(l2ForwarderFactory, l2ForwarderImpl);
//         l1Token = IERC20(new MockToken("MOCK", "MOCK", 100 ether, address(this)));
//         // l1Token.transfer(address(teleporter), 1);
//         vm.deal(address(this), 100 ether);
//     }

//     function testCalculateRequiredEthAndFeeToken() public {
//         revert("TODO");
//     }

//     // function testTeleportValueCheck() public {
//     //     (L1Teleporter.RetryableGasParams memory params, L1Teleporter.RetryableGasCosts memory costs) =
//     //         _defaultParamsAndCosts();

//     //     vm.expectRevert(abi.encodeWithSelector(L1Teleporter.InsufficientValue.selector, costs.total, costs.total - 1));
//     //     teleporter.teleport{value: costs.total - 1}(
//     //         L1Teleporter.TeleportParams({
//     //             l1Token: address(l1Token),
//     //             l1FeeToken: address(0),
//     //             l1l2Router: address(ethGatewayRouter),
//     //             l2l3RouterOrInbox: l2l3Router,
//     //             to: receiver,
//     //             amount: 10 ether,
//     //             gasParams: params
//     //         })
//     //     );
//     // }

//     function testHappyPathEvents() public {
//         l1Token.transfer(address(this), amount);

//         l1Token.approve(address(teleporter), amount);

//         (L1Teleporter.RetryableGasParams memory gasParams,) =
//             _defaultParamsAndCosts();

//         L1Teleporter.TeleportParams memory params =
//             L1Teleporter.TeleportParams({
//                 l1Token: address(l1Token),
//                 l1FeeToken: address(0),
//                 l1l2Router: address(ethGatewayRouter),
//                 l2l3RouterOrInbox: l2l3Router,
//                 to: receiver,
//                 amount: amount,
//                 gasParams: gasParams
//             });

//         (uint256 requiredEth,) = teleporter.calculateRequiredEthAndFeeToken(params);

//         _expectEvents();
//         teleporter.teleport{value: requiredEth}(params);

//         // make sure the teleporter has no ETH balance
//         assertEq(address(teleporter).balance, 0);
//     }

//     function _expectEvents() internal {
//         (L1Teleporter.RetryableGasParams memory params, L1Teleporter.RetryableGasCosts memory costs) =
//             _defaultParamsAndCosts();

//         L2ForwarderPredictor.L2ForwarderParams memory l2ForwarderParams;
//         {
//             l2ForwarderParams = L2ForwarderPredictor.L2ForwarderParams({
//                 owner: AddressAliasHelper.applyL1ToL2Alias(address(this)),
//                 l2Token: ethGatewayRouter.calculateL2TokenAddress(address(l1Token)),
//                 l2FeeToken: address(0), // 0x00 for ETH, addr of l3 fee token on L2
//                 routerOrInbox: l2l3Router,
//                 to: receiver,
//                 gasLimit: params.l2l3TokenBridgeGasLimit,
//                 gasPrice: params.l3GasPrice,
//                 relayerPayment: 0
//             });
//         }
//         uint256 msgCount = ethBridge.delayedMessageCount();
//         address l2Forwarder = teleporter.l2ForwarderAddress(l2ForwarderParams);
//         // address counterpartGateway = ethDefaultGateway.counterpartGateway();

//         // token bridge retryable
//         bytes memory l1l2TokenBridgeRetryableCalldata = _getTokenBridgeRetryableCalldata(l2Forwarder);
//         _expectRetryable(
//             address(ethInbox),
//             msgCount,
//             ethDefaultGateway.counterpartGateway(),
//             0, // l2 call value
//             costs.total - costs.l2ForwarderFactoryGasCost - costs.l2ForwarderFactorySubmissionCost, // msg.value
//             costs.total - costs.l2ForwarderFactoryGasCost - costs.l2ForwarderFactorySubmissionCost
//                 - costs.l1l2TokenBridgeGasCost, // maxSubmissionCost
//             l2Forwarder, // excessFeeRefundAddress
//             AddressAliasHelper.applyL1ToL2Alias(address(teleporter)), // callValueRefundAddress
//             params.l1l2TokenBridgeGasLimit, // gasLimit
//             params.l2GasPrice, // maxFeePerGas
//             l1l2TokenBridgeRetryableCalldata // data
//         );

//         // token bridge, indicating an actual bridge tx has been initiated
//         vm.expectEmit(address(ethDefaultGateway));
//         emit DepositInitiated({
//             l1Token: address(l1Token),
//             _from: address(teleporter),
//             _to: l2Forwarder,
//             _sequenceNumber: msgCount,
//             _amount: amount
//         });

//         // call to the factory
//         _expectRetryable(
//             address(ethInbox),
//             msgCount + 1,
//             l2ForwarderFactory, // to
//             0, // l2 call value
//             costs.l2ForwarderFactoryGasCost + costs.l2ForwarderFactorySubmissionCost, // msg.value
//             costs.l2ForwarderFactorySubmissionCost, // maxSubmissionCost
//             l2Forwarder, // excessFeeRefundAddress
//             l2Forwarder, // callValueRefundAddress
//             params.l2ForwarderFactoryGasLimit, // gasLimit
//             params.l2GasPrice, // maxFeePerGas
//             abi.encodeCall(L2ForwarderFactory.callForwarder, (l2ForwarderParams)) // data
//         );
//     }

//     function _getTokenBridgeRetryableCalldata(address l2Forwarder) internal view returns (bytes memory) {
//         address l1Gateway = ethGatewayRouter.getGateway(address(l1Token));
//         bytes memory l1l2TokenBridgeRetryableCalldata = L1ArbitrumGateway(l1Gateway).getOutboundCalldata({
//             _l1Token: address(l1Token),
//             _from: address(teleporter),
//             _to: l2Forwarder,
//             _amount: amount,
//             _data: ""
//         });
//         return l1l2TokenBridgeRetryableCalldata;
//     }

//     function _defaultParams() internal pure returns (L1Teleporter.RetryableGasParams memory) {
//         return L1Teleporter.RetryableGasParams({
//             l2GasPrice: 0.1 gwei,
//             l3GasPrice: 0.1 gwei,
//             l2ForwarderFactoryGasLimit: 1_000_000,
//             l1l2FeeTokenBridgeGasLimit: 1_000_000,
//             l1l2TokenBridgeGasLimit: 1_000_000,
//             l2l3TokenBridgeGasLimit: 1_000_000,
//             l1l2FeeTokenBridgeRetryableSize: 1000,
//             l1l2TokenBridgeRetryableSize: 1000,
//             l2l3TokenBridgeRetryableSize: 1000
//         });
//     }

//     function _defaultParamsAndCosts()
//         internal
//         view
//         returns (L1Teleporter.RetryableGasParams memory, L1Teleporter.RetryableGasCosts memory)
//     {
//         L1Teleporter.RetryableGasParams memory params = _defaultParams();
//         L1Teleporter.RetryableGasCosts memory costs =
//             teleporter.calculateRetryableGasCosts(ethGatewayRouter.inbox(), 0, params);
//         return (params, costs);
//     }
// }
