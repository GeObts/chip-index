// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ISlipstreamFactory} from "./interfaces/ISlipstreamRouter.sol";
import {OracleLib} from "./lib/OracleLib.sol";
import {Timelock} from "./lib/Timelock.sol";

interface IHoldings {
    function held(address token) external view returns (uint256);
}

/**
 * @title BasketRegistry
 * @notice The index's stock list: which B20 tokens, their Chainlink feeds and target weights.
 *
 *         - The launch basket is set in the constructor. Every later change (add, remove,
 *           re-weight, change a feed) goes through ONE timelocked call: queue a whole new
 *           basket, wait 48h, execute within 14 days.
 *         - A token dropped from the basket while the vault still holds it stays listed at
 *           weight 0, so holders can always redeem it. The Rebalancer sells it down and anyone
 *           can then `prune` it once the vault holds none.
 *         - Prices: value = raw token balance x feed price. The Coinbase feeds are total-return,
 *           so they already include the B20 dividend multiplier.
 */
contract BasketRegistry is Ownable2Step, Timelock {
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
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_ASSETS = 16;
    uint256 public constant MIN_FEED_AGE = 1 hours;
    uint256 public constant MAX_FEED_AGE = 72 hours;
    bytes32 public constant ACTION_BASKET = keccak256("BASKET");

    address public immutable sequencerFeed;
    ISlipstreamFactory public immutable slipstreamFactory;
    address public immutable usdc;
    address private immutable _deployer;

    Asset[] internal _assets;
    mapping(address token => uint256) internal _indexPlusOne;

    /// @notice The IndexVault, wired once by the deployer.
    address public vault;
    /// @notice A feed older than this is stale. 26h = the 24h heartbeat plus slack.
    uint256 public maxFeedAge = 26 hours;
    /// @notice Aerodrome Slipstream tick spacing of each token's token/USDC pool.
    mapping(address token => int24) public usdcTickSpacing;

    event BasketQueued(bytes32 indexed id, AssetConfig[] config, uint256 executableAt);
    event BasketExecuted(AssetConfig[] config);
    event AssetPruned(address indexed token);
    event MaxFeedAgeSet(uint256 maxFeedAge);
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
    error FeedAgeOutOfBounds(uint256 maxFeedAge);
    error NoSuchPool(address token, int24 tickSpacing);
    error NotDeployer();
    error LengthMismatch();
    error AlreadyWired();

    constructor(
        address owner_,
        address sequencerFeed_,
        address slipstreamFactory_,
        address usdc_,
        AssetConfig[] memory launch,
        int24[] memory launchTickSpacings
    ) Ownable(owner_) {
        if (slipstreamFactory_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
        sequencerFeed = sequencerFeed_;
        slipstreamFactory = ISlipstreamFactory(slipstreamFactory_);
        usdc = usdc_;
        _deployer = msg.sender;
        _validate(launch);
        _install(launch);
        if (launchTickSpacings.length != launch.length) revert LengthMismatch();
        for (uint256 i; i < launch.length; ++i) {
            _setTickSpacing(launch[i].token, launchTickSpacings[i]);
        }
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

        // Carry over anything the vault still holds that the new basket drops, at weight 0.
        Asset[] memory old = _assets;
        _clear();
        _install(config);
        for (uint256 i; i < old.length; ++i) {
            if (_indexPlusOne[old[i].token] == 0 && _held(old[i].token) > 0) {
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

    /// @notice Drop a weight-0 token the vault no longer holds. Permissionless.
    function prune(address token) external {
        uint256 ip1 = _indexPlusOne[token];
        if (ip1 == 0) revert NotListed(token);
        if (_assets[ip1 - 1].weightBps != 0) revert StillTargeted(token);
        uint256 h = _held(token);
        if (h != 0) revert StillHeld(token, h);
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

    function setMaxFeedAge(uint256 maxFeedAge_) external onlyOwner {
        if (maxFeedAge_ < MIN_FEED_AGE || maxFeedAge_ > MAX_FEED_AGE) revert FeedAgeOutOfBounds(maxFeedAge_);
        maxFeedAge = maxFeedAge_;
        emit MaxFeedAgeSet(maxFeedAge_);
    }

    /// @notice Point a token at a different Aerodrome token/USDC pool. Immediate: a bad pool only
    ///         makes slippage-checked trades fail, it cannot move funds.
    function setUsdcTickSpacing(address token, int24 tickSpacing) external onlyOwner {
        _setTickSpacing(token, tickSpacing);
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

    function _setTickSpacing(address token, int24 tickSpacing) internal {
        if (slipstreamFactory.getPool(token, usdc, tickSpacing) == address(0)) revert NoSuchPool(token, tickSpacing);
        usdcTickSpacing[token] = tickSpacing;
        emit UsdcTickSpacingSet(token, tickSpacing);
    }
}
