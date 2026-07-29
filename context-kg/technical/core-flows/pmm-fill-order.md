---
name: "pmm-fill-order"
description: "Fill flow — from the single caller-bound fillOrderRFQTo entry through OKX caller-auth, maker signature verification, settlement guardrails, time-slippage, and dual-leg transfer"
type: "design"
title: "Flow: Fill OrderRFQ"
tags: ["fill-flow", "fillOrderRFQTo", "caller-binding", "CallerAuth", "version-1.2", "SCDEX-1157"]
sources: ["src/PmmProtocol.sol", "src/libraries/CallerAuth.sol", "src/OrderRFQLib.sol"]
last_updated: "2026-07-05"
---

# Flow: Fill OrderRFQ

## Overview

Since SCDEX-1157 the settlement entry is the **single** caller-bound `fillOrderRFQTo`. It first verifies the OKX caller-auth (`_verifyCallerAuth`), then verifies the maker signature, applies amount / settlement / confidence math, transfers the maker leg (standard ERC-20 or Permit2), optionally unwraps WETH for native ETH delivery, then transfers the taker leg, and emits `OrderFilledRFQ`. In production this entry is reached via `PMMAdapter` (orderType=4) — see [[pmm-adapter-route]].

## Participants

| Actor | Role in Flow |
|-------|-------------|
| Maker (off-chain) | Signed the 15-field `OrderRFQ` digest against the PMMProtocol EIP-712 domain (`"OKX Labs PMM Protocol" / 1.2`). Owns the maker-asset balance. |
| Caller (`PmmAdapter`) | The only `msg.sender` in the OKX-signed `allowedCallers`; supplies `(allowedCallers, nonce, expiry, okxSig)` and the taker leg. Verified on the first line via `_verifyCallerAuth`. |
| `OKX_SIGNER` | Off-chain signer of the caller-auth tuple; immutable trust anchor. |
| Target | Recipient of the maker leg (the `target` arg of `fillOrderRFQTo`). |
| `_WETH` | Wrap / unwrap helper for native ETH legs. |
| Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) | Maker-leg custodian when `order.usePermit2 = true`. |

## Prerequisites

- The OKX-signed caller-auth tuple `(allowedCallers, nonce, expiry, okxSig)` is valid: `msg.sender ∈ allowedCallers` (== `[PmmAdapter]`), `block.timestamp <= expiry`, `okxSig` (EIP-2098 64-byte) recovers to `OKX_SIGNER`, and `nonce` is unused. Otherwise the fill reverts with an `OSA_*` error before the maker signature is even checked.
- Maker has signed `OrderRFQ` against `PMMProtocol.DOMAIN_SEPARATOR()` using all **15** struct fields (incl. `allowedSender`) per `OrderRFQLib._LIMIT_ORDER_RFQ_TYPEHASH`.
- `block.timestamp <= order.expiry`.
- `(maker, order.rfqId)` bit is not set in `_invalidator` (i.e., `isRfqIdUsed(maker, rfqId) == false`).
- Maker-leg allowance:
  - `usePermit2 = false` → maker has approved `PMMProtocol` directly on `makerAsset`.
  - `usePermit2 = true` with empty `permit2Signature` → maker has approved Permit2 on `makerAsset` with `address(PMMProtocol)` as the spender.
  - `usePermit2 = true` with non-empty `permit2Signature` → the embedded Permit2 signature is valid for `(maker, makerAsset, makerAmount, nonce=rfqId, deadline=expiry)`.
- Taker-leg supply:
  - `takerAsset != WETH` or `msg.value == 0` → taker has approved `PMMProtocol` on `takerAsset` and holds at least `takerAmount`.
  - `takerAsset == WETH && msg.value > 0` → `msg.value == takerAmount`.
- `target != address(0)`.
- If `usePermit2 = true` and the requested fill is the full order, `order.makerAmount <= uint160.max`.
- If `confidenceCap > 0`, then `confidenceCap <= 50000` (5%).

## Step-by-Step Flow

Trace through `PmmProtocol.sol:115-157` (the single entry) and `:159-294` (`_fillOrderRFQTo`).

1. **Entry.** Caller invokes the single `fillOrderRFQTo(order, signature, flagsAndAmount, target, address[] allowedCallers, uint256 nonce, uint256 expiry, bytes okxSig)` (`public payable nonReentrant`). The removed variants (`fillOrderRFQ`, `fillOrderRFQCompact`, `fillOrderRFQToWithPermit`) no longer exist.

   **1a. Caller binding (first line).** `_verifyCallerAuth(allowedCallers, nonce, expiry, okxSig)` — see [[contract-CallerAuth]]. Reverts `OSA_BadSigLen` / `OSA_BadOkxSig` / `OSA_Expired` / `OSA_UntrustedCaller` / `OSA_NonceUsed` before any order processing.

2. **Hash.** `orderHash = OrderRFQLib.hash(order, _domainSeparatorV4())`. See `arch/eip712-signature-design.md` for the exact 15-field struct encoding.

3. **Signature verification** (`PmmProtocol.sol:172-183`):
   - If `flagsAndAmount & _SIGNER_SMART_CONTRACT_HINT != 0`:
     - If `_IS_VALID_SIGNATURE_65_BYTES` also set and `signature.length != 65` → `RFQ_BadSignature(rfqId)`.
     - Else call `ECDSA.isValidSignature(makerAddress, orderHash, signature)` (ERC-1271).
   - Else call `ECDSA.recoverOrIsValidSignature(makerAddress, orderHash, signature)` (tries ECDSA recovery, falls back to ERC-1271).
   - Any false return → `RFQ_BadSignature(rfqId)`.

4. **Enter `_fillOrderRFQTo`** (`PmmProtocol.sol:202`):
   1. `target == address(0)` → `RFQ_ZeroTargetIsForbidden(rfqId)`.
   2. `block.timestamp > order.expiry` → `RFQ_OrderExpired(rfqId)`.
   3. `_invalidateOrder(maker, rfqId, 0)` flips bit; `RFQ_InvalidatedOrder(rfqId)` if already set.

5. **Derive fill amounts** (`PmmProtocol.sol:222-249`):
   - `amount = flagsAndAmount & _AMOUNT_MASK` (low 160 bits).
   - `amount == 0` → full fill (`makerAmount = order.makerAmount`, `takerAmount = order.takerAmount`); reverts `RFQ_AmountTooLarge(rfqId)` if `usePermit2 && makerAmount > uint160.max`.
   - `flagsAndAmount & _MAKER_AMOUNT_FLAG != 0` → maker-side fill: bound by `order.makerAmount`, `takerAmount = AmountCalculator.getTakerAmount(orderMaker, orderTaker, amount)` (ceiled).
   - else → taker-side fill: bound by `order.takerAmount`, `makerAmount = AmountCalculator.getMakerAmount(...)` (floored).

6. **Zero check.** `makerAmount == 0 || takerAmount == 0` → `RFQ_SwapWithZeroAmount(rfqId)`.

7. **Settlement limit** (`:256-261`). Both `makerAmount` and `takerAmount` must be ≥ `60% * order.{maker,taker}Amount`. Else → `RFQ_SettlementAmountTooSmall(rfqId)`. Evaluated **before** confidence reduction.

8. **Confidence (time-slippage) reduction** (`:265-281`):
   - Skipped if `confidenceT == 0` or `block.timestamp <= confidenceT`.
   - Skipped if `confidenceWeight == 0` or `confidenceCap == 0`.
   - `confidenceCap > 50000` → `RFQ_ConfidenceCapExceeded(rfqId)`.
   - `cutdownPercentageX6 = min(timeDiff * confidenceWeight, confidenceCap)`.
   - `makerAmount -= makerAmount * cutdownPercentageX6 / 1e6`. Taker amount unchanged.

9. **Decide unwrap.** `needUnwrap = (order.makerAsset == address(_WETH)) && (flagsAndAmount & _UNWRAP_WETH_FLAG != 0)`. `receiver = needUnwrap ? address(this) : target`.

10. **Maker leg transfer** (`:287-318`):
    - `usePermit2 && permit2Signature.length > 0 && permit2WitnessType.length > 0` → `IPermit2.permitWitnessTransferFrom(permit, transferDetails, maker, witness, witnessType, signature)`.
    - `usePermit2 && permit2Signature.length > 0` (no witness) → `IPermit2.permitTransferFrom(permit, transferDetails, maker, signature)`.
    - `usePermit2 && permit2Signature.length == 0` → `IERC20(makerAsset).safeTransferFromPermit2(maker, receiver, makerAmount)` (enforces `uint160` cap).
    - else → `IERC20(makerAsset).safeTransferFrom(maker, receiver, makerAmount)` (project's local `SafeERC20`).
    - In all Permit2 paths, the `PermitTransferFrom` is constructed with `permitted = TokenPermissions(makerAsset, order.makerAmount)`, `nonce = order.rfqId`, `deadline = order.expiry`.

11. **WETH unwrap** (`:319-324`, only when `needUnwrap`):
    - `_WETH.withdraw(makerAmount)` — receives ETH back via `receive()` (guarded by `msg.sender == _WETH`).
    - `(bool success,) = target.call{value: makerAmount, gas: _RAW_CALL_GAS_LIMIT}("")`.
    - `!success` → `RFQ_ETHTransferFailed(rfqId)`.

12. **Taker leg transfer** (`:327-336`):
    - `takerAsset == _WETH && msg.value > 0`:
      - `msg.value != takerAmount` → `RFQ_InvalidMsgValue(rfqId)`.
      - `_WETH.deposit{value: takerAmount}()` → `_WETH.transfer(maker, takerAmount)`.
    - else:
      - `msg.value != 0` → `RFQ_InvalidMsgValue(rfqId)`.
      - `IERC20(takerAsset).safeTransferFrom(msg.sender, maker, takerAmount)`.

13. **Emit** (`fillOrderRFQTo` body):
    ```
    OrderFilledRFQ(
        rfqId, expiry, makerAsset, takerAsset, makerAddress,
        order.makerAmount, order.takerAmount,
        filledMakerAmount, filledTakerAmount,
        usePermit2, permit2Signature, permit2Witness, permit2WitnessType
    )
    ```

## Error Conditions

| Condition | Error Thrown |
|-----------|-------------|
| Caller-auth fails (bad/expired/replayed okxSig or untrusted caller) | `OSA_BadSigLen` / `OSA_BadOkxSig` / `OSA_Expired` / `OSA_UntrustedCaller` / `OSA_NonceUsed` (checked first) |
| Maker signature does not validate | `RFQ_BadSignature(rfqId)` |
| `target == address(0)` | `RFQ_ZeroTargetIsForbidden(rfqId)` |
| `block.timestamp > order.expiry` | `RFQ_OrderExpired(rfqId)` |
| RFQ ID already used or cancelled | `RFQ_InvalidatedOrder(rfqId)` |
| Maker-side amount > `order.makerAmount` | `RFQ_MakerAmountExceeded(rfqId)` |
| Taker-side amount > `order.takerAmount` | `RFQ_TakerAmountExceeded(rfqId)` |
| Full-fill maker amount > `uint160.max` with `usePermit2` | `RFQ_AmountTooLarge(rfqId)` |
| Derived maker or taker amount is zero | `RFQ_SwapWithZeroAmount(rfqId)` |
| Fill < 60% of quoted maker or taker amount | `RFQ_SettlementAmountTooSmall(rfqId)` |
| `confidenceCap > 50000` | `RFQ_ConfidenceCapExceeded(rfqId)` |
| WETH-unwrap `.call` returns false | `RFQ_ETHTransferFailed(rfqId)` |
| `msg.value` mismatch on either leg | `RFQ_InvalidMsgValue(rfqId)` |
| Underlying ERC-20 transfer fails | `SafeTransferFromFailed()` (from `SafeERC20.sol`) |
| Permit2 transfer amount > `uint160.max` (allowance path) | `Permit2TransferAmountTooHigh()` |

## Key Invariants After Flow

- [Rule] `isRfqIdUsed(maker, rfqId) == true` post-fill — the same OrderRFQ can never be filled again.
- [Rule] Maker net balance decreased by exactly `filledMakerAmount` of `makerAsset`; taker net balance decreased by exactly `filledTakerAmount` of `takerAsset` (in addition to any ETH wrapping fee absorbed by WETH itself).
- [Rule] `PMMProtocol` ends the call with zero ERC-20 balance (CEI within `_fillOrderRFQTo`).
- [Rule] `OrderFilledRFQ` event always reports both quoted (`expectedMakerAmount`, `expectedTakerAmount`) and actual (`filledMakerAmount`, `filledTakerAmount`) amounts — `filledMakerAmount` may differ from the quote due to partial fills and confidence reduction.
