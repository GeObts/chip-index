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
import {IWETH} from "./interfaces/IExternal.sol";
import {ISlipstreamRouter} from "./interfaces/ISlipstreamRouter.sol";
import {OracleLib} from "./lib/OracleLib.sol";
import {Settings} from "./lib/Settings.sol";

/**
 * @title IndexRouter
 * @notice Mint the index with USDC or ETH, or redeem it to USDC or ETH, by trading every stock
 *         leg on Aerodrome Slipstream. It holds nothing between calls and has no special power
 *         over the vault: it uses the same public `mint`/`redeem` anyone can.
 *
 *         Protection on every call:
 *         - the user's own limit (max USDC/ETH in, or min USDC/ETH out), and
 *         - each leg must trade within `legSlippageBps` (max 1%) of the Chainlink price.
 *         Cash mints AND cash redeems need every feed fresh. When feeds are frozen
 *         (weekends, holidays) use the vault's in-kind redeem, which never stops.
 *
 *         Cash redeems refuse issuer-blocklisted callers and recipients (see IndexVault BLOCKLIST).
 *
 *         Assumes 1 USDC = $1 when comparing USDC against the stock feeds.
 *
 *         Settings (lib/Settings): SET_KEEPER, SET_LEG_SLIPPAGE, SET_ETH_FEED_MAX_AGE (lower is
 *         instant, higher is 48h; removing the keeper is instant, adding one is 48h) and
 *         SET_WETH_USDC_TICK_SPACING (pool choice: 48h only). Pausing (owner or keeper) and
 *         unpausing (owner) stay instant.
 */
contract IndexRouter is Settings, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_LEG_SLIPPAGE_BPS = 100; // 1%
    uint256 public constant MIN_ETH_FEED_AGE = 5 minutes;
    uint256 public constant MAX_ETH_FEED_AGE = 24 hours;

    uint8 public constant SET_KEEPER = 0;
    uint8 public constant SET_LEG_SLIPPAGE = 1;
    uint8 public constant SET_ETH_FEED_MAX_AGE = 2;
    uint8 public constant SET_WETH_USDC_TICK_SPACING = 3;

    IndexVault public immutable vault;
    BasketRegistry public immutable registry;
    ISlipstreamRouter public immutable swapRouter;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    address public immutable ethUsdFeed;
    uint8 internal immutable _ethFeedDecimals;

    address public keeper;
    int24 public wethUsdcTickSpacing;
    uint16 public legSlippageBps = MAX_LEG_SLIPPAGE_BPS;
    uint256 public ethFeedMaxAge = 1 hours;
    bool public cashMintPaused;
    bool public cashRedeemPaused;

    event MintedWithUsdc(address indexed user, address indexed to, uint256 shares, uint256 usdcSpent);
    event MintedWithEth(address indexed user, address indexed to, uint256 shares, uint256 ethSpent);
    event RedeemedToUsdc(address indexed user, address indexed to, uint256 shares, uint256 usdcOut);
    event RedeemedToEth(address indexed user, address indexed to, uint256 shares, uint256 ethOut);
    event CashMintPausedSet(bool paused, address by);
    event CashRedeemPausedSet(bool paused, address by);
    event EthPaidAsWeth(address indexed to, uint256 amount);

    error ZeroAddress();
    error Expired(uint256 deadline);
    error CashMintIsPaused();
    error CashRedeemIsPaused();
    error NotOwnerOrKeeper();
    error SlippageAboveCap(uint16 bps);
    error FeedAgeOutOfBounds(uint256 maxAge);
    error NoSuchPool(int24 tickSpacing);
    error SpentAboveMax(uint256 spent, uint256 max);
    error OutputBelowMin(uint256 out, uint256 min);
    error OnlyWeth();

    constructor(
        address owner_,
        IndexVault vault_,
        ISlipstreamRouter swapRouter_,
        address usdc_,
        address weth_,
        address ethUsdFeed_,
        int24 wethUsdcTickSpacing_,
        address keeper_
    ) Ownable(owner_) {
        if (
            address(vault_) == address(0) || address(swapRouter_) == address(0) || usdc_ == address(0)
                || weth_ == address(0) || ethUsdFeed_ == address(0)
        ) revert ZeroAddress();
        vault = vault_;
        registry = vault_.registry();
        swapRouter = swapRouter_;
        usdc = IERC20(usdc_);
        weth = IERC20(weth_);
        ethUsdFeed = ethUsdFeed_;
        _ethFeedDecimals = IAggregatorV3(ethUsdFeed_).decimals();
        keeper = keeper_;
        _requirePool(uint24(wethUsdcTickSpacing_));
        wethUsdcTickSpacing = wethUsdcTickSpacing_;
    }

    receive() external payable {
        if (msg.sender != address(weth)) revert OnlyWeth();
    }

    /* ------------------------------------------------------------------ */
    /*                               Mint                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Pay up to `maxUsdcIn` USDC for exactly `shares` index tokens (gross of the mint fee).
    ///         Unspent USDC is refunded.
    function mintWithUsdc(uint256 shares, uint256 maxUsdcIn, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcSpent)
    {
        _checkMint(deadline);
        uint256 before = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), maxUsdcIn);
        usdc.forceApprove(address(swapRouter), maxUsdcIn);

        (address[] memory list, uint256[] memory amounts) = vault.previewMint(shares);
        for (uint256 i; i < list.length; ++i) {
            if (amounts[i] == 0) continue;
            swapRouter.exactOutputSingle(
                ISlipstreamRouter.ExactOutputSingleParams({
                    tokenIn: address(usdc),
                    tokenOut: list[i],
                    tickSpacing: registry.usdcTickSpacing(list[i]),
                    recipient: address(this),
                    deadline: deadline,
                    amountOut: amounts[i],
                    amountInMaximum: _maxUsdcFor(list[i], amounts[i]),
                    sqrtPriceLimitX96: 0
                })
            );
            IERC20(list[i]).forceApprove(address(vault), amounts[i]);
        }
        usdc.forceApprove(address(swapRouter), 0);
        vault.mint(shares, to);

        uint256 left = usdc.balanceOf(address(this)) - before;
        usdcSpent = maxUsdcIn - left;
        if (left != 0) usdc.safeTransfer(msg.sender, left);
        emit MintedWithUsdc(msg.sender, to, shares, usdcSpent);
    }

    /// @notice Pay up to `msg.value` ETH for exactly `shares` index tokens. Unspent ETH is refunded.
    function mintWithEth(uint256 shares, address to, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 ethSpent)
    {
        _checkMint(deadline);
        uint256 ethUsd = _ethPrice();
        uint256 before = weth.balanceOf(address(this));
        IWETH(address(weth)).deposit{value: msg.value}();
        weth.forceApprove(address(swapRouter), msg.value);

        (address[] memory list, uint256[] memory amounts) = vault.previewMint(shares);
        for (uint256 i; i < list.length; ++i) {
            if (amounts[i] == 0) continue;
            uint256 maxWeth = _withSlippageUp(_wethForUsd(registry.valueUsd(list[i], amounts[i]), ethUsd, true));
            swapRouter.exactOutput(
                ISlipstreamRouter.ExactOutputParams({
                    // exactOutput paths are reversed: tokenOut first.
                    path: abi.encodePacked(
                        list[i], registry.usdcTickSpacing(list[i]), address(usdc), wethUsdcTickSpacing, address(weth)
                    ),
                    recipient: address(this),
                    deadline: deadline,
                    amountOut: amounts[i],
                    amountInMaximum: maxWeth
                })
            );
            IERC20(list[i]).forceApprove(address(vault), amounts[i]);
        }
        weth.forceApprove(address(swapRouter), 0);
        vault.mint(shares, to);

        uint256 left = weth.balanceOf(address(this)) - before;
        ethSpent = msg.value - left;
        if (left != 0) {
            IWETH(address(weth)).withdraw(left);
            _sendEth(msg.sender, left);
        }
        emit MintedWithEth(msg.sender, to, shares, ethSpent);
    }

    /* ------------------------------------------------------------------ */
    /*                              Redeem                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Redeem `shares` and sell every stock leg for USDC; at least `minUsdcOut` goes to `to`.
    ///         A leg the vault cannot deliver is credited to the caller in the vault (`claimOwed`).
    function redeemToUsdc(uint256 shares, uint256 minUsdcOut, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcOut)
    {
        _checkRedeem(deadline, to);
        (address[] memory list, uint256[] memory got) = _redeemHere(shares);
        uint256 before = usdc.balanceOf(address(this));
        for (uint256 i; i < list.length; ++i) {
            if (got[i] == 0) continue;
            IERC20(list[i]).forceApprove(address(swapRouter), got[i]);
            swapRouter.exactInputSingle(
                ISlipstreamRouter.ExactInputSingleParams({
                    tokenIn: list[i],
                    tokenOut: address(usdc),
                    tickSpacing: registry.usdcTickSpacing(list[i]),
                    recipient: address(this),
                    deadline: deadline,
                    amountIn: got[i],
                    amountOutMinimum: _minUsdcFor(list[i], got[i]),
                    sqrtPriceLimitX96: 0
                })
            );
        }
        usdcOut = usdc.balanceOf(address(this)) - before;
        if (usdcOut < minUsdcOut) revert OutputBelowMin(usdcOut, minUsdcOut);
        usdc.safeTransfer(to, usdcOut);
        emit RedeemedToUsdc(msg.sender, to, shares, usdcOut);
    }

    /// @notice Redeem `shares` and sell every stock leg for ETH; at least `minEthOut` goes to `to`.
    function redeemToEth(uint256 shares, uint256 minEthOut, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        _checkRedeem(deadline, to);
        uint256 ethUsd = _ethPrice();
        (address[] memory list, uint256[] memory got) = _redeemHere(shares);
        uint256 before = weth.balanceOf(address(this));
        for (uint256 i; i < list.length; ++i) {
            if (got[i] == 0) continue;
            uint256 minWeth = _withSlippageDown(_wethForUsd(registry.valueUsd(list[i], got[i]), ethUsd, false));
            IERC20(list[i]).forceApprove(address(swapRouter), got[i]);
            swapRouter.exactInput(
                ISlipstreamRouter.ExactInputParams({
                    path: abi.encodePacked(
                        list[i], registry.usdcTickSpacing(list[i]), address(usdc), wethUsdcTickSpacing, address(weth)
                    ),
                    recipient: address(this),
                    deadline: deadline,
                    amountIn: got[i],
                    amountOutMinimum: minWeth
                })
            );
        }
        ethOut = weth.balanceOf(address(this)) - before;
        if (ethOut < minEthOut) revert OutputBelowMin(ethOut, minEthOut);
        IWETH(address(weth)).withdraw(ethOut);
        _sendEth(to, ethOut);
        emit RedeemedToEth(msg.sender, to, shares, ethOut);
    }

    /* ------------------------------------------------------------------ */
    /*                              Admin                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Owner or keeper can pause (fast emergency stop); only the owner can unpause.
    function pauseCashMint() external {
        _onlyOwnerOrKeeper();
        cashMintPaused = true;
        emit CashMintPausedSet(true, msg.sender);
    }

    function pauseCashRedeem() external {
        _onlyOwnerOrKeeper();
        cashRedeemPaused = true;
        emit CashRedeemPausedSet(true, msg.sender);
    }

    function unpauseCashMint() external onlyOwner {
        cashMintPaused = false;
        emit CashMintPausedSet(false, msg.sender);
    }

    function unpauseCashRedeem() external onlyOwner {
        cashRedeemPaused = false;
        emit CashRedeemPausedSet(false, msg.sender);
    }

    /* ------------------------------------------------------------------ */
    /*                        Settings (lib/Settings)                      */
    /* ------------------------------------------------------------------ */

    function _checkSetting(uint8 key, uint256 v) internal view override {
        if (key == SET_KEEPER) {
            if (v > type(uint160).max) revert ZeroAddress();
        } else if (key == SET_LEG_SLIPPAGE) {
            if (v > MAX_LEG_SLIPPAGE_BPS) revert SlippageAboveCap(uint16(v));
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
        if (key == SET_LEG_SLIPPAGE) return legSlippageBps;
        if (key == SET_ETH_FEED_MAX_AGE) return ethFeedMaxAge;
        if (key == SET_WETH_USDC_TICK_SPACING) return uint24(wethUsdcTickSpacing);
        revert UnknownSetting(key);
    }

    function _applySetting(uint8 key, uint256 v) internal override {
        if (key == SET_KEEPER) keeper = address(uint160(v));
        else if (key == SET_LEG_SLIPPAGE) legSlippageBps = uint16(v);
        else if (key == SET_ETH_FEED_MAX_AGE) ethFeedMaxAge = v;
        else wethUsdcTickSpacing = int24(uint24(v));
    }

    /// @dev Keeper: only removal is instant. Pool: never instant. Others: lower is tighter.
    function _isTightening(uint8 key, uint256 v) internal view override returns (bool) {
        if (key == SET_KEEPER) return v == 0;
        if (key == SET_WETH_USDC_TICK_SPACING) return false;
        return v <= _getSetting(key);
    }

    /* ------------------------------------------------------------------ */
    /*                             Internals                               */
    /* ------------------------------------------------------------------ */

    function _checkMint(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert Expired(deadline);
        if (cashMintPaused) revert CashMintIsPaused();
        registry.requireAllFresh(); // never mint at a stale price
    }

    function _checkRedeem(uint256 deadline, address to) internal view {
        if (block.timestamp > deadline) revert Expired(deadline);
        if (cashRedeemPaused) revert CashRedeemIsPaused();
        if (to == address(0)) revert ZeroAddress();
        registry.requireAllFresh();
        // The vault checks the caller (as credit holder) and this router; the cash recipient is
        // checked here, so a blocklisted account cannot redeem through a clean address or vice versa.
        vault.requireNotBlocked(to);
    }

    /// @dev Pull the user's index tokens, redeem in kind to this contract (credits go to the user),
    ///      and return what actually arrived per token.
    function _redeemHere(uint256 shares) internal returns (address[] memory list, uint256[] memory got) {
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), shares);
        list = registry.tokens();
        got = new uint256[](list.length);
        for (uint256 i; i < list.length; ++i) {
            got[i] = IERC20(list[i]).balanceOf(address(this));
        }
        vault.redeem(shares, address(this), msg.sender);
        for (uint256 i; i < list.length; ++i) {
            got[i] = IERC20(list[i]).balanceOf(address(this)) - got[i];
        }
    }

    function _ethPrice() internal view returns (uint256) {
        OracleLib.checkSequencer(registry.sequencerFeed());
        return OracleLib.read(ethUsdFeed, ethFeedMaxAge);
    }

    /// @dev WETH (18 dec) worth `usd18` dollars at `ethUsd` (feed decimals).
    function _wethForUsd(uint256 usd18, uint256 ethUsd, bool roundUp) internal view returns (uint256) {
        return Math.mulDiv(
            usd18, 10 ** _ethFeedDecimals, ethUsd, roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor
        );
    }

    /// @dev Most USDC (6 dec) a leg buying `amount` of `token` may cost.
    function _maxUsdcFor(address token, uint256 amount) internal view returns (uint256) {
        uint256 usd6 = Math.mulDiv(registry.valueUsd(token, amount), 1, 1e12, Math.Rounding.Ceil);
        return _withSlippageUp(usd6);
    }

    /// @dev Least USDC (6 dec) a leg selling `amount` of `token` must return.
    function _minUsdcFor(address token, uint256 amount) internal view returns (uint256) {
        return _withSlippageDown(registry.valueUsd(token, amount) / 1e12);
    }

    function _withSlippageUp(uint256 x) internal view returns (uint256) {
        return Math.mulDiv(x, BPS + legSlippageBps, BPS, Math.Rounding.Ceil);
    }

    function _withSlippageDown(uint256 x) internal view returns (uint256) {
        return x * (BPS - legSlippageBps) / BPS;
    }

    function _requirePool(uint256 v) internal view {
        int24 tickSpacing = int24(uint24(v));
        if (v > type(uint24).max || registry.slipstreamFactory().getPool(address(weth), address(usdc), tickSpacing) == address(0)) {
            revert NoSuchPool(tickSpacing);
        }
    }

    function _onlyOwnerOrKeeper() internal view {
        if (msg.sender != owner() && msg.sender != keeper) revert NotOwnerOrKeeper();
    }

    /// @dev Pay ETH, falling back to WETH if the recipient cannot take ETH (a contract wallet with no
    ///      or a reverting `receive`). A refund or payout can therefore never block a mint or redeem.
    ///      All gas is forwarded, so Safes and smart wallets that do work in `receive` still get ETH.
    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) {
            IWETH(address(weth)).deposit{value: amount}();
            weth.safeTransfer(to, amount);
            emit EthPaidAsWeth(to, amount);
        }
    }
}
