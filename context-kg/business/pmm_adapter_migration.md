---
squad: web3-dex
domain: pmm
sub_domain: pmm_adapter_migration
title: PMMAdapter V1/V2/V3 OrderRFQ Migration
source_docs: ["README.md (Document Versions §2.1)", "docs/research-design-note.md (SCDEX-1157)", "src/PmmAdaptor.sol", "src/libraries/Errors.sol", "DEPLOYMENT.md"]
concept_keys: [PmmAdapter, OrderRFQV1, OrderRFQV2, OrderRFQV3, OrderType, OrderType4, SignatureType, SellBase, SellQuote, PayerOrigin, RefundFlow]
organized_at: 2026-06-01T00:00:00Z
last_updated: 2026-07-05
---

# PMMAdapter V1/V2/V3 OrderRFQ Migration

> Business line: Web3 DEX (PMM Aggregator Integration)

> **SCDEX-1157 update (2026-07-05).** The adapter added a **fourth** order type, `orderType == 4` (anti-toxic-flow), and now **inherits `CallerAuth` + `ReentrancyGuard`** — it is no longer stateless. The V1/V2/V3 legacy shapes and dispatch below are unchanged. The new path (`allowedSender == dexRouterCaller` + OKX caller binding) is documented in [[pmm_anti_toxic_flow]]; this doc stays focused on the legacy version migration.

## One-line Summary

`PMMAdapter` is the OKX DEX aggregator's dispatch layer: it accepts a versioned `OrderRFQ` payload (V1 / V2 / V3 legacy, plus V4/orderType=4 anti-toxic), approves the downstream `PMMProtocol` (called `pool`) for the taker asset balance the adapter currently holds, forwards the fill, refunds any leftover, and decodes downstream `RFQ_*` custom errors into human-readable strings. The three legacy versions exist for **backward compatibility** with in-flight maker quotes during protocol upgrades. As of SCDEX-1157 the adapter inherits `CallerAuth` + `ReentrancyGuard` (carries nonce/reentrancy storage — no longer stateless).

---

## 1. Business Background & Scope

- **Positioning**: As the PMM RFQ struct has evolved (v2 → v3 → v4 in the README's version history), maker tooling and live signed orders cannot all be migrated atomically. The adapter pins three concrete `OrderRFQ` shapes and dispatches based on a caller-supplied `orderType` so older signed quotes can still settle while makers upgrade.
- **Boundary notes**:
  - **In scope (this doc)**: the three `OrderRFQ` shapes (`IPMMProtocolV1.OrderRFQ`, `V2`, `V3`); the `orderType` dispatch table; aggregator-side approval and refund flow; downstream error decoding.
  - **Out of scope (here)**: the actual settlement semantics that run inside `PMMProtocol` — see [[pmm_settlement]]; aggregator-side route selection, quoting, and pricing.
  - **Not in this repo**: the aggregator router itself; the maker quoting service; the off-chain Apollo auto-offline monitor — see [[pmm_auto_offline]].

## 2. Core Content

### 2.1 OrderRFQ Version Shapes

The adapter declares three `OrderRFQ` interfaces in `src/PmmAdaptor.sol` (lines 8-68). Each represents a frozen snapshot of the struct at a given protocol version:

| Version | Field Count | Defined In | Adds vs Previous |
|---------|-------------|------------|------------------|
| V1 | 8 fields | `src/PmmAdaptor.sol:8-18` (interface `IPMMProtocolV1`) | Baseline: `rfqId, expiry, makerAsset, takerAsset, makerAddress, makerAmount, takerAmount, usePermit2`. (Source: src/PmmAdaptor.sol:9-17) |
| V2 | 11 fields | `src/PmmAdaptor.sol:25-43` (interface `IPMMProtocolV2`) | Adds inline Permit2 fields: `bytes permit2Signature, bytes32 permit2Witness, string permit2WitnessType`. (Source: src/PmmAdaptor.sol:35-37) |
| V3 | 14 fields | `src/PmmAdaptor.sol:45-68` (interface `IPMMProtocolV3`) | Adds time-slippage fields: `uint256 confidenceT, uint256 confidenceWeight, uint256 confidenceCap`. (Source: src/PmmAdaptor.sol:55-57) |

As of SCDEX-1157 the live struct in `src/OrderRFQLib.sol` is **15 fields** (V3's 14 fields + `allowedSender`) and no longer matches the `IPMMProtocolV3` interface; it is consumed by the new orderType=4 path (`IPMMProtocolV4`, which reuses `OrderRFQLib.OrderRFQ` directly). The three frozen `IPMMProtocolV{1,2,3}` interfaces remain for legacy in-flight quotes. (Source: src/PmmAdaptor.sol:59-99 + src/OrderRFQLib.sol:8-24)

### 2.2 Aggregator Dispatch Flow (`SellBase` / `SellQuote`)

**Entry points** (`src/PmmAdaptor.sol:197-213`):

```solidity
function sellBase(address to, address pool, bytes memory moreInfo)  external { ... }
function sellQuote(address to, address pool, bytes memory moreInfo) external { ... }
```

Both are structurally **byte-for-byte identical** — they both call `_PMMSwap(to, pool, moreInfo, payerOrigin)` after extracting `payerOrigin` from the trailing 32-byte calldata word via inline assembly.

**Direction is NOT determined by which entry-point is called.** In some other AMM-style aggregator adapters, `sellBase` means `token0 → token1` and `sellQuote` means `token1 → token0` — i.e., direction is encoded in the method name. PMM does not work that way: the swap direction is encoded explicitly in `OrderRFQ.makerAsset` / `OrderRFQ.takerAsset` inside `moreInfo`. The dual entry-points exist to satisfy the aggregator's interface contract (which expects every adapter to expose both `sellBase` and `sellQuote`), but routing through one vs the other has no semantic effect for PMM.

**Main flow**:
1. Aggregator calls `sellBase` or `sellQuote` with `(to, pool, moreInfo)` plus a trailing 32-byte `payerOrigin` word. (Source: src/PmmAdaptor.sol:197-213)
2. `_PMMSwap` decodes `moreInfo` as `(bytes orderInfo, bytes signature, uint256 signatureType, uint256 orderType)`. (Source: src/PmmAdaptor.sol:84-85)
3. Dispatch by `orderType`:
   - `1` → `_executeV1Order` (8-field decode)
   - `2` → `_executeV2Order` (11-field decode)
   - `3` → `_executeV3Order` (14-field decode)
   - `4` → `_executeV4Order` (15-field OrderRFQ + two `OkxAuth` tuples; caller-auth + `allowedSender` check — see [[pmm_anti_toxic_flow]])
   - any other value → revert `"PMMAdapter: unsupported orderType"`.
4. Each `_executeV*Order` does the same five steps:
   1. Decode `orderInfo` into the matching `IPMMProtocolV{1,2,3}.OrderRFQ`. (Source: src/PmmAdaptor.sol:106, :135, :164)
   2. `amount = min(IERC20(takerAsset).balanceOf(adapter), order.takerAmount)`. (Source: src/PmmAdaptor.sol:109-112, :138-141, :167-170)
   3. `require(amount > 0, "Zero balance of PMM adapter")`.
   4. `SafeERC20.safeApprove(takerAsset, pool, amount)` (OpenZeppelin `SafeERC20`, not the project's local one).
   5. `flagsAndAmount = (signatureType == SignatureType.EIP1271 ? 1 << 254 : 0) + amount` — only bit 254 is set; never bits 252 / 253 / 255. (Source: src/PmmAdaptor.sol:115, :144, :173)
   6. `_call(pool, abi.encodeWithSelector(IPMMProtocolV{1,2,3}.fillOrderRFQTo.selector, order, signature, flagsAndAmount, to), order.rfqId)`. (Source: src/PmmAdaptor.sol:118-122, :147-151, :177-181)
5. `_handleRefund(takerAsset, payerOrigin)` — see §2.4. (Source: src/PmmAdaptor.sol:124, :153, :183)

**Key constraints**:
- [Rule] `orderType` MUST be `1`, `2`, or `3`. Any other value reverts `"PMMAdapter: unsupported orderType"`. (Source: src/PmmAdaptor.sol:94)
- [Rule] The adapter MUST hold ≥ 1 unit of `takerAsset` when each `_executeV*Order` runs. Zero balance reverts `"Zero balance of PMM adapter"`. (Source: src/PmmAdaptor.sol:113, :142, :171)
- [Rule] The adapter NEVER encodes bits 252 / 253 / 255 in `flagsAndAmount`. WETH-unwrap (bit 252), 65-byte signature pin (bit 253), and maker-side fill direction (bit 255) cannot be requested through this adapter — callers needing those must call `PMMProtocol` directly. (Source: src/PmmAdaptor.sol:115, :144, :173)

### 2.3 Signature Type Selection (`SignatureType`)

```solidity
enum SignatureType { EIP712, EIP1271 }
```

(`src/PmmAdaptor.sol:76-79`)

The aggregator passes `signatureType` inside `moreInfo`:
- `EIP712` (value `0`) → bit 254 cleared; downstream `PMMProtocol` uses `ECDSA.recoverOrIsValidSignature`.
- `EIP1271` (value `1`) → bit 254 set; downstream `PMMProtocol` uses `ECDSA.isValidSignature` (ERC-1271 only path).

### 2.4 Refund Flow (`RefundFlow`, `PayerOrigin`)

After the fill returns, the adapter may still hold residual `takerAsset` (because step 2.2.iv.b capped at `min(balance, takerAmount)`, but a downstream partial fill or rounding may consume less). `_handleRefund` recovers the address to refund from the trailing 32-byte calldata word.

**Main flow** (`src/PmmAdaptor.sol:186-195`):
1. If `(payerOrigin & ORIGIN_PAYER) == ORIGIN_PAYER`, extract `_payerOrigin = address(uint160(payerOrigin & ADDRESS_MASK))`. (Source: src/PmmAdaptor.sol:188-190)
2. Otherwise `_payerOrigin = address(0)` and no refund happens. (Source: src/PmmAdaptor.sol:187)
3. `amountLeft = IERC20(takerAsset).balanceOf(adapter)`. (Source: src/PmmAdaptor.sol:191)
4. If `amountLeft > 0 && _payerOrigin != address(0)` → `SafeERC20.safeTransfer(takerAsset, _payerOrigin, amountLeft)`. (Source: src/PmmAdaptor.sol:192-194)

**Sentinel** (`src/PmmAdaptor.sol:73-74`):
```solidity
uint256 internal constant ORIGIN_PAYER = 0x3ca20afc2ccc0000000000000000000000000000000000000000000000000000;
uint256 constant ADDRESS_MASK = 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;
```

The high bits of the trailing word MUST match `ORIGIN_PAYER` for the refund to fire; otherwise the leftover stays in the adapter and would be consumed by the next caller's balance-of read.

**Key constraints**:
- [Rule] Aggregator MUST append a 32-byte trailing word whose high bits match `ORIGIN_PAYER` and whose low 160 bits are the payer address. Without it, leftover taker asset accumulates in the adapter and is "donated" to the next caller. (Source: src/PmmAdaptor.sol:186-195)
- [Pitfall] The adapter has no setter or owner; nobody can sweep stuck residuals. Aggregator-side hygiene is the only mitigation.

### 2.5 Downstream Error Decoding (`_call`)

`_call` (`src/PmmAdaptor.sol:215-297`) wraps the low-level call to `pool.fillOrderRFQTo` and re-reverts known `RFQ_*` custom errors as human-readable strings of the form `"<ErrorName> <rfqId>"`.

**Recognised selectors** (one switch case per error, `src/PmmAdaptor.sol:230-293`):

| Selector | Error Name |
|----------|-----------|
| `0x7d0bdf81` | `RFQ_InvalidMsgValue` |
| `0x1952c5f3` | `RFQ_ETHTransferFailed` |
| `0x8fde5c60` | `RFQ_ZeroTargetIsForbidden` |
| `0x87a26f41` | `RFQ_BadSignature` |
| `0x84935d57` | `RFQ_OrderExpired` |
| `0x48872c38` | `RFQ_MakerAmountExceeded` |
| `0x51c6158e` | `RFQ_TakerAmountExceeded` |
| `0x94d42471` | `RFQ_SwapWithZeroAmount` |
| `0x6fe432b3` | `RFQ_InvalidatedOrder` |
| `0xf4a08977` | `RFQ_EthDepositRejected` (no rfqId in error; adapter still appends rfqId for context) |
| `0xf4059071` | `SafeTransferFromFailed` (re-emitted as `RFQ_SafeTransferFromFailed`) |
| `0x8112e119` | `Permit2TransferAmountTooHigh` |
| `0xfb7f5079` | `SafeTransferFailed` |
| `0x19be9a90` | `ForceApproveFailed` |
| `0x8216cd1c` | `SafeIncreaseAllowanceFailed` |
| `0x840bdf26` | `SafeDecreaseAllowanceFailed` |
| `0x68275857` | `SafePermitBadLength` |
| `0xc6f643b2` | `RFQ_AmountTooLarge` |
| `0xa1475d7b` | `RFQ_SettlementAmountTooSmall` |
| `0x589584f5` | `RFQ_OrderAlreadyCancelledOrUsed` |
| `0x1204d22d` | `RFQ_ConfidenceCapExceeded` |

Fallback cases:
- Empty revert data → `"RFQ: Unknown error <rfqId>"`. (Source: src/PmmAdaptor.sol:220-223)
- Unrecognised selector → `"RFQ_Failed <rfqId>"`. (Source: src/PmmAdaptor.sol:294-296)

**Key constraints**:
- [Rule] Any new custom error added to `src/libraries/Errors.sol` MUST also be added to the `_call` switch — otherwise the adapter falls back to the generic `"RFQ_Failed"` message and downstream debugging suffers. (Source: src/PmmAdaptor.sol:215-297)

### 2.6 Upstream Caller: OKX DexRouter `exeAdapter` Convention

`PMMAdapter` is one of dozens of DEX adapters in the OKX aggregator's adapter family. The aggregator's router (`GitHub-Web3-DEX-EVM/contracts/8/router/SmartSwapRouter.sol`) calls every adapter through the same generic helper `CommonLib.exeAdapter` — the calling convention is fixed by that interface, not by `PMMAdapter` itself.

**Call chain from the aggregator side**:

```
DexRouter.smartSwap(...)
  → SmartSwapRouter._exeForks(path)                          // GitHub-Web3-DEX-EVM/contracts/8/router/SmartSwapRouter.sol:292-346
      ├─ decode rawData[i] → poolAddress + reverse + weight
      ├─ TransferLib.transferInternal(payer, assetTo[i], fromToken, weighted_amount)
      │   // ★ funds go to the adapter FIRST, then the adapter forwards to the pool
      └─ CommonLib.exeAdapter(reverse, adapter, to, pool, extra, refundTo)  // GitHub-Web3-DEX-EVM/contracts/8/libraries/CommonLib.sol:56-95
            ├─ if reverse  → adapter.sellQuote(to, pool, extra)
            └─ if !reverse → adapter.sellBase (to, pool, extra)
            ★ call uses abi.encodePacked + trailing 32-byte word = ORIGIN_PAYER + refundTo
  → adapter.sellBase / sellQuote                              // PMM lands at src/PmmAdaptor.sol:197-213
```

**The `reverse` bit comes from `path.rawData[i]`**, bit 161 (`_REVERSE_MASK`). For AMM-style adapters this signals direction (sellBase = token0→token1, sellQuote = token1→token0). For PMM, both entry-points are byte-for-byte identical and direction comes from `OrderRFQ.makerAsset`/`takerAsset` (see §2.2).

**Fund flow is "router pushes to adapter first"** — by the time `sellBase` / `sellQuote` runs, the adapter already holds the taker asset (router did `TransferLib.transferInternal` to the adapter address `assetTo[i]`). That's why `_executeV*Order` reads `IERC20(takerAsset).balanceOf(address(this))` (`src/PmmAdaptor.sol:109-112`). The adapter is a **transient custody point**, not a pass-through that pulls from `msg.sender`.

**Key constraints**:
- [Rule] `PMMAdapter` MUST tolerate the trailing 32-byte `ORIGIN_PAYER + refundTo` calldata word — without it the leftover taker asset donates to the next caller (see §2.4 RefundFlow). (Source: `GitHub-Web3-DEX-EVM/contracts/8/libraries/CommonLib.sol:73, 88`)
- [Rule] `PMMAdapter` MUST NOT depend on which entry-point (`sellBase` vs `sellQuote`) was called — the `reverse` bit is consumed by `exeAdapter`, not by PMM (see §2.2). (Source: src/PmmAdaptor.sol:197-213 — identical bodies)
- [Rule] `_executeV*Order` reads fund balance via `IERC20.balanceOf(address(this))`, NOT via a pull from `msg.sender` — the router-side `transferInternal` is what funded the adapter. (Source: src/PmmAdaptor.sol:109-112, 138-141, 167-170 vs `GitHub-Web3-DEX-EVM/contracts/8/router/SmartSwapRouter.sol:327-334`)
- [Pitfall] If `PMMAdapter` were ever refactored to pull from `msg.sender` instead of read its own balance, the OKX router integration would silently break — the adapter would try to pull funds from the router itself, which never approved it. (Source: derived from the call convention above)

---

## 3. State Machine

> The adapter has **no storage** (`forge inspect PMMAdapter storage-layout` returns empty) and therefore no state machine of its own. Each call is fully self-contained:

```
ENTRY (sellBase / sellQuote)
  └─► decode moreInfo
        └─► dispatch by orderType (1/2/3)
              └─► approve pool, call pool.fillOrderRFQTo
                    └─► _handleRefund
                          └─► EXIT
```

Failure exits short-circuit at any step; no rollback logic needed because of EVM transactional semantics.

---

## 4. Core Calculation Rules

- **`amount`** (per-call cap) = `min(IERC20(takerAsset).balanceOf(adapter), order.takerAmount)`. (Source: src/PmmAdaptor.sol:109-112)
- **`flagsAndAmount`** = `(signatureType == EIP1271 ? 1 << 254 : 0) + amount`. (Source: src/PmmAdaptor.sol:115)
- **`_payerOrigin`** = `address(uint160(payerOrigin & ADDRESS_MASK))` when `(payerOrigin & ORIGIN_PAYER) == ORIGIN_PAYER`, else `address(0)`. (Source: src/PmmAdaptor.sol:187-190)

---

## 5. Access Control

| Role | Permitted Actions | Constraints |
|------|-------------------|-------------|
| Aggregator router (any caller) | `sellBase(to, pool, moreInfo)`, `sellQuote(to, pool, moreInfo)` | `pool` is supplied per-call; nothing is pinned. The adapter is permissionless. (Source: src/PmmAdaptor.sol:197-213) |

- **Immutable roles**: `OKX_SIGNER` (from `CallerAuth`, set at deploy, used by orderType=4). No owner/admin. As of SCDEX-1157 `PMMAdapter` is no longer stateless (carries a caller-auth nonce bitmap + reentrancy status).
- **Open question**: whether the aggregator deployment exposes `PMMAdapter` publicly or only behind a trusted router. The contract itself imposes no restriction. (See [[contract-PMMAdapter]] for the same open item flagged at the technical level.)

---

## 6. Events

> `PMMAdapter` emits NO events of its own. All observability comes from the downstream `PMMProtocol.OrderFilledRFQ` (or `OrderCancelledRFQ`) event. (Source: src/PmmAdaptor.sol — `grep -n "event\|emit" src/PmmAdaptor.sol` returns no hits.)

---

## 7. Constraints & Risk Rules

- [Rule] `orderType ∈ {1, 2, 3}` only — extending the version set requires both adding a new `IPMMProtocolV*` interface AND a new `_executeV*Order` branch in `_PMMSwap`. (Source: src/PmmAdaptor.sol:87-95)
- [Rule] The adapter MUST hold ≥ 1 unit of the taker asset at each `_executeV*Order` entry; this is enforced by `require(amount > 0, "Zero balance of PMM adapter")`. (Source: src/PmmAdaptor.sol:113, :142, :171)
- [Rule] The adapter uses OpenZeppelin's `safeApprove` (not the project's local `forceApprove`). OpenZeppelin's `safeApprove` reverts on non-zero current allowance for USDT-style tokens. Aggregator must ensure approval is zero before each call OR the maker pre-cleans approvals externally. (Source: src/PmmAdaptor.sol:114, :143, :172 vs src/libraries/SafeERC20.sol:82-91)
- [Rule] Refund only fires when the trailing calldata word matches `ORIGIN_PAYER`. (Source: src/PmmAdaptor.sol:186-195)
- [Rule] Every `RFQ_*` selector defined in `src/libraries/Errors.sol` MUST appear in `_call`'s switch. (Source: src/PmmAdaptor.sol:215-297)
- [Pitfall] `sellBase` and `sellQuote` have byte-for-byte identical bodies. In AMM-style aggregator adapters one method name conventionally encodes a swap direction (base→quote vs quote→base); **PMM does not follow that convention** — direction is encoded in `OrderRFQ.makerAsset` / `takerAsset`. The dual entry-points exist only to satisfy the aggregator's interface contract. Consumers MUST NOT depend on which method is called to infer direction. (Source: src/PmmAdaptor.sol:197-213)
- [Pitfall] The adapter encodes `flagsAndAmount` with at most bit 254. Aggregators that need WETH-unwrap, signature-length pinning, or maker-side fill direction must NOT use this adapter — they must call `PMMProtocol.fillOrderRFQTo` directly. (Source: src/PmmAdaptor.sol:115, :144, :173)
- [Pitfall] Residual `takerAsset` left in the adapter (when no `ORIGIN_PAYER` is set) is permanently "donated" — there is no sweep function. (Source: src/PmmAdaptor.sol:186-195)

---

## 8. Test Focus

### Happy Path
- [ ] `sellBase` with `orderType = 3`, valid V3 order, EIP-712 signature: forwards correctly, leftover refunded to payer.
- [ ] `sellQuote` produces the same output as `sellBase` for the same inputs.
- [ ] `orderType = 1` (V1) and `orderType = 2` (V2): both still execute correctly, exercising backward compatibility.
- [ ] EIP-1271 signature path (`signatureType = 1`): bit 254 is set on `flagsAndAmount`.
- [ ] Refund: when `ORIGIN_PAYER` sentinel matches, leftover `takerAsset` is transferred to the encoded payer address.

### Unhappy Path
- [ ] `orderType = 0` or `orderType = 4` → revert `"PMMAdapter: unsupported orderType"`.
- [ ] Adapter has zero `takerAsset` balance → revert `"Zero balance of PMM adapter"`.
- [ ] Downstream `RFQ_BadSignature` selector → string revert `"RFQ_BadSignature <rfqId>"`.
- [ ] Downstream `RFQ_OrderExpired` selector → string revert `"RFQ_OrderExpired <rfqId>"`.
- [ ] Downstream returns empty revert data → `"RFQ: Unknown error <rfqId>"`.
- [ ] Downstream returns unrecognised selector → `"RFQ_Failed <rfqId>"`.

### High-Risk Scenarios
- [ ] USDT-style token: aggregator does not pre-clear adapter's existing approval → `safeApprove` reverts. Verify aggregator hygiene.
- [ ] Trailing calldata word missing or malformed (no `ORIGIN_PAYER` sentinel) → refund silently skipped, leftover stays in adapter — verify donation-to-next-caller behaviour.
- [ ] Two consecutive aggregator calls where the first leaves residual and the second has a higher `order.takerAmount`: the second's `amount` is capped at the combined balance (donation effect).
- [ ] `pool` address points to a non-`PMMProtocol` contract: arbitrary behaviour — verify the adapter does not pin a single `pool`.

---

## 9. Terminology

| Term | Definition |
|------|------------|
| `PMMAdapter` | The dispatch contract in `src/PmmAdaptor.sol` (inherits `CallerAuth` + `ReentrancyGuard` as of SCDEX-1157; no longer stateless). Currently single deployment per chain (see `DEPLOYMENT.md`). |
| `pool` | Per-call address of a `PMMProtocol` instance the adapter forwards into. |
| `orderType` | Caller-supplied dispatch tag: `1` = V1, `2` = V2, `3` = V3. Defined inside the `moreInfo` payload. |
| `sellBase` / `sellQuote` | The two external entry-points exposed by `PMMAdapter`. Byte-for-byte identical bodies. In AMM-style adapters these names conventionally signal swap direction; in PMM they do not — direction comes from `OrderRFQ.makerAsset` / `takerAsset`. |
| `SignatureType.EIP712` | EOA / ECDSA signature path. |
| `SignatureType.EIP1271` | Smart-contract signer path; sets bit 254 of `flagsAndAmount`. |
| `IPMMProtocolV1.OrderRFQ` | 8-field shape (pre-Permit2 inline fields). |
| `IPMMProtocolV2.OrderRFQ` | 11-field shape (adds `permit2Signature`, `permit2Witness`, `permit2WitnessType`). |
| `IPMMProtocolV3.OrderRFQ` | 14-field legacy shape (adds `confidenceT`, `confidenceWeight`, `confidenceCap`). **No longer matches** the live `OrderRFQLib.OrderRFQ`, which is now 15 fields (SCDEX-1157 added `allowedSender`) and is used by the orderType=4 path via `IPMMProtocolV4`. |
| `PayerOrigin` | Trailing 32-byte calldata word; high bits sentinel + low 160 bits payer address. |
| `ORIGIN_PAYER` | `0x3ca20afc2ccc0000…`; sentinel high-bit pattern enabling refund flow. |
| `RefundFlow` | The `_handleRefund` step that returns any residual `takerAsset` to the payer. |
