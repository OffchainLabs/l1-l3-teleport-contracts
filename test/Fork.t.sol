// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {L1ArbitrumGateway} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol";
import {Bridge} from "@arbitrum/nitro-contracts/src/bridge/Bridge.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";

contract ForkTest is Test {
    L1GatewayRouter l1l2Router = L1GatewayRouter(0x72Ce9c846789fdB6fC1f34aC4AD25Dd9ef7031ef);
    IInbox inbox = IInbox(l1l2Router.inbox());
    L1ArbitrumGateway defaultGateway = L1ArbitrumGateway(l1l2Router.defaultGateway());
    Bridge bridge = Bridge(address(inbox.bridge()));
}
