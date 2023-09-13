// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

contract L2ForwarderFactoryWithRelayer {
    function deployAndBridge(
        bytes32 salt,
        address _owner,
        address _token,
        address _router,
        address _to,
        uint256 _amount,
        uint256 _gasLimit,
        uint256 _gasPrice,
        uint256 _relayerPayment
    ) external {
        L2ForwarderWithRelayer forwarder =
            deploy(salt, _owner, _token, _router, _to, _amount, _gasLimit, _gasPrice, _relayerPayment);
        forwarder.bridgeToL3();
    }

    function deploy(
        bytes32 salt,
        address _owner,
        address _token,
        address _router,
        address _to,
        uint256 _amount,
        uint256 _gasLimit,
        uint256 _gasPrice,
        uint256 _relayerPayment
    ) public returns (L2ForwarderWithRelayer) {
        return new L2ForwarderWithRelayer{salt: salt}(
            _owner, _token, _router, _to, _amount, _gasLimit, _gasPrice, _relayerPayment
        );
    }

    function l2ForwarderAddress(
        bytes32 salt,
        address _owner,
        address _token,
        address _router,
        address _to,
        uint256 _amount,
        uint256 _gasLimit,
        uint256 _gasPrice,
        uint256 _relayerPayment
    ) external view returns (address) {
        bytes memory args = abi.encode(
            _owner,
            _token,
            _router,
            _to,
            _amount,
            _gasLimit,
            _gasPrice,
            _relayerPayment
        );

        bytes32 initCodeHash = keccak256(bytes.concat(type(L2ForwarderWithRelayer).creationCode, args));

        // calculate the address
        return Create2.computeAddress(salt, initCodeHash);
    }
}

contract L2ForwarderWithRelayer {
    using SafeERC20 for IERC20;

    address immutable owner;
    address immutable token;
    address immutable router;
    address immutable to;
    uint256 immutable amount;
    uint256 immutable gasLimit;
    uint256 immutable gasPrice;
    uint256 immutable relayerPayment;
    address immutable relayer;

    event BridgedToL3();

    /// @notice Emitted after a successful call to rescue
    /// @param  targets Addresses that were called
    /// @param  values  Values that were sent
    /// @param  datas   Calldata that was sent
    event Rescued(address[] targets, uint256[] values, bytes[] datas);

    error RelayerPaymentFailed();

    /// @notice Thrown when a non-owner calls rescue
    error OnlyOwner();
    /// @notice Thrown when the length of targets, values, and datas are not equal in a call to rescue
    error LengthMismatch();
    /// @notice Thrown when an external call in rescue fails
    error CallFailed(address to, uint256 value, bytes data, bytes returnData);

    constructor(
        address _owner,
        address _token,
        address _router,
        address _to,
        uint256 _amount,
        uint256 _gasLimit,
        uint256 _gasPrice,
        uint256 _relayerPayment
    ) {
        owner = _owner;
        token = _token;
        router = _router;
        to = _to;
        amount = _amount;
        gasLimit = _gasLimit;
        gasPrice = _gasPrice;
        relayerPayment = _relayerPayment;
        relayer = tx.origin;
    }

    function bridgeToL3() external {
        // get gateway
        address l2l3Gateway = L1GatewayRouter(router).getGateway(token);

        // approve gateway
        IERC20(token).safeApprove(l2l3Gateway, amount);

        // send tokens through the bridge to intended recipient
        // (send all the ETH we have too, we could have more than msg.value b/c of fee refunds)
        // overestimate submission cost to ensure all ETH is sent through
        uint256 balanceSubRelayerPayment = address(this).balance - relayerPayment;
        uint256 submissionCost = balanceSubRelayerPayment - gasLimit * gasPrice;
        L1GatewayRouter(router).outboundTransferCustomRefund{value: balanceSubRelayerPayment}(
            token, to, to, amount, gasLimit, gasPrice, abi.encode(submissionCost, bytes(""))
        );

        (bool paymentSuccess,) = relayer.call{value: relayerPayment}("");

        if (!paymentSuccess) revert RelayerPaymentFailed();

        emit BridgedToL3();
    }

    /// @notice Allows the L1 owner of this L2Forwarder to make arbitrary calls.
    ///         If the second leg of a teleportation fails, the L1 owner can call this to rescue their tokens.
    ///         When transferring tokens, failing second leg retryables should be cancelled to avoid race conditions and retreive any ETH.
    /// @param  targets Addresses to call
    /// @param  values  Values to send
    /// @param  datas   Calldata to send
    function rescue(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (targets.length != values.length || values.length != datas.length) revert LengthMismatch();

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, bytes memory retData) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert CallFailed(targets[i], values[i], datas[i], retData);
        }

        emit Rescued(targets, values, datas);
    }
}
