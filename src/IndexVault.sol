// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BasketRegistry} from "./BasketRegistry.sol";
import {Settings} from "./lib/Settings.sol";

/// @dev The two B20 surfaces the blocklist check needs (base-std IB20 / IPolicyRegistry).
interface IB20Policy {
    function policyId(bytes32 policyScope) external view returns (uint64);
}

interface IB20Pausable {
    /// @dev `feature` 0 = TRANSFER (base-std IB20.PausableFeature).
    function isPaused(uint8 feature) external view returns (bool);
}

interface IPolicyRegistryView {
    function isAuthorized(uint64 policyId, address account) external view returns (bool);
}

interface IRebalanceCallback {
    /// @notice Called by the vault mid-trade. `amountIn` of `tokenIn` has already been sent to
    ///         the caller; it must deliver `tokenOut` back to the vault before returning.
    function onRebalanceTrade(address tokenIn, uint256 amountIn, address tokenOut, bytes calldata data) external;
}

/**
 * @title IndexVault ("Chip Index")
 * @notice The index ERC-20. It holds the basket of B20 stocks.
 *
 *         MINT (in kind): deposit every held stock in the vault's current proportions and receive
 *         index tokens. It is pure pro-rata, `amount_i = ceil(held_i * shares / supply)`, so NO
 *         price is used: a stale or frozen feed cannot mis-price a mint.
 *
 *         REDEEM (in kind): burn index tokens and receive `floor(held_i * shares / supply)` of every
 *         stock. It can never be paused: there is no pause flag, no oracle read, and no registry
 *         freshness check on this path. If a single stock cannot be sent (issuer paused it, or a
 *         blocklist rejects the vault or the receiver), that leg is CREDITED to `creditTo` instead
 *         of reverting the whole redeem. The credit is claimable later with `claimOwed`.
 *
 *         BLOCKLIST: the vault refuses to deliver stock to, or on behalf of, any address the issuer
 *         has blocklisted. Before every redeem it checks the caller, the receiver and the credit
 *         holder against every listed stock's transfer policies (sender, receiver, executor) in
 *         Base's PolicyRegistry, and reverts `Blocklisted` if any of them is not authorized. A claim
 *         of credited stock gets the same check for that stock. This deliberately makes redeem
 *         unavailable to blocklisted accounts: it is the issuer's rule, not an admin switch here.
 *
 *         ACCOUNTING: `held[token]` is the vault's own book of what backs the index. Credits
 *         (`totalOwed`) are kept separately and are not index backing. If the issuer seizes stock
 *         from the vault, the real balance drops below `held + totalOwed`. Every action that pays
 *         out or prices against the books (mint, redeem, claimOwed, executeTrade) first re-reads
 *         the real balance of every listed stock and writes any shortfall down pro-rata for index
 *         holders and credit holders alike, so nobody is ever paid from the stale, too-high book.
 *         The views (previewMint, previewRedeem, navUsd, owed) show the same written-down figures.
 *         This write-down never reverts and never pauses redeem. A SURPLUS (a donation) is NOT
 *         folded in automatically: only an explicit `sync` gives it to index holders.
 *
 *         FEES (index tokens to `feeRecipient`): a mint fee and a redeem fee, both owner-settable
 *         under a hard cap, plus a management fee accrued continuously as newly minted index tokens.
 *         The mint fee is size-tiered: the dollar value of one mint, priced at NAV from the
 *         Chainlink feeds, picks one of three rates (launch: 1% under $10k, 0.75% from $10k,
 *         0.5% from $50k). It applies to every mint path, because USDC and ETH mints reach the
 *         vault through the router as an in-kind `mint`. If any feed is stale the mint still
 *         goes through, at the base (highest) rate: no fresh price, no discount. The schedule
 *         changes only through the 48h timelock, and no rate may exceed MAX_MINT_FEE_BPS (1%).
 */
contract IndexVault is ERC20, Settings, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_MINT_FEE_BPS = 100; // 1%, every tier
    uint256 public constant MAX_REDEEM_FEE_BPS = 200; // 2%
    uint256 public constant MAX_MGMT_FEE_BPS = 500; // 5% a year
    uint256 public constant MAX_TRADE_SLIPPAGE_BPS = 100; // rebalance hard cap (launch 0.75%)
    uint256 public constant MAX_DAILY_TRADE_BPS = 2_500; // hard cap: 25% of NAV traded per day
    uint256 public constant MAX_DAILY_LOSS_BPS = 50; // hard cap: 0.5% of NAV lost per day
    uint256 public constant TRADE_WINDOW = 1 days;
    /// @dev Gas forwarded to each B20 transfer on redeem. A real B20 transfer measured ~30k on a
    ///      Base fork (2026-10-12); this is generous so a leg only fails when the token refuses.
    uint256 public constant REDEEM_LEG_GAS = 250_000;

    bytes32 public constant ACTION_REBALANCER = keccak256("REBALANCER");
    bytes32 public constant ACTION_FEE_RECIPIENT = keccak256("FEE_RECIPIENT");
    bytes32 public constant ACTION_MINT_FEE_SCHEDULE = keccak256("MINT_FEE_SCHEDULE");

    /// @notice Setting keys (see lib/Settings.sol). Lowering any of them is instant; raising goes
    ///         through the 48h timelock.
    uint8 public constant SET_REDEEM_FEE = 0; // bps, <= MAX_REDEEM_FEE_BPS
    uint8 public constant SET_MGMT_FEE = 1; // bps a year, <= MAX_MGMT_FEE_BPS
    uint8 public constant SET_MINT_CAP = 2; // index token units
    uint8 public constant SET_MAX_TRADE_SLIPPAGE = 3; // bps, <= MAX_TRADE_SLIPPAGE_BPS
    uint8 public constant SET_DAILY_TRADE_CAP = 4; // bps of NAV, <= MAX_DAILY_TRADE_BPS
    uint8 public constant SET_DAILY_LOSS_CAP = 5; // bps of NAV, <= MAX_DAILY_LOSS_BPS
    bytes32 public constant TRANSFER_SENDER_POLICY = keccak256("TRANSFER_SENDER_POLICY");
    bytes32 public constant TRANSFER_RECEIVER_POLICY = keccak256("TRANSFER_RECEIVER_POLICY");
    bytes32 public constant TRANSFER_EXECUTOR_POLICY = keccak256("TRANSFER_EXECUTOR_POLICY");

    /// @notice Size-tiered mint fee. Thresholds are USD with 18 decimals and compare against the
    ///         NAV value of the gross shares minted: value < tier1MinUsd pays baseBps, value >=
    ///         tier1MinUsd pays tier1Bps, value >= tier2MinUsd pays tier2Bps.
    struct MintFeeSchedule {
        uint128 tier1MinUsd;
        uint128 tier2MinUsd;
        uint16 baseBps;
        uint16 tier1Bps;
        uint16 tier2Bps;
    }

    BasketRegistry public immutable registry;
    /// @notice Base's PolicyRegistry precompile (0x8453...0002 on mainnet).
    IPolicyRegistryView public immutable policyRegistry;
    address private immutable _deployer;

    mapping(address token => uint256) public held;

    /// @dev Credits are kept as shares of one pool per token, so a seizure can be written down for
    ///      every credit holder at once without looping over accounts. The pool's scale is
    ///      totalOwed / totalOwedShares; one account's credit is its shares at that scale, rounded
    ///      down, so the credits can never add up to more than `totalOwed`. If a seizure wipes a
    ///      pool out completely, the token's epoch moves on: older shares are worth nothing and
    ///      new credits start a fresh pool.
    mapping(address account => mapping(address token => uint256)) internal _owedShares;
    mapping(address account => mapping(address token => uint64)) internal _owedEpoch;
    mapping(address token => uint256) public totalOwed;
    mapping(address token => uint256) public totalOwedShares;
    mapping(address token => uint64) public owedEpoch;

    address public feeRecipient;
    address public rebalancer;
    MintFeeSchedule internal _mintFees;
    uint16 public redeemFeeBps;
    uint16 public mgmtFeeBps;
    uint16 public maxTradeSlippageBps = 75;
    /// @notice Rebalance trading allowed per 24h window, and Chainlink value it may lose, both in
    ///         bps of NAV at the window's first trade. Enforced here, so they bind ANY Rebalancer.
    uint16 public dailyTradeCapBps = 1_500; // 15% of NAV: one whole stock (12.5%) can be sold off in a day
    uint16 public dailyLossCapBps = 10; // 0.10% of NAV
    bool public mintPaused;
    uint64 public lastAccrual;
    uint256 public mintCap;

    /// @notice The current 24h trade window: when it opened, NAV then, and what was traded and lost.
    uint64 public tradeWindowStart;
    uint256 public windowNavUsd;
    uint256 public windowTradedUsd;
    uint256 public windowLostUsd;

    event Seeded(address indexed to, uint256 shares, uint256[] amounts);
    event Minted(address indexed caller, address indexed to, uint256 shares, uint256 fee, uint256[] amounts);
    event Redeemed(
        address indexed caller, address indexed receiver, uint256 shares, uint256 fee, uint256[] amounts
    );
    event LegCredited(address indexed creditTo, address indexed token, uint256 amount);
    event OwedClaimed(address indexed account, address indexed token, address to, uint256 amount);
    event ManagementFeeAccrued(uint256 shares, uint256 elapsed);
    event Synced(address indexed token, uint256 oldHeld, uint256 newHeld);
    event CreditsWrittenDown(address indexed token, uint256 oldTotalOwed, uint256 newTotalOwed);
    event Traded(address indexed tokenIn, uint256 amountIn, address indexed tokenOut, uint256 amountOut);
    event FeesSet(uint16 redeemFeeBps, uint16 mgmtFeeBps);
    event MintFeeScheduleSet(MintFeeSchedule schedule);
    event MintPausedSet(bool paused);
    event RebalancerSet(address rebalancer);
    event FeeRecipientSet(address feeRecipient);

    error ZeroAddress();
    error ZeroShares();
    error MintIsPaused();
    error NotSeeded();
    error AlreadySeeded();
    error MintCapExceeded(uint256 supplyAfter, uint256 cap);
    error FeeAboveCap(uint256 fee, uint256 cap);
    error BadTierThresholds(uint256 tier1MinUsd, uint256 tier2MinUsd);
    error LengthMismatch();
    error NothingHeld();
    error ShortDelivery(address token, uint256 expected, uint256 received);
    error NotRebalancer();
    error NotListed(address token);
    error InsufficientHeld(address token, uint256 wanted, uint256 held);
    error TradeBelowMin(uint256 received, uint256 minOut);
    error TradeValueLoss(uint256 valueIn, uint256 valueOut, uint256 maxSlippageBps);
    error TradeTookMore(address token);
    error NotEnoughGasForLeg();
    error NothingOwed();
    error NotDeployer();
    error AlreadyWired();
    error Blocklisted(address account, address token);
    error StockPaused(address token);
    error DailyTradeCapExceeded(uint256 tradedUsd, uint256 capUsd);
    error DailyLossCapExceeded(uint256 lostUsd, uint256 capUsd);

    constructor(
        address owner_,
        BasketRegistry registry_,
        address policyRegistry_,
        string memory name_,
        string memory symbol_,
        MintFeeSchedule memory mintFees_,
        uint16 redeemFeeBps_,
        uint16 mgmtFeeBps_,
        uint256 mintCap_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        if (address(registry_) == address(0) || policyRegistry_ == address(0)) revert ZeroAddress();
        registry = registry_;
        policyRegistry = IPolicyRegistryView(policyRegistry_);
        _deployer = msg.sender;
        _setMintFees(mintFees_);
        _setFees(redeemFeeBps_, mgmtFeeBps_);
        mintCap = mintCap_;
        lastAccrual = uint64(block.timestamp);
    }

    /// @notice One-time wiring by the deploy script (the Safe owns the vault from block one).
    ///         Later changes to either address go through the 48h timelock.
    function wire(address feeRecipient_, address rebalancer_) external {
        if (msg.sender != _deployer) revert NotDeployer();
        if (feeRecipient != address(0) || rebalancer != address(0)) revert AlreadyWired();
        if (feeRecipient_ == address(0) || rebalancer_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        rebalancer = rebalancer_;
        emit FeeRecipientSet(feeRecipient_);
        emit RebalancerSet(rebalancer_);
    }

    /* ------------------------------------------------------------------ */
    /*                               Mint                                  */
    /* ------------------------------------------------------------------ */

    /// @notice First mint, owner only. Sets the starting composition and the starting price of
    ///         one index token. `amounts` lines up with `registry.tokens()`.
    function seed(uint256[] calldata amounts, uint256 shares, address to) external onlyOwner nonReentrant {
        if (totalSupply() != 0) revert AlreadySeeded();
        if (shares == 0) revert ZeroShares();
        if (to == address(0) || feeRecipient == address(0)) revert ZeroAddress();
        address[] memory list = registry.tokens();
        if (amounts.length != list.length) revert LengthMismatch();
        _requireMintable();
        bool any;
        for (uint256 i; i < list.length; ++i) {
            if (amounts[i] == 0) continue;
            any = true;
            _pull(list[i], msg.sender, amounts[i]);
            held[list[i]] += amounts[i];
        }
        if (!any) revert NothingHeld();
        lastAccrual = uint64(block.timestamp);
        _mint(to, shares);
        if (totalSupply() > mintCap) revert MintCapExceeded(totalSupply(), mintCap);
        emit Seeded(to, shares, amounts);
    }

    /// @notice Stocks needed to mint `shares` (gross, before the mint fee), in `registry.tokens()` order.
    function previewMint(uint256 shares) public view returns (address[] memory list, uint256[] memory amounts) {
        uint256 supply = totalSupply() + pendingManagementFee();
        list = registry.tokens();
        amounts = new uint256[](list.length);
        if (supply == 0) return (list, amounts);
        for (uint256 i; i < list.length; ++i) {
            (uint256 h,) = _live(list[i]);
            amounts[i] = Math.mulDiv(h, shares, supply, Math.Rounding.Ceil);
        }
    }

    /// @notice Deposit stocks pro-rata and receive `shares` minus the mint fee.
    ///         Approve each stock to this vault first; amounts come from `previewMint`.
    function mint(uint256 shares, address to) external nonReentrant returns (uint256[] memory amounts) {
        if (mintPaused) revert MintIsPaused();
        if (shares == 0) revert ZeroShares();
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply() == 0) revert NotSeeded();
        _requireMintable();
        _reconcileAll();
        _accrue();

        // Priced before the deposit lands, against the same supply previewMint uses.
        (uint16 feeBps,) = mintFeeFor(shares);

        address[] memory list;
        (list, amounts) = previewMint(shares);
        for (uint256 i; i < list.length; ++i) {
            if (amounts[i] == 0) continue;
            _pull(list[i], msg.sender, amounts[i]);
            held[list[i]] += amounts[i];
        }

        uint256 fee = shares * feeBps / BPS;
        _mint(to, shares - fee);
        if (fee != 0) _mint(feeRecipient, fee);
        if (totalSupply() > mintCap) revert MintCapExceeded(totalSupply(), mintCap);
        emit Minted(msg.sender, to, shares, fee, amounts);
    }

    /// @notice The mint fee rate for minting `shares` now, and the NAV value it was priced at.
    ///         `valueUsd` is 0 when a feed is stale (or before the seed); the base rate applies.
    function mintFeeFor(uint256 shares) public view returns (uint16 feeBps, uint256 valueUsd) {
        MintFeeSchedule memory s = _mintFees;
        uint256 supply = totalSupply() + pendingManagementFee();
        if (supply == 0) return (s.baseBps, 0);
        try this.navUsd() returns (uint256 nav) {
            valueUsd = Math.mulDiv(nav, shares, supply);
        } catch {
            return (s.baseBps, 0);
        }
        if (valueUsd >= s.tier2MinUsd) return (s.tier2Bps, valueUsd);
        if (valueUsd >= s.tier1MinUsd) return (s.tier1Bps, valueUsd);
        return (s.baseBps, valueUsd);
    }

    function mintFeeSchedule() external view returns (MintFeeSchedule memory) {
        return _mintFees;
    }

    /* ------------------------------------------------------------------ */
    /*                       Redeem (never paused)                         */
    /* ------------------------------------------------------------------ */

    function previewRedeem(uint256 shares, address caller)
        public
        view
        returns (address[] memory list, uint256[] memory amounts, uint256 fee)
    {
        uint256 supply = totalSupply() + pendingManagementFee();
        fee = caller == feeRecipient ? 0 : shares * redeemFeeBps / BPS;
        uint256 net = shares - fee;
        list = registry.tokens();
        amounts = new uint256[](list.length);
        if (supply == 0) return (list, amounts, fee);
        for (uint256 i; i < list.length; ++i) {
            (uint256 h,) = _live(list[i]);
            amounts[i] = Math.mulDiv(h, net, supply);
        }
    }

    function redeem(uint256 shares, address receiver) external returns (uint256[] memory) {
        return redeem(shares, receiver, receiver);
    }

    /// @notice Burn `shares` (less the redeem fee) for the matching slice of every stock.
    /// @param receiver gets the stocks.
    /// @param creditTo is credited any leg that cannot be delivered (paused token, blocklist).
    function redeem(uint256 shares, address receiver, address creditTo)
        public
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0) || creditTo == address(0)) revert ZeroAddress();
        _requireNotBlocked(msg.sender, receiver, creditTo);
        _reconcileAll();
        _accrue();

        address[] memory list;
        uint256 fee;
        (list, amounts, fee) = previewRedeem(shares, msg.sender);

        if (fee != 0) _transfer(msg.sender, feeRecipient, fee);
        _burn(msg.sender, shares - fee);

        for (uint256 i; i < list.length; ++i) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            address token = list[i];
            held[token] -= amt;
            if (!_tryTransfer(token, receiver, amt)) {
                _credit(creditTo, token, amt);
                emit LegCredited(creditTo, token, amt);
            }
        }
        emit Redeemed(msg.sender, receiver, shares, fee, amounts);
    }

    /// @notice Collect a credited leg once the token can move again. Sends to `to`.
    ///         Credits only exist on listed tokens (the registry cannot drop a token while
    ///         `totalOwed` is above zero), so reconciling the listed tokens covers this one.
    function claimOwed(address token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        _reconcileAll();
        amount = owed(msg.sender, token);
        if (amount == 0) revert NothingOwed();
        if (isBlocked(msg.sender, token)) revert Blocklisted(msg.sender, token);
        if (isBlocked(to, token)) revert Blocklisted(to, token);
        totalOwedShares[token] -= _owedShares[msg.sender][token];
        totalOwed[token] -= amount;
        _owedShares[msg.sender][token] = 0;
        IERC20(token).safeTransfer(to, amount);
        emit OwedClaimed(msg.sender, token, to, amount);
    }

    /// @notice What `account` can claim of `token` right now, after any seizure write-down
    ///         (including one not yet written to storage).
    function owed(address account, address token) public view returns (uint256) {
        uint256 s = _owedShares[account][token];
        if (s == 0 || _owedEpoch[account][token] != owedEpoch[token]) return 0;
        (, uint256 o) = _live(token);
        return Math.mulDiv(s, o, totalOwedShares[token]);
    }

    /// @dev New credits buy pool shares at the current scale, rounded down, so they never dilute
    ///      existing credit holders.
    function _credit(address account, address token, uint256 amt) internal {
        uint64 epoch = owedEpoch[token];
        if (_owedEpoch[account][token] != epoch) {
            _owedShares[account][token] = 0; // worthless shares from a wiped-out pool
            _owedEpoch[account][token] = epoch;
        }
        uint256 supply = totalOwedShares[token];
        uint256 shares = supply == 0 ? amt : Math.mulDiv(amt, supply, totalOwed[token]);
        _owedShares[account][token] += shares;
        totalOwedShares[token] = supply + shares;
        totalOwed[token] += amt;
    }

    /* ------------------------------------------------------------------ */
    /*                             Blocklist                               */
    /* ------------------------------------------------------------------ */

    /// @notice True if `account` is not authorized under any of `token`'s transfer policies.
    function isBlocked(address account, address token) public view returns (bool) {
        IB20Policy t = IB20Policy(token);
        return !policyRegistry.isAuthorized(t.policyId(TRANSFER_SENDER_POLICY), account)
            || !policyRegistry.isAuthorized(t.policyId(TRANSFER_RECEIVER_POLICY), account)
            || !policyRegistry.isAuthorized(t.policyId(TRANSFER_EXECUTOR_POLICY), account);
    }

    /// @notice The first listed stock that blocklists `account`, or address(0) if none does.
    function blockedOn(address account) public view returns (address) {
        address[] memory list = registry.tokens();
        for (uint256 i; i < list.length; ++i) {
            if (isBlocked(account, list[i])) return list[i];
        }
        return address(0);
    }

    /// @notice Reverts `Blocklisted` if any listed stock blocklists `account`. Used by the Router.
    function requireNotBlocked(address account) external view {
        address t = blockedOn(account);
        if (t != address(0)) revert Blocklisted(account, t);
    }

    /// @notice Minting stops outright while any listed stock has transfers paused by its issuer,
    ///         or the issuer has blocklisted the vault on any of them. Otherwise stock could flow
    ///         in that the vault cannot send back out. Reverts StockPaused / Blocklisted(vault, t).
    function requireMintable() external view {
        _requireMintable();
    }

    function _requireMintable() internal view {
        address[] memory list = registry.tokens();
        for (uint256 i; i < list.length; ++i) {
            if (IB20Pausable(list[i]).isPaused(0)) revert StockPaused(list[i]);
        }
        _requireNotBlocked(address(this), address(this), address(this));
    }

    /// @dev One pass: every listed stock x 3 scopes, each DISTINCT policy id queried once per
    ///      distinct account (Coinbase uses one id for all 24 slots today, so that is 1-3 queries).
    function _requireNotBlocked(address a, address b, address c) internal view {
        address[] memory list = registry.tokens();
        bytes32[3] memory scopes = [TRANSFER_SENDER_POLICY, TRANSFER_RECEIVER_POLICY, TRANSFER_EXECUTOR_POLICY];
        uint64[] memory seen = new uint64[](list.length * 3);
        uint256 nSeen;
        for (uint256 i; i < list.length; ++i) {
            for (uint256 s; s < 3; ++s) {
                uint64 id = IB20Policy(list[i]).policyId(scopes[s]);
                bool dup;
                for (uint256 k; k < nSeen; ++k) {
                    if (seen[k] == id) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                seen[nSeen++] = id;
                if (!policyRegistry.isAuthorized(id, a)) revert Blocklisted(a, list[i]);
                if (b != a && !policyRegistry.isAuthorized(id, b)) revert Blocklisted(b, list[i]);
                if (c != a && c != b && !policyRegistry.isAuthorized(id, c)) revert Blocklisted(c, list[i]);
            }
        }
    }

    /* ------------------------------------------------------------------ */
    /*                              Upkeep                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Mint the management fee accrued so far. Permissionless.
    function accrue() external nonReentrant {
        _accrue();
    }

    /// @notice Re-read the real balance of a listed token. Permissionless.
    ///         - Balance above the books (a donation): the surplus goes to index holders. This is
    ///           the ONLY way a surplus is folded in.
    ///         - Balance below the books (an issuer seizure): the same write-down every action
    ///           already applies on its own (see `_writeDown`).
    function sync(address token) external nonReentrant {
        if (!registry.isListed(token)) revert NotListed(token);
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 h = held[token];
        uint256 o = totalOwed[token];
        if (bal < h + o) return _writeDown(token, h, o, bal);
        emit Synced(token, h, bal - o);
        held[token] = bal - o;
    }

    /// @notice Write every listed stock's books down to its real balance, if an issuer seizure
    ///         left them short. Permissionless; never adds a surplus. Every paying action does
    ///         this itself, so calling it is never required (the Rebalancer calls it before it
    ///         measures drift).
    function reconcile() external nonReentrant {
        _reconcileAll();
    }

    function _reconcileAll() internal {
        address[] memory list = registry.tokens();
        for (uint256 i; i < list.length; ++i) {
            address token = list[i];
            (bool ok, uint256 bal) = _balance(token);
            uint256 h = held[token];
            uint256 o = totalOwed[token];
            if (ok && bal < h + o) _writeDown(token, h, o, bal);
        }
    }

    /// @dev A seizure is shared pro-rata between index holders (`held`) and credit holders
    ///      (`totalOwed`, which scales every account's credit at once). Both round down, so
    ///      held + totalOwed <= balance afterwards.
    function _writeDown(address token, uint256 h, uint256 o, uint256 bal) internal {
        (uint256 newHeld, uint256 newOwed) = _scaled(h, o, bal);
        if (newOwed != o) {
            totalOwed[token] = newOwed;
            if (newOwed == 0) {
                // Nothing left to share: retire this pool's shares.
                totalOwedShares[token] = 0;
                ++owedEpoch[token];
            }
            emit CreditsWrittenDown(token, o, newOwed);
        }
        emit Synced(token, h, newHeld);
        held[token] = newHeld;
    }

    /// @dev `held` and `totalOwed` as they stand once any unrecorded shortfall is written down.
    ///      A balance read that fails leaves the books as they are, so this never reverts.
    function _live(address token) internal view returns (uint256 h, uint256 o) {
        h = held[token];
        o = totalOwed[token];
        (bool ok, uint256 bal) = _balance(token);
        if (ok && bal < h + o) (h, o) = _scaled(h, o, bal);
    }

    function _scaled(uint256 h, uint256 o, uint256 bal) internal pure returns (uint256, uint256) {
        return (Math.mulDiv(h, bal, h + o), Math.mulDiv(o, bal, h + o));
    }

    function _balance(address token) internal view returns (bool ok, uint256 bal) {
        bytes memory ret;
        (ok, ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        ok = ok && ret.length >= 32;
        if (ok) bal = abi.decode(ret, (uint256));
    }

    function pendingManagementFee() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || mgmtFeeBps == 0) return 0;
        uint256 elapsed = block.timestamp - lastAccrual;
        return Math.mulDiv(supply, uint256(mgmtFeeBps) * elapsed, BPS * YEAR);
    }

    /* ------------------------------------------------------------------ */
    /*                     Rebalance (Rebalancer only)                     */
    /* ------------------------------------------------------------------ */

    /// @notice Swap `amountIn` of one held stock for another. The vault itself enforces that the
    ///         value received (Chainlink, both feeds fresh) is within `maxTradeSlippageBps` of the
    ///         value sent, so even a faulty Rebalancer cannot trade away value.
    function executeTrade(address tokenIn, uint256 amountIn, address tokenOut, uint256 minAmountOut, bytes calldata data)
        external
        nonReentrant
        returns (uint256 received)
    {
        if (msg.sender != rebalancer) revert NotRebalancer();
        if (!registry.isListed(tokenIn)) revert NotListed(tokenIn);
        if (!registry.isListed(tokenOut)) revert NotListed(tokenOut);
        _reconcileAll();
        uint256 h = held[tokenIn];
        if (amountIn > h) revert InsufficientHeld(tokenIn, amountIn, h);

        uint256 valueIn = registry.valueUsd(tokenIn, amountIn);
        _countTraded(valueIn);
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        held[tokenIn] = h - amountIn;
        IERC20(tokenIn).safeTransfer(msg.sender, amountIn);
        IRebalanceCallback(msg.sender).onRebalanceTrade(tokenIn, amountIn, tokenOut, data);

        if (IERC20(tokenIn).balanceOf(address(this)) != inBefore - amountIn) revert TradeTookMore(tokenIn);
        received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (received < minAmountOut) revert TradeBelowMin(received, minAmountOut);
        uint256 valueOut = registry.valueUsd(tokenOut, received);
        if (valueOut * BPS < valueIn * (BPS - maxTradeSlippageBps)) {
            revert TradeValueLoss(valueIn, valueOut, maxTradeSlippageBps);
        }
        if (valueIn > valueOut) _countLost(valueIn - valueOut);
        held[tokenOut] += received;
        emit Traded(tokenIn, amountIn, tokenOut, received);
    }

    /// @dev Opens a fresh 24h window (pricing NAV once) on the first trade after the last one
    ///      expired, then adds this trade's Chainlink value to the window's total.
    function _countTraded(uint256 valueIn) internal {
        if (block.timestamp >= uint256(tradeWindowStart) + TRADE_WINDOW) {
            tradeWindowStart = uint64(block.timestamp);
            windowNavUsd = navUsd();
            windowTradedUsd = 0;
            windowLostUsd = 0;
        }
        uint256 traded = windowTradedUsd + valueIn;
        uint256 cap = windowNavUsd * dailyTradeCapBps / BPS;
        if (traded > cap) revert DailyTradeCapExceeded(traded, cap);
        windowTradedUsd = traded;
    }

    function _countLost(uint256 lost) internal {
        uint256 total = windowLostUsd + lost;
        uint256 cap = windowNavUsd * dailyLossCapBps / BPS;
        if (total > cap) revert DailyLossCapExceeded(total, cap);
        windowLostUsd = total;
    }

    /* ------------------------------------------------------------------ */
    /*                          Views (NAV)                                */
    /* ------------------------------------------------------------------ */

    /// @notice Total USD value of the backing (after any unrecorded seizure), 18 decimals.
    ///         Reverts if any feed is stale.
    function navUsd() public view returns (uint256 nav) {
        address[] memory list = registry.tokens();
        for (uint256 i; i < list.length; ++i) {
            (uint256 h,) = _live(list[i]);
            if (h != 0) nav += registry.valueUsd(list[i], h);
        }
    }

    /// @notice USD value of one index token (1e18 units), 18 decimals. Reverts if stale.
    function navPerShare() external view returns (uint256) {
        uint256 supply = totalSupply() + pendingManagementFee();
        if (supply == 0) return 0;
        return Math.mulDiv(navUsd(), 1e18, supply);
    }

    /* ------------------------------------------------------------------ */
    /*                         Owner settings                              */
    /* ------------------------------------------------------------------ */

    // Redeem fee, management fee, mint cap, trade slippage and the daily trade caps are
    // 	ighten (lower, instant) / queueSetting + executeSetting (anything, 48h): see
    // lib/Settings.sol and the SET_* keys. The mint fee schedule, rebalancer and fee recipient
    // have their own timelocked functions below. Mint pause is instant both ways.

    /// @notice Queue a new mint fee schedule (48h timelock). Checked now and again on execute.
    function queueMintFeeSchedule(MintFeeSchedule calldata s) external onlyOwner returns (bytes32) {
        _checkMintFees(s);
        return _queue(ACTION_MINT_FEE_SCHEDULE, abi.encode(s));
    }

    function executeMintFeeSchedule(MintFeeSchedule calldata s) external onlyOwner {
        _consume(ACTION_MINT_FEE_SCHEDULE, abi.encode(s));
        _setMintFees(s);
    }


    function setMintPaused(bool paused) external onlyOwner {
        mintPaused = paused;
        emit MintPausedSet(paused);
    }


    function queueRebalancer(address r) external onlyOwner returns (bytes32) {
        if (r == address(0)) revert ZeroAddress();
        return _queue(ACTION_REBALANCER, abi.encode(r));
    }

    function executeRebalancer(address r) external onlyOwner {
        _consume(ACTION_REBALANCER, abi.encode(r));
        rebalancer = r;
        emit RebalancerSet(r);
    }

    function queueFeeRecipient(address r) external onlyOwner returns (bytes32) {
        if (r == address(0)) revert ZeroAddress();
        return _queue(ACTION_FEE_RECIPIENT, abi.encode(r));
    }

    function executeFeeRecipient(address r) external onlyOwner {
        _consume(ACTION_FEE_RECIPIENT, abi.encode(r));
        _accrue(); // fees earned so far go to the old recipient
        feeRecipient = r;
        emit FeeRecipientSet(r);
    }

    /* ------------------------------------------------------------------ */
    /*                        Settings (lib/Settings)                      */
    /* ------------------------------------------------------------------ */

    function _checkSetting(uint8 key, uint256 v) internal pure override {
        if (key == SET_REDEEM_FEE) {
            if (v > MAX_REDEEM_FEE_BPS) revert FeeAboveCap(v, MAX_REDEEM_FEE_BPS);
        } else if (key == SET_MGMT_FEE) {
            if (v > MAX_MGMT_FEE_BPS) revert FeeAboveCap(v, MAX_MGMT_FEE_BPS);
        } else if (key == SET_MINT_CAP) {
            // any value; raising it is the timelocked direction
        } else if (key == SET_MAX_TRADE_SLIPPAGE) {
            if (v > MAX_TRADE_SLIPPAGE_BPS) revert FeeAboveCap(v, MAX_TRADE_SLIPPAGE_BPS);
        } else if (key == SET_DAILY_TRADE_CAP) {
            if (v > MAX_DAILY_TRADE_BPS) revert FeeAboveCap(v, MAX_DAILY_TRADE_BPS);
        } else if (key == SET_DAILY_LOSS_CAP) {
            if (v > MAX_DAILY_LOSS_BPS) revert FeeAboveCap(v, MAX_DAILY_LOSS_BPS);
        } else {
            revert UnknownSetting(key);
        }
    }

    function _getSetting(uint8 key) internal view override returns (uint256) {
        if (key == SET_REDEEM_FEE) return redeemFeeBps;
        if (key == SET_MGMT_FEE) return mgmtFeeBps;
        if (key == SET_MINT_CAP) return mintCap;
        if (key == SET_MAX_TRADE_SLIPPAGE) return maxTradeSlippageBps;
        if (key == SET_DAILY_TRADE_CAP) return dailyTradeCapBps;
        if (key == SET_DAILY_LOSS_CAP) return dailyLossCapBps;
        revert UnknownSetting(key);
    }

    function _applySetting(uint8 key, uint256 v) internal override {
        if (key == SET_REDEEM_FEE) {
            redeemFeeBps = uint16(v);
        } else if (key == SET_MGMT_FEE) {
            _accrue(); // the old management rate applies up to now
            mgmtFeeBps = uint16(v);
        } else if (key == SET_MINT_CAP) {
            mintCap = v;
        } else if (key == SET_MAX_TRADE_SLIPPAGE) {
            maxTradeSlippageBps = uint16(v);
        } else if (key == SET_DAILY_TRADE_CAP) {
            dailyTradeCapBps = uint16(v);
        } else {
            dailyLossCapBps = uint16(v);
        }
    }

    /* ------------------------------------------------------------------ */
    /*                             Internals                               */
    /* ------------------------------------------------------------------ */

    function _accrue() internal {
        uint256 fee = pendingManagementFee();
        uint256 elapsed = block.timestamp - lastAccrual;
        lastAccrual = uint64(block.timestamp);
        if (fee != 0 && feeRecipient != address(0)) {
            _mint(feeRecipient, fee);
            emit ManagementFeeAccrued(fee, elapsed);
        }
    }

    function _setFees(uint16 r, uint16 g) internal {
        if (r > MAX_REDEEM_FEE_BPS) revert FeeAboveCap(r, MAX_REDEEM_FEE_BPS);
        if (g > MAX_MGMT_FEE_BPS) revert FeeAboveCap(g, MAX_MGMT_FEE_BPS);
        redeemFeeBps = r;
        mgmtFeeBps = g;
        emit FeesSet(r, g);
    }

    /// @dev Rates are uint16, so none can go below 0%. Thresholds must be above zero and strictly
    ///      increasing, so the three bands always exist and in order.
    function _checkMintFees(MintFeeSchedule memory s) internal pure {
        if (s.baseBps > MAX_MINT_FEE_BPS) revert FeeAboveCap(s.baseBps, MAX_MINT_FEE_BPS);
        if (s.tier1Bps > MAX_MINT_FEE_BPS) revert FeeAboveCap(s.tier1Bps, MAX_MINT_FEE_BPS);
        if (s.tier2Bps > MAX_MINT_FEE_BPS) revert FeeAboveCap(s.tier2Bps, MAX_MINT_FEE_BPS);
        if (s.tier1MinUsd == 0 || s.tier2MinUsd <= s.tier1MinUsd) {
            revert BadTierThresholds(s.tier1MinUsd, s.tier2MinUsd);
        }
    }

    function _setMintFees(MintFeeSchedule memory s) internal {
        _checkMintFees(s);
        _mintFees = s;
        emit MintFeeScheduleSet(s);
    }

    /// @dev Pull and check the vault received exactly `amount` (B20s take no transfer fee; this
    ///      makes sure a token that did would fail loudly instead of under-backing the index).
    function _pull(address token, address from, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 got = IERC20(token).balanceOf(address(this)) - before;
        if (got != amount) revert ShortDelivery(token, amount, got);
    }

    /// @dev Gas-capped transfer that reports failure instead of reverting. The gas check first
    ///      makes sure a leg cannot be made to "fail" just by sending the redeem with too little gas.
    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool ok) {
        if (gasleft() < REDEEM_LEG_GAS * 64 / 63 + 10_000) revert NotEnoughGasForLeg();
        bytes memory ret;
        (ok, ret) = token.call{gas: REDEEM_LEG_GAS}(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && ret.length != 0) ok = ret.length >= 32 && abi.decode(ret, (bool));
    }
}
