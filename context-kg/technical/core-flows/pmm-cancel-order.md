---
name: "pmm-cancel-order"
description: "Maker invalidates one of their own RFQ IDs on-chain so it can no longer be filled"
---

# Flow: Cancel OrderRFQ

## Overview

A maker preemptively invalidates a previously-signed RFQ ID before any taker has consumed it. The on-chain effect is a single bit-flip in the maker's invalidator bitmap; once set, any subsequent `fillOrderRFQ*` for the same `(maker, rfqId)` reverts with `RFQ_InvalidatedOrder`.

## Participants

| Actor | Role in Flow |
|-------|-------------|
| Maker | The only caller — `msg.sender` is treated as the maker, so a maker can only cancel their **own** rfqIds. There is no admin override and no signature is required (the EOA control of `makerAddress` is the authorization). |

## Prerequisites

- The `rfqId` to cancel has not been filled or cancelled yet (`isRfqIdUsed(msg.sender, rfqId) == false`).

## Step-by-Step Flow

`PmmProtocol.sol:357-367`:

1. Caller (the maker) invokes `cancelOrderRFQ(uint64 rfqId)`.
2. `maker = msg.sender` is bound.
3. `isRfqIdUsed(maker, rfqId)` check:
   - Computes `slot = uint64(rfqId) >> 8`, `bit = 1 << (uint8(rfqId) & 0xff)`.
   - Returns `(invalidator[maker][slot] & bit) != 0`.
   - If `true` → `RFQ_OrderAlreadyCancelledOrUsed(rfqId)`.
4. `_invalidateOrder(maker, rfqId, 0)`:
   - Recomputes the same `slot` and `bit`.
   - Reads current bitmap `invalidator`.
   - If `invalidator & bit == bit` → `RFQ_InvalidatedOrder(rfqId)` (defensive — should not be reachable when step 3 passed).
   - Writes `invalidator | bit` back to storage.
5. Emit `OrderCancelledRFQ(rfqId, maker)` — both fields indexed.

`cancelOrderRFQ` is **not** `nonReentrant`; there are no external calls, so reentrancy is structurally impossible.

## Error Conditions

| Condition | Error Thrown |
|-----------|-------------|
| `rfqId` already used (filled) or cancelled | `RFQ_OrderAlreadyCancelledOrUsed(rfqId)` |
| (defensive) `_invalidateOrder` re-detects the bit | `RFQ_InvalidatedOrder(rfqId)` |

## Key Invariants After Flow

- [Rule] `isRfqIdUsed(maker, rfqId) == true` post-cancel.
- [Rule] No funds move; no allowance is touched; only `_invalidator[maker][rfqId >> 8]` is updated.
- [Rule] The cancellation is **per-maker**: cancelling rfqId `7` for maker A does not affect rfqId `7` for maker B.
- [Rule] After cancellation, every `fillOrderRFQ*` for the same `(maker, rfqId)` reverts at step 4.3 of [[pmm-fill-order]] (`RFQ_InvalidatedOrder`).
