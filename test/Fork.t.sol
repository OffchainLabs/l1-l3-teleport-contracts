// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {L1ArbitrumGateway} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol";
import {Bridge} from "@arbitrum/nitro-contracts/src/bridge/Bridge.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";

contract ForkTest is Test {
    L1GatewayRouter l1l2Router = L1GatewayRouter(0x72Ce9c846789fdB6fC1f34aC4AD25Dd9ef7031ef);
    IInbox inbox = IInbox(l1l2Router.inbox());
    L1ArbitrumGateway defaultGateway = L1ArbitrumGateway(l1l2Router.defaultGateway());
    Bridge bridge = Bridge(address(inbox.bridge()));

    // from the default gateway
    event DepositInitiated(
        address l1Token, address indexed _from, address indexed _to, uint256 indexed _sequenceNumber, uint256 _amount
    );

    // from inbox
    event InboxMessageDelivered(uint256 indexed messageNum, bytes data);

    function _expectRetryable(
        uint256 msgCount,
        address to,
        uint256 l2CallValue,
        uint256 msgValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes memory data
    ) internal {
        vm.expectEmit(address(inbox));
        emit InboxMessageDelivered(
            msgCount,
            abi.encodePacked(
                uint256(uint160(to)), // to
                l2CallValue, // l2 call value
                msgValue, // msg.value
                maxSubmissionCost, // maxSubmissionCost
                uint256(uint160(excessFeeRefundAddress)), // excessFeeRefundAddress
                uint256(uint160(callValueRefundAddress)), // callValueRefundAddress
                gasLimit, // gasLimit
                maxFeePerGas, // maxFeePerGas
                data.length, // data.length
                data // data
            )
        );
    }
}
