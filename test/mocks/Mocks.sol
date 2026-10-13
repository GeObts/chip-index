// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISlipstreamRouter} from "../../src/interfaces/ISlipstreamRouter.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../../src/interfaces/IUniswapV4.sol";

/// @notice ERC-20 with configurable decimals and a public mint, for test balances.
contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @notice Base PolicyRegistry stand-in: blocklists by policy id. Id 0 (ALWAYS_ALLOW) and unknown
///         ids authorize everyone, as an empty blocklist does.
contract MockPolicyRegistry {
    mapping(uint64 => mapping(address => bool)) public blocked;

    function setBlocked(uint64 id, address a, bool b) external {
        blocked[id][a] = b;
    }

    function isAuthorized(uint64 id, address a) external view returns (bool) {
        return !blocked[id][a];
    }
}

/// @notice B20 stand-in: 8 decimals, issuer pause, and ONE blocklist policy bound to the sender,
///         receiver and executor (msg.sender) scopes, read from a shared MockPolicyRegistry exactly
///         like a real B20. The multiplier never touches balances.
contract MockB20 is MockERC20 {
    MockPolicyRegistry public immutable policies;
    uint64 public immutable policy;
    bool public transfersPaused;
    uint256 public multiplier = 1e18;

    error ContractPaused();
    error PolicyForbids(address account);

    constructor(string memory n, string memory s, MockPolicyRegistry policies_, uint64 policy_) MockERC20(n, s, 8) {
        policies = policies_;
        policy = policy_;
    }

    /// @dev Same id on all three transfer scopes, like Coinbase's policy 5.
    function policyId(bytes32) external view returns (uint64) {
        return policy;
    }

    function setPaused(bool p) external {
        transfersPaused = p;
    }

    /// @dev base-std IB20.isPaused: feature 0 = TRANSFER.
    function isPaused(uint8 feature) external view returns (bool) {
        return feature == 0 && transfersPaused;
    }

    /// @dev Convenience: block `a` under THIS token's policy.
    function setBlocked(address a, bool b) external {
        policies.setBlocked(policy, a, b);
    }

    /// @dev Issuer seizure: moves tokens out of `from` regardless of pause or blocklist.
    function seize(address from, address to, uint256 amount) external {
        super._update(from, to, amount);
    }

    function setMultiplier(uint256 m) external {
        multiplier = m;
    }

    function _update(address from, address to, uint256 value) internal override {
        // Mint/burn (test setup) bypass issuer controls.
        if (from != address(0) && to != address(0)) {
            if (transfersPaused) revert ContractPaused();
            if (!policies.isAuthorized(policy, from)) revert PolicyForbids(from);
            if (!policies.isAuthorized(policy, to)) revert PolicyForbids(to);
            if (!policies.isAuthorized(policy, msg.sender)) revert PolicyForbids(msg.sender);
        }
        super._update(from, to, value);
    }
}

contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    bool public broken;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setStartedAt(uint256 t) external {
        startedAt = t;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    /// @dev Every MockAggregator has the same code hash and, deployed by one fixture, the same
    ///      owner, like the real Chainlink proxies (one code, one owner: Chainlink's Base multisig).
    address public owner = msg.sender;
    string public description = "mock";

    function setDescription(string calldata d) external {
        description = d;
    }

    function setOwner(address o) external {
        owner = o;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed broken");
        return (1, answer, startedAt, updatedAt, 1);
    }
}

/// @notice Base's B20 factory stand-in: answers isB20Initialized for tokens a test registers.
contract MockB20Factory {
    mapping(address => bool) public isB20Initialized;

    function setB20(address token, bool b) external {
        isB20Initialized[token] = b;
    }
}

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth");
    }
}

contract MockSlipstreamFactory {
    mapping(bytes32 => address) public pools;

    function setPool(address a, address b, int24 ts) external {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pools[keccak256(abi.encode(t0, t1, ts))] = address(uint160(uint256(keccak256(abi.encode(t0, t1, ts)))));
    }

    function getPool(address a, address b, int24 ts) external view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return pools[keccak256(abi.encode(t0, t1, ts))];
    }
}

/**
 * @notice Swap router that fills at a USD price table (18-dec USD per whole token) worsened by
 *         `skewBps`. Inputs are pulled from the caller; outputs are minted (mock tokens only).
 *         Multi-hop paths are priced directly from the first token to the last one.
 */
contract MockSlipstreamRouter {
    address public immutable factory;
    mapping(address => uint256) public usdPrice;
    uint256 public skewBps;
    uint256 public lastAmountOutMinimum; // what the last exactInput call asked for

    constructor(address factory_) {
        factory = factory_;
    }

    function setPrice(address token, uint256 usd18) external {
        usdPrice[token] = usd18;
    }

    function setSkewBps(uint256 bps) external {
        skewBps = bps;
    }

    function quoteOut(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        uint256 usd = Math.mulDiv(amountIn, usdPrice[tokenIn], 10 ** MockERC20(tokenIn).decimals());
        uint256 out = Math.mulDiv(usd, 10 ** MockERC20(tokenOut).decimals(), usdPrice[tokenOut]);
        return out * (10_000 - skewBps) / 10_000;
    }

    function quoteIn(address tokenIn, address tokenOut, uint256 amountOut) public view returns (uint256) {
        uint256 usd = Math.mulDiv(amountOut, usdPrice[tokenOut], 10 ** MockERC20(tokenOut).decimals(), Math.Rounding.Ceil);
        uint256 inAmt = Math.mulDiv(usd, 10 ** MockERC20(tokenIn).decimals(), usdPrice[tokenIn], Math.Rounding.Ceil);
        return Math.mulDiv(inAmt, 10_000 + skewBps, 10_000, Math.Rounding.Ceil);
    }

    function exactInputSingle(ISlipstreamRouter.ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        out = quoteOut(p.tokenIn, p.tokenOut, p.amountIn);
        require(out >= p.amountOutMinimum, "Too little received");
        _settle(p.tokenIn, p.amountIn, p.tokenOut, out, p.recipient);
    }

    function exactInput(ISlipstreamRouter.ExactInputParams calldata p) external payable returns (uint256 out) {
        (address first, address last) = _ends(p.path);
        lastAmountOutMinimum = p.amountOutMinimum;
        out = quoteOut(first, last, p.amountIn);
        require(out >= p.amountOutMinimum, "Too little received");
        _settle(first, p.amountIn, last, out, p.recipient);
    }

    function exactOutputSingle(ISlipstreamRouter.ExactOutputSingleParams calldata p)
        external
        payable
        returns (uint256 amountIn)
    {
        amountIn = quoteIn(p.tokenIn, p.tokenOut, p.amountOut);
        require(amountIn <= p.amountInMaximum, "Too much requested");
        _settle(p.tokenIn, amountIn, p.tokenOut, p.amountOut, p.recipient);
    }

    function exactOutput(ISlipstreamRouter.ExactOutputParams calldata p) external payable returns (uint256 amountIn) {
        (address out, address inTok) = _ends(p.path); // reversed path
        amountIn = quoteIn(inTok, out, p.amountOut);
        require(amountIn <= p.amountInMaximum, "Too much requested");
        _settle(inTok, amountIn, out, p.amountOut, p.recipient);
    }

    function _settle(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address to) internal {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(to, amountOut);
    }

    function _ends(bytes calldata path) internal pure returns (address first, address last) {
        first = address(bytes20(path[0:20]));
        last = address(bytes20(path[path.length - 20:]));
    }
}

/// @notice Minimal v4 PoolManager: one pool, fixed CHIP-per-WETH rate, real sync/settle/take checks.
contract MockPoolManager {
    uint256 public chipPerWeth; // 18-dec CHIP per 1e18 WETH
    address public syncedCurrency;
    uint256 public syncedBalance;
    int256 public owedWeth; // what the locker still has to pay
    bool internal _unlocked;

    constructor(uint256 rate) {
        chipPerWeth = rate;
    }

    function unlock(bytes calldata data) external returns (bytes memory r) {
        _unlocked = true;
        r = IUnlockCallback(msg.sender).unlockCallback(data);
        require(owedWeth == 0, "CurrencyNotSettled");
        _unlocked = false;
    }

    function swap(PoolKey memory key, SwapParams memory p, bytes calldata) external returns (int256) {
        require(_unlocked, "locked");
        require(p.amountSpecified < 0, "exact-in only");
        uint256 wethIn = uint256(-p.amountSpecified);
        uint256 chipOut = wethIn * chipPerWeth / 1e18;
        owedWeth = int256(wethIn);
        // currency0 = WETH in the real pool (0x42.. < 0x75..); this mock follows the key.
        int128 a0;
        int128 a1;
        if (p.zeroForOne) {
            a0 = -int128(int256(wethIn));
            a1 = int128(int256(chipOut));
        } else {
            a1 = -int128(int256(wethIn));
            a0 = int128(int256(chipOut));
        }
        key; // silence
        return (int256(a0) << 128) | int256(uint256(uint128(a1)));
    }

    function sync(address currency) external {
        syncedCurrency = currency;
        syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(syncedCurrency).balanceOf(address(this)) - syncedBalance;
        owedWeth -= int256(paid);
    }

    function take(address currency, address to, uint256 amount) external {
        MockERC20(currency).mint(to, amount);
    }
}

contract MockChipBurner {
    MockERC20 public immutable chip;
    uint256 public totalBurned;

    constructor(MockERC20 chip_) {
        chip = chip_;
    }

    function burnAll() external returns (uint256 burned) {
        burned = chip.balanceOf(address(this));
        chip.burn(burned);
        totalBurned += burned;
    }
}
