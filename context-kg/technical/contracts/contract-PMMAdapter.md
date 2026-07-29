---
name: "contract-PMMAdapter"
description: "Aggregator-side adapter — decodes V1/V2/V3 legacy + V4/orderType=4 anti-toxic OrderRFQ payloads, enforces caller-auth + allowedSender==dexRouterCaller, forwards to PMMProtocol, refunds leftover"
type: "design"
title: "Contract: PMMAdapter"
tags: ["PMMAdapter", "adapter", "CallerAuth", "orderType-4", "allowedSender", "dexRouterCaller", "RFQ_BadSender", "anti-toxic-flow", "SCDEX-1157"]
sources: ["src/PmmAdaptor.sol", "src/libraries/CallerAuth.sol", "src/libraries/Constants.sol", "src/libraries/Errors.sol"]
last_updated: "2026-07-05"
---

# Contract: PMMAdapter

Source: `src/PmmAdaptor.sol` (pragma `0.8.17`). Solidity name: `contract PMMAdapter`.

## Purpose

`PMMAdapter` lets the OKX DEX aggregator route through PMM liquidity. The aggregator/router calls `sellBase` / `sellQuote`, the adapter decodes an `OrderRFQ` from a calldata blob, approves the taker asset to the `pool` (a `PMMProtocol` instance), forwards the fill, and refunds any leftover taker-asset balance to a payer extracted from the trailing calldata word.

It stays backward-compatible with **three** legacy `OrderRFQ` shapes (`IPMMProtocolV1` — 8 fields, `IPMMProtocolV2` — 11 fields, `IPMMProtocolV3` — 14 fields) via `orderType ∈ {1,2,3}`, and since SCDEX-1157 adds a fourth, **`orderType == 4`** (anti-toxic-flow), which:
1. binds the caller via `CallerAuth._verifyCallerAuth(adaptorAuth…)` (`allowedCallers == [DexRouter, DynamicRoute]`),
2. enforces `order.allowedSender != 0 && order.allowedSender == _extractDexRouterCaller()` (the outermost DexRouter address read from calldata `-64`), else reverts `RFQ_BadSender`, and
3. forwards to `PMMProtocol.fillOrderRFQTo`, passing `protocolAuth` (bound to `[PmmAdapter]`) verbatim.

See [[pmm_anti_toxic_flow]] and [[contract-CallerAuth]].

## Inheritance

`contract PMMAdapter is CallerAuth, ReentrancyGuard` (was: no base contract).

| Parent | Provides |
|--------|----------|
| `CallerAuth` (abstract) | **NEW (SCDEX-1157).** Immutable `OKX_SIGNER`, `_verifyCallerAuth`, `_extractDexRouterCaller`, `isNonceUsed`, nonce bitmap. |
| `ReentrancyGuard` (OpenZeppelin 4.8.1) | `nonReentrant` modifier on `sellBase` / `sellQuote`. |

## State Variables

`PMMAdapter` is **no longer stateless.** Verified via `forge inspect PMMAdapter storageLayout`:

| Variable | Type | Slot | Purpose |
|----------|------|------|---------|
| `_callerAuthNonceBitmap` | `mapping(uint256 => uint256)` | 0 | Inherited from `CallerAuth`. Single-use OKX caller-auth nonce bitmap. |
| `_status` | `uint256` | 1 | Inherited from `ReentrancyGuard`. |
| `OKX_SIGNER` | `address` (immutable) | — | Inherited from `CallerAuth`. Set in constructor `(address okxSigner)`; zero rejected (`OSA_ZeroSigner`). |

Constants: the marker constants are now **imported from `src/libraries/Constants.sol`** (file-level), not inlined. `PMMAdapter` imports `{ORIGIN_PAYER, _ADDRESS_MASK}`; the orderType=4 path additionally uses `DEX_ROUTER_CALLER_MARKER` / `MARKER_MASK` (via `CallerAuth._extractDexRouterCaller`).

| Constant | Value | Purpose |
|----------|-------|---------|
| `ORIGIN_PAYER` | `0x3ca20afc2ccc…000` | Sentinel for the refund payer-origin word at calldata `-32`. |
| `_ADDRESS_MASK` | low-20-bytes mask | Recovers an address from a marked calldata word. |
| `DEX_ROUTER_CALLER_MARKER` | `0x3ca20afc2ddd…000` | Sentinel for the `dexRouterCaller` word at calldata `-64` (differs from `ORIGIN_PAYER` only in the 3rd marker byte `ddd` vs `ccc`). |
| `MARKER_MASK` | `0xffffffffffff…000` | High-6-byte mask for exact-match marker validation. |
| `_CONFIDENCE_CAP_LIMIT` | `50000` | Mirrors PMMProtocol; used only by the read-only maker-balance fallback in `_call`. |

## Access Control

`sellBase` / `sellQuote` are now `nonReentrant`. The legacy `orderType ∈ {1,2,3}` paths remain **unrestricted** (backward-compatible — no caller-auth, no allowedSender check). The new `orderType == 4` path is **caller-bound**: `_verifyCallerAuth` requires `msg.sender ∈ [DexRouter, DynamicRoute]` with a valid OKX `okxSig`, and additionally enforces the `allowedSender == dexRouterCaller` anti-toxic check. `OKX_SIGNER` is an immutable trust anchor, not a mutable admin.

## Functions

External:

| Function | Mutability | Description |
|----------|-----------|-------------|
| `sellBase(address to, address pool, bytes memory moreInfo)` | nonpayable, `nonReentrant` | Aggregator entry point. Reads a trailing 32-byte `payerOrigin` word via inline assembly (`calldataload(sub(calldatasize(), 32))`) and forwards to `_PMMSwap`. Selector `0x30e6ae31`. |
| `sellQuote(address to, address pool, bytes memory moreInfo)` | nonpayable, `nonReentrant` | Identical behavior to `sellBase`. Selector `0x6f7929f2`. |
| `OKX_SIGNER()` | view | Inherited from `CallerAuth`. Selector `0x6c26f9cc`. |
| `isNonceUsed(uint256 nonce)` | view | Inherited from `CallerAuth`. Selector `0x5d00bb12`. |

Internal:

| Function | Description |
|----------|-------------|
| `_PMMSwap(address to, address pool, bytes moreInfo, uint256 payerOrigin)` | Decodes `(bytes orderInfo, bytes signature, uint256 signatureType, uint256 orderType)` from `moreInfo`; dispatches to `_executeV1Order` / `_executeV2Order` / `_executeV3Order` / `_executeV4Order` by `orderType ∈ {1,2,3,4}`. Reverts `"PMMAdapter: unsupported orderType"` otherwise. |
| `_executeV1Order(...)` / `_executeV2Order(...)` / `_executeV3Order(...)` | **Unchanged (legacy).** Decode the order in the matching `IPMMProtocolV*.OrderRFQ` shape; compute `flagsAndAmount = (signatureType == EIP1271 ? 1 << 254 : 0) + amount`; `SafeERC20.safeApprove(takerAsset, pool, amount)`; call `pool.fillOrderRFQTo(order, signature, flagsAndAmount, to)` (the legacy 4-arg selector); then `_handleRefund`. No caller-auth, no allowedSender check. |
| `_executeV4Order(...)` | **NEW (SCDEX-1157).** `orderInfo = abi.encode(OrderRFQLib.OrderRFQ order, OkxAuth adaptorAuth, OkxAuth protocolAuth)`. Steps: (1) `_verifyCallerAuth(adaptorAuth.allowedCallers, .nonce, .expiry, .okxSig)`; (2) `dexRouterCaller = _extractDexRouterCaller()`; if `order.allowedSender == address(0) || order.allowedSender != dexRouterCaller` → `revert Errors.RFQ_BadSender(order.rfqId)`; (3) approve + `_call(pool, IPMMProtocolV4.fillOrderRFQTo.selector, order, signature, flagsAndAmount, to, protocolAuth.allowedCallers, protocolAuth.nonce, protocolAuth.expiry, protocolAuth.okxSig)`; (4) `_handleRefund`. |
| `_handleRefund(address takerAsset, uint256 payerOrigin)` | If `(payerOrigin & ORIGIN_PAYER) == ORIGIN_PAYER`, recovers the payer address via `_ADDRESS_MASK`; if the adapter still holds any `takerAsset`, transfers the leftover back to the payer via `SafeERC20.safeTransfer`. Reads `-32`; independent of the `-64` dexRouterCaller word. |
| `_call(...)` (3-arg / 4-arg) | Low-level `call` to `pool`. On revert, decodes the 4-byte custom-error selector and re-reverts as a human-readable `string` (e.g., `"RFQ_BadSignature 12345"`). Now also maps `RFQ_BadSender` and the six `OSA_*` selectors (for observability if they bubble up). The 4-arg overload adds a read-only maker-balance fallback for Permit2 full-fills. |

`OkxAuth` struct (adapter-side, `PmmAdaptor.sol:15-20`): `{ address[] allowedCallers; uint256 nonce; uint256 expiry; bytes okxSig; }` — mirrors the `(allowedCallers, nonce, expiry, okxSig)` tuple `CallerAuth` verifies. `adaptorAuth` binds this adapter call (`[DexRouter, DynamicRoute]`); `protocolAuth` is forwarded to the protocol (`[PmmAdapter]`).

## Events

`PMMAdapter` emits no events of its own. Fills emit `OrderFilledRFQ` from the downstream `PMMProtocol`.

## Custom Errors

`PMMAdapter` now surfaces `RFQ_BadSender(uint256 rfqId)` directly (reverted in `_executeV4Order`) and inherits the six `OSA_*` errors from `CallerAuth` (thrown by `_verifyCallerAuth`). Verified in the PMMAdapter ABI (`forge inspect PMMAdapter abi`): `RFQ_BadSender`, `OSA_ZeroSigner`, `OSA_Expired`, `OSA_UntrustedCaller`, `OSA_BadOkxSig`, `OSA_BadSigLen`, `OSA_NonceUsed`.

For downstream `pool.fillOrderRFQTo` reverts, `_call` still inspects the 4-byte selector and converts it into a `string` `"<ErrorName> <rfqId>"`. The recognised selectors now also include `RFQ_BadSender` and all six `OSA_*` (in addition to the existing `RFQ_*` and `SafeERC20` selectors) — an unmapped selector still degrades to `"RFQ_Failed <rfqId>"`. See `terminology.md`.

## Security Patterns Used

- `SafeERC20.safeApprove` / `SafeERC20.safeTransfer` (OpenZeppelin) — used because the adapter approves an arbitrary `pool` for an arbitrary `takerAsset` per call. (Note: this is OpenZeppelin's `SafeERC20`, not the project's local `src/libraries/SafeERC20.sol` used by `PMMProtocol`.)
- `IERC20(takerAsset).balanceOf(address(this))` before each call — protects against double-spending unrelated balances and is the source of the refunded amount.
- Custom error → string revert decoding — surfaces the original `RFQ_*` reason and `rfqId` to the aggregator so a failed PMM leg can be diagnosed without parsing raw selectors.

## Key Invariants

- [Rule] `PMMAdapter` holds no permanent ERC-20 balance; any leftover is refunded inside `_handleRefund` within the same transaction.
- [Rule] `PMMAdapter._PMMSwap` only dispatches to recognised order versions (`1`, `2`, `3`, `4`); any other `orderType` reverts.
- [Rule] `flagsAndAmount` constructed inside the adapter never sets bits 253 (`_IS_VALID_SIGNATURE_65_BYTES`), 252 (`_UNWRAP_WETH_FLAG`), or 255 (`_MAKER_AMOUNT_FLAG`); only bit 254 (`_SIGNER_SMART_CONTRACT_HINT`) is conditionally set when `signatureType == SignatureType.EIP1271`. (Holds for all four order paths.)
- [Rule] The adapter DOES carry storage now (`_callerAuthNonceBitmap` slot 0, `_status` slot 1) — the earlier "no storage" invariant is void as of SCDEX-1157.
- [Rule] orderType=4 requires BOTH a valid caller-auth (`msg.sender ∈ [DexRouter, DynamicRoute]`) AND `order.allowedSender == _extractDexRouterCaller()` with a non-zero `allowedSender`. `_extractDexRouterCaller` fail-closes to `address(0)` on a missing/forged marker, which can never equal a non-zero `allowedSender`.
- [Rule] The `-64` dexRouterCaller read only fires on orderType=4; the `-32` refund read is unchanged; markers `DEX_ROUTER_CALLER_MARKER@-64` and `ORIGIN_PAYER@-32` never collide.
- [Rule] Legacy V1/V2/V3 paths are byte-for-byte unchanged (FR-6-AC-1) — no caller-auth, no allowedSender check, no `-64` read.
