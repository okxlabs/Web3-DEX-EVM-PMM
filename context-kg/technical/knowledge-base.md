---
name: "knowledge-base"
description: "Highest-authority rules and constraints for OKX Labs PMM Protocol — AI Skills must never violate these"
---

# Knowledge Base

> This is the highest-authority file in the knowledge base. All Skills supporting this project treat the rules below as hard constraints — they override general best-practice suggestions when they conflict.

---

## 1. Security Constraints

- [Rule] All four maker-callable fill entrypoints (`fillOrderRFQ`, `fillOrderRFQTo`, `fillOrderRFQCompact`, `fillOrderRFQToWithPermit`) **must** route through `nonReentrant` — `_fillOrderRFQTo` performs external token transfers and a low-level ETH `.call`, which is the reentrancy surface
- [Rule] `_invalidateOrder` **must** be called before any maker leg transfer in `_fillOrderRFQTo` (checks-effects-interactions); **never** transfer first then invalidate
- [Rule] Every external low-level `.call{value}` (currently only the WETH-unwrap path in `_fillOrderRFQTo`) **must** check the return value and revert on failure with `RFQ_ETHTransferFailed`
- [Rule] EIP-712 domain separator **must** include both `chainId` and `verifyingContract` — `EIP712._buildDomainSeparator` encodes both, so any change to `EIP712.sol` must preserve this
- [Rule] `order.expiry` **must** be checked (`block.timestamp > expiry → RFQ_OrderExpired`) before any state change in `_fillOrderRFQTo`
- [Rule] When `flagsAndAmount & _IS_VALID_SIGNATURE_65_BYTES != 0`, signature length **must** be exactly 65 bytes; the malleability of 64-vs-65-byte signatures (documented in `ECDSA.recover`) is mitigated by also tracking RFQ IDs in the invalidator bitmap

---

## 2. Architecture Constraints

- [Rule] `_WETH` is `immutable` and set once in the `PMMProtocol` constructor — **never** add a setter; redeploy for a new WETH address
- [Rule] `_NAME = "OKX Labs PMM Protocol"` and `_VERSION = "1.1"` constants in `PmmProtocol.sol` are bound into the cached domain separator at construction — changing either invalidates every outstanding maker signature
- [Rule] `_invalidator[maker][slot]` is keyed by maker first, then by `rfqId >> 8`; maker bitmaps **must** be independent — **never** share a slot across makers
- [Rule] `PMMAdapter` supports V1/V2/V3 `OrderRFQ` shapes via `orderType` dispatch; **never** remove a V1/V2 branch without coordinating an aggregator migration (older orders still in flight will revert)
- [Rule] `receive()` on `PMMProtocol` rejects any ETH not sent by `_WETH` — **never** loosen this to accept generic deposits
- [Rule] `PMMAdapter` has no state variables and no privileged functions; it is a pure dispatch layer
- [Rule] `cancelOrderRFQ` is callable by any address; the cancellation only affects the caller's own maker bitmap (`maker = msg.sender`), so cancelling for another maker is impossible by construction

---

## 3. Backend Integration Constraints

- [Rule] Maker EIP-712 signature **must** cover all 14 OrderRFQ fields in the order declared in `_LIMIT_ORDER_RFQ_TYPEHASH`: `rfqId, expiry, makerAsset, takerAsset, makerAddress, makerAmount, takerAmount, usePermit2, confidenceT, confidenceWeight, confidenceCap, bytes permit2Signature, bytes32 permit2Witness, string permit2WitnessType` — omitting any field will produce a different digest and fail `ECDSA.recoverOrIsValidSignature`
- [Rule] `permit2Signature` (`bytes`) and `permit2WitnessType` (`string`) **must** be hashed with `keccak256` before being placed in the EIP-712 struct hash; `permit2Witness` (`bytes32`) is encoded directly without hashing — see `OrderRFQLib.hash`
- [Rule] When `usePermit2 = true` and `permit2Signature` is non-empty, the Permit2 signature **must** be signed against the Permit2 domain separator (3-field: name, chainId, verifyingContract — **no version field**) before the OrderRFQ signature, because the OrderRFQ struct hash depends on `keccak256(permit2Signature)`
- [Rule] Permit2 `nonce` **must** be set to `order.rfqId`; `deadline` **must** be set to `order.expiry` — these are bound on-chain inside `_fillOrderRFQTo` and a backend that signs different values will produce mismatched digests
- [Rule] `confidenceCap` **must** be ≤ `50000` (5% in 1e6 units) — any larger value reverts with `RFQ_ConfidenceCapExceeded`
- [Rule] `confidenceT`, `confidenceWeight`, `confidenceCap` are all required for time-slippage; if any is zero the mechanism is fully disabled (no partial behavior)
- [Rule] `flagsAndAmount` low 160 bits encode the requested amount; bits 252–255 are reserved flags (`_UNWRAP_WETH_FLAG`, `_IS_VALID_SIGNATURE_65_BYTES`, `_SIGNER_SMART_CONTRACT_HINT`, `_MAKER_AMOUNT_FLAG`) — never overflow the amount mask
- [Rule] Settlement limit (`_SETTLE_LIMIT / _SETTLE_LIMIT_BASE = 60%`) is checked **before** the confidence reduction; a backend must apply confidence cap math to the post-fill maker amount and present it as an estimate, not as the settle-limit input

---

## 4. Testing Constraints

- [Rule] Signature generation in tests **must** use `vm.sign(privateKey, digest)` — **never** hardcode signature bytes
- [Rule] Fork tests **must** use named RPC endpoints from `foundry.toml` (e.g., `vm.createSelectFork("arbitrum")`); **never** rely on `"latest"` block when block determinism matters
- [Rule] Every custom-error revert path in `Errors.sol` **must** have a `testRevert*` case asserting the specific selector via `vm.expectRevert(abi.encodeWithSelector(...))`; **never** use bare `vm.expectRevert()` without a selector when the path emits a custom error

---

## 5. Git / PR Constraints

- [Rule] Branch naming: `feat/` / `fix/` / `refactor/` / `docs/` / `chore/` + short description
- [Rule] Commit messages in English, focused on why (not what)
- [Rule] PR body must include Summary and Test plan
- [Rule] **never** `--no-verify` to skip hooks unless the user explicitly requests it
- [Rule] **never** force push to main / master
- [Rule] Changes that touch `OrderRFQLib._LIMIT_ORDER_RFQ_TYPEHASH` or `_NAME`/`_VERSION` constants **must** be flagged in the PR body as breaking for off-chain signers

---

## 6. Reference Index

| File / Directory | Contents |
|-----------------|----------|
| `terminology.md` | Roles, OrderRFQ field definitions, flag bits, storage slots |
| `arch/architecture-overview.md` | Contract inventory, interaction diagram, deployment params |
| `arch/eip712-signature-design.md` | Domain separator, OrderRFQ typehash, verification order |
| `contracts/contract-PMMProtocol.md` | Main settlement contract reference |
| `contracts/contract-PMMAdapter.md` | Aggregator adapter reference (V1/V2/V3 dispatch) |
| `contracts/contract-EIP712.md` | EIP-712 base — cached domain separator |
| `core-flows/pmm-fill-order.md` | Taker fill flow trace |
| `core-flows/pmm-cancel-order.md` | Maker cancel flow trace |
| `core-flows/pmm-adapter-route.md` | Aggregator → adapter → protocol trace |
| `pitfalls/signature-replay.md` | EIP-712 replay vectors |
| `pitfalls/token-handling.md` | ERC-20 / Permit2 edge cases |
| `conventions/solidity.md` | Solidity coding conventions |
| `conventions/testing-patterns.md` | Foundry testing conventions |
