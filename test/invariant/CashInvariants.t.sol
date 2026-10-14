// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {IndexRouter} from "../../src/IndexRouter.sol";
import {IndexVault} from "../../src/IndexVault.sol";
import {Fixture} from "../Fixture.sol";
import {MockAggregator, MockB20, MockERC20, MockSlipstreamRouter} from "../mocks/Mocks.sol";

/// @notice Cash mint/redeem at random sizes, at random pool prices (0% to 20% worse than
///         Chainlink), with feeds fresh or frozen at random. Around every cash call the handler
///         measures what EXISTING holders own per CHIPX and counts any drop.
contract CashHandler is Test {
    uint256 public constant ACTORS = 4;

    IndexVault internal vault;
    IndexRouter internal router;
    MockB20[8] internal stocks;
    MockAggregator[8] internal feeds;
    MockAggregator internal ethFeed;
    MockERC20 internal usdc;
    MockSlipstreamRouter internal swap;
    address[ACTORS] public actors;

    /// Any stock-per-CHIPX drop, and any USD-per-CHIPX drop (at the feeds' last answers).
    uint256 public holderLosses;
    uint256 public navLosses;
    uint256 public freshFills;
    uint256 public staleFills;
    uint256 public refused;

    constructor(
        IndexVault vault_,
        IndexRouter router_,
        MockB20[8] memory stocks_,
        MockAggregator[8] memory feeds_,
        MockAggregator ethFeed_,
        MockERC20 usdc_,
        MockSlipstreamRouter swap_
    ) {
        (vault, router, stocks, feeds, ethFeed, usdc, swap) = (vault_, router_, stocks_, feeds_, ethFeed_, usdc_, swap_);
        for (uint256 k; k < ACTORS; ++k) {
            actors[k] = makeAddr(string.concat("cash-actor-", vm.toString(k)));
            vm.prank(actors[k]);
            usdc.approve(address(router), type(uint256).max);
            vm.prank(actors[k]);
            vault.approve(address(router), type(uint256).max);
        }
    }

    /* ----------------------------- measuring ----------------------------- */

    function _supply() internal view returns (uint256) {
        return vault.totalSupply() + vault.pendingManagementFee();
    }

    function _snap() internal view returns (uint256[8] memory per, uint256 nav) {
        uint256 s = _supply();
        for (uint256 i; i < 8; ++i) {
            uint256 h = vault.held(address(stocks[i]));
            per[i] = h * 1e36 / s;
            nav += h * uint256(feeds[i].answer()); // feeds' last answer, fresh or not
        }
        nav = nav * 1e18 / s;
    }

    function _check(uint256[8] memory per0, uint256 nav0) internal {
        (uint256[8] memory per1, uint256 nav1) = _snap();
        for (uint256 i; i < 8; ++i) {
            if (per1[i] < per0[i]) ++holderLosses;
        }
        if (nav1 < nav0) ++navLosses;
    }

    function _filled() internal {
        if (router.band(true).fresh) ++freshFills;
        else ++staleFills;
    }

    /* ------------------------------ actions ------------------------------ */

    function mintUsdc(uint256 who, uint256 shares) external {
        address a = actors[who % ACTORS];
        shares = bound(shares, 1e15, 20e18);
        usdc.mint(a, 1_000e6);
        (uint256[8] memory p, uint256 n) = _snap();
        uint256 dl = block.timestamp + 1 hours;
        vm.prank(a);
        try router.mintWithUsdc(shares, 1_000e6, a, dl) {
            _filled();
            _check(p, n);
        } catch {
            ++refused;
        }
    }

    function mintEth(uint256 who, uint256 shares) external {
        address a = actors[who % ACTORS];
        shares = bound(shares, 1e15, 20e18);
        vm.deal(a, 1 ether);
        (uint256[8] memory p, uint256 n) = _snap();
        uint256 dl = block.timestamp + 1 hours;
        vm.prank(a);
        try router.mintWithEth{value: 1 ether}(shares, a, dl) {
            _filled();
            _check(p, n);
        } catch {
            ++refused;
        }
    }

    function redeemUsdc(uint256 who, uint256 shares) external {
        address a = actors[who % ACTORS];
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        (uint256[8] memory p, uint256 n) = _snap();
        uint256 dl = block.timestamp + 1 hours;
        vm.prank(a);
        try router.redeemToUsdc(shares, 1, a, dl) {
            _filled();
            _check(p, n);
        } catch {
            ++refused;
        }
    }

    function redeemEth(uint256 who, uint256 shares) external {
        address a = actors[who % ACTORS];
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        (uint256[8] memory p, uint256 n) = _snap();
        uint256 dl = block.timestamp + 1 hours;
        vm.prank(a);
        try router.redeemToEth(shares, 1, a, dl) {
            _filled();
            _check(p, n);
        } catch {
            ++refused;
        }
    }

    /// Pool prices anywhere from Chainlink to 20% worse for the user.
    function setPoolOff(uint256 bps) external {
        swap.setSkewBps(bound(bps, 0, 2_000));
    }

    /// Markets close: stock feeds freeze; ETH keeps updating.
    function weekend(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 27 hours, 4 days));
        ethFeed.setUpdatedAt(block.timestamp);
    }

    /// Markets open: every feed updates, prices move up to +/-5% (pools move with them).
    function marketOpen(uint256 seed) external {
        vm.warp(block.timestamp + 1 hours);
        for (uint256 i; i < 8; ++i) {
            int256 a = feeds[i].answer();
            int256 move = int256(bound(uint256(keccak256(abi.encode(seed, i))), 0, 1_000)) - 500; // bps
            a = a * (10_000 + move) / 10_000;
            feeds[i].set(a);
            swap.setPrice(address(stocks[i]), uint256(a) * 1e10);
        }
        ethFeed.setUpdatedAt(block.timestamp);
    }
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract CashInvariantsTest is Fixture {
    CashHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.deal(address(weth), 1_000_000 ether); // the mock router mints WETH; back it so unwraps work
        handler = new CashHandler(vault, router, stocks, feeds, ethFeed, usdc, swap);
        targetContract(address(handler));
    }

    /// Existing holders' stock per CHIPX never drops from a cash mint or redeem, whatever the
    /// pool price and whether feeds are fresh or frozen.
    function invariant_cashNeverDilutesHolders() public view {
        assertEq(handler.holderLosses(), 0);
    }

    /// The handler really reaches every case: fresh fills, frozen-feed fills inside the 10% band,
    /// and refusals beyond it, with no holder loss along the way.
    function test_handlerCoversFreshStaleAndRefused() public {
        for (uint256 k; k < 4; ++k) {
            handler.mintUsdc(k, 5e18);
            handler.mintEth(k, 2e18);
        }
        assertEq(handler.freshFills(), 8);
        handler.weekend(0);
        handler.setPoolOff(900); // 9% worse: inside the band
        for (uint256 k; k < 4; ++k) {
            handler.mintUsdc(k, 1e18);
            handler.mintEth(k, 1e18);
            handler.redeemUsdc(k, 1e18);
            handler.redeemEth(k, 1e18);
        }
        assertEq(handler.staleFills(), 16);
        handler.setPoolOff(1_500); // 15% worse: outside the band
        handler.mintUsdc(0, 1e18);
        handler.redeemEth(1, 1e18);
        assertEq(handler.refused(), 2);
        assertEq(handler.holderLosses(), 0);
        assertEq(handler.navLosses(), 0);
    }

    /// Same in dollars: NAV per CHIPX (at the feeds' last prices) never drops from a cash call.
    function invariant_cashNeverLowersNavPerShare() public view {
        assertEq(handler.navLosses(), 0);
    }
}
