// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {
    ProxySetter,
    ClonableBeaconProxy
} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/libraries/ClonableBeaconProxy.sol";
import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {L2Forwarder} from "./L2Forwarder.sol";

// this contract is deployed to every L2 in advance
// it receives commands from the teleporter to create and call L2Forwarders
contract L2ForwarderFactory is ProxySetter {
    bytes32 constant cloneableProxyHash = keccak256(type(ClonableBeaconProxy).creationCode);

    address public immutable override beacon;
    address public immutable l1Teleporter;

    event CreatedL2Forwarder(address indexed l1Owner, address l2Forwarder);
    event CalledL2Forwarder(
        address indexed l1Owner,
        address l2Forwarder,
        address l2l3Router,
        address l2Token,
        address to,
        uint256 amount,
        uint256 l2l3TicketGasLimit,
        uint256 l3GasPrice
    );

    error OnlyL1Teleporter();

    constructor(address _beacon, address _l1Teleporter) {
        beacon = _beacon;
        l1Teleporter = _l1Teleporter;
    }

    function callForwarder(
        address l1Owner,
        address token,
        address router,
        address to,
        uint256 amount,
        uint256 gasLimit,
        uint256 gasPrice
    ) external payable {
        if (msg.sender != AddressAliasHelper.applyL1ToL2Alias(l1Teleporter)) revert OnlyL1Teleporter();

        L2Forwarder l2Forwarder = _tryCreateL2Forwarder(l1Owner);

        l2Forwarder.bridgeToL3{value: msg.value}(token, router, to, amount, gasLimit, gasPrice);
    }

    function calculateL2ForwarderAddress(address l1Owner) public view returns (address) {
        return Create2.computeAddress(bytes20(l1Owner), cloneableProxyHash, address(this));
    }

    function createL2Forwarder(address l1Owner) public returns (L2Forwarder) {
        L2Forwarder l2Forwarder = L2Forwarder(address(new ClonableBeaconProxy{ salt: bytes20(l1Owner) }()));
        l2Forwarder.initialize(l1Owner);

        emit CreatedL2Forwarder(l1Owner, address(l2Forwarder));

        return l2Forwarder;
    }

    function _tryCreateL2Forwarder(address l1Owner) internal returns (L2Forwarder) {
        address calculatedAddress = calculateL2ForwarderAddress(l1Owner);

        uint256 size;
        assembly {
            size := extcodesize(calculatedAddress)
        }
        if (size > 0) {
            // contract already exists
            return L2Forwarder(calculatedAddress);
        }

        // contract doesn't exist, create it
        return createL2Forwarder(l1Owner);
    }
}
