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

/// @notice B20 stand-in: 8 decimals, issuer pause, one blocklist checked on sender, receiver and
///         executor (msg.sender) like Coinbase policy 5, and a multiplier that never touches balances.
contract MockB20 is MockERC20 {
    bool public transfersPaused;
    mapping(address => bool) public blocked;
    uint256 public multiplier = 1e18;

    error ContractPaused();
    error PolicyForbids(address account);

    constructor(string memory n, string memory s) MockERC20(n, s, 8) {}

    function setPaused(bool p) external {
        transfersPaused = p;
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function setMultiplier(uint256 m) external {
        multiplier = m;
    }

    function _update(address from, address to, uint256 value) internal override {
        // Mint/burn (test setup) bypass issuer controls.
        if (from != address(0) && to != address(0)) {
            if (transfersPaused) revert ContractPaused();
            if (blocked[from]) revert PolicyForbids(from);
            if (blocked[to]) revert PolicyForbids(to);
            if (blocked[msg.sender]) revert PolicyForbids(msg.sender);
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

    function description() external pure returns (string memory) {
        return "mock";
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed broken");
        return (1, answer, startedAt, updatedAt, 1);
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
