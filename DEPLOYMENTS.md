# JITShield Deployments

## Sepolia (chain id 11155111)

| Field | Value |
|---|---|
| **Hook address** | [`0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8`](https://sepolia.etherscan.io/address/0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8) |
| Deploy tx | [`0x6060b50cfe595df84215eb9bcdcf071b7155b1e5e75f4ec0bae9d06de736cccd`](https://sepolia.etherscan.io/tx/0x6060b50cfe595df84215eb9bcdcf071b7155b1e5e75f4ec0bae9d06de736cccd) |
| Deployer | `0xf5Ac3902153CD6BF53E8e7474380C3b86e8afA37` (single-use throwaway) |
| Hook owner | `0xf5Ac3902153CD6BF53E8e7474380C3b86e8afA37` (testnet only; multisig required for mainnet) |
| PoolManager | [`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) (Uniswap V4 canonical) |
| CREATE2 salt | `0x00000000000000000000000000000000000000000000000000000000000003d7` |
| Hook flag bits | `0x2AC8` (low 14 bits) — verified on-chain |
| Surge fee | `7000` pips (0.7%) |
| Protocol share | `1000` bips (10% of surge premium) |
| Time-lock window | `5` blocks |
| Gas used | ~1.33M (deploy cost: 0.00133 ETH @ ~2 gwei) |
| Source commit | `2c924d6` (post-Slither + manual review fixes) |

### On-chain verification

```bash
cast call 0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8 'owner()(address)' \
    --rpc-url https://ethereum-sepolia.publicnode.com
# → 0xf5Ac3902153CD6BF53E8e7474380C3b86e8afA37

cast call 0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8 'poolManager()(address)' \
    --rpc-url https://ethereum-sepolia.publicnode.com
# → 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543

cast call 0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8 'surgeFeeBips()(uint24)' \
    --rpc-url https://ethereum-sepolia.publicnode.com
# → 7000
```

### Hook permission bits — what 0x2AC8 means

```
0x2AC8 = 0010 1010 1100 1000
         |  | |  | |   |
         |  | |  | |   └── BEFORE_SWAP_RETURNS_DELTA (bit 3)  ← carve protocol cut
         |  | |  | └────── AFTER_SWAP                (bit 6)  ← record lastSwapBlock
         |  | |  └──────── BEFORE_SWAP               (bit 7)  ← surge fee override
         |  | └─────────── BEFORE_REMOVE_LIQUIDITY   (bit 9)  ← arm surge on early exit
         |  └───────────── BEFORE_ADD_LIQUIDITY      (bit 11) ← same-block JIT detection
         └──────────────── BEFORE_INITIALIZE         (bit 13) ← reject non-dynamic-fee pools
```

The address embedding these bits means Uniswap V4's PoolManager will route the matching
callbacks to this hook on every initialise / liquidity / swap action in any pool that
uses it.

## Live test pool on Sepolia

A working dynamic-fee pool was initialised against this hook with two mock ERC20s so the
mechanism can be exercised end-to-end on a public network.

| Field | Value |
|---|---|
| **Pool ID** | `0x467d6551c1ac498475b01dd23cd73ce9a61de3fae5e00455e696cc55d5522818` |
| Initial price | `sqrtPriceX96 = 79228162514264337593543950336` (1.0 : 1.0) |
| Tick spacing | `60` |
| Fee mode | dynamic (`0x800000`) — surge fee overrides per-swap |
| `currency0` | [`0x7CE8535D4fD28DE2d929B03A7B6d9d6045F36872`](https://sepolia.etherscan.io/address/0x7CE8535D4fD28DE2d929B03A7B6d9d6045F36872) (JTA, JIT Test Token A, 18 dec) |
| `currency1` | [`0x995b4cD6Cc4Bb7985b3869DC8eDBd32FCd38a892`](https://sepolia.etherscan.io/address/0x995b4cD6Cc4Bb7985b3869DC8eDBd32FCd38a892) (JTB, JIT Test Token B, 18 dec) |
| Liquidity router | [`0xC76480A173321F33CF976D0355DF8ECC8e22B4ff`](https://sepolia.etherscan.io/address/0xC76480A173321F33CF976D0355DF8ECC8e22B4ff) (`PoolModifyLiquidityTest` from v4-core/src/test) |
| Seed liquidity | `1e21` over ticks `[-600, +600]` from the deployer |
| `initialize` tx | [`0x4198bd4f0ca2723e0f9632bbc708a4af8e53ccde5c46e398f6092d320ee7546b`](https://sepolia.etherscan.io/tx/0x4198bd4f0ca2723e0f9632bbc708a4af8e53ccde5c46e398f6092d320ee7546b) |
| Seed-liquidity tx | [`0xf5b8e0452c35ca99e4f3b2366aff54005aefe6c9408781e4b3cb880c208cbd77`](https://sepolia.etherscan.io/tx/0xf5b8e0452c35ca99e4f3b2366aff54005aefe6c9408781e4b3cb880c208cbd77) |

### Verifying the pool

```bash
POOL_ID=0x467d6551c1ac498475b01dd23cd73ce9a61de3fae5e00455e696cc55d5522818
PM=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
RPC=https://ethereum-sepolia.publicnode.com

# slot0 lives at keccak(abi.encode(poolId, uint256(6)))
SLOT=$(cast keccak "$(cast abi-encode 'f(bytes32,uint256)' $POOL_ID 6)")
cast call $PM 'extsload(bytes32)' $SLOT --rpc-url $RPC
# → 0x0000...0001000000...0  (sqrtPriceX96 = 2^96 = price 1:1, tick = 0)
```

The hook itself can be queried for live state at any time:

```bash
cast call 0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8 \
    'lastSwapBlock(bytes32)(uint256)' $POOL_ID --rpc-url $RPC
cast call 0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8 \
    'surgePending(bytes32)(bool)' $POOL_ID --rpc-url $RPC
```

## Live JIT scenario proof — surge fired on Sepolia

The scenario primer-swap → JIT-add → JIT-remove → final-swap was executed atomically against
the live pool. All four operations landed in the same block, so the hook's same-block
detection actually fired. The protocol-fee accrual was then read back from on-chain state.

| Field | Value |
|---|---|
| Atomic scenario tx | [`0x2ee624d85aa911c9a7d54a975266b77f7cb8a75810d312c963b791e8f35a1d1f`](https://sepolia.etherscan.io/tx/0x2ee624d85aa911c9a7d54a975266b77f7cb8a75810d312c963b791e8f35a1d1f) |
| JITSimulator deploy tx | [`0x8a2ab97fb101f1eb68a81849ec7bab74447c125b53d525f992db1bdd714d970b`](https://sepolia.etherscan.io/tx/0x8a2ab97fb101f1eb68a81849ec7bab74447c125b53d525f992db1bdd714d970b) |
| JITSimulator address | [`0x86A1a915D2a63F054220fca41e95aE437Ed51E6b`](https://sepolia.etherscan.io/address/0x86A1a915D2a63F054220fca41e95aE437Ed51E6b) |
| Final swap input | `1e18` of currency0 (1 JTA token) |
| Surge premium (LPs) | `6.3e15` (0.0063 JTA) |
| **Protocol cut (us)** | `7e14` (0.0007 JTA) — **physically held by the hook contract** |
| Formula check | `input × surgeBips × protocolBips / 1e10 = 1e18 × 7000 × 1000 / 1e10 = 7e14` ✓ |
| `lastSwapBlock` after | `11023819` (was `0` before) |
| `surgePending` after | `false` (consumed) |

### Anyone can re-verify right now

```bash
HOOK=0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8
C0=0x7CE8535D4fD28DE2d929B03A7B6d9d6045F36872
RPC=https://ethereum-sepolia.publicnode.com

# Hook says it accrued 7e14 of currency0:
cast call $HOOK 'accruedFees(address)(uint256)' $C0 --rpc-url $RPC
# → 700000000000000

# Currency0 contract confirms the hook actually holds those tokens:
cast call $C0 'balanceOf(address)(uint256)' $HOOK --rpc-url $RPC
# → 700000000000000
```

The two numbers match — the hook's internal bookkeeping is exactly equal to the real ERC20
balance the hook contract holds. That is the end-to-end proof: the mechanism does not just
emit events and update mappings; it actually accumulates a tradeable balance.

### Mainnet readiness

Sepolia deploy does **not** mean mainnet ready. See [SECURITY.md](SECURITY.md) for the open
pre-mainnet checklist (multisig owner, two-step ownership transfer, pause, exact-output cut,
external audit, bug bounty).
