// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ISlipstreamFactory} from "./interfaces/ISlipstreamRouter.sol";
import {OracleLib} from "./lib/OracleLib.sol";
import {Settings} from "./lib/Settings.sol";

interface IHoldings {
    function held(address token) external view returns (uint256);
    function totalOwed(address token) external view returns (uint256);
}

/// @dev Base's B20 factory precompile (0xB20f...0000): the only trusted answer to "is this a B20?".
interface IB20FactoryView {
    function isB20Initialized(address token) external view returns (bool);
}

/// @dev Coinbase's TokenSupplyManager (proxy 0xD1Ca...664C on Base): the contract that mints and
///      redeems Coinbase tokenized stocks. Only its admin can register a token, and every token
///      on api.coinbase.com/v1/tokenized-stocks is registered (all 135 checked 2026-10-13).
interface IIssuerRegistry {
    function isRegisteredToken(address token) external view returns (bool);
}

interface IOwnedFeed {
    function owner() external view returns (address);
}

/**
 * @title BasketRegistry
 * @notice The index's stock list: which B20 tokens, their Chainlink feeds and target weights.
 *
 *         - The launch basket is set in the constructor. Every later change (add, remove,
 *           re-weight, change a feed) goes through ONE timelocked call: queue a whole new
 *           basket, wait 48h, execute within 14 days.
 *         - A token dropped from the basket while the vault still holds it, or still owes credits
 *           in it, stays listed at weight 0, so holders can always redeem it. The Rebalancer
 *           sells it down and anyone can then `prune` it once the vault holds and owes none.
 *         - The pool each token trades in (its Aerodrome token/USDC tick spacing) is part of the
 *           basket, so choosing or changing a pool is a basket change and waits 48h too.
 *         - Every basket entry is checked when queued AND when executed, so a fake token is
 *           refused even if the Safe queues it:
 *             1. the token is a B20 that Base's B20 factory says it created (`isB20Initialized`)
 *                AND Coinbase's own TokenSupplyManager lists it (`isRegisteredToken`). Only
 *                Coinbase's admin can add to that list, so a copycat "NVDAc" is refused;
 *             2. the feed has the same code (`extcodehash`) and the same owner as the launch
 *                Chainlink feeds (Chainlink's Base multisig; ownership moves only by acceptance);
 *             3. the feed's description is "Coinbase <TICKER>" where the token's symbol is
 *                "<TICKER>c" (Coinbase's naming: NVDAc / "Coinbase NVDA");
 *             4. a token/USDC pool with that tick spacing exists on the Slipstream factory.
 *           The issuer check trusts Coinbase's register (an upgradeable Coinbase contract). The
 *           Safe still checks every address against api.coinbase.com/v1/tokenized-stocks before
 *           queueing, and script/VerifyDeployment.s.sol does the same after deploy.
 *         - Prices: value = raw token balance x feed price. The Coinbase feeds are total-return,
 *           so they already include the B20 dividend multiplier.
 */
contract BasketRegistry is Settings {
    struct Asset {
        address token;
        address feed;
        uint16 weightBps;
        uint8 tokenDecimals;
        uint8 feedDecimals;
    }

    struct AssetConfig {
        address token;
        address feed;
        uint16 weightBps;
        int24 usdcTickSpacing;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_ASSETS = 16;
    uint256 public constant MIN_FEED_AGE = 1 hours;
    uint256 public constant MAX_FEED_AGE = 72 hours;
    bytes32 public constant ACTION_BASKET = keccak256("BASKET");

    /// @notice Setting keys (lib/Settings). Max feed age: lower is instant, higher is 48h. The
    ///         trusted feed owner and code hash: 48h only (for when Chainlink migrates its feeds).
    uint8 public constant SET_MAX_FEED_AGE = 0;
    uint8 public constant SET_TRUSTED_FEED_OWNER = 1;
    uint8 public constant SET_TRUSTED_FEED_CODEHASH = 2;
    /// @notice Coinbase's token register (48h only, for if Coinbase ever moves it).
    uint8 public constant SET_ISSUER_REGISTRY = 3;

    address public immutable sequencerFeed;
    ISlipstreamFactory public immutable slipstreamFactory;
    address public immutable usdc;
    IB20FactoryView public immutable b20Factory;
    address private immutable _deployer;

    Asset[] internal _assets;
    mapping(address token => uint256) internal _indexPlusOne;

    /// @notice The IndexVault, wired once by the deployer.
    address public vault;
    /// @notice A feed older than this is stale. 26h = the 24h heartbeat plus slack.
    uint256 public maxFeedAge = 26 hours;
    /// @notice Aerodrome Slipstream tick spacing of each token's token/USDC pool.
    mapping(address token => int24) public usdcTickSpacing;
    /// @notice Every feed must match the launch feeds' owner and code (see the header).
    address public trustedFeedOwner;
    bytes32 public trustedFeedCodehash;
    /// @notice Every token must be registered here (Coinbase's TokenSupplyManager).
    address public issuerRegistry;

    event BasketQueued(bytes32 indexed id, AssetConfig[] config, uint256 executableAt);
    event BasketExecuted(AssetConfig[] config);
    event AssetPruned(address indexed token);
    event UsdcTickSpacingSet(address indexed token, int24 tickSpacing);
    event VaultWired(address vault);

    error ZeroAddress();
    error WeightsMustSum(uint256 sum);
    error DuplicateToken(address token);
    error TooManyAssets(uint256 count);
    error EmptyBasket();
    error BadDecimals(address what, uint8 decimals);
    error NotListed(address token);
    error StillTargeted(address token);
    error StillHeld(address token, uint256 held);
    error StillOwed(address token, uint256 totalOwed);
    error FeedAgeOutOfBounds(uint256 maxFeedAge);
    error NoSuchPool(address token, int24 tickSpacing);
    error NotDeployer();
    error LengthMismatch();
    error AlreadyWired();
    error NotB20(address token);
    error UntrustedFeed(address feed);
    error FeedDoesNotMatchToken(address token, address feed);
    error NotCoinbaseIssued(address token);

    constructor(
        address owner_,
        address sequencerFeed_,
        address slipstreamFactory_,
        address usdc_,
        address b20Factory_,
        address issuerRegistry_,
        AssetConfig[] memory launch
    ) Ownable(owner_) {
        if (
            slipstreamFactory_ == address(0) || usdc_ == address(0) || b20Factory_ == address(0)
                || issuerRegistry_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (launch.length == 0) revert EmptyBasket();
        sequencerFeed = sequencerFeed_;
        slipstreamFactory = ISlipstreamFactory(slipstreamFactory_);
        usdc = usdc_;
        b20Factory = IB20FactoryView(b20Factory_);
        issuerRegistry = issuerRegistry_;
        _deployer = msg.sender;
        // The first launch feed sets the trusted Chainlink owner and code; every feed must match.
        trustedFeedOwner = IOwnedFeed(launch[0].feed).owner();
        trustedFeedCodehash = launch[0].feed.codehash;
        _validate(launch);
        _install(launch);
        emit BasketExecuted(launch);
    }

    /// @notice One-time wiring by the deploy script, so the Safe owns this from block one.
    function wireVault(address vault_) external {
        if (msg.sender != _deployer) revert NotDeployer();
        if (vault != address(0)) revert AlreadyWired();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultWired(vault_);
    }

    /* ------------------------------------------------------------------ */
    /*                        Basket changes (48h)                         */
    /* ------------------------------------------------------------------ */

    function queueBasket(AssetConfig[] calldata config) external onlyOwner returns (bytes32 id) {
        _validate(config);
        id = _queue(ACTION_BASKET, abi.encode(config));
        emit BasketQueued(id, config, executableAt[id]);
    }

    function executeBasket(AssetConfig[] calldata config) external onlyOwner {
        _consume(ACTION_BASKET, abi.encode(config));
        // Re-validated at execute: decimals or feeds could in principle have changed.
        _validate(config);

        // Carry over anything the vault still holds (or owes) that the new basket drops, at weight 0.
        Asset[] memory old = _assets;
        _clear();
        _install(config);
        for (uint256 i; i < old.length; ++i) {
            if (_indexPlusOne[old[i].token] == 0 && (_held(old[i].token) > 0 || _owed(old[i].token) > 0)) {
                old[i].weightBps = 0;
                _push(old[i]);
            }
        }
        if (_assets.length > MAX_ASSETS) revert TooManyAssets(_assets.length);
        emit BasketExecuted(config);
    }

    function cancelBasket(bytes32 id) external onlyOwner {
        _cancel(id);
    }

    /// @notice Drop a weight-0 token the vault no longer holds and owes no one. Permissionless.
    ///         Outstanding credits keep it listed so sync can still write them down.
    function prune(address token) external {
        uint256 ip1 = _indexPlusOne[token];
        if (ip1 == 0) revert NotListed(token);
        if (_assets[ip1 - 1].weightBps != 0) revert StillTargeted(token);
        uint256 h = _held(token);
        if (h != 0) revert StillHeld(token, h);
        uint256 o = _owed(token);
        if (o != 0) revert StillOwed(token, o);
        uint256 last = _assets.length - 1;
        if (ip1 - 1 != last) {
            Asset memory moved = _assets[last];
            _assets[ip1 - 1] = moved;
            _indexPlusOne[moved.token] = ip1;
        }
        _assets.pop();
        delete _indexPlusOne[token];
        emit AssetPruned(token);
    }

    /* ------------------------------------------------------------------ */
    /*                      Operational settings                           */
    /* ------------------------------------------------------------------ */

    function _checkSetting(uint8 key, uint256 v) internal pure override {
        if (key == SET_MAX_FEED_AGE) {
            if (v < MIN_FEED_AGE || v > MAX_FEED_AGE) revert FeedAgeOutOfBounds(v);
        } else if (key == SET_TRUSTED_FEED_OWNER || key == SET_ISSUER_REGISTRY) {
            if (v == 0 || v > type(uint160).max) revert ZeroAddress();
        } else if (key != SET_TRUSTED_FEED_CODEHASH) {
            revert UnknownSetting(key);
        }
    }

    function _getSetting(uint8 key) internal view override returns (uint256) {
        if (key == SET_MAX_FEED_AGE) return maxFeedAge;
        if (key == SET_TRUSTED_FEED_OWNER) return uint160(trustedFeedOwner);
        if (key == SET_TRUSTED_FEED_CODEHASH) return uint256(trustedFeedCodehash);
        if (key == SET_ISSUER_REGISTRY) return uint160(issuerRegistry);
        revert UnknownSetting(key);
    }

    function _applySetting(uint8 key, uint256 v) internal override {
        if (key == SET_MAX_FEED_AGE) maxFeedAge = v;
        else if (key == SET_TRUSTED_FEED_OWNER) trustedFeedOwner = address(uint160(v));
        else if (key == SET_TRUSTED_FEED_CODEHASH) trustedFeedCodehash = bytes32(v);
        else issuerRegistry = address(uint160(v));
    }

    /// @dev Only a shorter max feed age is instant (it can only stop cash paths, never price them).
    function _isTightening(uint8 key, uint256 v) internal view override returns (bool) {
        return key == SET_MAX_FEED_AGE && v <= maxFeedAge;
    }

    /* ------------------------------------------------------------------ */
    /*                              Views                                  */
    /* ------------------------------------------------------------------ */

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function assets() external view returns (Asset[] memory) {
        return _assets;
    }

    function assetAt(uint256 i) external view returns (Asset memory) {
        return _assets[i];
    }

    function tokens() external view returns (address[] memory list) {
        uint256 n = _assets.length;
        list = new address[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = _assets[i].token;
        }
    }

    function isListed(address token) public view returns (bool) {
        return _indexPlusOne[token] != 0;
    }

    function asset(address token) public view returns (Asset memory) {
        uint256 ip1 = _indexPlusOne[token];
        if (ip1 == 0) revert NotListed(token);
        return _assets[ip1 - 1];
    }

    /// @notice USD price of one whole token, 18 decimals. Reverts if stale or sequencer down.
    function priceUsd(address token) public view returns (uint256) {
        OracleLib.checkSequencer(sequencerFeed);
        Asset memory a = asset(token);
        return OracleLib.read(a.feed, maxFeedAge) * 10 ** (18 - a.feedDecimals);
    }

    /// @notice USD value (18 decimals) of `amount` raw units. Reverts if stale.
    function valueUsd(address token, uint256 amount) external view returns (uint256) {
        uint256 p = priceUsd(token);
        return Math.mulDiv(amount, p, 10 ** asset(token).tokenDecimals);
    }

    /// @notice Raw units of `token` worth `usd18` dollars, rounded down. Reverts if stale.
    function amountForUsd(address token, uint256 usd18) external view returns (uint256) {
        uint256 p = priceUsd(token);
        return Math.mulDiv(usd18, 10 ** asset(token).tokenDecimals, p);
    }

    /// @notice True when the sequencer is up and every listed feed is fresh.
    function allFresh() public view returns (bool) {
        if (!OracleLib.sequencerUp(sequencerFeed)) return false;
        uint256 n = _assets.length;
        for (uint256 i; i < n; ++i) {
            if (!OracleLib.isFresh(_assets[i].feed, maxFeedAge)) return false;
        }
        return true;
    }

    /// @notice Reverts with the first stale feed's details.
    function requireAllFresh() external view {
        OracleLib.checkSequencer(sequencerFeed);
        uint256 n = _assets.length;
        for (uint256 i; i < n; ++i) {
            OracleLib.read(_assets[i].feed, maxFeedAge);
        }
    }

    /* ------------------------------------------------------------------ */
    /*                             Internals                               */
    /* ------------------------------------------------------------------ */

    function _held(address token) internal view returns (uint256) {
        return vault == address(0) ? 0 : IHoldings(vault).held(token);
    }

    function _owed(address token) internal view returns (uint256) {
        return vault == address(0) ? 0 : IHoldings(vault).totalOwed(token);
    }

    function _validate(AssetConfig[] memory config) internal view {
        uint256 n = config.length;
        if (n == 0) revert EmptyBasket();
        if (n > MAX_ASSETS) revert TooManyAssets(n);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            AssetConfig memory c = config[i];
            if (c.token == address(0) || c.feed == address(0)) revert ZeroAddress();
            for (uint256 j; j < i; ++j) {
                if (config[j].token == c.token) revert DuplicateToken(c.token);
            }
            uint8 td = IERC20Metadata(c.token).decimals();
            if (td > 18) revert BadDecimals(c.token, td);
            uint8 fd = IAggregatorV3(c.feed).decimals();
            if (fd > 18) revert BadDecimals(c.feed, fd);
            _checkAuthentic(c);
            sum += c.weightBps;
        }
        if (sum != BPS) revert WeightsMustSum(sum);
    }

    function _install(AssetConfig[] memory config) internal {
        for (uint256 i; i < config.length; ++i) {
            AssetConfig memory c = config[i];
            _push(
                Asset({
                    token: c.token,
                    feed: c.feed,
                    weightBps: c.weightBps,
                    tokenDecimals: IERC20Metadata(c.token).decimals(),
                    feedDecimals: IAggregatorV3(c.feed).decimals()
                })
            );
            usdcTickSpacing[c.token] = c.usdcTickSpacing;
            emit UsdcTickSpacingSet(c.token, c.usdcTickSpacing);
        }
    }

    function _push(Asset memory a) internal {
        _assets.push(a);
        _indexPlusOne[a.token] = _assets.length;
    }

    function _clear() internal {
        uint256 n = _assets.length;
        for (uint256 i; i < n; ++i) {
            delete _indexPlusOne[_assets[i].token];
        }
        delete _assets;
    }

    /// @dev Checks 1-4 in the header. Any revert inside a call (no such function) also rejects.
    function _checkAuthentic(AssetConfig memory c) internal view {
        if (!b20Factory.isB20Initialized(c.token)) revert NotB20(c.token);
        if (!IIssuerRegistry(issuerRegistry).isRegisteredToken(c.token)) revert NotCoinbaseIssued(c.token);
        if (c.feed.codehash != trustedFeedCodehash || IOwnedFeed(c.feed).owner() != trustedFeedOwner) {
            revert UntrustedFeed(c.feed);
        }
        bytes memory sym = bytes(IERC20Metadata(c.token).symbol());
        uint256 n = sym.length;
        if (n < 2 || sym[n - 1] != "c") revert FeedDoesNotMatchToken(c.token, c.feed);
        bytes memory ticker = new bytes(n - 1);
        for (uint256 i; i < n - 1; ++i) {
            ticker[i] = sym[i];
        }
        if (keccak256(bytes(IAggregatorV3(c.feed).description())) != keccak256(abi.encodePacked("Coinbase ", ticker))) {
            revert FeedDoesNotMatchToken(c.token, c.feed);
        }
        if (slipstreamFactory.getPool(c.token, usdc, c.usdcTickSpacing) == address(0)) {
            revert NoSuchPool(c.token, c.usdcTickSpacing);
        }
    }
}
