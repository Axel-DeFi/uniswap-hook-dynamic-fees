#!/usr/bin/env python3
"""
Fetch historical Uniswap v4 swaps for a specific Optimism pool directly via RPC,
save them to CSV, and print threshold analysis for choosing dust filter size.

This script is designed for the user's current Uniswap v4 ETH/USDC pool on Optimism.

Key features:
- Uses project-standard RPC_URL resolution:
  1) environment variable RPC_URL
  2) ./config/hook.optimism.conf
  3) ./config/hook.conf
- Uses PoolManager logs only, so it works with older hook versions as well.
- Searches Initialize backwards from latest block.
- Automatically splits eth_getLogs requests if the RPC enforces a smaller max block range.
- Saves CSV and prints threshold analysis for $1 / $2 / $3 / $4 / $5 / $7.5 / $10.

Requirements:
    python3 -m pip install web3 pandas

Usage:
    python3 ./scripts/fetch_pool_swaps_op_v4_fixed.py

Optional overrides:
    export RPC_URL="https://..."
    export FROM_BLOCK=0
    export TO_BLOCK=0
    export OUT_CSV="pool_swaps_op_v4.csv"
    export BLOCK_STEP=10000
"""

from __future__ import annotations

import os
import sys
import time
from decimal import Decimal, getcontext
from pathlib import Path
from typing import Dict, List, Tuple

import pandas as pd
from web3 import Web3
from web3._utils.events import get_event_data
from web3.exceptions import Web3RPCError

getcontext().prec = 80

CHAIN_NAME = "Optimism"
CHAIN_ID = 10

POOL_ID = "0x2cf70f1927e5ecc3d025deb35cd33bf3ebf0d783992dd06764e3fa3d742eb694"
POOL_MANAGER = "0x9a13f98cb987694c9f086b1f5eb990eea8264ec3"

USDC = "0x0b2c639c533813f4aa9d7837caf62653d097ff85"
USDC_E = "0x7f5c764cbc14f9669b88837ca1490cca17c31607"
USDT = "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58"
DAI = "0xda10009cbd5d07dd0cecc66161fc93d7c9000da1"

KNOWN_STABLES = {
    USDC.lower(): "USDC",
    USDC_E.lower(): "USDC.e",
    USDT.lower(): "USDT",
    DAI.lower(): "DAI",
}

NATIVE_CURRENCY = "0x0000000000000000000000000000000000000000"
CANDIDATE_THRESHOLDS = [1, 2, 3, 4, 5, 7.5, 10]

FROM_BLOCK_ENV = os.environ.get("FROM_BLOCK", "").strip()
TO_BLOCK_ENV = os.environ.get("TO_BLOCK", "").strip()
BLOCK_STEP = int(os.environ.get("BLOCK_STEP", "10000"))
OUT_CSV = os.environ.get("OUT_CSV", "pool_swaps_op_v4.csv")

SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parent.parent if SCRIPT_PATH.parent.name == "scripts" else SCRIPT_PATH.parent


def load_dotenv_like(path: Path) -> Dict[str, str]:
    data: Dict[str, str] = {}
    if not path.exists():
        return data

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()

        if not line or line.startswith("#"):
            continue

        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        data[key] = value

    return data


def resolve_rpc_url() -> str:
    env_rpc = os.environ.get("RPC_URL", "").strip()
    if env_rpc:
        print("Using RPC_URL from environment")
        return env_rpc

    candidates = [
        REPO_ROOT / "config" / "hook.optimism.conf",
        REPO_ROOT / "config" / "hook.conf",
    ]

    for candidate in candidates:
        cfg = load_dotenv_like(candidate)
        rpc = cfg.get("RPC_URL", "").strip()
        if rpc:
            print(f"Using RPC_URL from {candidate}")
            return rpc

    return ""


RPC_URL = resolve_rpc_url()

if not RPC_URL:
    print(
        "ERROR: RPC_URL is not set and was not found in "
        "config/hook.optimism.conf or config/hook.conf",
        file=sys.stderr,
    )
    sys.exit(1)

w3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 60}))

if not w3.is_connected():
    print(f"ERROR: cannot connect to RPC_URL: {RPC_URL}", file=sys.stderr)
    sys.exit(1)

pool_manager = Web3.to_checksum_address(POOL_MANAGER)
pool_id_bytes32 = Web3.to_hex(hexstr=POOL_ID if POOL_ID.startswith("0x") else "0x" + POOL_ID)


def normalize_topic(topic: str) -> str:
    topic = topic.strip()
    return topic if topic.startswith("0x") else "0x" + topic

INITIALIZE_EVENT_ABI = {
    "anonymous": False,
    "inputs": [
        {"indexed": True, "internalType": "bytes32", "name": "id", "type": "bytes32"},
        {"indexed": True, "internalType": "address", "name": "currency0", "type": "address"},
        {"indexed": True, "internalType": "address", "name": "currency1", "type": "address"},
        {"indexed": False, "internalType": "uint24", "name": "fee", "type": "uint24"},
        {"indexed": False, "internalType": "int24", "name": "tickSpacing", "type": "int24"},
        {"indexed": False, "internalType": "address", "name": "hooks", "type": "address"},
        {"indexed": False, "internalType": "uint160", "name": "sqrtPriceX96", "type": "uint160"},
        {"indexed": False, "internalType": "int24", "name": "tick", "type": "int24"},
    ],
    "name": "Initialize",
    "type": "event",
}

SWAP_EVENT_ABI = {
    "anonymous": False,
    "inputs": [
        {"indexed": True, "internalType": "bytes32", "name": "id", "type": "bytes32"},
        {"indexed": True, "internalType": "address", "name": "sender", "type": "address"},
        {"indexed": False, "internalType": "int128", "name": "amount0", "type": "int128"},
        {"indexed": False, "internalType": "int128", "name": "amount1", "type": "int128"},
        {"indexed": False, "internalType": "uint160", "name": "sqrtPriceX96", "type": "uint160"},
        {"indexed": False, "internalType": "uint128", "name": "liquidity", "type": "uint128"},
        {"indexed": False, "internalType": "int24", "name": "tick", "type": "int24"},
        {"indexed": False, "internalType": "uint24", "name": "fee", "type": "uint24"},
    ],
    "name": "Swap",
    "type": "event",
}

initialize_topic0 = Web3.to_hex(
    w3.keccak(text="Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)")
)
swap_topic0 = Web3.to_hex(
    w3.keccak(text="Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
)

ERC20_DECIMALS_ABI = [
    {
        "inputs": [],
        "name": "decimals",
        "outputs": [{"internalType": "uint8", "name": "", "type": "uint8"}],
        "stateMutability": "view",
        "type": "function",
    }
]

ERC20_SYMBOL_ABI = [
    {
        "inputs": [],
        "name": "symbol",
        "outputs": [{"internalType": "string", "name": "", "type": "string"}],
        "stateMutability": "view",
        "type": "function",
    }
]


def norm_addr(addr: str) -> str:
    return Web3.to_checksum_address(addr)


def maybe_token_meta(addr: str) -> Tuple[str, int]:
    if addr.lower() == NATIVE_CURRENCY.lower():
        return "ETH", 18

    contract = w3.eth.contract(address=norm_addr(addr), abi=ERC20_DECIMALS_ABI + ERC20_SYMBOL_ABI)

    symbol = "UNKNOWN"
    decimals = 18

    try:
        symbol = contract.functions.symbol().call()
    except Exception:
        pass

    try:
        decimals = int(contract.functions.decimals().call())
    except Exception:
        pass

    return symbol, decimals


def decode_event(log: dict, abi: dict) -> dict:
    return get_event_data(w3.codec, abi, log)


def is_block_range_error(exc: Exception) -> bool:
    msg = str(exc).lower()
    return (
        "exceed maximum block range" in msg
        or "block range is too wide" in msg
        or "query returned more than" in msg
        or "please limit the query to at most" in msg
        or "response size exceeded" in msg
    )


def rpc_get_logs(params: dict, max_retries: int = 3) -> List[dict]:
    for attempt in range(max_retries):
        try:
            return w3.eth.get_logs(params)
        except Web3RPCError as exc:
            if is_block_range_error(exc):
                raise
            if attempt == max_retries - 1:
                raise
            sleep_s = 1.5 * (attempt + 1)
            print(f"Retrying eth_getLogs after RPC error: {exc} (sleep {sleep_s:.1f}s)")
            time.sleep(sleep_s)


def safe_get_logs(params: dict) -> List[dict]:
    """
    Fetch logs for the requested range. If the RPC enforces a smaller maximum block
    range than requested, split the range recursively and combine results.
    """
    from_block = int(params["fromBlock"])
    to_block = int(params["toBlock"])

    if from_block > to_block:
        return []

    try:
        return rpc_get_logs(params)
    except Web3RPCError as exc:
        if not is_block_range_error(exc):
            raise

        if from_block == to_block:
            raise

        mid = (from_block + to_block) // 2

        left_params = dict(params)
        left_params["fromBlock"] = from_block
        left_params["toBlock"] = mid

        right_params = dict(params)
        right_params["fromBlock"] = mid + 1
        right_params["toBlock"] = to_block

        left_logs = safe_get_logs(left_params)
        right_logs = safe_get_logs(right_params)

        return left_logs + right_logs


def find_initialize_log(pool_id_hex: str, latest_block: int, block_step: int) -> dict:
    """
    Search backwards from latest block to find the pool Initialize event.
    """
    if block_step <= 0:
        raise ValueError("block_step must be positive")

    end = latest_block

    while end >= 0:
        start = max(0, end - block_step + 1)

        logs = safe_get_logs(
            {
                "fromBlock": start,
                "toBlock": end,
                "address": pool_manager,
                "topics": [normalize_topic(initialize_topic0), normalize_topic(pool_id_hex)],
            }
        )

        if logs:
            return logs[0]

        print(f"Scanning Initialize logs backwards: blocks {start}-{end}, logs=0")

        if start == 0:
            break

        end = start - 1

    raise RuntimeError("Initialize log not found for the provided pool id")


def fetch_swaps(pool_id_hex: str, from_block: int, to_block: int, block_step: int) -> List[dict]:
    rows: List[dict] = []
    start = from_block

    while start <= to_block:
        end = min(start + block_step - 1, to_block)

        logs = safe_get_logs(
            {
                "fromBlock": start,
                "toBlock": end,
                "address": pool_manager,
                "topics": [normalize_topic(swap_topic0), normalize_topic(pool_id_hex)],
            }
        )

        rows.extend(logs)
        print(f"Fetched Swap logs: blocks {start}-{end}, logs={len(logs)}")
        start = end + 1

    return rows


def classify_stable_side(currency0: str, currency1: str, symbol0: str, symbol1: str) -> Tuple[str, bool]:
    c0 = currency0.lower()
    c1 = currency1.lower()

    if c0 in KNOWN_STABLES and c1 not in KNOWN_STABLES:
        return KNOWN_STABLES[c0], True
    if c1 in KNOWN_STABLES and c0 not in KNOWN_STABLES:
        return KNOWN_STABLES[c1], False
    if c0 in KNOWN_STABLES and c1 in KNOWN_STABLES:
        return KNOWN_STABLES[c0], True

    if symbol0.upper() in {"USDC", "USDC.E", "USDT", "DAI"}:
        return symbol0, True
    if symbol1.upper() in {"USDC", "USDC.E", "USDT", "DAI"}:
        return symbol1, False

    raise RuntimeError("Could not auto-detect stable side for this pool")


def load_block_timestamps(block_numbers: List[int]) -> Dict[int, int]:
    ts: Dict[int, int] = {}
    for block_number in sorted(set(block_numbers)):
        block = w3.eth.get_block(block_number)
        ts[block_number] = int(block["timestamp"])
    return ts


def main() -> None:
    latest_block = w3.eth.block_number

    init_log = find_initialize_log(pool_id_bytes32, latest_block, BLOCK_STEP)
    init_decoded = decode_event(init_log, INITIALIZE_EVENT_ABI)["args"]

    currency0 = Web3.to_checksum_address(init_decoded["currency0"])
    currency1 = Web3.to_checksum_address(init_decoded["currency1"])
    fee = int(init_decoded["fee"])
    tick_spacing = int(init_decoded["tickSpacing"])
    hooks = Web3.to_checksum_address(init_decoded["hooks"])
    init_sqrt_price_x96 = int(init_decoded["sqrtPriceX96"])
    init_tick = int(init_decoded["tick"])
    init_block = int(init_log["blockNumber"])
    init_tx_hash = init_log["transactionHash"].hex()

    symbol0, decimals0 = maybe_token_meta(currency0)
    symbol1, decimals1 = maybe_token_meta(currency1)

    stable_symbol, stable_is_token0 = classify_stable_side(currency0, currency1, symbol0, symbol1)
    stable_address = currency0 if stable_is_token0 else currency1
    stable_decimals = decimals0 if stable_is_token0 else decimals1

    from_block = int(FROM_BLOCK_ENV) if FROM_BLOCK_ENV else init_block
    to_block = int(TO_BLOCK_ENV) if TO_BLOCK_ENV and TO_BLOCK_ENV != "0" else latest_block

    print("=" * 90)
    print(f"Chain                 : {CHAIN_NAME} ({CHAIN_ID})")
    print(f"RPC                   : {RPC_URL}")
    print(f"PoolManager           : {pool_manager}")
    print(f"PoolId                : {pool_id_bytes32}")
    print(f"Initialize block      : {init_block}")
    print(f"Initialize tx         : {init_tx_hash}")
    print(f"currency0             : {currency0} ({symbol0}, {decimals0})")
    print(f"currency1             : {currency1} ({symbol1}, {decimals1})")
    print(f"fee                   : {fee} (hundredths of a bip)")
    print(f"tickSpacing           : {tick_spacing}")
    print(f"hooks                 : {hooks}")
    print(f"init sqrtPriceX96     : {init_sqrt_price_x96}")
    print(f"init tick             : {init_tick}")
    print(f"stable side           : {'token0' if stable_is_token0 else 'token1'}")
    print(f"stable token          : {stable_address} ({stable_symbol}, {stable_decimals})")
    print(f"fromBlock             : {from_block}")
    print(f"toBlock               : {to_block}")
    print(f"block step            : {BLOCK_STEP}")
    print(f"output csv            : {OUT_CSV}")
    print("=" * 90)

    raw_logs = fetch_swaps(pool_id_bytes32, from_block, to_block, BLOCK_STEP)

    if not raw_logs:
        print("No Swap logs found in the selected range")
        return

    decoded_rows: List[dict] = []
    block_numbers: List[int] = []

    for log in raw_logs:
        evt = decode_event(log, SWAP_EVENT_ABI)["args"]

        amount0 = int(evt["amount0"])
        amount1 = int(evt["amount1"])

        stable_raw = abs(amount0) if stable_is_token0 else abs(amount1)
        stable_amount = Decimal(stable_raw) / (Decimal(10) ** stable_decimals)

        decoded_rows.append(
            {
                "block_number": int(log["blockNumber"]),
                "tx_hash": log["transactionHash"].hex(),
                "log_index": int(log["logIndex"]),
                "sender": Web3.to_checksum_address(evt["sender"]),
                "amount0_raw": amount0,
                "amount1_raw": amount1,
                "stable_raw": int(stable_raw),
                "stable_amount": float(stable_amount),
                "sqrtPriceX96": int(evt["sqrtPriceX96"]),
                "liquidity": int(evt["liquidity"]),
                "tick": int(evt["tick"]),
                "fee_hundredths_bip": int(evt["fee"]),
            }
        )
        block_numbers.append(int(log["blockNumber"]))

    ts_map = load_block_timestamps(block_numbers)

    for row in decoded_rows:
        ts = ts_map[row["block_number"]]
        row["timestamp"] = ts
        row["datetime_utc"] = pd.to_datetime(ts, unit="s", utc=True).isoformat()

    df = pd.DataFrame(decoded_rows)
    df = df.sort_values(["block_number", "log_index"]).reset_index(drop=True)
    df.to_csv(OUT_CSV, index=False)

    total_count = len(df)
    total_volume = float(df["stable_amount"].sum())
    mean_swap = float(df["stable_amount"].mean())
    median_swap = float(df["stable_amount"].median())

    print("\nSaved CSV:", OUT_CSV)
    print(f"Total swaps           : {total_count:,}")
    print(f"Total stable volume   : ${total_volume:,.2f}")
    print(f"Average swap size     : ${mean_swap:,.4f}")
    print(f"Median swap size      : ${median_swap:,.4f}")

    quantiles = df["stable_amount"].quantile([0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99])
    print("\nQuantiles (stable-side notional):")
    print(quantiles.to_string())

    print("\nThreshold analysis:")
    for t in CANDIDATE_THRESHOLDS:
        sub = df[df["stable_amount"] < t]
        ignored_count = len(sub)
        ignored_volume = float(sub["stable_amount"].sum())
        ignored_count_share = ignored_count / total_count * 100 if total_count else 0.0
        ignored_volume_share = ignored_volume / total_volume * 100 if total_volume else 0.0

        print(
            f"< ${t:>4}: "
            f"ignored swaps = {ignored_count:>7,} ({ignored_count_share:>6.2f}%), "
            f"ignored volume = ${ignored_volume:>12,.2f} ({ignored_volume_share:>6.2f}%)"
        )

    print("\nDone.")


if __name__ == "__main__":
    main()
