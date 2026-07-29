---
name: "pmm-adapter-route"
description: "Aggregator-initiated fill through PMMAdapter — decode V1/V2/V3 legacy + V4/orderType=4 anti-toxic OrderRFQ, caller-auth + allowedSender check, approve pool, forward to PMMProtocol, refund leftover"
type: "design"
title: "Flow: Aggregator Route via PMMAdapter"
tags: ["adapter-route", "orderType-4", "CallerAuth", "allowedSender", "dexRouterCaller", "RFQ_BadSender", "anti-toxic-flow"]
sources: ["src/PmmAdaptor.sol", "src/libraries/CallerAuth.sol", "src/libraries/Constants.sol"]
last_updated: "2026-07-27"
---

# Flow: Aggregator Route via PMMAdapter

## Overview

The OKX DEX aggregator routes a PMM leg by calling `PMMAdapter.sellBase` (or `sellQuote`, both now `nonReentrant`). The adapter decodes an `OrderRFQ` payload, approves the configured `pool` (a `PMMProtocol`) for the taker-asset balance it holds, forwards the fill, and refunds any unused taker-asset balance to a payer extracted from the trailing calldata word. The downstream settlement is identical to [[pmm-fill-order]] — see that file for the inner trace.

Two families of order types coexist: **legacy `orderType ∈ {1,2,3}`** (no caller authorization or allowedSender check) and **`orderType == 4`**, which adds caller authorization and the `allowedSender == dexRouterCaller` check.

## Participants

| Actor | Role in Flow |
|-------|-------------|
| Aggregator router | Caller of `sellBase` / `sellQuote`; supplies `to`, `pool`, the encoded `moreInfo` blob, and an optional `payerOrigin` trailing word. |
| Adapter (`PMMAdapter`) | Dispatch contract (inherits `CallerAuth` + `ReentrancyGuard`); performs ABI decode, caller-auth + allowedSender check (orderType=4), approval, forwarding, and refund. |
| `AUTH_SIGNER` / caller set | For orderType=4: the signed `allowedCallers` (`[DexRouter, DynamicRoute]`) and the `dexRouterCaller` injected at calldata `-64`. |
| `pool` | A deployed `PMMProtocol` instance. The address is supplied by the caller — the adapter does not pin a particular `pool`. |
| Payer | Address recovered from the trailing 32-byte word when it matches the `ORIGIN_PAYER` sentinel. Receives any unused taker-asset balance. |

## Prerequisites

- The aggregator has transferred at least 1 unit of `order.takerAsset` to the adapter address (`amount > 0` is enforced by the `require`).
- `moreInfo` is the ABI encoding of `(bytes orderInfo, bytes signature, uint256 signatureType, uint256 orderType)`.
- `orderType ∈ {1, 2, 3, 4}` — otherwise reverts `"PMMAdapter: unsupported orderType"`.
- For `orderType ∈ {1,2,3}`: `orderInfo` decodes to the corresponding `IPMMProtocolV{1,2,3}.OrderRFQ` shape.
- For `orderType == 4`: `orderInfo = abi.encode(OrderRFQLib.OrderRFQ order, CallerAuthData adaptorAuth, CallerAuthData protocolAuth)`, `msg.sender ∈ [DexRouter, DynamicRoute]`, and the `dexRouterCaller` word is present at calldata `-64`.
- All [[pmm-fill-order]] prerequisites hold for the downstream `pool.fillOrderRFQTo` call (incl. the `protocolAuth` caller-auth tuple).

## Step-by-Step Flow

`PmmAdaptor.sol` — entry `sellBase`/`sellQuote` (`:319-335`), dispatch `_PMMSwap` (`:121-136`), error decoding `_call` (`:339-469`), refund `_handleRefund` (`:308-317`):

1. **Entry.** Aggregator calls `sellBase(to, pool, moreInfo)` or `sellQuote(to, pool, moreInfo)`. Both functions are structurally identical:
   ```
   assembly { payerOrigin := calldataload(sub(calldatasize(), 32)) }
   _PMMSwap(to, pool, moreInfo, payerOrigin);
   ```
2. **`_PMMSwap` dispatch.** Decodes `(orderInfo, signature, signatureType, orderType)` and routes to `_executeV1Order` / `_executeV2Order` / `_executeV3Order` / `_executeV4Order` by `orderType ∈ {1,2,3,4}`. Any other value reverts `"PMMAdapter: unsupported orderType"`.

   **orderType == 4:** before the approve/forward steps below, `_executeV4Order`:
   1. `_verifyCallerAuth(keccak256(abi.encode(order)), adaptorAuth.allowedCallers, adaptorAuth.nonce, adaptorAuth.authSig)` — binds `msg.sender ∈ [DexRouter, DynamicRoute]` and this exact `OrderRFQ` (else `AUTH_UntrustedCaller` / `AUTH_BadAuthSig` etc.).
   2. `dexRouterCaller = _extractDexRouterCaller()` (reads calldata `-64`, exact `MARKER_MASK` match, fail-closed to `address(0)`).
   3. `if (order.allowedSender == address(0) || order.allowedSender != dexRouterCaller) revert Errors.RFQ_BadSender(order.rfqId);`
   4. Forwards to `pool.fillOrderRFQTo(order, signature, flagsAndAmount, to, protocolAuth.allowedCallers, protocolAuth.nonce, protocolAuth.authSig)` — the protocol re-verifies `protocolAuth` against the same `keccak256(abi.encode(order))` payload (allowedCallers `[PmmAdapter]`).

3. **`_executeV*Order`** (V1/V2/V3 legacy are structurally identical aside from the decoded struct shape):
   1. Decode the order in the matching `IPMMProtocolV{1,2,3}.OrderRFQ` struct.
   2. `amount = min(IERC20(takerAsset).balanceOf(adapter), order.takerAmount)`.
   3. `require(amount > 0, "Zero balance of PMM adapter")`.
   4. `SafeERC20.safeApprove(takerAsset, pool, amount)` (OpenZeppelin `SafeERC20`).
   5. `flagsAndAmount = (signatureType == SignatureType.EIP1271 ? 1 << 254 : 0) + amount`.
   6. `_call(pool, abi.encodeWithSelector(IPMMProtocolV{1,2,3}.fillOrderRFQTo.selector, order, signature, flagsAndAmount, to), order.rfqId)`.
4. **Downstream fill.** `pool.fillOrderRFQTo` runs the full sequence described in [[pmm-fill-order]]. The maker leg lands at `to`; the taker leg comes out of the adapter (`msg.sender` for `pool`'s `safeTransferFrom`) and goes to the maker.
5. **`_call` error decoding** (`:339-469`). On revert, the adapter inspects the 4-byte selector and re-reverts as a string `"<ErrorName> <rfqId>"`. All `RFQ_*` selectors from `Errors.sol` plus `SafeERC20` selectors are recognised; an unknown selector yields `"RFQ_Failed <rfqId>"`. Empty revert data yields `"RFQ: Unknown error <rfqId>"`.
6. **Refund** (`_handleRefund`, `:308-317`):
   1. If `(payerOrigin & MARKER_MASK) == ORIGIN_PAYER`: `_payerOrigin = address(uint160(payerOrigin & ADDRESS_MASK))`.
   2. Else `_payerOrigin = address(0)` (no refund happens).
   3. `amountLeft = IERC20(takerAsset).balanceOf(adapter)`.
   4. If `amountLeft > 0 && _payerOrigin != address(0)` → `SafeERC20.safeTransfer(takerAsset, _payerOrigin, amountLeft)`.

## Error Conditions

| Condition | Error Thrown |
|-----------|-------------|
| `orderType ∉ {1, 2, 3, 4}` | `"PMMAdapter: unsupported orderType"` (string revert) |
| orderType=4: `msg.sender ∉ [DexRouter, DynamicRoute]` / bad payload or signature / replayed `authSig` | `AUTH_UntrustedCaller` / `AUTH_BadAuthSig` / `AUTH_BadSigLen` / `AUTH_NonceUsed` (custom error) |
| orderType=4: `order.allowedSender == 0` or `!= dexRouterCaller` (incl. missing/forged `-64` marker) | `RFQ_BadSender(rfqId)` (custom error) |
| Adapter holds zero balance of `takerAsset` | `"Zero balance of PMM adapter"` (string revert) |
| `safeApprove` fails | OpenZeppelin `SafeERC20`'s internal revert |
| `pool.fillOrderRFQTo` reverts with a known custom error | String `"<ErrorName> <rfqId>"` (e.g., `"RFQ_BadSignature 12345"`) |
| Downstream `RFQ_InvalidRfqId` (rfqId > `uint64.max` in the protocol) | Re-thrown by `_call` as `"RFQ_InvalidRfqId <rfqId>"` (`PmmAdaptor.sol:427-429`) |
| `pool` returns empty revert data | `"RFQ: Unknown error <rfqId>"` |
| `pool` returns an unrecognised selector | `"RFQ_Failed <rfqId>"` |

## Key Invariants After Flow

- [Rule] Residual taker assets are refunded only when the trailing payer marker is valid; otherwise they remain in the adapter and affect a later balance-based fill.
- [Rule] The adapter carries storage (`_callerAuthNonceBitmap` slot 0, `_status` slot 1) but emits no events of its own; successful fills are observable through `PMMProtocol.OrderFilledRFQ`.
- [Rule] orderType=4 consumes an adapter caller-authorization nonce (`adaptorAuth.nonce`) per fill; replay of the same nonce reverts `AUTH_NonceUsed`. The `-64` dexRouterCaller read only fires on orderType=4; the `-32` refund read is unchanged.
- [Rule] `flagsAndAmount` constructed by the adapter encodes only bit 254 (ERC-1271 hint) and the masked amount; the adapter route does not expose WETH unwrap, 65-byte pinning, or maker-side fill flags.
- [Pitfall] The adapter uses OpenZeppelin `safeApprove`, which rejects a non-zero-to-non-zero allowance change. Successful standard fills consume the approved amount, but non-standard token behavior can still make later approvals fail.
