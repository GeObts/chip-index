// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BasketRegistry} from "./BasketRegistry.sol";
import {IndexVault} from "./IndexVault.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IChipBurner} from "./interfaces/IExternal.sol";
import {ISlipstreamRouter} from "./interfaces/ISlipstreamRouter.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "./interfaces/IUniswapV4.sol";
import {OracleLib} from "./lib/OracleLib.sol";
import {Settings} from "./lib/Settings.sol";

/**
 * @title IndexFeeSplitter
 * @notice Receives every Chip Index fee (as index tokens) and turns it into:
 *         - 50% USDC sent to the Chipworks Pot, and
 *         - 50% spent buying $CHIP, which is sent to the ChipBurner and burned.
 *
 *         Flow: `redeemFees` (anyone) redeems the index tokens for stocks, with no redeem fee
 *         because this is the fee recipient -> `sellForUsdc` (keeper) sells each stock for USDC
 *         within 1% of Chainlink -> `distribute` (anyone) sends half the new USDC to the Pot and
 *         books the other half as `chipBudget` -> `buyAndBurn` (keeper) spends budget on $CHIP
 *         (USDC -> WETH on Aerodrome, WETH -> $CHIP on the Uniswap v4 pool) and burns it.
 *
 *         $CHIP has no onchain TWAP (its v4 hook keeps no oracle), so the $CHIP leg is protected
 *         by the keeper's `minChipOut` (which may not be 0), a per-call size cap (`maxChipBuyUsdc`,
 *         hard limit $500) and a 24h spend cap (`dailyChipBuyUsdc`, hard limit $2,000).
 *
 *         Settings (lib/Settings): SET_KEEPER, SET_MAX_CHIP_BUY, SET_DAILY_CHIP_BUY,
 *         SET_SELL_SLIPPAGE, SET_ETH_FEED_MAX_AGE (lower is instant, higher is 48h; removing the
 *         keeper is instant, adding one is 48h) and SET_WETH_USDC_TICK_SPACING (48h only).
 */
contract IndexFeeSplitter is Settings, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    struct Config {
        address owner;
        IndexVault vault;
        ISlipstreamRouter swapRouter;
        address usdc;
        address weth;
        address chip;
        address burner;
        address pot;
        address poolManager;
        address ethUsdFeed;
        PoolKey chipPoolKey;
        int24 wethUsdcTickSpacing;
        address keeper;
        uint256 maxChipBuyUsdc;
        uint256 dailyChipBuyUsdc;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant POT_SHARE_BPS = 5_000; // 50% to the Pot, 50% to buy-and-burn
    uint16 public constant MAX_SELL_SLIPPAGE_BPS = 200;
    uint256 public constant MAX_CHIP_BUY_LIMIT = 500e6; // hard limit per buyAndBurn call
    uint256 public constant DAILY_CHIP_BUY_LIMIT = 2_000e6; // hard limit per 24h
    uint256 public constant MIN_ETH_FEED_AGE = 5 minutes;
    uint256 public constant MAX_ETH_FEED_AGE = 24 hours;

    uint8 public constant SET_KEEPER = 0;
    uint8 public constant SET_MAX_CHIP_BUY = 1;
    uint8 public constant SET_DAILY_CHIP_BUY = 2;
    uint8 public constant SET_SELL_SLIPPAGE = 3;
    uint8 public constant SET_ETH_FEED_MAX_AGE = 4;
    uint8 public constant SET_WETH_USDC_TICK_SPACING = 5;
    /// @dev TickMath.MIN_SQRT_PRICE + 1 / MAX_SQRT_PRICE - 1.
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740;
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    IndexVault public immutable vault;
    BasketRegistry public immutable registry;
    ISlipstreamRouter public immutable swapRouter;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    IERC20 public immutable chip;
    IChipBurner public immutable burner;
    address public immutable pot;
    IPoolManager public immutable poolManager;
    address public immutable ethUsdFeed;
    uint8 internal immutable _ethFeedDecimals;
    bool public immutable chipIsCurrency0;

    // PoolKey fields (structs cannot be immutable).
    address internal immutable _c0;
    address internal immutable _c1;
    uint24 internal immutable _fee;
    int24 internal immutable _tickSpacing;
    address internal immutable _hooks;

    address public keeper;
    int24 public wethUsdcTickSpacing;
    uint16 public sellSlippageBps = 100;
    uint256 public ethFeedMaxAge = 1 hours;
    uint256 public maxChipBuyUsdc;
    /// @notice Most USDC `buyAndBurn` may spend per 24h window, and the current window.
    uint256 public dailyChipBuyUsdc;
    uint64 public chipWindowStart;
    uint256 public chipWindowSpent;
    /// @notice USDC set aside for $CHIP buys (the non-Pot half of everything distributed).
    uint256 public chipBudget;

    event FeesRedeemed(uint256 shares);
    event SoldForUsdc(address indexed token, uint256 amountIn, uint256 usdcOut);
    event Distributed(uint256 toPot, uint256 toChipBudget);
    event ChipBoughtAndBurned(uint256 usdcIn, uint256 wethIn, uint256 chipOut);
    event Swept(address indexed token, address to, uint256 amount);

    error ZeroAddress();
    error NotKeeper();
    error NotPoolManager();
    error KeyIsNotChipWeth();
    error NothingToRedeem();
    error NotListed(address token);
    error OverBudget(uint256 usdcIn, uint256 budget);
    error OverCap(uint256 usdcIn, uint256 cap);
    error OverDailyCap(uint256 spentToday, uint256 cap);
    error ChipOutBelowMin(uint256 out, uint256 min);
    error ZeroMinChipOut();
    error PartialFill(uint256 paid, uint256 wanted);
    error SlippageAboveCap(uint16 bps);
    error NoSuchPool(int24 tickSpacing);
    error CannotSweep(address token);
    error FeedAgeOutOfBounds(uint256 maxAge);

    constructor(Config memory c) Ownable(c.owner) {
        if (
            address(c.vault) == address(0) || address(c.swapRouter) == address(0) || c.usdc == address(0)
                || c.weth == address(0) || c.chip == address(0) || c.burner == address(0) || c.pot == address(0)
                || c.poolManager == address(0) || c.ethUsdFeed == address(0)
        ) revert ZeroAddress();
        vault = c.vault;
        registry = c.vault.registry();
        swapRouter = c.swapRouter;
        usdc = IERC20(c.usdc);
        weth = IERC20(c.weth);
        chip = IERC20(c.chip);
        burner = IChipBurner(c.burner);
        pot = c.pot;
        poolManager = IPoolManager(c.poolManager);
        ethUsdFeed = c.ethUsdFeed;
        _ethFeedDecimals = IAggregatorV3(c.ethUsdFeed).decimals();

        PoolKey memory k = c.chipPoolKey;
        if (k.currency0 == c.chip && k.currency1 == c.weth) chipIsCurrency0 = true;
        else if (k.currency0 == c.weth && k.currency1 == c.chip) chipIsCurrency0 = false;
        else revert KeyIsNotChipWeth();
        _c0 = k.currency0;
        _c1 = k.currency1;
        _fee = k.fee;
        _tickSpacing = k.tickSpacing;
        _hooks = k.hooks;

        keeper = c.keeper;
        if (c.maxChipBuyUsdc > MAX_CHIP_BUY_LIMIT) revert OverCap(c.maxChipBuyUsdc, MAX_CHIP_BUY_LIMIT);
        if (c.dailyChipBuyUsdc > DAILY_CHIP_BUY_LIMIT) revert OverDailyCap(c.dailyChipBuyUsdc, DAILY_CHIP_BUY_LIMIT);
        maxChipBuyUsdc = c.maxChipBuyUsdc;
        dailyChipBuyUsdc = c.dailyChipBuyUsdc;
        _requirePool(uint24(c.wethUsdcTickSpacing));
        wethUsdcTickSpacing = c.wethUsdcTickSpacing;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    /* ------------------------------------------------------------------ */
    /*                          Permissionless                             */
    /* ------------------------------------------------------------------ */

    /// @notice Redeem all index tokens held here into stocks (no redeem fee for the fee recipient).
    function redeemFees() external nonReentrant {
        vault.accrue();
        uint256 shares = vault.balanceOf(address(this));
        if (shares == 0) revert NothingToRedeem();
        vault.redeem(shares, address(this), address(this));
        emit FeesRedeemed(shares);
    }

    /// @notice Collect a leg the vault credited here because it could not be delivered at redeem.
    function claimOwed(address token) external nonReentrant {
        vault.claimOwed(token, address(this));
    }

    /// @notice Send half of any undistributed USDC to the Pot and book the other half for $CHIP.
    function distribute() external nonReentrant {
        _distribute();
    }

    /* ------------------------------------------------------------------ */
    /*                              Keeper                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Sell `amountIn` of a listed stock for USDC on Aerodrome. The minimum out is the
    ///         larger of the keeper's `minUsdcOut` and Chainlink value minus `sellSlippageBps`.
    function sellForUsdc(address token, uint256 amountIn, uint256 minUsdcOut, uint256 deadline)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 usdcOut)
    {
        if (!registry.isListed(token)) revert NotListed(token);
        uint256 oracleMin = (registry.valueUsd(token, amountIn) / 1e12) * (BPS - sellSlippageBps) / BPS;
        IERC20(token).forceApprove(address(swapRouter), amountIn);
        usdcOut = swapRouter.exactInputSingle(
            ISlipstreamRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(usdc),
                tickSpacing: registry.usdcTickSpacing(token),
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: Math.max(minUsdcOut, oracleMin),
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(token).forceApprove(address(swapRouter), 0);
        emit SoldForUsdc(token, amountIn, usdcOut);
        _distribute();
    }

    /// @notice Spend `usdcIn` of the $CHIP budget buying $CHIP, then burn it via the ChipBurner.
    function buyAndBurn(uint256 usdcIn, uint256 minChipOut, uint256 deadline)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 chipOut)
    {
        // No onchain price for $CHIP: the keeper must send a floor from a live quote, never 0.
        if (minChipOut == 0) revert ZeroMinChipOut();
        if (usdcIn > chipBudget) revert OverBudget(usdcIn, chipBudget);
        if (usdcIn > maxChipBuyUsdc) revert OverCap(usdcIn, maxChipBuyUsdc);
        if (block.timestamp >= uint256(chipWindowStart) + 1 days) {
            chipWindowStart = uint64(block.timestamp);
            chipWindowSpent = 0;
        }
        uint256 spent = chipWindowSpent + usdcIn;
        if (spent > dailyChipBuyUsdc) revert OverDailyCap(spent, dailyChipBuyUsdc);
        chipWindowSpent = spent;        chipBudget -= usdcIn;

        // 1. USDC -> WETH on Aerodrome, within sellSlippageBps of Chainlink ETH/USD.
        OracleLib.checkSequencer(registry.sequencerFeed());
        uint256 ethUsd = OracleLib.read(ethUsdFeed, ethFeedMaxAge);
        uint256 fairWeth = Math.mulDiv(usdcIn * 1e12, 10 ** _ethFeedDecimals, ethUsd);
        usdc.forceApprove(address(swapRouter), usdcIn);
        uint256 wethIn = swapRouter.exactInputSingle(
            ISlipstreamRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                tickSpacing: wethUsdcTickSpacing,
                recipient: address(this),
                deadline: deadline,
                amountIn: usdcIn,
                amountOutMinimum: fairWeth * (BPS - sellSlippageBps) / BPS,
                sqrtPriceLimitX96: 0
            })
        );
        usdc.forceApprove(address(swapRouter), 0);

        // 2. WETH -> $CHIP on the Uniswap v4 pool (exact input).
        uint256 chipBefore = chip.balanceOf(address(this));
        poolManager.unlock(abi.encode(wethIn));
        chipOut = chip.balanceOf(address(this)) - chipBefore;
        if (chipOut == 0 || chipOut < minChipOut) revert ChipOutBelowMin(chipOut, minChipOut);

        // 3. Burn.
        chip.safeTransfer(address(burner), chipOut);
        burner.burnAll();
        emit ChipBoughtAndBurned(usdcIn, wethIn, chipOut);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 wethIn = abi.decode(data, (uint256));

        // Selling WETH: zeroForOne exactly when WETH is currency0.
        bool zeroForOne = !chipIsCurrency0;
        int256 delta = poolManager.swap(
            poolKey(),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(wethIn), // negative = exact input
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        int128 wethDelta = chipIsCurrency0 ? amount1 : amount0;
        int128 chipDelta = chipIsCurrency0 ? amount0 : amount1;
        uint256 wethOwed = wethDelta < 0 ? uint256(uint128(-wethDelta)) : 0;
        if (wethOwed != wethIn || chipDelta <= 0) revert PartialFill(wethOwed, wethIn);

        poolManager.sync(address(weth));
        weth.safeTransfer(address(poolManager), wethOwed);
        poolManager.settle();
        poolManager.take(address(chip), address(this), uint256(uint128(chipDelta)));
        return "";
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({currency0: _c0, currency1: _c1, fee: _fee, tickSpacing: _tickSpacing, hooks: _hooks});
    }

    /* ------------------------------------------------------------------ */
    /*                              Owner                                  */
    /* ------------------------------------------------------------------ */


    /// @notice Recover a token that is NOT part of the fee flow (sent by mistake, or a stock that
    ///         was delisted and has no price any more). USDC, WETH, $CHIP, the index token and
    ///         every listed stock can never be swept.
    function sweep(address token, address to) external onlyOwner {
        if (
            token == address(usdc) || token == address(weth) || token == address(chip) || token == address(vault)
                || registry.isListed(token)
        ) revert CannotSweep(token);
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, bal);
        emit Swept(token, to, bal);
    }

    /* ------------------------------------------------------------------ */
    /*                             Internals                               */
    /* ------------------------------------------------------------------ */

    function _distribute() internal {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal <= chipBudget) return;
        uint256 fresh = bal - chipBudget;
        uint256 toPot = fresh * POT_SHARE_BPS / BPS;
        uint256 toChip = fresh - toPot;
        chipBudget += toChip;
        if (toPot != 0) usdc.safeTransfer(pot, toPot);
        emit Distributed(toPot, toChip);
    }

    function _requirePool(uint256 v) internal view {
        int24 tickSpacing = int24(uint24(v));
        if (v > type(uint24).max || registry.slipstreamFactory().getPool(address(weth), address(usdc), tickSpacing) == address(0)) {
            revert NoSuchPool(tickSpacing);
        }
    }

    /* ------------------------------------------------------------------ */
    /*                        Settings (lib/Settings)                      */
    /* ------------------------------------------------------------------ */

    function _checkSetting(uint8 key, uint256 v) internal view override {
        if (key == SET_KEEPER) {
            if (v > type(uint160).max) revert ZeroAddress();
        } else if (key == SET_MAX_CHIP_BUY) {
            if (v > MAX_CHIP_BUY_LIMIT) revert OverCap(v, MAX_CHIP_BUY_LIMIT);
        } else if (key == SET_DAILY_CHIP_BUY) {
            if (v > DAILY_CHIP_BUY_LIMIT) revert OverDailyCap(v, DAILY_CHIP_BUY_LIMIT);
        } else if (key == SET_SELL_SLIPPAGE) {
            if (v > MAX_SELL_SLIPPAGE_BPS) revert SlippageAboveCap(uint16(v));
        } else if (key == SET_ETH_FEED_MAX_AGE) {
            if (v < MIN_ETH_FEED_AGE || v > MAX_ETH_FEED_AGE) revert FeedAgeOutOfBounds(v);
        } else if (key == SET_WETH_USDC_TICK_SPACING) {
            _requirePool(v);
        } else {
            revert UnknownSetting(key);
        }
    }

    function _getSetting(uint8 key) internal view override returns (uint256) {
        if (key == SET_KEEPER) return uint160(keeper);
        if (key == SET_MAX_CHIP_BUY) return maxChipBuyUsdc;
        if (key == SET_DAILY_CHIP_BUY) return dailyChipBuyUsdc;
        if (key == SET_SELL_SLIPPAGE) return sellSlippageBps;
        if (key == SET_ETH_FEED_MAX_AGE) return ethFeedMaxAge;
        if (key == SET_WETH_USDC_TICK_SPACING) return uint24(wethUsdcTickSpacing);
        revert UnknownSetting(key);
    }

    function _applySetting(uint8 key, uint256 v) internal override {
        if (key == SET_KEEPER) keeper = address(uint160(v));
        else if (key == SET_MAX_CHIP_BUY) maxChipBuyUsdc = v;
        else if (key == SET_DAILY_CHIP_BUY) dailyChipBuyUsdc = v;
        else if (key == SET_SELL_SLIPPAGE) sellSlippageBps = uint16(v);
        else if (key == SET_ETH_FEED_MAX_AGE) ethFeedMaxAge = v;
        else wethUsdcTickSpacing = int24(uint24(v));
    }

    /// @dev Keeper: only removal is instant. Pool: never instant. Others: lower is tighter.
    function _isTightening(uint8 key, uint256 v) internal view override returns (bool) {
        if (key == SET_KEEPER) return v == 0;
        if (key == SET_WETH_USDC_TICK_SPACING) return false;
        return v <= _getSetting(key);
    }
}
