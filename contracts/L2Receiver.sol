// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// there is one of these for every account that bridges from L1 to L3
// they are created by the L2ReceiverFactory
contract L2Receiver {
    address l1Owner;
    address deployer;

    error AlreadyInitialized();
    error OnlyL1OwnerOrDeployer();
    error OnlyL1Owner();
    error LengthMismatch();
    error CallFailed(address to, uint256 value, bytes data);

    function initialize(address _l1Owner) external {
        if (l1Owner != address(0)) revert AlreadyInitialized();
        l1Owner = _l1Owner;
        deployer = msg.sender;
    }

    function bridgeToL3(
        L1GatewayRouter l2l3Router,
        IERC20 l2Token,
        address to,
        uint256 amount,
        uint256 l2l3TicketGasLimit,
        uint256 l3GasPrice
    ) external payable {
        if (msg.sender != deployer && msg.sender != AddressAliasHelper.applyL1ToL2Alias(l1Owner)) revert OnlyL1OwnerOrDeployer();

        // get gateway
        address l2l3Gateway = l2l3Router.getGateway(address(l2Token));

        // approve gateway
        l2Token.approve(l2l3Gateway, amount);

        // send tokens through the bridge to intended recipient (send all the ETH we have too, we could have more than msg.value b/c of fee refunds)
        l2l3Router.outboundTransferCustomRefund{value: address(this).balance}(
            address(l2Token),
            to,
            to,
            amount,
            l2l3TicketGasLimit,
            l3GasPrice,
            abi.encode(address(this).balance - l2l3TicketGasLimit * l3GasPrice, bytes(""))
        );
    }

    function rescue(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas) external {
        if (msg.sender != AddressAliasHelper.applyL1ToL2Alias(l1Owner)) revert OnlyL1Owner();
        if (targets.length != values.length || values.length != datas.length) revert LengthMismatch();

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success,) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert CallFailed(targets[i], values[i], datas[i]);
        }
    }
}
