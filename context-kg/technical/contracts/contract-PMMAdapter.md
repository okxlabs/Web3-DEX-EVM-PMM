---
name: "contract-PMMAdapter"
description: "Aggregator-side adapter that decodes V1/V2/V3 OrderRFQ payloads and forwards to PMMProtocol, with refund handling"
---

# Contract: PMMAdapter

Source: `src/PmmAdaptor.sol` (pragma `0.8.17`).

## Purpose

`PMMAdapter` is a stateless dispatch layer that lets the OKX DEX aggregator route through PMM liquidity. The aggregator calls `sellBase` / `sellQuote`, the adapter decodes an `OrderRFQ` (in V1, V2, or V3 layout) from a calldata blob, approves the taker asset to the `pool` (a `PMMProtocol` instance), forwards the fill, and refunds any leftover taker-asset balance to a payer extracted from the trailing calldata word.

The adapter is intentionally backward-compatible with **three** historical `OrderRFQ` shapes (`IPMMProtocolV1` — 8 fields, `IPMMProtocolV2` — 11 fields, `IPMMProtocolV3` — 14 fields) so that orders quoted against older PMMProtocol deployments can still be filled while a migration is in flight.

## Inheritance

None. `PMMAdapter` does not inherit from any base contract.

## State Variables

`PMMAdapter` has **no storage** (verified via `forge inspect PMMAdapter storage-layout` — empty).

Constants (`PmmAdaptor.sol:73-74`):

| Constant | Value | Purpose |
|----------|-------|---------|
| `ORIGIN_PAYER` (internal) | `0x3ca20afc2ccc...000` | Sentinel bit pattern that, when set in the trailing calldata word, marks it as a payer-origin word rather than zero padding. |
| `ADDRESS_MASK` | `uint160.max` | Mask used to recover the payer address from the trailing 32-byte word. |

## Access Control

None. `sellBase` and `sellQuote` are unrestricted — anyone can call them, and they invoke arbitrary `pool` addresses. Authorization is enforced by the downstream `PMMProtocol` via the maker signature.

<!-- TODO: Confirm with the team whether the aggregator deployment expects this adapter to be exposed publicly or only behind a trusted router. The contract itself imposes no restriction. -->

## Functions

External:

| Function | Mutability | Description |
|----------|-----------|-------------|
| `sellBase(address to, address pool, bytes memory moreInfo)` | nonpayable | Aggregator entry point. Reads a trailing 32-byte `payerOrigin` word via inline assembly (`calldataload(sub(calldatasize(), 32))`) and forwards to `_PMMSwap`. |
| `sellQuote(address to, address pool, bytes memory moreInfo)` | nonpayable | Identical behavior to `sellBase` — both exist to match the aggregator's `sellBase / sellQuote` interface contract. <!-- TODO: confirm with team whether sellBase and sellQuote have a semantic difference in the aggregator that this adapter does not need to reflect --> |

Internal:

| Function | Description |
|----------|-------------|
| `_PMMSwap(address to, address pool, bytes moreInfo, uint256 payerOrigin)` | Decodes `(bytes orderInfo, bytes signature, uint256 signatureType, uint256 orderType)` from `moreInfo`; dispatches to `_executeV1Order` / `_executeV2Order` / `_executeV3Order` by `orderType`. Reverts `"PMMAdapter: unsupported orderType"` otherwise. |
| `_executeV1Order(...)` / `_executeV2Order(...)` / `_executeV3Order(...)` | Decode the order in the matching `IPMMProtocolV*.OrderRFQ` shape; compute `flagsAndAmount = (signatureType == EIP1271 ? 1 << 254 : 0) + amount`; `SafeERC20.safeApprove(takerAsset, pool, amount)`; call `pool.fillOrderRFQTo(...)`; then `_handleRefund`. |
| `_handleRefund(address takerAsset, uint256 payerOrigin)` | If the trailing word matches `ORIGIN_PAYER`, recovers the payer address via `ADDRESS_MASK`; if the adapter still holds any `takerAsset`, transfers the leftover back to the payer via `SafeERC20.safeTransfer`. |
| `_call(address target, bytes data, uint256 rfqId)` | Low-level `call` to `pool` with the encoded fill payload. On revert, decodes the 4-byte custom-error selector and re-reverts as a human-readable `string` (e.g., `"RFQ_BadSignature 12345"`). |

## Events

`PMMAdapter` emits no events of its own. Fills emit `OrderFilledRFQ` from the downstream `PMMProtocol`.

## Custom Errors

`PMMAdapter` defines **no custom errors**. The `_call` function inspects the 4-byte selector of any revert returned by `pool.fillOrderRFQTo` and converts it into a `string` revert reason of the form `"<ErrorName> <rfqId>"`. The selectors it recognises (`_call` switch cases) include all `RFQ_*` errors from `Errors.sol` plus `SafeERC20` errors — see `terminology.md`.

## Security Patterns Used

- `SafeERC20.safeApprove` / `SafeERC20.safeTransfer` (OpenZeppelin) — used because the adapter approves an arbitrary `pool` for an arbitrary `takerAsset` per call. (Note: this is OpenZeppelin's `SafeERC20`, not the project's local `src/libraries/SafeERC20.sol` used by `PMMProtocol`.)
- `IERC20(takerAsset).balanceOf(address(this))` before each call — protects against double-spending unrelated balances and is the source of the refunded amount.
- Custom error → string revert decoding — surfaces the original `RFQ_*` reason and `rfqId` to the aggregator so a failed PMM leg can be diagnosed without parsing raw selectors.

## Key Invariants

- [Rule] `PMMAdapter` holds no permanent ERC-20 balance; any leftover is refunded inside `_handleRefund` within the same transaction.
- [Rule] `PMMAdapter._PMMSwap` only dispatches to recognised order versions (`1`, `2`, `3`); any other `orderType` reverts.
- [Rule] `flagsAndAmount` constructed inside the adapter never sets bits 253 (`_IS_VALID_SIGNATURE_65_BYTES`), 252 (`_UNWRAP_WETH_FLAG`), or 255 (`_MAKER_AMOUNT_FLAG`); only bit 254 (`_SIGNER_SMART_CONTRACT_HINT`) is conditionally set when `signatureType == SignatureType.EIP1271`.

<!-- TODO: Document whether the aggregator-side caller is expected to set bits 252/253/255 by passing them via `flagsAndAmount` directly to PMMProtocol on a separate path, since this adapter cannot encode them today -->
