// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Addrs, Deploy} from "../../script/Deploy.s.sol";
import {VerifyDeployment} from "../../script/VerifyDeployment.s.sol";
import {BasketRegistry} from "../../src/BasketRegistry.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Runs script/VerifyDeployment.s.sol against a fresh deploy (made by the real deploy
///         script) on a Base fork. A clean deploy must be all PASS; planted problems must each
///         produce a FAIL line. The Coinbase list is passed in here (the live script reads it
///         with curl): the 8 launch stocks with their real symbols, as on the API 2026-10-13.
contract VerifyDeploymentForkTest is Test {
    Deploy.Deployed internal d;
    VerifyDeployment internal verifier;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        _freshenFeeds();
        Deploy script = new Deploy();
        d = script.deploy(script.launchParams());
        verifier = new VerifyDeployment();
    }

    function _coinbaseList(bool dropMsft) internal pure returns (address[] memory t, string[] memory s) {
        BasketRegistry.AssetConfig[] memory cfg = Addrs.basket();
        string[8] memory sym = ["NVDAc", "MSTRc", "GOOGLc", "AMZNc", "AAPLc", "METAc", "TSLAc", "MSFTc"];
        uint256 n = dropMsft ? 7 : 8;
        t = new address[](n);
        s = new string[](n);
        for (uint256 i; i < n; ++i) {
            (t[i], s[i]) = (cfg[i].token, sym[i]);
        }
    }

    function test_fork_verifyDeployment_cleanDeployAllPass() public {
        (address[] memory t, string[] memory s) = _coinbaseList(false);
        (uint256 passes, uint256 fails) = verifier.check(d, t, s);
        assertEq(fails, 0, "a clean deploy has no FAIL line");
        assertEq(passes, 150, "all 150 checks ran");
    }

    /// Five planted problems, five FAIL lines.
    function test_fork_verifyDeployment_catchesProblems() public {
        vm.startPrank(Addrs.SAFE);
        d.vault.queueSetting(d.vault.SET_MINT_CAP(), 1_000_000e18); // 1. a change waiting in the timelock
        d.router.transferOwnership(address(0xBEEF)); // 2. an ownership transfer not accepted
        d.router.tighten(d.router.SET_KEEPER(), 0); // 3. the router keeper removed
        vm.stopPrank();
        // 4 + 5. Coinbase's list no longer has MSFT: "on the list" and "symbol matches" both fail.
        (address[] memory t, string[] memory s) = _coinbaseList(true);

        (, uint256 fails) = verifier.check(d, t, s);
        assertEq(fails, 5);
    }

    function _freshenFeeds() internal {
        BasketRegistry.AssetConfig[] memory cfg = Addrs.basket();
        for (uint256 i; i < cfg.length; ++i) {
            (uint80 r, int256 a, uint256 st,, uint80 air) = IAggregatorV3(cfg[i].feed).latestRoundData();
            vm.mockCall(
                cfg[i].feed,
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(r, a, st, block.timestamp, air)
            );
        }
    }
}
