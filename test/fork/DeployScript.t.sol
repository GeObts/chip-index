// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Addrs, Deploy} from "../../script/Deploy.s.sol";
import {ISlipstreamFactory} from "../../src/interfaces/ISlipstreamRouter.sol";

/// @notice Rehearses the real deploy script on a Base fork, then the Safe's seed mint.
contract DeployScriptForkTest is Test {
    function test_fork_deployScriptAndSafeSeed() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        address deployer = makeAddr("deployer");
        Deploy script = new Deploy();
        Deploy.Params memory p = Deploy.Params("Chip Index", "CHIDX", 100_000e18, 1_000e6);

        vm.prank(deployer);
        Deploy.Deployed memory d = script.deploy(p);
        script.verify(d, p);

        // The deploy wallet owns nothing and cannot re-wire.
        vm.prank(deployer);
        vm.expectRevert();
        d.vault.setMintCap(1);

        // Safe seeds with $100 of each stock (taken from the pools here) for 80 index tokens.
        address[] memory list = d.registry.tokens();
        uint256[] memory amounts = new uint256[](list.length);
        for (uint256 i; i < list.length; ++i) {
            amounts[i] = d.registry.amountForUsd(list[i], 100e18);
            address pool = ISlipstreamFactory(Addrs.SLIP_FACTORY).getPool(list[i], Addrs.USDC, Addrs.STOCK_USDC_TS);
            vm.prank(pool);
            IERC20(list[i]).transfer(Addrs.SAFE, amounts[i]);
            vm.prank(Addrs.SAFE);
            IERC20(list[i]).approve(address(d.vault), amounts[i]);
        }
        vm.prank(Addrs.SAFE);
        d.vault.seed(amounts, 80e18, Addrs.SAFE);
        assertEq(d.vault.balanceOf(Addrs.SAFE), 80e18);
    }
}
