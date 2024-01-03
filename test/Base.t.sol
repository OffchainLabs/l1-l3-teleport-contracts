// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {L1ArbitrumGateway} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol";
import {L1ERC20Gateway} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1ERC20Gateway.sol";
import {L1OrbitERC20Gateway} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1OrbitERC20Gateway.sol";

import {L1OrbitGatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1OrbitGatewayRouter.sol";

import {IBridge, Bridge} from "@arbitrum/nitro-contracts/src/bridge/Bridge.sol";
import {IInbox, Inbox} from "@arbitrum/nitro-contracts/src/bridge/Inbox.sol";

import {IERC20Bridge, ERC20Bridge} from "@arbitrum/nitro-contracts/src/bridge/ERC20Bridge.sol";
import {IERC20Inbox, ERC20Inbox} from "@arbitrum/nitro-contracts/src/bridge/ERC20Inbox.sol";

import {ISequencerInbox} from "@arbitrum/nitro-contracts/src/bridge/ISequencerInbox.sol";

import {IOwnable} from "@arbitrum/nitro-contracts/src/bridge/IOwnable.sol";

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";



contract BaseTest is Test {
    // we need to deploy rollup contracts and token bridge

    ProxyAdmin pa = new ProxyAdmin();

    Inbox public ethInbox;
    Bridge public ethBridge;

    IERC20 public nativeToken;
    ERC20Inbox public erc20Inbox;
    ERC20Bridge public erc20Bridge;

    uint256 public constant MAX_DATA_SIZE = 117_964;

    address public user = address(100);
    address public rollup = address(1000);
    address public seqInbox = address(1001);


    // token bridge contracts

    L1GatewayRouter public ethGatewayRouter;
    L1OrbitGatewayRouter public erc20GatewayRouter;

    L1ERC20Gateway public ethDefaultGateway;
    L1OrbitERC20Gateway public erc20DefaultGateway;

    address public l2GatewayRouter = address(0x9900);
    address public l2DefaultGateway = address(0x9901);

    function setUp() public virtual {
        ethBridge = Bridge(_deployProxy(address(new Bridge())));
        ethInbox = Inbox(_deployProxy(address(new Inbox(MAX_DATA_SIZE))));

        erc20Bridge = ERC20Bridge(_deployProxy(address(new ERC20Bridge())));
        erc20Inbox = ERC20Inbox(_deployProxy(address(new ERC20Inbox(MAX_DATA_SIZE))));

        nativeToken = IERC20(new ERC20PresetMinterPauser("NATIVE", "NATIVE"));
        ERC20PresetMinterPauser(address(nativeToken)).mint(address(this), 100 ether);

        ethBridge.initialize(IOwnable(rollup));
        erc20Bridge.initialize(IOwnable(rollup), address(nativeToken));

        ethInbox.initialize(ethBridge, ISequencerInbox(seqInbox));
        erc20Inbox.initialize(erc20Bridge, ISequencerInbox(seqInbox));
        
        vm.prank(rollup);
        ethBridge.setDelayedInbox(address(ethInbox), true);
        vm.prank(rollup);
        erc20Bridge.setDelayedInbox(address(erc20Inbox), true);

        vm.label(address(ethBridge), "ethBridge");
        vm.label(address(ethInbox), "ethInbox");
        vm.label(address(erc20Bridge), "erc20Bridge");
        vm.label(address(erc20Inbox), "erc20Inbox");

        _deployTokenBridge();
    }

    function _deployTokenBridge() internal {
        ethGatewayRouter = L1GatewayRouter(_deployProxy(address(new L1GatewayRouter())));
        erc20GatewayRouter = L1OrbitGatewayRouter(_deployProxy(address(new L1OrbitGatewayRouter())));

        ethDefaultGateway = L1ERC20Gateway(_deployProxy(address(new L1ERC20Gateway())));
        erc20DefaultGateway = L1OrbitERC20Gateway(_deployProxy(address(new L1OrbitERC20Gateway())));

        ethGatewayRouter.initialize(address(this), address(ethDefaultGateway), address(0), l2GatewayRouter, address(ethInbox));
        erc20GatewayRouter.initialize(address(this), address(erc20DefaultGateway), address(0), l2GatewayRouter, address(erc20Inbox));

        ethDefaultGateway.initialize(l2DefaultGateway, address(ethGatewayRouter), address(ethInbox), keccak256("1"), address(1));
        erc20DefaultGateway.initialize(l2DefaultGateway, address(erc20GatewayRouter), address(erc20Inbox), keccak256("1"), address(1));

        vm.label(address(ethGatewayRouter), "ethGatewayRouter");
        vm.label(address(erc20GatewayRouter), "erc20GatewayRouter");
        vm.label(address(ethDefaultGateway), "ethDefaultGateway");
        vm.label(address(erc20DefaultGateway), "erc20DefaultGateway");
    }

    function _deployProxy(address logic) internal returns (address) {
        return address(new TransparentUpgradeableProxy(address(logic), address(pa), ""));
    }

    // from inbox
    event InboxMessageDelivered(uint256 indexed messageNum, bytes data);
    // from the default gateway
    event DepositInitiated(
        address l1Token, address indexed _from, address indexed _to, uint256 indexed _sequenceNumber, uint256 _amount
    );

    function _expectErc20Deposit(uint256 msgCount, address to, uint256 amount) internal {
        vm.expectEmit(address(erc20Inbox));
        emit InboxMessageDelivered(
            msgCount,
            abi.encodePacked(to, amount)
        );
    }

    function _expectRetryable(
        address inbox,
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
