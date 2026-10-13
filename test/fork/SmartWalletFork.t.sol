// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ChipIndexForkBase} from "./ChipIndexFork.t.sol";
import {IndexRouter} from "../../src/IndexRouter.sol";

/// @dev Coinbase Smart Wallet v1.1 (the Base app's wallet). Factory and implementation were
///      checked on Base mainnet on 2026-10-13: factory.implementation() = 0x000100ab...9E72.
interface ICoinbaseSmartWalletFactory {
    function createAccount(bytes[] calldata owners, uint256 nonce) external payable returns (address);
}

interface ICoinbaseSmartWallet {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    function execute(address target, uint256 value, bytes calldata data) external payable;
    function executeBatch(Call[] calldata calls) external payable;
    function isOwnerAddress(address account) external view returns (bool);
}

/// @dev Safe v1.4.1 (same version as the Chipworks Safe).
interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool);

    function getOwners() external view returns (address[] memory);
}

/**
 * @notice Mint and redeem (ETH and USDC) from the two contract wallets most Base users have:
 *         a real Coinbase Smart Wallet and a real Safe, both deployed on the fork with the
 *         official factories. Checks every refund/payout lands in the wallet as ETH (not WETH),
 *         nothing reverts, and the Router keeps nothing.
 */
contract SmartWalletForkTest is ChipIndexForkBase {
    address constant CBSW_FACTORY = 0x0BA5ED0c6AA8c49038F819E587E2633c4A9F428a;
    address constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    address internal walletOwner = makeAddr("chip-index-test-wallet-owner");

    /* ------------------------------------------------------------------ */
    /*                      Coinbase Smart Wallet                          */
    /* ------------------------------------------------------------------ */

    function _newCoinbaseWallet() internal returns (ICoinbaseSmartWallet w) {
        assertEq(walletOwner.code.length, 0);
        bytes[] memory owners = new bytes[](1);
        owners[0] = abi.encode(walletOwner);
        w = ICoinbaseSmartWallet(ICoinbaseSmartWalletFactory(CBSW_FACTORY).createAccount(owners, 0));
        assertTrue(w.isOwnerAddress(walletOwner));
        assertGt(address(w).code.length, 0);
    }

    function _cbCall(ICoinbaseSmartWallet w, address target, uint256 value, bytes memory data) internal {
        vm.prank(walletOwner);
        w.execute(target, value, data);
    }

    function test_coinbaseWallet_ethMintAndRedeem() public {
        ICoinbaseSmartWallet w = _newCoinbaseWallet();
        vm.deal(address(w), 1 ether);

        _cbCall(
            w,
            address(router),
            0.05 ether,
            abi.encodeCall(IndexRouter.mintWithEth, (2e18, address(w), block.timestamp + 600))
        );
        uint256 spent = 1 ether - address(w).balance;
        console2.log("CB wallet: ETH spent on $20 mint", spent);
        assertEq(vault.balanceOf(address(w)), 1.98e18);
        assertLt(spent, 0.05 ether, "unspent ETH came back");
        assertEq(IERC20(WETH).balanceOf(address(w)), 0, "refund was ETH, not WETH");

        uint256 before = address(w).balance;
        _cbCall(w, address(vault), 0, abi.encodeCall(IERC20.approve, (address(router), type(uint256).max)));
        _cbCall(
            w,
            address(router),
            0,
            abi.encodeCall(IndexRouter.redeemToEth, (1.98e18, 1, address(w), block.timestamp + 600))
        );
        console2.log("CB wallet: ETH back from redeem", address(w).balance - before);
        assertGt(address(w).balance, before);
        assertEq(vault.balanceOf(address(w)), 0);
        _assertRouterClean();
    }

    function test_coinbaseWallet_usdcMintAndRedeem() public {
        ICoinbaseSmartWallet w = _newCoinbaseWallet();
        deal(USDC, address(w), 50e6);

        ICoinbaseSmartWallet.Call[] memory calls = new ICoinbaseSmartWallet.Call[](2);
        calls[0] = ICoinbaseSmartWallet.Call(USDC, 0, abi.encodeCall(IERC20.approve, (address(router), 50e6)));
        calls[1] = ICoinbaseSmartWallet.Call(
            address(router), 0, abi.encodeCall(IndexRouter.mintWithUsdc, (2e18, 50e6, address(w), block.timestamp + 600))
        );
        vm.prank(walletOwner);
        w.executeBatch(calls);
        uint256 spent = 50e6 - IERC20(USDC).balanceOf(address(w));
        console2.log("CB wallet: USDC spent on $20 mint", spent);
        assertEq(vault.balanceOf(address(w)), 1.98e18);
        assertLt(spent, 21e6, "unspent USDC came back");

        calls[0] = ICoinbaseSmartWallet.Call(address(vault), 0, abi.encodeCall(IERC20.approve, (address(router), 1.98e18)));
        calls[1] = ICoinbaseSmartWallet.Call(
            address(router), 0, abi.encodeCall(IndexRouter.redeemToUsdc, (1.98e18, 1, address(w), block.timestamp + 600))
        );
        uint256 before = IERC20(USDC).balanceOf(address(w));
        vm.prank(walletOwner);
        w.executeBatch(calls);
        console2.log("CB wallet: USDC back from redeem", IERC20(USDC).balanceOf(address(w)) - before);
        assertGt(IERC20(USDC).balanceOf(address(w)), before);
        _assertRouterClean();
    }

    /* ------------------------------------------------------------------ */
    /*                                Safe                                 */
    /* ------------------------------------------------------------------ */

    function _newSafe() internal returns (ISafe s) {
        assertEq(walletOwner.code.length, 0);
        address[] memory owners = new address[](1);
        owners[0] = walletOwner;
        bytes memory init = abi.encodeCall(
            ISafe.setup, (owners, 1, address(0), "", SAFE_FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
        s = ISafe(ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_L2_SINGLETON, init, 1));
        assertEq(s.getOwners()[0], walletOwner);
    }

    /// @dev 1-of-1 Safe executed by its owner: the "approved by msg.sender" signature (v = 1).
    function _safeCall(ISafe s, address to, uint256 value, bytes memory data) internal {
        bytes memory sig = abi.encodePacked(uint256(uint160(walletOwner)), uint256(0), uint8(1));
        vm.prank(walletOwner);
        bool ok = s.execTransaction(to, value, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
        assertTrue(ok, "Safe inner call failed");
    }

    function test_safe_ethMintAndRedeem() public {
        ISafe s = _newSafe();
        vm.deal(address(s), 1 ether);

        _safeCall(
            s, address(router), 0.05 ether, abi.encodeCall(IndexRouter.mintWithEth, (2e18, address(s), block.timestamp + 600))
        );
        uint256 spent = 1 ether - address(s).balance;
        console2.log("Safe: ETH spent on $20 mint", spent);
        assertEq(vault.balanceOf(address(s)), 1.98e18);
        assertLt(spent, 0.05 ether, "unspent ETH came back");
        assertEq(IERC20(WETH).balanceOf(address(s)), 0, "refund was ETH, not WETH");

        uint256 before = address(s).balance;
        _safeCall(s, address(vault), 0, abi.encodeCall(IERC20.approve, (address(router), type(uint256).max)));
        _safeCall(
            s, address(router), 0, abi.encodeCall(IndexRouter.redeemToEth, (1.98e18, 1, address(s), block.timestamp + 600))
        );
        console2.log("Safe: ETH back from redeem", address(s).balance - before);
        assertGt(address(s).balance, before);
        _assertRouterClean();
    }

    function test_safe_usdcMintAndRedeem() public {
        ISafe s = _newSafe();
        deal(USDC, address(s), 50e6);

        _safeCall(s, USDC, 0, abi.encodeCall(IERC20.approve, (address(router), 50e6)));
        _safeCall(
            s, address(router), 0, abi.encodeCall(IndexRouter.mintWithUsdc, (2e18, 50e6, address(s), block.timestamp + 600))
        );
        uint256 spent = 50e6 - IERC20(USDC).balanceOf(address(s));
        console2.log("Safe: USDC spent on $20 mint", spent);
        assertEq(vault.balanceOf(address(s)), 1.98e18);
        assertLt(spent, 21e6);

        uint256 before = IERC20(USDC).balanceOf(address(s));
        _safeCall(s, address(vault), 0, abi.encodeCall(IERC20.approve, (address(router), 1.98e18)));
        _safeCall(
            s, address(router), 0, abi.encodeCall(IndexRouter.redeemToUsdc, (1.98e18, 1, address(s), block.timestamp + 600))
        );
        console2.log("Safe: USDC back from redeem", IERC20(USDC).balanceOf(address(s)) - before);
        assertGt(IERC20(USDC).balanceOf(address(s)), before);
        _assertRouterClean();
    }

    /// In-kind redeem straight to each wallet type (stocks land in a contract wallet).
    function test_contractWallets_inKindRedeem() public {
        ICoinbaseSmartWallet w = _newCoinbaseWallet();
        ISafe s = _newSafe();
        vm.startPrank(SAFE);
        vault.redeem(5e18, address(w));
        vault.redeem(5e18, address(s));
        vm.stopPrank();
        for (uint256 i; i < N; ++i) {
            assertGt(IERC20(tokens[i]).balanceOf(address(w)), 0);
            assertGt(IERC20(tokens[i]).balanceOf(address(s)), 0);
        }
    }

    /// A contract that cannot take ETH still mints on the real chain; refund arrives as WETH.
    function test_ethRejectingContract_refundAsWeth() public {
        NoEthWallet nw = new NoEthWallet();
        vm.deal(address(nw), 1 ether);
        uint256 spent = nw.mint(router, 0.05 ether, 2e18, block.timestamp + 600);
        assertEq(vault.balanceOf(address(nw)), 1.98e18);
        assertEq(IERC20(WETH).balanceOf(address(nw)), 0.05 ether - spent, "refund paid as WETH");
        _assertRouterClean();
    }

    function _assertRouterClean() internal view {
        assertEq(address(router).balance, 0, "router ETH");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router WETH");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router USDC");
        assertEq(vault.balanceOf(address(router)), 0, "router index");
    }
}

contract NoEthWallet {
    receive() external payable {
        revert("no ETH");
    }

    function mint(IndexRouter router, uint256 value, uint256 shares, uint256 deadline) external returns (uint256) {
        return router.mintWithEth{value: value}(shares, address(this), deadline);
    }
}
