# Manual Tools

Utility scripts for manual on-chain interaction with deployed pools/hooks.

## Ethereum Sepolia Canonical Tokens

- USDC: `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (6 decimals)
- WETH: `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` (18 decimals)

## Scripts

- `wrap_weth.sh`  
  Wrap native ETH into WETH (`deposit()`).

- `approve_tokens.sh`  
  Approve `TOKEN0` and `TOKEN1` from `config/pool.<chain>.conf` for helper contracts.

- `add_liquidity.sh`  
  Add liquidity through `PoolModifyLiquidityTest`.

- `swap.sh`  
  Execute a swap through `PoolSwapTest`.

- `simulate_arb_traffic.sh`  
  Runs varied two-sided swap flow (arbitrage-like traffic) and prints gas/cost stats.

## Typical Flow (manual)

1. Set config to your real pair (`USDC/WETH`) and hook:
   - `config/hook.ethereum.conf`
   - `config/pool.ethereum.conf`
2. Wrap ETH if you need WETH:
   - `./scripts/tools/wrap_weth.sh --chain ethereum --amount-eth 0.1`
3. Approve both tokens for helpers:
   - `./scripts/tools/approve_tokens.sh --chain ethereum --spender both`
4. Add liquidity:
   - `./scripts/tools/add_liquidity.sh --chain ethereum --liquidity 1000000000000000`
5. Swap:
   - `./scripts/tools/swap.sh --chain ethereum --amount 1000000 --zero-for-one true`
6. Simulate varied traffic + gas report:
   - `./scripts/tools/simulate_arb_traffic.sh --chain ethereum --tx-count 40`

## Notes

- Scripts load `.env` automatically (if present).
- You can override `--rpc-url` and `--private-key` explicitly.
- For chains without built-in helper defaults, pass helper addresses directly:
  - `--modify-test-address`
  - `--swap-test-address`
