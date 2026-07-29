---
name: "pmm-adapter-route"
description: "Aggregator-initiated fill through PMMAdapter — decode V1/V2/V3 legacy + V4/orderType=4 anti-toxic OrderRFQ, caller-auth + allowedSender check, approve pool, forward to PMMProtocol, refund leftover"
type: "design"
title: "Flow: Aggregator Route via PMMAdapter"
tags: ["adapter-route", "orderType-4", "CallerAuth", "allowedSender", "dexRouterCaller", "RFQ_BadSender", "anti-toxic-flow", "SCDEX-1157"]
sources: ["src/PmmAdaptor.sol", "src/libraries/CallerAuth.sol", "src/libraries/Constants.sol"]
last_updated: "2026-07-05"
---

# Flow: Aggregator Route via PMMAdapter

## Overview

The OKX DEX aggregator routes a PMM leg by calling `PMMAdapter.sellBase` (or `sellQuote`, both now `nonReentrant`). The adapter decodes an `OrderRFQ` payload, approves the configured `pool` (a `PMMProtocol`) for the taker-asset balance it holds, forwards the fill, and refunds any unused taker-asset balance to a payer extracted from the trailing calldata word. The downstream settlement is identical to [[pmm-fill-order]] — see that file for the inner trace.

Two families of order types coexist: **legacy `orderType ∈ {1,2,3}`** (unchanged, no caller-auth, no allowedSender check) and the **new `orderType == 4`** (SCDEX-1157 anti-toxic-flow), which adds OKX caller-auth and the `allowedSender == dexRouterCaller` check.

## Participants

| Actor | Role in Flow |
|-------|-------------|
| Aggregator router | Caller of `sellBase` / `sellQuote`; supplies `to`, `pool`, the encoded `moreInfo` blob, and an optional `payerOrigin` trailing word. |
| Adapter (`PMMAdapter`) | Dispatch contract (inherits `CallerAuth` + `ReentrancyGuard`); performs ABI decode, caller-auth + allowedSender check (orderType=4), approval, forwarding, and refund. |
| `OKX_SIGNER` / caller set | For orderType=4: the OKX-signed `allowedCallers` (`[DexRouter, DynamicRoute]`) and the `dexRouterCaller` injected at calldata `-64`. |
| `pool` | A deployed `PMMProtocol` instance. The address is supplied by the caller — the adapter does not pin a particular `pool`. |
| Payer | Address recovered from the trailing 32-byte word when it matches the `ORIGIN_PAYER` sentinel. Receives any unused taker-asset balance. |

## Prerequisites

- The aggregator has transferred at least 1 unit of `order.takerAsset` to the adapter address (`amount > 0` is enforced by the `require`).
- `moreInfo` is the ABI encoding of `(bytes orderInfo, bytes signature, uint256 signatureType, uint256 orderType)`.
- `orderType ∈ {1, 2, 3, 4}` — otherwise reverts `"PMMAdapter: unsupported orderType"`.
- For `orderType ∈ {1,2,3}`: `orderInfo` decodes to the corresponding `IPMMProtocolV{1,2,3}.OrderRFQ` shape.
- For `orderType == 4`: `orderInfo = abi.encode(OrderRFQLib.OrderRFQ order, OkxAuth adaptorAuth, OkxAuth protocolAuth)`, `msg.sender ∈ [DexRouter, DynamicRoute]`, and the `dexRouterCaller` word is present at calldata `-64`.
- All [[pmm-fill-order]] prerequisites hold for the downstream `pool.fillOrderRFQTo` call (incl. the `protocolAuth` caller-auth tuple).

## Step-by-Step Flow

`PmmAdaptor.sol:83-213`:

1. **Entry.** Aggregator calls `sellBase(to, pool, moreInfo)` or `sellQuote(to, pool, moreInfo)`. Both functions are structurally identical:
   ```
   assembly { payerOrigin := calldataload(sub(calldatasize(), 32)) }
   _PMMSwap(to, pool, moreInfo, payerOrigin);
   ```
2. **`_PMMSwap` dispatch.** Decodes `(orderInfo, signature, signatureType, orderType)` and routes to `_executeV1Order` / `_executeV2Order` / `_executeV3Order` / `_executeV4Order` by `orderType ∈ {1,2,3,4}`. Any other value reverts `"PMMAdapter: unsupported orderType"`.

   **orderType == 4 (anti-toxic-flow, SCDEX-1157):** before the approve/forward steps below, `_executeV4Order`:
   1. `_verifyCallerAuth(adaptorAuth.allowedCallers, .nonce, .expiry, .okxSig)` — binds `msg.sender ∈ [DexRouter, DynamicRoute]` (else `OSA_UntrustedCaller` etc.).
   2. `dexRouterCaller = _extractDexRouterCaller()` (reads calldata `-64`, exact `MARKER_MASK` match, fail-closed to `address(0)`).
   3. `if (order.allowedSender == address(0) || order.allowedSender != dexRouterCaller) revert Errors.RFQ_BadSender(order.rfqId);`
   4. Forwards to `pool.fillOrderRFQTo(order, signature, flagsAndAmount, to, protocolAuth.allowedCallers, protocolAuth.nonce, protocolAuth.expiry, protocolAuth.okxSig)` — the protocol re-verifies `protocolAuth` (allowedCallers `[PmmAdapter]`).

3. **`_executeV*Order`** (V1/V2/V3 legacy are structurally identical aside from the decoded struct shape):
   1. Decode the order in the matching `IPMMProtocolV{1,2,3}.OrderRFQ` struct.
   2. `amount = min(IERC20(takerAsset).balanceOf(adapter), order.takerAmount)`.
   3. `require(amount > 0, "Zero balance of PMM adapter")`.
   4. `SafeERC20.safeApprove(takerAsset, pool, amount)` (OpenZeppelin `SafeERC20`).
   5. `flagsAndAmount = (signatureType == SignatureType.EIP1271 ? 1 << 254 : 0) + amount`.
   6. `_call(pool, abi.encodeWithSelector(IPMMProtocolV{1,2,3}.fillOrderRFQTo.selector, order, signature, flagsAndAmount, to), order.rfqId)`.
4. **Downstream fill.** `pool.fillOrderRFQTo` runs the full sequence described in [[pmm-fill-order]]. The maker leg lands at `to`; the taker leg comes out of the adapter (`msg.sender` for `pool`'s `safeTransferFrom`) and goes to the maker.
5. **`_call` error decoding** (`:215-297`). On revert, the adapter inspects the 4-byte selector and re-reverts as a string `"<ErrorName> <rfqId>"`. All `RFQ_*` selectors from `Errors.sol` plus `SafeERC20` selectors are recognised; an unknown selector yields `"RFQ_Failed <rfqId>"`. Empty revert data yields `"RFQ_Unknown error <rfqId>"`.
6. **Refund** (`_handleRefund`, `:186-195`):
   1. If `(payerOrigin & ORIGIN_PAYER) == ORIGIN_PAYER`: `_payerOrigin = address(uint160(payerOrigin & ADDRESS_MASK))`.
   2. Else `_payerOrigin = address(0)` (no refund happens).
   3. `amountLeft = IERC20(takerAsset).balanceOf(adapter)`.
   4. If `amountLeft > 0 && _payerOrigin != address(0)` → `SafeERC20.safeTransfer(takerAsset, _payerOrigin, amountLeft)`.

## Error Conditions

| Condition | Error Thrown |
|-----------|-------------|
| `orderType ∉ {1, 2, 3, 4}` | `"PMMAdapter: unsupported orderType"` (string revert) |
| orderType=4: `msg.sender ∉ [DexRouter, DynamicRoute]` / bad/expired/replayed `okxSig` | `OSA_UntrustedCaller` / `OSA_BadOkxSig` / `OSA_BadSigLen` / `OSA_Expired` / `OSA_NonceUsed` (custom error) |
| orderType=4: `order.allowedSender == 0` or `!= dexRouterCaller` (incl. missing/forged `-64` marker) | `RFQ_BadSender(rfqId)` (custom error) |
| Adapter holds zero balance of `takerAsset` | `"Zero balance of PMM adapter"` (string revert) |
| `safeApprove` fails | OpenZeppelin `SafeERC20`'s internal revert |
| `pool.fillOrderRFQTo` reverts with a known custom error | String `"<ErrorName> <rfqId>"` (e.g., `"RFQ_BadSignature 12345"`) |
| `pool` returns empty revert data | `"RFQ_Unknown error <rfqId>"` |
| `pool` returns an unrecognised selector | `"RFQ_Failed <rfqId>"` |

## Key Invariants After Flow

- [Rule] Adapter holds no ERC-20 balance after the call (refunded to payer, or — if no payer was provided — left in the adapter until the next call zeros it out via `balanceOf`).
- [Rule] Adapter now carries storage (`_callerAuthNonceBitmap` slot 0, `_status` slot 1) but emits no events of its own; observability is entirely on `PMMProtocol`'s `OrderFilledRFQ`. (The earlier "no storage" claim is void as of SCDEX-1157.)
- [Rule] orderType=4 consumes an OKX caller-auth nonce (`adaptorAuth.nonce`) per fill; replay of the same nonce reverts `OSA_NonceUsed`. The `-64` dexRouterCaller read only fires on orderType=4; the `-32` refund read is unchanged.
- [Rule] `flagsAndAmount` constructed by the adapter encodes only bit 254 (ERC-1271 hint) and the masked amount — never sets the WETH-unwrap, 65-byte, or maker-side flags. Aggregators that need those must call `PMMProtocol` directly.

<!-- TODO: Document any aggregator-side allowance hygiene that needs to happen for tokens that don't reset approval to zero between calls (USDT-style) — `safeApprove` from OpenZeppelin reverts on non-zero current allowance, which the adapter does not pre-clear -->
