// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {BasketRegistry} from "./BasketRegistry.sol";
import {IndexVault, IRebalanceCallback} from "./IndexVault.sol";
import {ISlipstreamRouter} from "./interfaces/ISlipstreamRouter.sol";
import {Settings} from "./lib/Settings.sol";

/**
 * @title Rebalancer
 * @notice Keeper-only. Moves the basket back toward its target weights.
 *
 *         A rebalance is allowed when EITHER some stock is more than 3 points (300 bps) away
 *         from its target weight, OR 30 days have passed since the last rebalance.
 *         Anti-churn rules, so a stolen keeper key cannot trade value away:
 *         - each trade must sell an overweight stock and buy an underweight one;
 *         - no trade may push either stock past its target (the seller stays at or above its
 *           target, the buyer at or below), so nothing sold can be bought back in the same or a
 *           later rebalance until prices move;
 *         - the Chainlink value sold in one rebalance is capped at the basket's total overweight
 *           (in dollars) when the rebalance starts;
 *         - the rebalance as a whole must reduce the total drift.
 *         On top of that the VAULT caps all rebalance trading per 24h (volume and value lost), for
 *         this and any future Rebalancer.
 *
 *         Trades route stock -> USDC -> stock on Aerodrome. Price protection is layered: the swap
 *         carries a Chainlink-derived minimum (value in minus the vault's `maxTradeSlippageBps`,
 *         0.75% at launch), the VAULT re-checks value in vs out after the trade, and the keeper's
 *         own minOut applies too.
 *
 *         Settings: SET_KEEPER (0). Removing the keeper (0) is instant; any other keeper is 48h.
 */
contract Rebalancer is Settings, ReentrancyGuard, IRebalanceCallback {
    using SafeERC20 for IERC20;

    struct Trade {
        address sell;
        address buy;
        uint256 amountIn;
        uint256 minOut;
    }

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant DRIFT_THRESHOLD = 3e16; // 3 percentage points
    uint256 public constant SCHEDULE = 30 days;
    uint8 public constant SET_KEEPER = 0;

    IndexVault public immutable vault;
    BasketRegistry public immutable registry;
    ISlipstreamRouter public immutable swapRouter;
    address public immutable usdc;

    address public keeper;
    uint64 public lastRebalanceAt;
    uint256 internal _deadline; // set only for the duration of a rebalance

    event Rebalanced(uint256 trades, uint256 absDriftBefore, uint256 absDriftAfter);

    error ZeroAddress();
    error NotKeeper();
    error NotVault();
    error Expired(uint256 deadline);
    error NoTrades();
    error NotEligible(uint256 maxDrift, uint256 nextScheduled);
    error NotOverweight(address token);
    error NotUnderweight(address token);
    error NoImprovement(uint256 before, uint256 afterwards);
    error EmptyNav();
    error Overshoot(address token);
    error OverTradeBudget(uint256 soldUsd, uint256 budgetUsd);

    constructor(address owner_, IndexVault vault_, ISlipstreamRouter swapRouter_, address usdc_, address keeper_)
        Ownable(owner_)
    {
        if (address(vault_) == address(0) || address(swapRouter_) == address(0) || usdc_ == address(0)) {
            revert ZeroAddress();
        }
        vault = vault_;
        registry = vault_.registry();
        swapRouter = swapRouter_;
        usdc = usdc_;
        keeper = keeper_;
        lastRebalanceAt = uint64(block.timestamp);
    }


    /// @notice Run a batch of trades. Reverts unless the rules above are met.
    function rebalance(Trade[] calldata trades, uint256 deadline) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        if (block.timestamp > deadline) revert Expired(deadline);
        if (trades.length == 0) revert NoTrades();

        // Measure drift against the real balances: write down any issuer seizure first (F-01).
        vault.reconcile();
        (address[] memory list, int256[] memory drift, uint256 nav) = _state();
        (uint256 maxBefore, uint256 sumBefore) = _measure(drift);
        uint256 next = uint256(lastRebalanceAt) + SCHEDULE;
        if (maxBefore <= DRIFT_THRESHOLD && block.timestamp < next) revert NotEligible(maxBefore, next);

        // Most this rebalance may sell: the dollars by which overweight stocks exceed target.
        uint256 budget = overweightUsd(drift, nav);
        uint256 sold;

        _deadline = deadline;
        for (uint256 t; t < trades.length; ++t) {
            Trade calldata tr = trades[t];
            if (_driftOf(list, drift, tr.sell) <= 0) revert NotOverweight(tr.sell);
            if (_driftOf(list, drift, tr.buy) >= 0) revert NotUnderweight(tr.buy);
            sold += registry.valueUsd(tr.sell, tr.amountIn);
            if (sold > budget) revert OverTradeBudget(sold, budget);
            vault.executeTrade(tr.sell, tr.amountIn, tr.buy, tr.minOut, "");
            (list, drift,) = _state();
            // Neither side may cross its target.
            if (_driftOf(list, drift, tr.sell) < 0) revert Overshoot(tr.sell);
            if (_driftOf(list, drift, tr.buy) > 0) revert Overshoot(tr.buy);
        }
        _deadline = 0;

        (, uint256 sumAfter) = _measure(drift);
        if (sumAfter >= sumBefore) revert NoImprovement(sumBefore, sumAfter);

        lastRebalanceAt = uint64(block.timestamp);
        emit Rebalanced(trades.length, sumBefore, sumAfter);
    }

    /// @inheritdoc IRebalanceCallback
    function onRebalanceTrade(address tokenIn, uint256 amountIn, address tokenOut, bytes calldata) external {
        if (msg.sender != address(vault)) revert NotVault();
        // The swap itself refuses to fill below Chainlink value minus the vault's trade slippage,
        // so a bad fill reverts inside the router. The vault re-checks value after the callback.
        uint256 minOut = registry.amountForUsd(
            tokenOut, registry.valueUsd(tokenIn, amountIn) * (BPS - vault.maxTradeSlippageBps()) / BPS
        );
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);
        swapRouter.exactInput(
            ISlipstreamRouter.ExactInputParams({
                path: abi.encodePacked(
                    tokenIn, registry.usdcTickSpacing(tokenIn), usdc, registry.usdcTickSpacing(tokenOut), tokenOut
                ),
                recipient: address(vault),
                deadline: _deadline,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
        IERC20(tokenIn).forceApprove(address(swapRouter), 0);
    }

    /// @notice Each listed token's current weight minus its target, in WAD (1e18 = 100 points).
    ///         Positive = overweight. Reverts if any feed is stale.
    function drifts() public view returns (address[] memory list, int256[] memory drift) {
        (list, drift,) = _state();
    }

    /// @notice Dollars (18 dec) by which the overweight stocks exceed their targets in total:
    ///         the most one rebalance may sell.
    function overweightUsd(int256[] memory drift, uint256 nav) public pure returns (uint256 usd) {
        for (uint256 i; i < drift.length; ++i) {
            if (drift[i] > 0) usd += uint256(drift[i]) * nav / WAD;
        }
    }

    function _state() internal view returns (address[] memory list, int256[] memory drift, uint256 nav) {
        BasketRegistry.Asset[] memory a = registry.assets();
        uint256 n = a.length;
        list = new address[](n);
        drift = new int256[](n);
        uint256[] memory value = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = a[i].token;
            uint256 h = vault.held(a[i].token);
            value[i] = h == 0 ? 0 : registry.valueUsd(a[i].token, h);
            nav += value[i];
        }
        if (nav == 0) revert EmptyNav();
        for (uint256 i; i < n; ++i) {
            uint256 w = value[i] * WAD / nav;
            uint256 target = uint256(a[i].weightBps) * WAD / 10_000;
            drift[i] = int256(w) - int256(target);
        }
    }

    /// @notice Whether a rebalance is currently allowed, and the largest drift (WAD).
    function eligible() external view returns (bool ok, uint256 maxDrift, uint256 nextScheduled) {
        (, int256[] memory drift) = drifts();
        (maxDrift,) = _measure(drift);
        nextScheduled = uint256(lastRebalanceAt) + SCHEDULE;
        ok = maxDrift > DRIFT_THRESHOLD || block.timestamp >= nextScheduled;
    }

    function _measure(int256[] memory drift) internal pure returns (uint256 maxAbs, uint256 sumAbs) {
        for (uint256 i; i < drift.length; ++i) {
            uint256 d = drift[i] < 0 ? uint256(-drift[i]) : uint256(drift[i]);
            sumAbs += d;
            if (d > maxAbs) maxAbs = d;
        }
    }

    function _driftOf(address[] memory list, int256[] memory drift, address token) internal pure returns (int256) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == token) return drift[i];
        }
        return 0; // unlisted: neither over- nor underweight, so both checks reject it
    }

    /* ------------------------------------------------------------------ */
    /*                        Settings (lib/Settings)                      */
    /* ------------------------------------------------------------------ */

    function _checkSetting(uint8 key, uint256 v) internal pure override {
        if (key != SET_KEEPER) revert UnknownSetting(key);
        if (v > type(uint160).max) revert ZeroAddress();
    }

    function _getSetting(uint8 key) internal view override returns (uint256) {
        if (key != SET_KEEPER) revert UnknownSetting(key);
        return uint160(keeper);
    }

    function _applySetting(uint8, uint256 v) internal override {
        keeper = address(uint160(v));
    }

    /// @dev Only removing the keeper is instant.
    function _isTightening(uint8, uint256 v) internal pure override returns (bool) {
        return v == 0;
    }
}
