---
name: "token-handling"
description: "ERC-20, Permit2, and native ETH edge cases for OKX Labs PMM Protocol"
---

# Pitfall: Token Handling

## P-001: Non-Standard ERC-20 (USDT-style approve)

- [Pitfall] `IERC20.approve(spender, newAmount)` reverts on USDT when the current allowance is non-zero.
- Trigger: Calling bare `approve` against a token that requires the zero-then-set pattern.
- Correct approach: `PMMProtocol` uses the project's local `src/libraries/SafeERC20.sol` whose `forceApprove` retries `approve(spender, 0)` then `approve(spender, value)` on failure. `PMMAdapter`, however, uses OpenZeppelin's `safeApprove`, which does **not** auto-reset — if the adapter is reused across calls without explicit re-zeroing, USDT-style tokens may revert. <!-- TODO: Confirm whether the aggregator handles approval resets externally or whether PMMAdapter should be hardened to forceApprove -->

## P-002: Fee-on-Transfer Tokens

- [Pitfall] For fee-bearing tokens, `transferFrom(maker, target, amount)` delivers less than `amount` to `target`. `PMMProtocol` records `filledMakerAmount` from the **calculated** amount, not the actual received balance.
- Trigger: Maker quotes a fee-on-transfer token as `makerAsset`.
- Correct approach: The protocol explicitly does not support deflationary or rebasing tokens (see `PmmProtocol.sol:162-164` comments). Off-chain quoting must exclude these tokens; on-chain there is no balance-of-before/after measurement. If a fee-bearing maker asset is signed in error, the taker / target will receive less than `filledMakerAmount` reported in the event.

## P-003: Native ETH Identity

- [Pitfall] The protocol does **not** use a sentinel address (e.g. `0xEeee…eEEeE`) for native ETH. Native ETH is supported only via the WETH wrap/unwrap path, gated by `_UNWRAP_WETH_FLAG` and `msg.value` handling.
- Trigger: Caller passes `address(0)` (or any sentinel) as `makerAsset` / `takerAsset`.
- Correct approach: Always use the actual WETH9 address (`_WETH`) and the appropriate flag/`msg.value` combination — see `core-flows/pmm-fill-order.md` steps 9–12.

## P-004: WETH Unwrap to a Non-Receiving `target`

- [Pitfall] If `_UNWRAP_WETH_FLAG` is set and `target` does not accept ETH within the 5000-gas stipend (`_RAW_CALL_GAS_LIMIT`), the call reverts `RFQ_ETHTransferFailed` *after* the maker leg has already been pulled via Permit2 / safeTransferFrom — but inside the same atomic transaction, so all of the fill reverts.
- Trigger: `target` is a smart contract whose `receive` / `fallback` consumes >5000 gas.
- Correct approach: Aggregators must select a `target` that is either an EOA or a contract with a minimal `receive()` (≤ 5000 gas). Single-hop swaps to user EOAs are always safe.

## P-005: WETH Taker Leg Requires Exact `msg.value`

- [Pitfall] `takerAsset == WETH && msg.value > 0` requires `msg.value == takerAmount` exactly. Off-by-one or partial-fill mis-quoting yields `RFQ_InvalidMsgValue`.
- Trigger: Sending native ETH for a WETH taker leg without recomputing the new `takerAmount` after a partial fill bound (e.g. when the taker hits `_AMOUNT_MASK`).
- Correct approach: Compute `takerAmount` from `flagsAndAmount` on the client side using `AmountCalculator` semantics and send exactly that value. Alternatively, send WETH directly via `safeTransferFrom` (set `msg.value = 0`).

## P-006: Permit2 `uint160` Cap

- [Pitfall] The Permit2 allowance path accepts a maximum of `uint160.max` per transfer.
- Trigger: Full-fill of an order with `makerAmount > uint160.max` when `usePermit2 = true`. Reverts `RFQ_AmountTooLarge` (full-fill check) or `Permit2TransferAmountTooHigh` (allowance path) or — in the signature path — the Permit2 contract itself.
- Correct approach: For maker amounts beyond 2^160-1, set `usePermit2 = false` so the protocol falls back to `safeTransferFrom`.

## P-007: ERC-20 `permit` Spec Variance

- [Pitfall] `safePermit` auto-detects EIP-2612 (7-word payload, 32×7 bytes) vs Dai-style (8-word payload, 32×8 bytes) based on `permit.length`. Any other length reverts `SafePermitBadLength`.
- Trigger: Taker passes a permit blob in a non-canonical encoding (extra padding, missing field, or chain-specific variant).
- Correct approach: Use one of the two supported encodings exactly. `RevertReasonForwarder.reRevert()` will surface the underlying token's revert string when the call selector is correct but the permit signature is invalid.

## P-008: Adapter Refund Window

- [Pitfall] `PMMAdapter._handleRefund` only refunds when `(payerOrigin & ORIGIN_PAYER) == ORIGIN_PAYER`. Without the sentinel, any leftover `takerAsset` stays in the adapter and is consumed by the **next** caller (since `balanceOf` is used as the spend cap).
- Trigger: Aggregator forgets to append the payer-origin word, or appends a malformed word.
- Correct approach: Always append a trailing 32-byte word whose high bits match `ORIGIN_PAYER` (`0x3ca20afc2ccc…000`) and whose low 160 bits are the payer address; pre-flight any aggregator integration with a leftover-balance test.

<!-- TODO: Add cases specific to chain-dependent token quirks (e.g., USDC bridged variants, rebasing tokens on a particular L2) -->
