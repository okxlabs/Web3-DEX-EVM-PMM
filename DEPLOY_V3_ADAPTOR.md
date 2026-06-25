# Deploy Guide — V3 PMMAdapter (SCDEX-1154)

This guide covers the **redeployment of the V3 `PMMAdapter` only**. The PmmProtocol
settlement contract is **NOT** redeployed — it already exists and is unchanged on all 5
chains (verified read-only below). The SCDEX-1154 change touches only `src/PmmAdaptor.sol`
(Permit2 maker-balance → `RFQ_SafeTransferFromFailed` error attribution), so a standalone
Adaptor deploy keeps every protocol address stable.

> ⚠️ **Deployment is performed MANUALLY by an operator after this MR is merged.**
> It is NOT executed inside the Oli automation. Nothing in this repo broadcasts a
> transaction. The deploy script `scripts/DeployAdaptor.s.sol` was only **dry-run
> (simulation, no `--broadcast`)** during preparation.

---

## 0. Deploy script

`scripts/DeployAdaptor.s.sol:DeployAdaptor` — deploys only `PMMAdapter` (no-arg constructor).

Dry-run already performed (no `--broadcast`, no RPC, no tx):

```bash
forge build
forge script scripts/DeployAdaptor.s.sol:DeployAdaptor
# => "Script ran successfully", gas ~1,566,172, simulated PMMAdapter address logged.
```

---

## 1. Pre-deploy checklist

- [ ] MR merged to `main`; local checkout at the merge commit.
- [ ] `forge build` clean; `forge test` green (see Code MR for results).
- [ ] `forge script scripts/DeployAdaptor.s.sol:DeployAdaptor` dry-run passes locally.
- [ ] Per-chain PmmProtocol address re-confirmed (Section 2 — addresses must match this table).
- [ ] Deployer key funded with native gas on the target chain.
- [ ] `$PRIVATE_KEY` and `$RPC_URL` exported from a secure source (env / secrets manager).
      **Never** commit a key or `.env`; never paste a key into a command that gets logged.
- [ ] Block-explorer API key available if `--verify` is used (export as `$ETHERSCAN_API_KEY`).

---

## 2. On-chain read-only PmmProtocol verification (already executed, all PASS)

PmmProtocol must **exist and remain unchanged** at the address below on each chain. Verified
read-only with `cast code` (existence) and `cast call DOMAIN_SEPARATOR()` (live contract). All
five returned 7128 bytes of runtime code and a valid (chain-specific) domain separator.

| Chain | ChainId | PmmProtocol (must be unchanged) | Status |
|-------|---------|----------------------------------|--------|
| Ethereum | 1 | `0x5035D128ef482276Aa3bCce4307ffF8961ba30F9` | ✅ present, live |
| Arbitrum | 42161 | `0xcdC09a6B5211bb51F18A1Af7691B6725bB024434` | ✅ present, live |
| Base | 8453 | `0x4EFBd630205DD9B987c3BcbEe257600abC1e3C11` | ✅ present, live |
| BNB Chain | 56 | `0xdD30339C4b2f7bac319Ef4Fa5c6963cc9F470B2d` | ✅ present, live |
| XLayer | 196 | `0x5E18E052517Af66575105ACff6A7f17DED3f10F2` | ✅ present, live |

Re-run this check before each chain's deploy:

```bash
# existence (expect non-empty 0x... bytecode)
cast code <PMM_PROTOCOL_ADDR> --rpc-url $RPC_URL
# liveness (expect a 32-byte domain separator)
cast call <PMM_PROTOCOL_ADDR> "DOMAIN_SEPARATOR()(bytes32)" --rpc-url $RPC_URL
```

If any chain's PmmProtocol address is empty / changed → **block that chain** and escalate
before deploying its Adaptor.

---

## 3. Per-chain deploy commands (run manually; secrets via env placeholders)

Set `$PRIVATE_KEY` and `$RPC_URL` per chain from a secure source. The Adaptor constructor takes
no arguments, so no extra constructor params are needed. Optional `--verify` requires the
chain's explorer API key.

### Ethereum (chainId 1)
```bash
export RPC_URL=<ethereum-rpc>
forge script scripts/DeployAdaptor.s.sol:DeployAdaptor \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

### Arbitrum (chainId 42161)
```bash
export RPC_URL=https://arb1.arbitrum.io/rpc
forge script scripts/DeployAdaptor.s.sol:DeployAdaptor \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

### Base (chainId 8453)
```bash
export RPC_URL=https://mainnet.base.org
forge script scripts/DeployAdaptor.s.sol:DeployAdaptor \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

### BNB Chain (chainId 56)
```bash
export RPC_URL=<bsc-rpc>
forge script scripts/DeployAdaptor.s.sol:DeployAdaptor \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

### XLayer (chainId 196)
```bash
export RPC_URL=https://rpc.xlayer.tech
forge script scripts/DeployAdaptor.s.sol:DeployAdaptor \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

---

## 4. Post-deploy verification (per chain, after broadcast)

After each broadcast, capture the deployed Adaptor address from the forge output / broadcast
log, then confirm it is live (read-only):

```bash
# 1. bytecode present at the new Adaptor address
cast code <NEW_ADAPTER_ADDR> --rpc-url $RPC_URL          # expect non-empty 0x...

# 2. PmmProtocol still unchanged at its canonical address (Section 2)
cast call <PMM_PROTOCOL_ADDR> "DOMAIN_SEPARATOR()(bytes32)" --rpc-url $RPC_URL
```

Functional smoke (optional): drive a known Permit2 full-fill order with insufficient maker
balance through the new Adaptor on a fork and assert the revert string is
`RFQ_SafeTransferFromFailed <rfqId>` (the SCDEX-1154 behaviour). Do this on a fork, not mainnet.

---

## 5. Address backfill (fill in after deployment, then update DEPLOYMENT.md)

Replace each `TBD` with the deployed address and the explorer link, then mirror the change into
[`DEPLOYMENT.md`](./DEPLOYMENT.md) (PmmAdaptor → V3 table) and `CLAUDE.md` (V3 matrix).

| Chain | ChainId | New V3 PMMAdapter | Explorer link | Deploy tx |
|-------|---------|-------------------|---------------|-----------|
| Ethereum | 1 | `TBD` | `TBD` | `TBD` |
| Arbitrum | 42161 | `TBD` | `TBD` | `TBD` |
| Base | 8453 | `TBD` | `TBD` | `TBD` |
| BNB Chain | 56 | `TBD` | `TBD` | `TBD` |
| XLayer | 196 | `TBD` | `TBD` | `TBD` |

Previous (current) V3 Adaptor addresses — for reference / rollback (from `DEPLOYMENT.md`):

| Chain | Old V3 PMMAdapter |
|-------|-------------------|
| Ethereum | `0xce937da1ffd21673Aa1e063459873F30189A2193` |
| Arbitrum | `0x50FEC44764EB2FBf86a212139213A743e299313c` |
| Base | `0x4997a12D61520b0eB6D3758c8c0E97a6109B7995` |
| BNB Chain | `0x61e3FcA605e2f0E29d5A176E1C9868d4f0ee817F` |
| XLayer | `0x33a8547ddE7fBFd031fD82685dB8a06a3Db98fF7` |

---

## 6. Downstream link-up verification — `RFQ_SafeTransferFromFailed` signal

The SCDEX-1154 change makes the Adaptor translate a Permit2 full-fill maker-balance shortfall
into the revert string `RFQ_SafeTransferFromFailed <rfqId>`. After each chain's Adaptor is live,
confirm downstream consumers pick up that signal:

- [ ] DEX aggregator router points at the **new** Adaptor address for the chain.
- [ ] A Permit2 full-fill order where `makerBalance < required` reverts with
      `RFQ_SafeTransferFromFailed <rfqId>` (not the generic `RFQ_Failed`).
- [ ] Backward-compat unchanged: V1 / non-Permit2 / partial-fill orders still revert exactly as
      before (no new error code, success path byte-identical).
- [ ] Existing error codes unchanged: `RFQ_BadSignature` / `RFQ_OrderExpired` /
      `RFQ_ConfidenceCapExceeded` keep their original semantics & triggers.
- [ ] Downstream monitoring/alerting parses `RFQ_SafeTransferFromFailed` + `rfqId` and routes it
      to the maker-liquidity / inventory channel for the affected chain.
- [ ] Confidence/time-slippage threshold in the Adaptor recheck mirrors PmmProtocol L263-279
      (`_CONFIDENCE_CAP_LIMIT = 50000`); spot-check on a V3 order with confidence params set.

---

## 7. Rollback

The Adaptor is independently replaceable; PmmProtocol is untouched. To roll back, point the
aggregator router back at the previous V3 Adaptor address (Section 5 reference table). No
protocol migration is involved.
