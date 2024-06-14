// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L1Teleporter} from "../contracts/L1Teleporter.sol";
import {IL1Teleporter} from "../contracts/interfaces/IL1Teleporter.sol";
import {IL2Forwarder} from "../contracts/interfaces/IL2Forwarder.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2ForwarderPredictor} from "../contracts/L2ForwarderPredictor.sol";
import {TeleportationType, InvalidTeleportation} from "../contracts/lib/TeleportationType.sol";
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

    address admin = address(0x110000);
    address pauser = address(0x220000);

    function setUp() public override {
        super.setUp();

        teleporter = new L1Teleporter(l2ForwarderFactory, l2ForwarderImpl, admin, pauser);
        l1Token = new ERC20PresetMinterPauser("TOKEN", "TOKEN");
        ERC20PresetMinterPauser(address(l1Token)).mint(address(this), 100 ether);

        vm.deal(address(this), 10000 ether);
    }

    function _boundGasParams(IL1Teleporter.RetryableGasParams memory gasParams)
        internal
        view
        returns (IL1Teleporter.RetryableGasParams memory newGasParams)
    {
        newGasParams.l2GasPriceBid = bound(gasParams.l2GasPriceBid, 0.01 gwei, 100 gwei);
        newGasParams.l3GasPriceBid = bound(gasParams.l3GasPriceBid, 0.01 gwei, 100 gwei);

        newGasParams.l2ForwarderFactoryGasLimit =
            uint64(bound(gasParams.l2ForwarderFactoryGasLimit, 100_000, 100_000_000));
        newGasParams.l1l2FeeTokenBridgeGasLimit =
            uint64(bound(gasParams.l1l2FeeTokenBridgeGasLimit, 100_000, 100_000_000));
        newGasParams.l1l2TokenBridgeGasLimit = uint64(bound(gasParams.l1l2TokenBridgeGasLimit, 100_000, 100_000_000));
        newGasParams.l2l3TokenBridgeGasLimit = uint64(bound(gasParams.l2l3TokenBridgeGasLimit, 100_000, 100_000_000));

        newGasParams.l1l2FeeTokenBridgeMaxSubmissionCost =
            bound(gasParams.l1l2FeeTokenBridgeMaxSubmissionCost, 100, 100_000);
        newGasParams.l1l2TokenBridgeMaxSubmissionCost = bound(gasParams.l1l2TokenBridgeMaxSubmissionCost, 100, 100_000);
        newGasParams.l2l3TokenBridgeMaxSubmissionCost = bound(gasParams.l2l3TokenBridgeMaxSubmissionCost, 100, 100_000);
    }

    function testAccessControl() public {
        assertTrue(teleporter.hasRole(teleporter.DEFAULT_ADMIN_ROLE(), admin), "admin");
        assertTrue(teleporter.hasRole(teleporter.PAUSER_ROLE(), pauser), "pauser");

        bytes32 pauserRole = teleporter.PAUSER_ROLE();

        address bob = address(0x330000);

        vm.startPrank(bob);
        vm.expectRevert(
            "AccessControl: account 0x0000000000000000000000000000000000330000 is missing role 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a"
        );
        teleporter.pause();
        vm.expectRevert(
            "AccessControl: account 0x0000000000000000000000000000000000330000 is missing role 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a"
        );
        teleporter.unpause();
        vm.stopPrank();

        vm.prank(admin);
        teleporter.grantRole(pauserRole, bob);

        vm.prank(bob);
        teleporter.pause();
        vm.prank(pauser);
        teleporter.unpause();
    }

    function testPause() public {
        // don't test access control, it's already tested in testAccessControl

        vm.prank(pauser);
        teleporter.pause();

        IL1Teleporter.TeleportParams memory params;
        vm.expectRevert("Pausable: paused");
        teleporter.teleport(params);

        // don't need to test 'doesn't revert when unpaused' because it's already tested in other tests
    }

    function testBuildL2ForwarderParamsAliased(IL1Teleporter.TeleportParams memory params) public {
        assertTrue(address(this).code.length > 0, "address(this).code.length > 0");
        testBuildL2ForwarderParams(params, address(this));
    }

    function testBuildL2ForwarderParams(IL1Teleporter.TeleportParams memory params, address l2Owner) public {
        params.l1l2Router = address(ethGatewayRouter);

        if (params.l1Token == address(0)) {
            vm.expectRevert(InvalidTeleportation.selector);
            teleporter.buildL2ForwarderParams(params, l2Owner);
            return;
        }

        address l2Token = ethGatewayRouter.calculateL2TokenAddress(params.l1Token);

        // test standard mode
        params.l3FeeTokenL1Addr = address(0);
        IL2Forwarder.L2ForwarderParams memory standardParams = teleporter.buildL2ForwarderParams(params, l2Owner);
        if (l2Owner.code.length == 0) {
            assertEq(standardParams.owner, l2Owner, "standardParams.owner");
        } else {
            assertEq(standardParams.owner, AddressAliasHelper.applyL1ToL2Alias(l2Owner), "standardParams.owner");
        }
        assertEq(standardParams.l2Token, l2Token, "standardParams.l2Token");
        assertEq(standardParams.l3FeeTokenL2Addr, address(0), "standardParams.l3FeeTokenL2Addr");
        assertEq(standardParams.routerOrInbox, params.l2l3RouterOrInbox, "standardParams.routerOrInbox");
        assertEq(standardParams.to, params.to, "standardParams.to");
        assertEq(standardParams.gasLimit, params.gasParams.l2l3TokenBridgeGasLimit, "standardParams.gasLimit");
        assertEq(standardParams.gasPriceBid, params.gasParams.l3GasPriceBid, "standardParams.gasPriceBid");
        assertEq(standardParams.maxSubmissionCost, 0, "standardParams.maxSubmissionCost");

        // test OnlyCustomFee
        params.l3FeeTokenL1Addr = params.l1Token;
        IL2Forwarder.L2ForwarderParams memory onlyFeeParams = teleporter.buildL2ForwarderParams(params, l2Owner);
        if (l2Owner.code.length == 0) {
            assertEq(onlyFeeParams.owner, l2Owner, "onlyFeeParams.owner");
        } else {
            assertEq(onlyFeeParams.owner, AddressAliasHelper.applyL1ToL2Alias(l2Owner), "onlyFeeParams.owner");
        }
        assertEq(onlyFeeParams.l2Token, l2Token, "onlyFeeParams.l2Token");
        assertEq(onlyFeeParams.l3FeeTokenL2Addr, l2Token, "onlyFeeParams.l3FeeTokenL2Addr");
        assertEq(onlyFeeParams.routerOrInbox, params.l2l3RouterOrInbox, "onlyFeeParams.routerOrInbox");
        assertEq(onlyFeeParams.to, params.to, "onlyFeeParams.to");
        assertEq(onlyFeeParams.gasLimit, params.gasParams.l2l3TokenBridgeGasLimit, "onlyFeeParams.gasLimit");
        assertEq(onlyFeeParams.gasPriceBid, params.gasParams.l3GasPriceBid, "onlyFeeParams.gasPriceBid");
        assertEq(onlyFeeParams.maxSubmissionCost, 0, "onlyFeeParams.maxSubmissionCost");

        // test NonFeeTokenToCustomFee
        params.l3FeeTokenL1Addr = address(0x1234);
        vm.assume(params.l1Token != address(0x1234));
        address feeToken = ethGatewayRouter.calculateL2TokenAddress(params.l3FeeTokenL1Addr);
        IL2Forwarder.L2ForwarderParams memory feeParams = teleporter.buildL2ForwarderParams(params, l2Owner);
        if (l2Owner.code.length == 0) {
            assertEq(feeParams.owner, l2Owner, "feeParams.owner");
        } else {
            assertEq(feeParams.owner, AddressAliasHelper.applyL1ToL2Alias(l2Owner), "feeParams.owner");
        }
        assertEq(feeParams.l2Token, l2Token, "feeParams.l2Token");
        assertEq(feeParams.l3FeeTokenL2Addr, feeToken, "feeParams.l3FeeTokenL2Addr");
        assertEq(feeParams.routerOrInbox, params.l2l3RouterOrInbox, "feeParams.routerOrInbox");
        assertEq(feeParams.to, params.to, "feeParams.to");
        assertEq(feeParams.gasLimit, params.gasParams.l2l3TokenBridgeGasLimit, "feeParams.gasLimit");
        assertEq(feeParams.gasPriceBid, params.gasParams.l3GasPriceBid, "feeParams.gasPriceBid");
        assertEq(
            feeParams.maxSubmissionCost,
            params.gasParams.l2l3TokenBridgeMaxSubmissionCost,
            "feeParams.maxSubmissionCost"
        );
    }

    function testCalculateRequiredEthAndFeeToken(IL1Teleporter.RetryableGasParams memory gasParams, uint256 baseFee)
        public
    {
        // bound parameters to reasonable values to avoid overflow
        baseFee = bound(baseFee, 0.1 gwei, 1_000 gwei);

        gasParams = _boundGasParams(gasParams);

        gasParams = _boundGasParams(gasParams);

        {
            // test standard mode
            IL1Teleporter.TeleportParams memory standardParams = IL1Teleporter.TeleportParams({
                l1Token: address(l1Token),
                l3FeeTokenL1Addr: address(0),
                l1l2Router: address(ethGatewayRouter),
                l2l3RouterOrInbox: l2l3RouterOrInbox,
                to: address(1),
                amount: 10,
                gasParams: gasParams,
                l3Calldata: ""
            });
            (
                uint256 standardEth,
                uint256 standardFeeToken,
                TeleportationType standardType,
                IL1Teleporter.RetryableGasCosts memory standardCosts
            ) = teleporter.determineTypeAndFees(standardParams);
            assertTrue(standardType == TeleportationType.Standard, "standardType");
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
                (gasParams.l1l2FeeTokenBridgeGasLimit * gasParams.l2GasPriceBid)
                    + gasParams.l1l2FeeTokenBridgeMaxSubmissionCost,
                "l1l2FeeTokenBridgeCost"
            );
            assertEq(
                standardCosts.l1l2TokenBridgeCost,
                (gasParams.l1l2TokenBridgeGasLimit * gasParams.l2GasPriceBid)
                    + gasParams.l1l2TokenBridgeMaxSubmissionCost,
                "l1l2TokenBridgeCost"
            );
            assertEq(
                standardCosts.l2ForwarderFactoryCost,
                (gasParams.l2ForwarderFactoryGasLimit * gasParams.l2GasPriceBid)
                    + gasParams.l2ForwarderFactoryMaxSubmissionCost,
                "l2ForwarderFactoryCost"
            );
            assertEq(
                standardCosts.l2l3TokenBridgeCost,
                (gasParams.l2l3TokenBridgeGasLimit * gasParams.l3GasPriceBid)
                    + gasParams.l2l3TokenBridgeMaxSubmissionCost,
                "l2l3TokenBridgeCost"
            );
        }

        {
            // test standard mode with hardcoded values
            // test standard mode
            IL1Teleporter.TeleportParams memory standardParams = IL1Teleporter.TeleportParams({
                l1Token: address(l1Token),
                l3FeeTokenL1Addr: address(0),
                l1l2Router: address(ethGatewayRouter),
                l2l3RouterOrInbox: l2l3RouterOrInbox,
                to: address(1),
                amount: 10,
                gasParams: IL1Teleporter.RetryableGasParams({
                    l2GasPriceBid: 1,
                    l3GasPriceBid: 2,
                    l2ForwarderFactoryGasLimit: 3,
                    l1l2FeeTokenBridgeGasLimit: 4,
                    l1l2TokenBridgeGasLimit: 5,
                    l2l3TokenBridgeGasLimit: 6,
                    l2ForwarderFactoryMaxSubmissionCost: 7,
                    l1l2FeeTokenBridgeMaxSubmissionCost: 8,
                    l1l2TokenBridgeMaxSubmissionCost: 9,
                    l2l3TokenBridgeMaxSubmissionCost: 10
                }),
                l3Calldata: ""
            });
            (
                uint256 standardEth,
                uint256 standardFeeToken,
                TeleportationType standardType,
                IL1Teleporter.RetryableGasCosts memory standardCosts
            ) = teleporter.determineTypeAndFees(standardParams);
            assertTrue(standardType == TeleportationType.Standard, "standardType");
            assertEq(standardFeeToken, 0, "standardFeeToken");
            assertEq(standardEth, 46, "standardEth");

            // we only check RetryableGasCosts once because it'll be the same for all modes
            assertEq(standardCosts.l1l2FeeTokenBridgeCost, 12, "l1l2FeeTokenBridgeCost");
            assertEq(standardCosts.l1l2TokenBridgeCost, 14, "l1l2TokenBridgeCost");
            assertEq(standardCosts.l2ForwarderFactoryCost, 10, "l2ForwarderFactoryCost");
            assertEq(standardCosts.l2l3TokenBridgeCost, 22, "l2l3TokenBridgeCost");
        }

        // test fee token mode
        IL1Teleporter.TeleportParams memory feeTokenParams = IL1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l3FeeTokenL1Addr: address(l1Token),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: address(1),
            amount: 10,
            gasParams: gasParams,
            l3Calldata: ""
        });
        (
            uint256 feeTokenEth,
            uint256 feeTokenFeeToken,
            TeleportationType onlyFeeType,
            IL1Teleporter.RetryableGasCosts memory feeTokenGasCosts
        ) = teleporter.determineTypeAndFees(feeTokenParams);
        assertTrue(onlyFeeType == TeleportationType.OnlyCustomFee, "onlyFeeType");
        assertEq(feeTokenFeeToken, feeTokenGasCosts.l2l3TokenBridgeCost, "feeTokenFeeToken");
        assertEq(
            feeTokenEth, feeTokenGasCosts.l1l2TokenBridgeCost + feeTokenGasCosts.l2ForwarderFactoryCost, "feeTokenEth"
        );

        // test fee token mode with fee token != l1 token
        IL1Teleporter.TeleportParams memory feeTokenParams2 = IL1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l3FeeTokenL1Addr: address(0x1234),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: address(1),
            amount: 10,
            gasParams: gasParams,
            l3Calldata: ""
        });
        (
            uint256 feeTokenEth2,
            uint256 feeTokenFeeToken2,
            TeleportationType feeType2,
            IL1Teleporter.RetryableGasCosts memory feeTokenGasCosts2
        ) = teleporter.determineTypeAndFees(feeTokenParams2);
        assertTrue(feeType2 == TeleportationType.NonFeeTokenToCustomFee, "feeType2");
        assertEq(feeTokenFeeToken2, feeTokenGasCosts2.l2l3TokenBridgeCost, "feeTokenFeeToken2");
        assertEq(
            feeTokenEth2,
            feeTokenGasCosts2.l1l2FeeTokenBridgeCost + feeTokenGasCosts2.l1l2TokenBridgeCost
                + feeTokenGasCosts2.l2ForwarderFactoryCost,
            "feeTokenEth2"
        );

        // test skip fee token mode
        IL1Teleporter.TeleportParams memory skipFeeTokenParams = IL1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l3FeeTokenL1Addr: teleporter.SKIP_FEE_TOKEN_MAGIC_ADDRESS(),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: address(1),
            amount: 10,
            gasParams: gasParams,
            l3Calldata: ""
        });
        skipFeeTokenParams.gasParams.l3GasPriceBid = 0;
        skipFeeTokenParams.gasParams.l2l3TokenBridgeGasLimit = 0;
        skipFeeTokenParams.gasParams.l2l3TokenBridgeMaxSubmissionCost = 0;
        skipFeeTokenParams.gasParams.l1l2FeeTokenBridgeGasLimit = 0;
        skipFeeTokenParams.gasParams.l1l2FeeTokenBridgeMaxSubmissionCost = 0;
        (
            uint256 skipFeeTokenEth,
            uint256 skipFeeTokenFeeToken,
            TeleportationType skipFeeType,
            IL1Teleporter.RetryableGasCosts memory skipFeeTokenGasCosts
        ) = teleporter.determineTypeAndFees(skipFeeTokenParams);
        assertTrue(skipFeeType == TeleportationType.NonFeeTokenToCustomFee, "skipFeeType");
        assertEq(skipFeeTokenFeeToken, 0, "skipFeeTokenFeeToken");
        assertEq(
            skipFeeTokenEth,
            skipFeeTokenGasCosts.l1l2TokenBridgeCost + skipFeeTokenGasCosts.l2ForwarderFactoryCost,
            "skipFeeTokenEth"
        );

        // should revert if any of the 0 set fields above are nonzero
        skipFeeTokenParams.gasParams.l3GasPriceBid = 1;
        vm.expectRevert(IL1Teleporter.NonZeroFeeTokenAmount.selector);
        teleporter.determineTypeAndFees(skipFeeTokenParams);
        skipFeeTokenParams.gasParams.l3GasPriceBid = 0;

        skipFeeTokenParams.gasParams.l2l3TokenBridgeGasLimit = 1;
        vm.expectRevert(IL1Teleporter.NonZeroFeeTokenAmount.selector);
        teleporter.determineTypeAndFees(skipFeeTokenParams);
        skipFeeTokenParams.gasParams.l2l3TokenBridgeGasLimit = 0;

        skipFeeTokenParams.gasParams.l2l3TokenBridgeMaxSubmissionCost = 1;
        vm.expectRevert(IL1Teleporter.NonZeroFeeTokenAmount.selector);
        teleporter.determineTypeAndFees(skipFeeTokenParams);
        skipFeeTokenParams.gasParams.l2l3TokenBridgeMaxSubmissionCost = 0;

        skipFeeTokenParams.gasParams.l1l2FeeTokenBridgeGasLimit = 1;
        vm.expectRevert(IL1Teleporter.NonZeroFeeTokenAmount.selector);
        teleporter.determineTypeAndFees(skipFeeTokenParams);
        skipFeeTokenParams.gasParams.l1l2FeeTokenBridgeGasLimit = 0;

        skipFeeTokenParams.gasParams.l1l2FeeTokenBridgeMaxSubmissionCost = 1;
        vm.expectRevert(IL1Teleporter.NonZeroFeeTokenAmount.selector);
        teleporter.determineTypeAndFees(skipFeeTokenParams);
        skipFeeTokenParams.gasParams.l1l2FeeTokenBridgeMaxSubmissionCost = 0;
    }

    function testStandardTeleport(IL1Teleporter.RetryableGasParams memory gasParams, address receiver, uint256 amount)
        public
    {
        gasParams = _boundGasParams(gasParams);
        amount = bound(amount, 1, 100 ether);

        IL1Teleporter.TeleportParams memory params = IL1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l3FeeTokenL1Addr: address(0),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: receiver,
            amount: amount,
            gasParams: gasParams,
            l3Calldata: ""
        });

        (uint256 requiredEth,,, IL1Teleporter.RetryableGasCosts memory retryableCosts) =
            teleporter.determineTypeAndFees(params);
        IL2Forwarder.L2ForwarderParams memory l2ForwarderParams =
            teleporter.buildL2ForwarderParams(params, AddressAliasHelper.applyL1ToL2Alias(address(this)));
        address l2Forwarder = teleporter.l2ForwarderAddress(
            l2ForwarderParams.owner, l2ForwarderParams.routerOrInbox, l2ForwarderParams.to
        );

        l1Token.approve(address(teleporter), amount);

        // make sure it checks msg.value properly
        vm.expectRevert(abi.encodeWithSelector(IL1Teleporter.IncorrectValue.selector, requiredEth, requiredEth - 1));
        teleporter.teleport{value: requiredEth - 1}(params);
        vm.expectRevert(abi.encodeWithSelector(IL1Teleporter.IncorrectValue.selector, requiredEth, requiredEth + 1));
        teleporter.teleport{value: requiredEth + 1}(params);

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
            msgCount + 1, params, retryableCosts, l2ForwarderParams, l2Forwarder, retryableCosts.l2l3TokenBridgeCost
        );
        teleporter.teleport{value: requiredEth}(params);

        _sanityCheckZeroTeleporterBalances();
    }

    function testFeeTokenOnlyTeleport(
        IL1Teleporter.RetryableGasParams memory gasParams,
        address receiver,
        uint256 amount
    ) public {
        gasParams = _boundGasParams(gasParams);

        IL1Teleporter.TeleportParams memory params = IL1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l3FeeTokenL1Addr: address(l1Token),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: receiver,
            amount: amount,
            gasParams: gasParams,
            l3Calldata: ""
        });

        (uint256 requiredEth, uint256 requiredFeeTokenAmount,, IL1Teleporter.RetryableGasCosts memory retryableCosts) =
            teleporter.determineTypeAndFees(params);

        // we don't need to check msg.value here because it's already checked in testStandardTeleport

        // make sure it checks fee token amount properly
        // since token is fee token, params.amount must be greater than retryable costs
        params.amount = requiredFeeTokenAmount - 1;
        vm.expectRevert(
            abi.encodeWithSelector(IL1Teleporter.InsufficientFeeToken.selector, requiredFeeTokenAmount, params.amount)
        );
        teleporter.teleport{value: requiredEth}(params);

        params.amount = bound(amount, requiredFeeTokenAmount, 100 ether);
        l1Token.approve(address(teleporter), params.amount);

        IL2Forwarder.L2ForwarderParams memory l2ForwarderParams =
            teleporter.buildL2ForwarderParams(params, AddressAliasHelper.applyL1ToL2Alias(address(this)));
        address l2Forwarder = teleporter.l2ForwarderAddress(
            l2ForwarderParams.owner, l2ForwarderParams.routerOrInbox, l2ForwarderParams.to
        );

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
        _expectFactoryRetryable(msgCount + 1, params, retryableCosts, l2ForwarderParams, l2Forwarder, 0);
        teleporter.teleport{value: requiredEth}(params);

        _sanityCheckZeroTeleporterBalances();
    }

    function testNonFeeTokenTeleport(
        IL1Teleporter.RetryableGasParams memory gasParams,
        address receiver,
        uint256 amount
    ) public {
        gasParams = _boundGasParams(gasParams);
        amount = bound(amount, 1, 100 ether);

        IL1Teleporter.TeleportParams memory params = IL1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l3FeeTokenL1Addr: address(nativeToken),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: receiver,
            amount: amount,
            gasParams: gasParams,
            l3Calldata: ""
        });

        (uint256 requiredEth, uint256 requiredFeeTokenAmount,, IL1Teleporter.RetryableGasCosts memory retryableCosts) =
            teleporter.determineTypeAndFees(params);

        // we don't need to check msg.value here because it's already checked in testStandardTeleport

        l1Token.approve(address(teleporter), params.amount);
        nativeToken.approve(address(teleporter), requiredFeeTokenAmount);

        IL2Forwarder.L2ForwarderParams memory l2ForwarderParams =
            teleporter.buildL2ForwarderParams(params, AddressAliasHelper.applyL1ToL2Alias(address(this)));
        address l2Forwarder = teleporter.l2ForwarderAddress(
            l2ForwarderParams.owner, l2ForwarderParams.routerOrInbox, l2ForwarderParams.to
        );

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
        _expectFactoryRetryable(msgCount + 2, params, retryableCosts, l2ForwarderParams, l2Forwarder, 0);
        teleporter.teleport{value: requiredEth}(params);

        _sanityCheckZeroTeleporterBalances();
    }

    function testNonFeeTokenTeleportSkipFeeToken(
        IL1Teleporter.RetryableGasParams memory gasParams,
        address receiver,
        uint256 amount
    ) public {
        gasParams = _boundGasParams(gasParams);
        amount = bound(amount, 1, 100 ether);

        gasParams.l3GasPriceBid = 0;
        gasParams.l2l3TokenBridgeGasLimit = 0;
        gasParams.l2l3TokenBridgeMaxSubmissionCost = 0;
        gasParams.l1l2FeeTokenBridgeGasLimit = 0;
        gasParams.l1l2FeeTokenBridgeMaxSubmissionCost = 0;

        IL1Teleporter.TeleportParams memory params = IL1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l3FeeTokenL1Addr: teleporter.SKIP_FEE_TOKEN_MAGIC_ADDRESS(),
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: receiver,
            amount: amount,
            gasParams: gasParams,
            l3Calldata: ""
        });

        (uint256 requiredEth,,, IL1Teleporter.RetryableGasCosts memory retryableCosts) =
            teleporter.determineTypeAndFees(params);
        IL2Forwarder.L2ForwarderParams memory l2ForwarderParams =
            teleporter.buildL2ForwarderParams(params, AddressAliasHelper.applyL1ToL2Alias(address(this)));
        address l2Forwarder = teleporter.l2ForwarderAddress(
            l2ForwarderParams.owner, l2ForwarderParams.routerOrInbox, l2ForwarderParams.to
        );

        l1Token.approve(address(teleporter), amount);

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
        _expectFactoryRetryable(msgCount + 1, params, retryableCosts, l2ForwarderParams, l2Forwarder, 0);
        teleporter.teleport{value: requiredEth}(params);

        _sanityCheckZeroTeleporterBalances();
    }

    function _sanityCheckZeroTeleporterBalances() internal {
        assertEq(l1Token.balanceOf(address(teleporter)), 0, "l1Token balance");
        assertEq(nativeToken.balanceOf(address(teleporter)), 0, "nativeToken balance");
        assertEq(address(teleporter).balance, 0, "eth balance");
    }

    function _expectFeeTokenBridgeRetryable(
        uint256 msgCount,
        IL1Teleporter.TeleportParams memory params,
        IL1Teleporter.RetryableGasCosts memory retryableCosts,
        address l2Forwarder,
        bytes memory l1l2FeeTokenBridgeRetryableCalldata
    ) internal {
        _expectRetryable({
            inbox: address(ethInbox),
            msgCount: msgCount,
            to: childDefaultGateway,
            l2CallValue: 0,
            msgValue: retryableCosts.l1l2FeeTokenBridgeCost,
            maxSubmissionCost: params.gasParams.l1l2FeeTokenBridgeMaxSubmissionCost,
            excessFeeRefundAddress: l2Forwarder,
            callValueRefundAddress: AddressAliasHelper.applyL1ToL2Alias(address(teleporter)),
            gasLimit: params.gasParams.l1l2FeeTokenBridgeGasLimit,
            maxFeePerGas: params.gasParams.l2GasPriceBid,
            data: l1l2FeeTokenBridgeRetryableCalldata
        });
    }

    function _expectTokenBridgeRetryable(
        uint256 msgCount,
        IL1Teleporter.TeleportParams memory params,
        IL1Teleporter.RetryableGasCosts memory retryableCosts,
        address l2Forwarder,
        bytes memory l1l2TokenBridgeRetryableCalldata
    ) internal {
        _expectRetryable({
            inbox: address(ethInbox),
            msgCount: msgCount,
            to: childDefaultGateway,
            l2CallValue: 0,
            msgValue: retryableCosts.l1l2TokenBridgeCost,
            maxSubmissionCost: params.gasParams.l1l2TokenBridgeMaxSubmissionCost,
            excessFeeRefundAddress: l2Forwarder,
            callValueRefundAddress: AddressAliasHelper.applyL1ToL2Alias(address(teleporter)),
            gasLimit: params.gasParams.l1l2TokenBridgeGasLimit,
            maxFeePerGas: params.gasParams.l2GasPriceBid,
            data: l1l2TokenBridgeRetryableCalldata
        });
    }

    function _expectFactoryRetryable(
        uint256 msgCount,
        IL1Teleporter.TeleportParams memory params,
        IL1Teleporter.RetryableGasCosts memory retryableCosts,
        IL2Forwarder.L2ForwarderParams memory l2ForwarderParams,
        address l2Forwarder,
        uint256 l2CallValue
    ) internal {
        _expectRetryable({
            inbox: address(ethInbox),
            msgCount: msgCount,
            to: l2ForwarderFactory,
            l2CallValue: l2CallValue,
            msgValue: retryableCosts.l2ForwarderFactoryCost + l2CallValue,
            maxSubmissionCost: params.gasParams.l2ForwarderFactoryMaxSubmissionCost,
            excessFeeRefundAddress: l2Forwarder,
            callValueRefundAddress: l2Forwarder,
            gasLimit: params.gasParams.l2ForwarderFactoryGasLimit,
            maxFeePerGas: params.gasParams.l2GasPriceBid,
            data: abi.encodeCall(L2ForwarderFactory.callForwarder, l2ForwarderParams)
        });
    }
}
