// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// there is one of these for every account that bridges from L1 to L3
// they are created by the L2ForwarderFactory
contract L2Forwarder {
    address public l1Owner;
    address public deployer;

    event BridgedToL3(
        address indexed l2Token,
        address indexed router,
        address indexed to,
        uint256 amount,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 submissionCost
    );

    event Rescued(
        address[] targets,
        uint256[] values,
        bytes[] datas
    );

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
        address token,
        address router,
        address to,
        uint256 amount,
        uint256 gasLimit,
        uint256 gasPrice
    ) external payable {
        if (msg.sender != deployer && msg.sender != AddressAliasHelper.applyL1ToL2Alias(l1Owner)) revert OnlyL1OwnerOrDeployer();

        // get gateway
        address l2l3Gateway = L1GatewayRouter(router).getGateway(token);

        // approve gateway
        IERC20(token).approve(l2l3Gateway, amount);

        // send tokens through the bridge to intended recipient (send all the ETH we have too, we could have more than msg.value b/c of fee refunds)
        // overestimate submission cost to ensure all ETH is sent through
        uint256 submissionCost = address(this).balance - gasLimit * gasPrice;
        L1GatewayRouter(router).outboundTransferCustomRefund{value: address(this).balance}(
            token,
            to,
            to,
            amount,
            gasLimit,
            gasPrice,
            abi.encode(submissionCost, bytes(""))
        );

        emit BridgedToL3(token, router, to, amount, gasLimit, gasPrice, submissionCost);
    }

    function rescue(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas) external {
        if (msg.sender != AddressAliasHelper.applyL1ToL2Alias(l1Owner)) revert OnlyL1Owner();
        if (targets.length != values.length || values.length != datas.length) revert LengthMismatch();

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success,) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert CallFailed(targets[i], values[i], datas[i]);
        }

        emit Rescued(targets, values, datas);
    }
}
