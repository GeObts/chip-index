// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Addrs, LaunchConfig} from "./Deploy.s.sol";
import {BasketRegistry} from "../src/BasketRegistry.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {ISlipstreamRouter} from "../src/interfaces/ISlipstreamRouter.sol";

/**
 * @notice Builds the Safe's FIRST MINT as one atomic Safe batch (Transaction Builder JSON):
 *
 *           1. approve USDC to the Aerodrome router
 *           2. buy exactly $125 (at Chainlink, now) of each of the 8 stocks, max +2% each
 *           3. reset the USDC approval to 0
 *           4. approve each stock to the vault
 *           5. vault.seed(amounts, 100 index tokens, Safe)
 *
 *         The Safe needs about $1,020 of USDC. Everything reverts together if any step fails.
 *         Nothing is sent by this script: it only writes the JSON for the owner to review and sign.
 *
 *             VAULT=0x... base-forge script script/SafeSeed.s.sol --rpc-url $BASE_RPC_URL
 */
contract SafeSeed is Script {
    struct Call {
        address to;
        bytes data;
    }

    uint256 internal constant BUY_BUFFER_BPS = 200; // the Safe may sign hours later
    uint256 internal constant DEADLINE_WINDOW = 7 days;

    function run() external {
        IndexVault vault = IndexVault(vm.envAddress("VAULT"));
        (Call[] memory calls, uint256 maxUsdc) = build(vault, block.timestamp + DEADLINE_WINDOW);

        string memory txs = "[";
        for (uint256 i; i < calls.length; ++i) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(calls[i].to),
                '","value":"0","data":"',
                vm.toString(calls[i].data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
        }
        string memory json = string.concat(
            '{"version":"1.0","chainId":"8453","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"Chip Index seed","description":"Buy $125 of each of 8 stocks and mint 100 index tokens. Needs up to ',
            vm.toString(maxUsdc / 1e6),
            ' USDC in the Safe."},"transactions":',
            txs,
            "]}"
        );
        vm.writeFile("safe/seed.json", json);
        console2.log("wrote safe/seed.json; USDC needed at most", maxUsdc);
    }

    /// @notice The batch, in order. Also executed call-by-call in the fork rehearsal.
    function build(IndexVault vault, uint256 deadline) public view returns (Call[] memory calls, uint256 maxUsdc) {
        BasketRegistry registry = vault.registry();
        address[] memory list = registry.tokens();
        uint256 n = list.length;
        uint256[] memory amounts = new uint256[](n);
        calls = new Call[](3 + 2 * n);

        uint256 k = 1; // slot 0 = USDC approve, filled once maxUsdc is known
        for (uint256 i; i < n; ++i) {
            amounts[i] = registry.amountForUsd(list[i], LaunchConfig.SEED_USD_PER_STOCK * 1e18);
            uint256 maxIn = (LaunchConfig.SEED_USD_PER_STOCK * 1e6) * (10_000 + BUY_BUFFER_BPS) / 10_000;
            maxUsdc += maxIn;
            calls[k++] = Call(
                Addrs.SLIP_ROUTER,
                abi.encodeCall(
                    ISlipstreamRouter.exactOutputSingle,
                    (
                        ISlipstreamRouter.ExactOutputSingleParams({
                            tokenIn: Addrs.USDC,
                            tokenOut: list[i],
                            tickSpacing: registry.usdcTickSpacing(list[i]),
                            recipient: Addrs.SAFE,
                            deadline: deadline,
                            amountOut: amounts[i],
                            amountInMaximum: maxIn,
                            sqrtPriceLimitX96: 0
                        })
                    )
                )
            );
        }
        calls[0] = Call(Addrs.USDC, abi.encodeCall(IERC20.approve, (Addrs.SLIP_ROUTER, maxUsdc)));
        calls[k++] = Call(Addrs.USDC, abi.encodeCall(IERC20.approve, (Addrs.SLIP_ROUTER, 0)));
        for (uint256 i; i < n; ++i) {
            calls[k++] = Call(list[i], abi.encodeCall(IERC20.approve, (address(vault), amounts[i])));
        }
        calls[k++] = Call(
            address(vault), abi.encodeCall(IndexVault.seed, (amounts, LaunchConfig.SEED_TOKENS * 1e18, Addrs.SAFE))
        );
    }
}
