// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L2ForwarderContractsDeployer} from "../contracts/L2ForwarderContractsDeployer.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2Forwarder} from "../contracts/L2Forwarder.sol";
import {L2ForwarderPredictor} from "../contracts/L2ForwarderPredictor.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {ForkTest} from "./Fork.t.sol";
import {L1ArbitrumGateway} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";

contract L2ForwarderTest is ForkTest {
    L2ForwarderFactory factory;
    L2Forwarder implementation;

    address owner = address(0x1111);
    address l3Recipient = address(0x2222);
    MockToken l2Token;

    function setUp() public {
        L2ForwarderContractsDeployer deployer = new L2ForwarderContractsDeployer();
        factory = L2ForwarderFactory(deployer.factory());
        implementation = L2Forwarder(payable(deployer.implementation()));
        l2Token = new MockToken("MOCK", "MOCK", 100 ether, address(this));
    }

    // make sure the implementation has correct implementation and factory addresses set
    // this is needed to predict the address of the L2Forwarder based on parameters
    function testProperConstruction() public {
        assertEq(implementation.l2ForwarderFactory(), address(factory));
        assertEq(implementation.l2ForwarderImplementation(), address(implementation));
    }

    /// forge-config: default.fuzz.runs = 5
    function testCannotPassBadParams(L2Forwarder.L2ForwarderParams memory params) public {
        L2Forwarder forwarder = factory.createL2Forwarder(params);

        // change a param
        unchecked {
            params.gasLimit++;
        }

        // try to call the forwarder with the bad params
        vm.expectRevert(L2Forwarder.IncorrectParams.selector);
        forwarder.bridgeToL3(params);
    }

    function testHappyCase() public {
        _happyCase(1 ether, 1_000_000, 0.1 gwei, 0.1 ether, 1 ether);
    }

    function testHappyCaseWhenForwarderExists() public {
        _happyCase(1 ether, 1_000_000, 0.1 gwei, 0.1 ether, 1 ether);
        _happyCase(1 ether, 1_000_000, 0.1 gwei, 0.1 ether, 1 ether);
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

    // check that the L2Forwarder creates the correct bridge tx
    // and pays the relayer
    function _happyCase(
        uint256 tokenAmount,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 relayerPayment,
        uint256 forwarderETHBalance
    ) public {
        L2ForwarderPredictor.L2ForwarderParams memory params = L2ForwarderPredictor.L2ForwarderParams({
            owner: owner,
            token: address(l2Token),
            router: address(l1l2Router),
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

        _expectHappyCaseEvents(params, forwarderETHBalance, gasLimit, gasPrice, tokenAmount);
        factory.callForwarder(params);

        // make sure the relayer was paid
        assertEq(tx.origin.balance, relayerBalanceBefore + relayerPayment);

        // make sure the forwarder has no ETH left
        assertEq(address(forwarder).balance, 0);
    }

    function _expectHappyCaseEvents(
        L2ForwarderPredictor.L2ForwarderParams memory params,
        uint256 forwarderETHBalance,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 tokenAmount
    ) internal {
        address forwarder = factory.l2ForwarderAddress(params);

        uint256 msgCount = bridge.delayedMessageCount();

        _expectRetryable({
            msgCount: msgCount,
            to: defaultGateway.counterpartGateway(),
            l2CallValue: 0,
            msgValue: forwarderETHBalance - params.relayerPayment,
            maxSubmissionCost: forwarderETHBalance - gasLimit * gasPrice - params.relayerPayment,
            excessFeeRefundAddress: l3Recipient,
            callValueRefundAddress: AddressAliasHelper.applyL1ToL2Alias(forwarder),
            gasLimit: gasLimit,
            maxFeePerGas: gasPrice,
            data: _getTokenBridgeRetryableCalldata(forwarder, tokenAmount)
        });

        // token bridge, indicating an actual bridge tx has been initiated
        vm.expectEmit(address(defaultGateway));
        emit DepositInitiated({
            l1Token: address(l2Token),
            _from: address(forwarder),
            _to: l3Recipient,
            _sequenceNumber: msgCount,
            _amount: tokenAmount
        });
    }

    function _getTokenBridgeRetryableCalldata(address l2Forwarder, uint256 tokenAmount)
        internal
        view
        returns (bytes memory)
    {
        address l1Gateway = l1l2Router.getGateway(address(l2Token));
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
