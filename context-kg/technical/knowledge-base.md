---
name: "knowledge-base"
description: "Highest-authority rules and constraints for OKX Labs PMM Protocol — AI Skills must never violate these (incl. single caller-bound fillOrderRFQTo, 15-field OrderRFQ, domain version 1.2, anti-toxic allowedSender)"
type: "design"
title: "Knowledge Base"
tags: ["knowledge-base", "hard-rules", "CallerAuth", "caller-binding", "allowedSender", "version-1.2", "orderType-4", "anti-toxic-flow"]
sources: ["src/PmmProtocol.sol", "src/PmmAdaptor.sol", "src/OrderRFQLib.sol", "src/libraries/CallerAuth.sol", "src/libraries/Constants.sol", "src/EIP712.sol"]
last_updated: "2026-07-27"
---

# Knowledge Base

> This is the highest-authority file in the knowledge base. All Skills supporting this project treat the rules below as hard constraints — they override general best-practice suggestions when they conflict.

---

## 0. Anti-Toxic-Flow / Caller Binding

- [Rule] The settlement entry is the **single** `fillOrderRFQTo(order, signature, flagsAndAmount, target, address[] allowedCallers, uint256 nonce, bytes authSig)`. The prior fill variants (`fillOrderRFQ`, `fillOrderRFQCompact`, `fillOrderRFQToWithPermit`) are **removed** — never reference them as live entrypoints.
- [Rule] `fillOrderRFQTo`'s first statement is the rfqId range check (`order.rfqId > type(uint64).max → RFQ_InvalidRfqId(rfqId)`, `PmmProtocol.sol:115-117`); `_verifyCallerAuth(keccak256(abi.encode(order)), allowedCallers, nonce, authSig)` (caller binding scoped to the exact `OrderRFQ`) runs immediately after it (`PmmProtocol.sol:118`). Never reorder caller-auth after the maker-signature check or fund movement.
- [Rule] `rfqId` **must** fit in `uint64` — `fillOrderRFQTo` reverts `RFQ_InvalidRfqId(rfqId)` for any `order.rfqId > type(uint64).max`, because the `_invalidator` replay bitmap keys off the low 64 bits only; a larger rfqId would alias another order's invalidator bit.
- [Rule] The `allowedSender == dexRouterCaller` anti-toxic check lives **only in `PMMAdapter` (orderType=4)** — `PMMProtocol` must **never** check `allowedSender` (verified: `RFQ_BadSender` is absent from the PMMProtocol ABI).
- [Rule] `AUTH_SIGNER` is `immutable`, set in the constructor of both `PMMProtocol` and `PMMAdapter`; a zero signer is rejected at deploy (`AUTH_ZeroSigner`). Never add a setter.
- [Rule] Caller-auth uses an append-only Permit2-style nonce bitmap (`_callerAuthNonceBitmap`, storage slot 0 in both contracts); the nonce is consumed in `_verify*` before any external call (CEI). `authSig` must be EIP-2098 64-byte compact (else `AUTH_BadSigLen`).
- [Rule] PMM caller-auth digest binds `payloadHash = keccak256(abi.encode(order))`, so a valid `adaptorAuth` / `protocolAuth` cannot be replayed against a different `OrderRFQ`. Caller-auth no longer has a standalone `expiry`; order freshness remains enforced by `order.expiry` and RFQ replay remains enforced by `rfqId`.
- [Rule] `_extractDexRouterCaller` reads calldata `-64` with an **exact** marker match (`word & MARKER_MASK == DEX_ROUTER_CALLER_MARKER`) and fail-closes to `address(0)`; `_handleRefund` independently reads `-32` with `word & MARKER_MASK == ORIGIN_PAYER`. Never conflate or allow subset aliases between the two markers.
- [Rule] Legacy `orderType ∈ {1,2,3}` adapter paths must stay caller-auth-free and allowedSender-free for backward compatibility.

---

## 1. Security Constraints

- [Rule] The single fill entrypoint `fillOrderRFQTo` **must** route through `nonReentrant` — `_fillOrderRFQTo` performs external token transfers and a low-level ETH `.call`, which is the reentrancy surface. Adapter `sellBase`/`sellQuote` are also `nonReentrant`.
- [Rule] `_invalidateOrder` **must** be called before any maker leg transfer in `_fillOrderRFQTo` (checks-effects-interactions); **never** transfer first then invalidate
- [Rule] Every external low-level `.call{value}` (currently only the WETH-unwrap path in `_fillOrderRFQTo`) **must** check the return value and revert on failure with `RFQ_ETHTransferFailed`
- [Rule] EIP-712 domain separator **must** include both `chainId` and `verifyingContract` — `EIP712._buildDomainSeparator` encodes both, so any change to `EIP712.sol` must preserve this
- [Rule] `order.expiry` **must** be checked (`block.timestamp > expiry → RFQ_OrderExpired`) before any state change in `_fillOrderRFQTo`
- [Rule] When `flagsAndAmount & _IS_VALID_SIGNATURE_65_BYTES != 0`, signature length **must** be exactly 65 bytes; the malleability of 64-vs-65-byte signatures (documented in `ECDSA.recover`) is mitigated by also tracking RFQ IDs in the invalidator bitmap

---

## 2. Architecture Constraints

- [Rule] `_WETH` is `immutable` and set once in the `PMMProtocol` constructor — **never** add a setter; redeploy for a new WETH address
- [Rule] `_NAME = "OKX Labs PMM Protocol"` and `_VERSION = "1.2"` constants in `PmmProtocol.sol` are bound into the cached domain separator at construction — changing either invalidates every outstanding maker signature. The `1.1 → 1.2` bump for the `allowedSender` field invalidated all `1.1` signatures.
- [Rule] `_invalidator[maker][slot]` is keyed by maker first, then by `rfqId >> 8`; maker bitmaps **must** be independent — **never** share a slot across makers. (Storage slot is now **2** in `PMMProtocol`; `CallerAuth`'s nonce bitmap took slot 0 and `_status` slot 1.)
- [Rule] `PMMAdapter` supports V1/V2/V3 (legacy) and V4/orderType=4 (anti-toxic) `OrderRFQ` shapes via `orderType` dispatch; **never** remove a V1/V2/V3 branch without coordinating an aggregator migration (older orders still in flight will revert)
- [Rule] `receive()` on `PMMProtocol` rejects any ETH not sent by `_WETH` — **never** loosen this to accept generic deposits
- [Rule] `PMMAdapter` inherits `CallerAuth` + `ReentrancyGuard` and now carries caller-auth nonce/reentrancy storage; it is no longer a stateless pure-dispatch layer. It has no owner/admin, but orderType=4 is caller-bound.
- [Rule] `cancelOrderRFQ` is callable by any address; the cancellation only affects the caller's own maker bitmap (`maker = msg.sender`), so cancelling for another maker is impossible by construction

---

## 3. Off-Chain Integration Constraints

- [Rule] Maker EIP-712 signature **must** cover all **15** OrderRFQ fields in the order declared in `_LIMIT_ORDER_RFQ_TYPEHASH`: `rfqId, expiry, makerAsset, takerAsset, makerAddress, makerAmount, takerAmount, usePermit2, address allowedSender, confidenceT, confidenceWeight, confidenceCap, bytes permit2Signature, bytes32 permit2Witness, string permit2WitnessType` — `allowedSender` sits at index 8 (between `usePermit2` and `confidenceT`); omitting or misplacing any field produces a different digest and fails `ECDSA.recoverOrIsValidSignature`. The struct, typehash string, and `abi.encode` in `hash()` **must** agree three-way.
- [Rule] `permit2Signature` (`bytes`) and `permit2WitnessType` (`string`) **must** be hashed with `keccak256` before being placed in the EIP-712 struct hash; `permit2Witness` (`bytes32`) is encoded directly without hashing — see `OrderRFQLib.hash`
- [Rule] When `usePermit2 = true` and `permit2Signature` is non-empty, the Permit2 signature **must** be signed against the Permit2 domain separator (3-field: name, chainId, verifyingContract — **no version field**) before the OrderRFQ signature, because the OrderRFQ struct hash depends on `keccak256(permit2Signature)`
- [Rule] Permit2 `nonce` **must** be set to `order.rfqId`; `deadline` **must** be set to `order.expiry` — signing different values produces mismatched digests
- [Rule] `confidenceCap` **must** be ≤ `50000` (5% in 1e6 units) — any larger value reverts with `RFQ_ConfidenceCapExceeded`
- [Rule] `confidenceT`, `confidenceWeight`, `confidenceCap` are all required for time-slippage; if any is zero the mechanism is fully disabled (no partial behavior)
- [Rule] `flagsAndAmount` low 160 bits encode the requested amount; bits 252–255 are reserved flags (`_UNWRAP_WETH_FLAG`, `_IS_VALID_SIGNATURE_65_BYTES`, `_SIGNER_SMART_CONTRACT_HINT`, `_MAKER_AMOUNT_FLAG`) — never overflow the amount mask
- [Rule] Settlement limit (`_SETTLE_LIMIT / _SETTLE_LIMIT_BASE = 60%`) is checked **before** the confidence reduction; quote estimates must apply confidence math to the post-fill maker amount, not to the settle-limit input

---

## 4. Testing Constraints

- [Rule] Signature generation in tests **must** use `vm.sign(privateKey, digest)` — **never** hardcode signature bytes
- [Rule] Fork tests **must** use named RPC endpoints from `foundry.toml` (e.g., `vm.createSelectFork("arbitrum")`); **never** rely on `"latest"` block when block determinism matters
- [Rule] Every custom-error revert path in `Errors.sol` **must** have a `testRevert*` case asserting the specific selector via `vm.expectRevert(abi.encodeWithSelector(...))`; **never** use bare `vm.expectRevert()` without a selector when the path emits a custom error

---

## 5. Reference Index

| File / Directory | Contents |
|-----------------|----------|
| `terminology.md` | Roles, OrderRFQ field definitions, flag bits, storage slots |
| `arch/architecture-overview.md` | Contract inventory, interaction diagram, deployment params |
| `arch/eip712-signature-design.md` | Domain separator, OrderRFQ typehash, verification order |
| `contracts/contract-PMMProtocol.md` | Main settlement contract reference (single caller-bound fillOrderRFQTo) |
| `contracts/contract-PMMAdapter.md` | Aggregator adapter reference (V1/V2/V3 legacy + orderType=4 anti-toxic dispatch) |
| `contracts/contract-CallerAuth.md` | Caller-authorization base — payloadHash, allowedCallers, nonce bitmap, dexRouterCaller |
| `contracts/contract-EIP712.md` | EIP-712 base — cached domain separator |
| `core-flows/pmm-fill-order.md` | Taker fill flow trace |
| `core-flows/pmm-cancel-order.md` | Maker cancel flow trace |
| `core-flows/pmm-adapter-route.md` | Aggregator → adapter → protocol trace |
| `pitfalls/signature-replay.md` | EIP-712 replay vectors |
| `pitfalls/token-handling.md` | ERC-20 / Permit2 edge cases |
| `conventions/solidity.md` | Solidity coding conventions |
| `conventions/testing-patterns.md` | Foundry testing conventions |
