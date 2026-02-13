# Stateless Dynamic Fee Hook (Uniswap v4)

A **STATELESS** Uniswap v4 Hook that applies **Dynamic LP Fees** per swap in the range **0.01%..1%** (100..10_000 units),
with **zero manual controls** and **no storage writes on swaps**.

## Repo layout

- `src/StatelessDynamicFeeHook.sol`
- `test/StatelessDynamicFeeHook.math.t.sol`
- `test/StatelessDynamicFeeHook.integration.t.sol`
- `script/DeployHook.s.sol`
- `script/DeployPoolAndSwap.s.sol`

## Install

This project expects you to install Uniswap v4 dependencies into `lib/`.

```bash
forge --version
forge init --force
```

Install deps:

```bash
forge install Uniswap/v4-core --no-commit
forge install Uniswap/v4-periphery --no-commit
forge install foundry-rs/forge-std --no-commit
```

Remappings are provided in `remappings.txt`.

## Build

```bash
forge build
```

## Test

```bash
forge test -vv
```

## Local run (Anvil)

Terminal 1:

```bash
anvil
```

Terminal 2:

### 1) Deploy PoolManager (if you don't already have one)

On local Anvil you can deploy a fresh PoolManager via `cast`:

```bash
cast send --private-key $ANVIL_PRIVATE_KEY --create $(forge inspect @uniswap/v4-core/src/PoolManager.sol:PoolManager bytecode)   --constructor-args $(cast abi-encode "constructor(address)" $(cast wallet address $ANVIL_PRIVATE_KEY))
```

Or deploy in a tiny custom script (recommended) if you want a stable workflow.

### 2) Deploy the hook (CREATE2 + mined salt)

Set `POOL_MANAGER` to your deployed manager address:

```bash
export POOL_MANAGER=0xYourPoolManagerAddress
export SALT_SEARCH_MAX=2000000  # optional

forge script script/DeployHook.s.sol:DeployHook   --rpc-url http://127.0.0.1:8545   --broadcast -vv
```

The script prints the hook address.

### 3) Create pool + swap (demo)

Set:

```bash
export POOL_MANAGER=0xYourPoolManagerAddress
export HOOK=0xYourHookAddress
```

Run:

```bash
forge script script/DeployPoolAndSwap.s.sol:DeployPoolAndSwap   --rpc-url http://127.0.0.1:8545   --broadcast -vv
```

You should see two logged fee values:
- **Small swap override fee** (close to `MIN_FEE`)
- **Large swap override fee** (>= small fee)

## Notes

- The hook overrides LP fees **only** when `key.fee` is the dynamic-fee flag (`LPFeeLibrary.DYNAMIC_FEE_FLAG`).
- No owner/admin, no setters, and `hookData` is ignored.
- The fee model is purely based on current `sqrtPriceX96`, `liquidity`, and `amountSpecified` (stateless).
