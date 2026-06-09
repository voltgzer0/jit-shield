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

### Mainnet readiness

Sepolia deploy does **not** mean mainnet ready. See [SECURITY.md](SECURITY.md) for the open
pre-mainnet checklist (multisig owner, two-step ownership transfer, pause, exact-output cut,
external audit, bug bounty).
