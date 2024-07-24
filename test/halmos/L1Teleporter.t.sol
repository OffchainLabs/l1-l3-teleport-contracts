// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";
import {L1Teleporter, IL1Teleporter} from "../../contracts/L1Teleporter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20PresetMinterPauser} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import {BaseTest} from "../util/Base.t.sol";

contract L1TeleporterSymTest is SymTest, BaseTest {
    L1Teleporter teleporter;
    IERC20 l1Token;
    IERC20 feeToken;

    function setUp() public override {
        super.setUp();

        address l2ForwarderFactory = svm.createAddress("l2ForwarderFactory");
        address l2ForwarderImplementation = svm.createAddress("l2ForwarderImplementation");
        address admin = svm.createAddress("admin");
        address pauser = svm.createAddress("pauser");
        teleporter = new L1Teleporter(l2ForwarderFactory, l2ForwarderImplementation, admin, pauser);

        l1Token = new ERC20PresetMinterPauser("TOKEN", "TOKEN");
        ERC20PresetMinterPauser(address(l1Token)).mint(address(this), 100 ether);

        feeToken = new ERC20PresetMinterPauser("FEE", "FEE");
        ERC20PresetMinterPauser(address(feeToken)).mint(address(this), 100 ether);
    }

    function check_teleport_no_leftovers(
        IL1Teleporter.RetryableGasParams memory gasParams,
        address receiver,
        uint256 amount,
        address l2l3RouterOrInbox,
        address l3FeeTokenL1Addr
    ) public {
        vm.assume(
            l3FeeTokenL1Addr == address(0) || l3FeeTokenL1Addr == address(l1Token)
                || l3FeeTokenL1Addr == address(feeToken)
        );
        vm.assume(amount <= l1Token.balanceOf(address(this)));

        uint256 startBalance = l1Token.balanceOf(address(this));

        l1Token.approve(address(teleporter), type(uint256).max);
        feeToken.approve(address(teleporter), type(uint256).max);

        IL1Teleporter.TeleportParams memory params = IL1Teleporter.TeleportParams({
            l1Token: address(l1Token),
            l3FeeTokenL1Addr: l3FeeTokenL1Addr,
            l1l2Router: address(ethGatewayRouter),
            l2l3RouterOrInbox: l2l3RouterOrInbox,
            to: receiver,
            amount: amount,
            gasParams: gasParams
        });

        teleporter.teleport(params);

        assert(l1Token.balanceOf(address(teleporter)) == 0);
        assert(l1Token.balanceOf(address(this)) == startBalance - amount);
    }
}
