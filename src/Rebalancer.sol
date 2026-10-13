// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {BasketRegistry} from "./BasketRegistry.sol";
import {IndexVault, IRebalanceCallback} from "./IndexVault.sol";
import {ISlipstreamRouter} from "./interfaces/ISlipstreamRouter.sol";

/**
 * @title Rebalancer
 * @notice Keeper-only. Moves the basket back toward its target weights.
 *
 *         A rebalance is allowed when EITHER some stock is more than 3 points (300 bps) away
 *         from its target weight, OR 30 days have passed since the last rebalance.
 *         Each trade must sell an overweight stock and buy an underweight one, and the
 *         rebalance as a whole must reduce the total drift, so the keeper cannot churn.
 *
 *         Trades route stock -> USDC -> stock on Aerodrome. Price protection is layered: the swap
 *         carries a Chainlink-derived minimum (value in minus the vault's `maxTradeSlippageBps`),
 *         the VAULT re-checks value in vs out after the trade (max 1% by default, hard cap 2%),
 *         and the keeper's own minOut applies too.
 */
contract Rebalancer is Ownable2Step, ReentrancyGuard, IRebalanceCallback {
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

    IndexVault public immutable vault;
    BasketRegistry public immutable registry;
    ISlipstreamRouter public immutable swapRouter;
    address public immutable usdc;

    address public keeper;
    uint64 public lastRebalanceAt;
    uint256 internal _deadline; // set only for the duration of a rebalance

    event Rebalanced(uint256 trades, uint256 absDriftBefore, uint256 absDriftAfter);
    event KeeperSet(address keeper);

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

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Run a batch of trades. Reverts unless the rules above are met.
    function rebalance(Trade[] calldata trades, uint256 deadline) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        if (block.timestamp > deadline) revert Expired(deadline);
        if (trades.length == 0) revert NoTrades();

        (address[] memory list, int256[] memory drift) = drifts();
        (uint256 maxBefore, uint256 sumBefore) = _measure(drift);
        uint256 next = uint256(lastRebalanceAt) + SCHEDULE;
        if (maxBefore <= DRIFT_THRESHOLD && block.timestamp < next) revert NotEligible(maxBefore, next);

        _deadline = deadline;
        for (uint256 t; t < trades.length; ++t) {
            Trade calldata tr = trades[t];
            if (t != 0) (list, drift) = drifts();
            if (_driftOf(list, drift, tr.sell) <= 0) revert NotOverweight(tr.sell);
            if (_driftOf(list, drift, tr.buy) >= 0) revert NotUnderweight(tr.buy);
            vault.executeTrade(tr.sell, tr.amountIn, tr.buy, tr.minOut, "");
        }
        _deadline = 0;

        (, drift) = drifts();
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
        BasketRegistry.Asset[] memory a = registry.assets();
        uint256 n = a.length;
        list = new address[](n);
        drift = new int256[](n);
        uint256[] memory value = new uint256[](n);
        uint256 nav;
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
}
