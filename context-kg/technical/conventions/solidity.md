---
name: "solidity-conventions"
description: "Solidity coding conventions for OKX Labs PMM Protocol"
---

# Solidity Conventions

## Token Transfers

- [Rule] All ERC-20 transfers from inside `PMMProtocol` use the project's local `src/libraries/SafeERC20.sol` — never `IERC20.transferFrom` directly.
- [Rule] `PMMAdapter` uses OpenZeppelin's `@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol` for `safeApprove` / `safeTransfer`. Do not mix the two libraries within the same contract; the adapter intentionally relies on OZ to match its aggregator integration history.
- [Rule] Native ETH is identified by the immutable WETH9 address (`_WETH`). The project does **not** use an `ETH_ADDRESS` sentinel like `0xEeee…eEEeE`.
- [Rule] WETH unwrap forwards ETH via a low-level `.call{value, gas: 5000}` — recipient contracts must accept ETH within 5 000 gas.

## Error Handling

- [Rule] Use custom errors over `require` with strings. All `RFQ_*` errors live in `src/libraries/Errors.sol`.
- [Rule] Every custom error carries `uint256 rfqId` so the adapter and downstream clients can correlate failures to specific orders. The only exception is `RFQ_EthDepositRejected()` (no rfq context exists at that callsite).
- [Rule] `PMMAdapter._call` decodes downstream custom errors by 4-byte selector and re-reverts as a `string` of the form `"<ErrorName> <rfqId>"`. Any new custom error in `Errors.sol` MUST also be added to the `_call` switch — otherwise the adapter falls through to the generic `"RFQ_Failed <rfqId>"`.

## Mathematical Safety

- [Rule] Solidity `0.8.x` checked arithmetic is the default — no `unchecked` blocks are used in `src/` today.
- [Rule] `AmountCalculator.getMakerAmount` floors; `AmountCalculator.getTakerAmount` ceils — the ceiling math is intentional to avoid the taker under-paying due to integer division (`(swapMakerAmount * orderTakerAmount + orderMakerAmount - 1) / orderMakerAmount`).
- [Rule] Confidence reduction must compute `makerAmount - makerAmount * cutdownPercentageX6 / 1e6` in that exact order — never reorder to avoid precision loss.

## Immutables and Constants

- [Rule] Values fixed at construction MUST be declared `immutable` (e.g. `_WETH`, the `EIP712` cached fields).
- [Rule] Compile-time-known magic numbers MUST be named `constant` — never use bare literals for flag bits or settlement ratios.
- [Rule] Flag-bit constants are written as `1 << N` (not hex masks) to keep the bit position obvious.

## Compiler Version

- [Rule] Top-level contracts target `pragma solidity 0.8.17` (pinned exact version — never floating `^`). Project libraries `SafeERC20` and `ECDSA` use `^0.8.0` because they are imported from external code; the production build resolves them to 0.8.17 via `foundry.toml`.
- [Rule] `evm_version = "london"` in `foundry.toml`. Do not rely on shanghai / cancun opcodes (no `PUSH0`, no transient storage).
- [Rule] `via_ir = true` is enabled. New code MUST be tested under IR — the `OrderRFQLib.hash` manual struct encoding exists specifically to avoid the IR pipeline's "stack too deep" failure on nested memory structs.

## Assembly

- [Rule] Inline assembly is restricted to `src/libraries/` (`SafeERC20`, `ECDSA`) and to the two `calldataload(sub(calldatasize(), 32))` payer-extraction blocks in `PmmAdaptor.sol`. New assembly outside these locations requires explicit review.
- [Rule] Every `assembly` block in `SafeERC20` / `ECDSA` is tagged `memory-safe` (`/// @solidity memory-safe-assembly`). Maintain this annotation when modifying — IR optimisation correctness depends on it.

## NatSpec

- [Rule] All external / public functions in `PMMProtocol` SHOULD have `@notice`. The current source documents events fully (`OrderFilledRFQ`, `OrderCancelledRFQ`) but external functions are lightly commented — additions should include `@notice` and parameter docs.
- [Rule] Non-obvious `revert` conditions (e.g. the post-confidence settlement-limit ordering) have inline comments — preserve them when refactoring.

## Lint Warnings That Are Expected

`forge build` surfaces the following warnings on `src/` today; they are known and **not** to be "fixed" without coordination:

- `unsafe-typecast` on `uint8(rfqId)` / `uint64(orderInfo)` in `_invalidateOrder` and `isRfqIdUsed` — the truncation is intentional (we want the low 8 / 64 bits as the bitmap index).
- `incorrect-shift` on `1 << uint8(orderInfo)` — left operand is `1`; the lint heuristic mis-identifies the constant as the shift amount.
- `block-timestamp` on the expiry check and confidence check — `block.timestamp` is the correct authority for both; validator manipulation by a few seconds is within the design tolerance.
- `erc20-unchecked-transfer` on `_WETH.transfer(maker, takerAmount)` — `_WETH` is a known WETH9 contract whose `transfer` returns `true` on success.
- `unsafe-typecast` on `uint160(uint256(payerOrigin) & ADDRESS_MASK)` in `PMMAdapter._handleRefund` — the mask is the explicit truncation guarantee.

If a new warning of one of these classes appears in unrelated code, treat it as a bug and resolve it; do not silence existing ones without team review.
