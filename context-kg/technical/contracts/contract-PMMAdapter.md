---
name: "contract-PMMAdapter"
description: "Aggregator-side adapter — decodes V1/V2/V3 legacy + V4/orderType=4 anti-toxic OrderRFQ payloads, enforces caller-auth + allowedSender==dexRouterCaller, forwards to PMMProtocol, refunds leftover"
type: "design"
title: "Contract: PMMAdapter"
tags: ["PMMAdapter", "adapter", "CallerAuth", "orderType-4", "allowedSender", "dexRouterCaller", "RFQ_BadSender", "anti-toxic-flow"]
sources: ["src/PmmAdaptor.sol", "src/libraries/CallerAuth.sol", "src/libraries/Constants.sol", "src/libraries/Errors.sol"]
last_updated: "2026-07-27"
---

# Contract: PMMAdapter

Source: `src/PmmAdaptor.sol` (pragma `0.8.17`). Solidity name: `contract PMMAdapter`.

## Purpose

`PMMAdapter` lets the OKX DEX aggregator route through PMM liquidity. The aggregator/router calls `sellBase` / `sellQuote`, the adapter decodes an `OrderRFQ` from a calldata blob, approves the taker asset to the `pool` (a `PMMProtocol` instance), forwards the fill, and refunds any leftover taker-asset balance to a payer extracted from the trailing calldata word.

It stays backward-compatible with **three** legacy `OrderRFQ` shapes (`IPMMProtocolV1` — 8 fields, `IPMMProtocolV2` — 11 fields, `IPMMProtocolV3` — 14 fields) via `orderType ∈ {1,2,3}` and supports **`orderType == 4`**, which:
1. binds the caller and exact order via `CallerAuth._verifyCallerAuth(keccak256(abi.encode(order)), adaptorAuth…)` (`allowedCallers == [DexRouter, DynamicRoute]`),
2. enforces `order.allowedSender != 0 && order.allowedSender == _extractDexRouterCaller()` (the outermost DexRouter address read from calldata `-64`), else reverts `RFQ_BadSender`, and
3. forwards to `PMMProtocol.fillOrderRFQTo`, passing `protocolAuth` (bound to `[PmmAdapter]`) verbatim.

See [[pmm_anti_toxic_flow]] and [[contract-CallerAuth]].

## Inheritance

`contract PMMAdapter is CallerAuth, ReentrancyGuard` (was: no base contract).

| Parent | Provides |
|--------|----------|
| `CallerAuth` (abstract) | Immutable `AUTH_SIGNER`, `_verifyCallerAuth`, `_extractDexRouterCaller`, `isNonceUsed`, nonce bitmap. |
| `ReentrancyGuard` (OpenZeppelin 4.8.1) | `nonReentrant` modifier on `sellBase` / `sellQuote`. |

## State Variables

`PMMAdapter` is **no longer stateless.** Verified via `forge inspect PMMAdapter storageLayout`:

| Variable | Type | Slot | Purpose |
|----------|------|------|---------|
| `_callerAuthNonceBitmap` | `mapping(uint256 => uint256)` | 0 | Inherited from `CallerAuth`. Single-use caller-auth nonce bitmap. |
| `_status` | `uint256` | 1 | Inherited from `ReentrancyGuard`. |
| `AUTH_SIGNER` | `address` (immutable) | — | Inherited from `CallerAuth`. Set in constructor `(address authSigner)`; zero rejected (`AUTH_ZeroSigner`). |

Constants: the marker constants are **imported from `src/libraries/Constants.sol`** (file-level), not inlined. `PMMAdapter` imports `{ORIGIN_PAYER, MARKER_MASK, _ADDRESS_MASK}` for refund parsing; the orderType=4 path additionally uses `DEX_ROUTER_CALLER_MARKER` via `CallerAuth._extractDexRouterCaller`.

| Constant | Value | Purpose |
|----------|-------|---------|
| `ORIGIN_PAYER` | `0x3ca20afc2ccc…000` | Sentinel for the refund payer-origin word at calldata `-32`. |
| `_ADDRESS_MASK` | low-20-bytes mask | Recovers an address from a marked calldata word. |
| `DEX_ROUTER_CALLER_MARKER` | `0x3ca20afc2ddd…000` | Sentinel for the `dexRouterCaller` word at calldata `-64` (differs from `ORIGIN_PAYER` only in the 3rd marker byte `ddd` vs `ccc`). |
| `MARKER_MASK` | `0xffffffffffff…000` | High-6-byte mask for exact-match marker validation. |
| `_CONFIDENCE_CAP_LIMIT` | `50000` | Mirrors PMMProtocol; used only by the read-only maker-balance fallback in `_call`. |

## Access Control

`sellBase` / `sellQuote` are now `nonReentrant`. The legacy `orderType ∈ {1,2,3}` paths remain **unrestricted** (backward-compatible — no caller-auth, no allowedSender check). The new `orderType == 4` path is **caller-bound**: `_verifyCallerAuth` requires `msg.sender ∈ [DexRouter, DynamicRoute]` with a valid `authSig`, and additionally enforces the `allowedSender == dexRouterCaller` anti-toxic check. `AUTH_SIGNER` is an immutable trust anchor, not a mutable admin.

## Functions

External:

| Function | Mutability | Description |
|----------|-----------|-------------|
| `sellBase(address to, address pool, bytes memory moreInfo)` | nonpayable, `nonReentrant` | Aggregator entry point. Reads a trailing 32-byte `payerOrigin` word via inline assembly (`calldataload(sub(calldatasize(), 32))`) and forwards to `_PMMSwap`. Selector `0x30e6ae31`. |
| `sellQuote(address to, address pool, bytes memory moreInfo)` | nonpayable, `nonReentrant` | Identical behavior to `sellBase`. Selector `0x6f7929f2`. |
| `AUTH_SIGNER()` | view | Inherited from `CallerAuth`. Selector `0x0a5c9024`. |
| `isNonceUsed(uint256 nonce)` | view | Inherited from `CallerAuth`. Selector `0x5d00bb12`. |

Internal:

| Function | Description |
|----------|-------------|
| `_PMMSwap(address to, address pool, bytes moreInfo, uint256 payerOrigin)` | Decodes `(bytes orderInfo, bytes signature, uint256 signatureType, uint256 orderType)` from `moreInfo`; dispatches to `_executeV1Order` / `_executeV2Order` / `_executeV3Order` / `_executeV4Order` by `orderType ∈ {1,2,3,4}`. Reverts `"PMMAdapter: unsupported orderType"` otherwise. |
| `_executeV1Order(...)` / `_executeV2Order(...)` / `_executeV3Order(...)` | Decode the order in the matching `IPMMProtocolV*.OrderRFQ` shape; compute `flagsAndAmount = (signatureType == EIP1271 ? 1 << 254 : 0) + amount`; `SafeERC20.safeApprove(takerAsset, pool, amount)`; call `pool.fillOrderRFQTo(order, signature, flagsAndAmount, to)` (the legacy 4-arg selector); then `_handleRefund`. No caller-auth or allowedSender check. Their settlement behavior is unchanged; the shared refund parser now requires an exact `MARKER_MASK` match. |
| `_executeV4Order(...)` | `orderInfo = abi.encode(OrderRFQLib.OrderRFQ order, CallerAuthData adaptorAuth, CallerAuthData protocolAuth)`. Steps: (1) verify `adaptorAuth` over `keccak256(abi.encode(order))`; (2) require non-zero `allowedSender == _extractDexRouterCaller()`; (3) approve and call the V4 protocol selector with `protocolAuth`; (4) `_handleRefund`. |
| `_handleRefund(address takerAsset, uint256 payerOrigin)` | If `(payerOrigin & MARKER_MASK) == ORIGIN_PAYER`, recovers the payer address via `_ADDRESS_MASK`; if the adapter still holds any `takerAsset`, transfers the leftover back to the payer via `SafeERC20.safeTransfer`. Reads `-32`; independent of the `-64` dexRouterCaller word. A caller marker or other marker alias is rejected. |
| `_call(...)` (3-arg / 4-arg) | Low-level `call` to `pool`. On revert, decodes the 4-byte custom-error selector and re-reverts as a human-readable `string` (e.g., `"RFQ_BadSignature 12345"`). Now also maps `RFQ_BadSender`, `RFQ_InvalidRfqId` and the five `AUTH_*` selectors (for observability if they bubble up). The 4-arg overload adds a read-only maker-balance fallback for Permit2 full-fills. |

`CallerAuthData` struct (adapter-side, `PmmAdaptor.sol:13-17`): `{ address[] allowedCallers; uint256 nonce; bytes authSig; }` — mirrors the `(allowedCallers, nonce, authSig)` tuple carried alongside the implicit `payloadHash = keccak256(abi.encode(order))` verified by `CallerAuth`. `adaptorAuth` binds this adapter call (`[DexRouter, DynamicRoute]`) to the exact order; `protocolAuth` is forwarded to the protocol (`[PmmAdapter]`) for the same exact order.

## Events

`PMMAdapter` emits no events of its own. Fills emit `OrderFilledRFQ` from the downstream `PMMProtocol`.

## Custom Errors

`PMMAdapter` now surfaces `RFQ_BadSender(uint256 rfqId)` directly (reverted in `_executeV4Order`) and inherits the five `AUTH_*` errors from `CallerAuth` (thrown by `_verifyCallerAuth`): `AUTH_ZeroSigner`, `AUTH_UntrustedCaller`, `AUTH_BadAuthSig`, `AUTH_BadSigLen`, `AUTH_NonceUsed`.

For downstream `pool.fillOrderRFQTo` reverts, `_call` still inspects the 4-byte selector and converts it into a `string` `"<ErrorName> <rfqId>"`. The recognised selectors now also include `RFQ_BadSender`, `RFQ_InvalidRfqId` and all five `AUTH_*` (in addition to the existing `RFQ_*` and `SafeERC20` selectors) — an unmapped selector still degrades to `"RFQ_Failed <rfqId>"`. See `terminology.md`.

## Security Patterns Used

- `SafeERC20.safeApprove` / `SafeERC20.safeTransfer` (OpenZeppelin) — used because the adapter approves an arbitrary `pool` for an arbitrary `takerAsset` per call. (Note: this is OpenZeppelin's `SafeERC20`, not the project's local `src/libraries/SafeERC20.sol` used by `PMMProtocol`.)
- `IERC20(takerAsset).balanceOf(address(this))` before each call — protects against double-spending unrelated balances and is the source of the refunded amount.
- Custom error → string revert decoding — surfaces the original `RFQ_*` reason and `rfqId` to the aggregator so a failed PMM leg can be diagnosed without parsing raw selectors.

## Key Invariants

- [Rule] With a canonical `ORIGIN_PAYER` tail, any leftover is refunded inside `_handleRefund` in the same transaction. A missing or malformed tail skips the refund and can leave a balance in the adapter.
- [Rule] `PMMAdapter._PMMSwap` only dispatches to recognised order versions (`1`, `2`, `3`, `4`); any other `orderType` reverts.
- [Rule] `flagsAndAmount` constructed inside the adapter never sets bits 253 (`_IS_VALID_SIGNATURE_65_BYTES`), 252 (`_UNWRAP_WETH_FLAG`), or 255 (`_MAKER_AMOUNT_FLAG`); only bit 254 (`_SIGNER_SMART_CONTRACT_HINT`) is conditionally set when `signatureType == SignatureType.EIP1271`. (Holds for all four order paths.)
- [Rule] The adapter carries storage: `_callerAuthNonceBitmap` at slot 0 and `_status` at slot 1.
- [Rule] orderType=4 requires BOTH a valid caller-auth (`msg.sender ∈ [DexRouter, DynamicRoute]`) AND `order.allowedSender == _extractDexRouterCaller()` with a non-zero `allowedSender`. `_extractDexRouterCaller` fail-closes to `address(0)` on a missing/forged marker, which can never equal a non-zero `allowedSender`.
- [Rule] The `-64` dexRouterCaller read only fires on orderType=4; the `-32` refund read is shared by all order types. Both marker reads use `MARKER_MASK`, so `DEX_ROUTER_CALLER_MARKER@-64` and `ORIGIN_PAYER@-32` cannot alias.
- [Rule] Legacy V1/V2/V3 settlement paths remain caller-auth-free / allowedSender-free and do not read `-64`; only their shared refund marker validation was tightened from subset matching to exact `MARKER_MASK` matching.
