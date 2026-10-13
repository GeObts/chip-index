// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Addrs, Deploy, LaunchConfig} from "../../script/Deploy.s.sol";
import {SafeSeed} from "../../script/SafeSeed.s.sol";
import {BasketRegistry} from "../../src/BasketRegistry.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Rehearses the real deploy script with the real launch config on a Base fork, then
///         executes the Safe's seed batch call by call as the Safe.
contract DeployScriptForkTest is Test {
    function test_fork_deployScriptAndSafeSeed() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        _freshenFeeds();

        Deploy script = new Deploy();
        Deploy.Params memory p = script.launchParams();
        assertEq(p.mintCap, 5_000e18, "cap = 5,000 tokens = $50k at $10");
        assertEq(p.maxChipBuyUsdc, 100e6, "max CHIP buy = $100");

        Deploy.Deployed memory d = script.deploy(p);
        script.verify(d, p);

        // Seed batch, executed exactly as the Safe would.
        deal(Addrs.USDC, Addrs.SAFE, 1_100e6);
        uint256 usdcBefore = IERC20(Addrs.USDC).balanceOf(Addrs.SAFE);
        SafeSeed seeder = new SafeSeed();
        (SafeSeed.Call[] memory calls,) = seeder.build(d.vault, block.timestamp + 7 days);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(Addrs.SAFE);
            (bool ok, bytes memory ret) = calls[i].to.call(calls[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        uint256 spent = usdcBefore - IERC20(Addrs.USDC).balanceOf(Addrs.SAFE);
        console2.log("seed: USDC spent", spent);
        console2.log("seed: NAV per index token", d.vault.navPerShare());

        assertEq(d.vault.balanceOf(Addrs.SAFE), LaunchConfig.SEED_TOKENS * 1e18);
        assertApproxEqRel(d.vault.navPerShare(), 10e18, 1e15, "starts at $10");
        assertLe(spent, 1_020e6);
        assertEq(IERC20(Addrs.USDC).allowance(Addrs.SAFE, Addrs.SLIP_ROUTER), 0, "approval reset");
    }

    /// @dev Keep each real price, refresh only updatedAt (so the rehearsal also runs on weekends).
    function _freshenFeeds() internal {
        BasketRegistry.AssetConfig[] memory cfg = Addrs.basket();
        for (uint256 i; i < cfg.length; ++i) {
            (uint80 r, int256 a, uint256 s,, uint80 air) = IAggregatorV3(cfg[i].feed).latestRoundData();
            vm.mockCall(
                cfg[i].feed,
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(r, a, s, block.timestamp, air)
            );
        }
    }
}