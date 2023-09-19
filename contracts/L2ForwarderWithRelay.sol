// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ClonableBeaconProxy, ProxySetter} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/libraries/ClonableBeaconProxy.sol";

abstract contract L2ForwarderPredictor {
    struct L2ForwarderParams {
        address l1Owner;
        address token;
        address router;
        address to;
        uint256 amount;
        uint256 gasLimit;
        uint256 gasPrice;
        uint256 relayerPayment;
    }

    bytes32 constant clonableProxyHash = keccak256(type(ClonableBeaconProxy).creationCode);

    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function l2ForwarderAddress(L2ForwarderParams memory params) public view returns (address) {
        return Create2.computeAddress(_salt(params), clonableProxyHash, address(this));
    }

    function _salt(L2ForwarderParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }
}

contract L2ForwarderFactory is L2ForwarderPredictor, ProxySetter {
    /// @notice Beacon setting the L2Forwarder implementation for all proxy instances
    address public immutable override beacon;

    /// @notice Emitted when a new L2Forwarder is created
    event CreatedL2Forwarder(address indexed l2Forwarder, L2ForwarderParams params);

    /// @notice Emitted when an L2Forwarder is called to bridge tokens to L3
    event CalledL2Forwarder(
        address indexed l2Forwarder, L2ForwarderParams params
    );

    constructor(address _beacon) L2ForwarderPredictor(address(this)) {
        beacon = _beacon;
    }

    /// @notice Calls an L2Forwarder to bridge tokens to L3. Will create the L2Forwarder first if it doesn't exist.
    function callForwarder(L2ForwarderParams memory params) external {
        L2Forwarder l2Forwarder = _tryCreateL2Forwarder(params);

        l2Forwarder.bridgeToL3(params);

        emit CalledL2Forwarder(address(l2Forwarder), params);
    }

    /// @notice Creates an L2Forwarder for the given L1 owner. There is no access control.
    function createL2Forwarder(L2ForwarderParams memory params) public returns (L2Forwarder) {
        L2Forwarder l2Forwarder = L2Forwarder(address(new ClonableBeaconProxy{ salt: _salt(params) }()));
        l2Forwarder.initialize(params.l1Owner);

        emit CreatedL2Forwarder(address(l2Forwarder), params);

        return l2Forwarder;
    }

    /// @dev Create an L2Forwarder if it doesn't exist, otherwise return the existing one.
    function _tryCreateL2Forwarder(L2ForwarderParams memory params) internal returns (L2Forwarder) {
        address calculatedAddress = l2ForwarderAddress(params);

        uint256 size;
        assembly {
            size := extcodesize(calculatedAddress)
        }
        if (size > 0) {
            // contract already exists
            return L2Forwarder(calculatedAddress);
        }

        // contract doesn't exist, create it
        return createL2Forwarder(params);
    }
}

contract L2Forwarder is L2ForwarderPredictor {
    using SafeERC20 for IERC20;

    /// @notice L1 address that owns this L2Forwarder
    address public l1Owner;

    /// @notice Emitted after a successful call to rescue
    /// @param  targets Addresses that were called
    /// @param  values  Values that were sent
    /// @param  datas   Calldata that was sent
    event Rescued(address[] targets, uint256[] values, bytes[] datas);

    /// @notice Thrown when initialize is called after initialization
    error AlreadyInitialized();
    /// @notice Thrown when a non-owner calls rescue
    error OnlyL1Owner();
    /// @notice Thrown when the length of targets, values, and datas are not equal in a call to rescue
    error LengthMismatch();
    /// @notice Thrown when an external call in rescue fails
    error CallFailed(address to, uint256 value, bytes data, bytes returnData);
    /// @notice Thrown when the relayer payment fails
    error RelayerPaymentFailed();
    /// @notice Thrown when bridgeToL3 is called with incorrect parameters
    error IncorrectParams();

    constructor(address _factory) L2ForwarderPredictor(_factory) {}

    /// @notice Initialize this L2Forwarder
    /// @param  _l1Owner The L1 address that owns this L2Forwarder
    /// @dev    Can only be called once.
    function initialize(address _l1Owner) external {
        if (l1Owner != address(0)) revert AlreadyInitialized();
        l1Owner = _l1Owner;
    }

    function bridgeToL3(L2ForwarderParams memory params) external {
        if (address(this) != l2ForwarderAddress(params)) revert IncorrectParams();

        // get gateway
        address l2l3Gateway = L1GatewayRouter(params.router).getGateway(params.token);

        // approve gateway
        IERC20(params.token).safeApprove(l2l3Gateway, params.amount);

        // send tokens through the bridge to intended recipient
        // (send all the ETH we have too, we could have more than msg.value b/c of fee refunds)
        // overestimate submission cost to ensure all ETH is sent through
        uint256 balanceSubRelayerPayment = address(this).balance - params.relayerPayment;
        uint256 submissionCost = balanceSubRelayerPayment - params.gasLimit * params.gasPrice;
        L1GatewayRouter(params.router).outboundTransferCustomRefund{value: balanceSubRelayerPayment}(
            params.token, params.to, params.to, params.amount, params.gasLimit, params.gasPrice, abi.encode(submissionCost, bytes(""))
        );
        
        if (params.relayerPayment > 0) {
            (bool paymentSuccess,) = tx.origin.call{value: params.relayerPayment}("");

            if (!paymentSuccess) revert RelayerPaymentFailed();
        }
    }

    /// @notice Allows the L1 owner of this L2Forwarder to make arbitrary calls.
    ///         If the second leg of a teleportation fails, the L1 owner can call this to rescue their tokens.
    ///         When transferring tokens, failing second leg retryables should be cancelled to avoid race conditions and retreive any ETH.
    /// @param  targets Addresses to call
    /// @param  values  Values to send
    /// @param  datas   Calldata to send
    function rescue(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas) external {
        if (msg.sender != AddressAliasHelper.applyL1ToL2Alias(l1Owner)) revert OnlyL1Owner();
        if (targets.length != values.length || values.length != datas.length) revert LengthMismatch();

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, bytes memory retData) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert CallFailed(targets[i], values[i], datas[i], retData);
        }

        emit Rescued(targets, values, datas);
    }
}


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

        (bool paymentSuccess,) = tx.origin.call{value: relayerPayment}("");

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
