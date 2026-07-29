---
name: "signature-replay"
description: "EIP-712 signature replay vectors and required mitigations for OrderRFQ"
---

# Pitfall: Signature Replay

## P-001: Cross-Chain Replay

- [Pitfall] An OrderRFQ signed for chain A MUST NOT be accepted on chain B.
- Trigger: `chainId` omitted from the EIP-712 domain separator.
- Correct approach: `EIP712._buildDomainSeparator` encodes `block.chainid` into the domain hash; the cached separator is rebuilt on chain-id divergence. Never remove the `chainId` field from `EIP712Domain`.

## P-002: Cross-Contract Replay

- [Pitfall] A signature issued for one `PMMProtocol` deployment MUST NOT work on a different deployment of the same contract on the same chain.
- Trigger: `verifyingContract` omitted from the domain separator.
- Correct approach: `EIP712._buildDomainSeparator` encodes `address(this)`. The cached separator is rebuilt if `address(this) != _CACHED_THIS` (defence against `DELEGATECALL`-style relocation).

## P-003: Single-Use Within Same Contract

- [Pitfall] After a successful fill of `(maker, rfqId)`, the same maker signature MUST NOT allow a second fill.
- Trigger: Forgetting to flip the bit in `_invalidator[maker]` before completing the fill.
- Correct approach: `_fillOrderRFQTo` calls `_invalidateOrder(maker, rfqId, 0)` at step 3.3 (before any external transfer); `_invalidateOrder` reverts `RFQ_InvalidatedOrder(rfqId)` if the bit is already set.

## P-004: Expired Signature Acceptance

- [Pitfall] Orders with `block.timestamp > order.expiry` MUST be rejected.
- Trigger: Missing or out-of-order expiry check.
- Correct approach: `_fillOrderRFQTo` (`PmmProtocol.sol:166-168`) reverts `RFQ_OrderExpired(rfqId)` before the invalidator update and before any transfer.

## P-005: ECDSA Signature Malleability (64 vs 65 bytes)

- [Pitfall] `ECDSA.recover` accepts both 65-byte canonical signatures and EIP-2098 64-byte compact signatures. A canonical signature and its compact form recover to the same signer — meaning the "same" signature has **two** byte representations.
- Trigger: Using the raw signature bytes (or their hash) as an idempotency key rather than the `(maker, rfqId)` pair.
- Correct approach: This protocol guards against the issue by tracking single-use at the `(maker, rfqId)` level via `_invalidator`. Off-chain systems MUST NOT rely on signature uniqueness for replay protection — see the comment in `src/libraries/ECDSA.sol:57-64`.

## P-006: Permit2 Signature ↔ OrderRFQ Signature Order Inversion

- [Pitfall] The Permit2 signature is hashed (`keccak256(order.permit2Signature)`) into the OrderRFQ struct hash. Signing the OrderRFQ first and then computing a fresh Permit2 signature breaks the binding.
- Trigger: Off-chain signer pipeline that emits the OrderRFQ digest before the Permit2 digest is finalised, then back-fills `permit2Signature` afterwards.
- Correct approach: Always sign the Permit2 payload first, embed the resulting 65-byte signature into `order.permit2Signature`, then compute the OrderRFQ digest and sign it. See `arch/eip712-signature-design.md` Section 3.

## P-007: Domain `NAME` / `VERSION` Drift

- [Pitfall] If `_NAME` or `_VERSION` is changed in the contract without updating off-chain signers, every new maker signature fails on-chain with `RFQ_BadSignature`.
- Trigger: A contract domain change without coordinated signer updates.
- Correct approach: Treat any change to `_NAME` / `_VERSION` as a breaking redeploy and update all signing integrations before deployment.

## P-008: ERC-1271 Hint Bit Misuse

- [Pitfall] An EOA maker mistakenly setting `_SIGNER_SMART_CONTRACT_HINT` causes the protocol to call `IERC1271.isValidSignature` on the EOA address. EOAs are not contracts → the staticcall returns success with empty data → verification fails with `RFQ_BadSignature`.
- Trigger: Taker / aggregator hard-codes the hint bit without checking whether the maker is a contract.
- Correct approach: Taker UI / aggregator should set bit 254 only when the maker's `code.length > 0`. The default path `ECDSA.recoverOrIsValidSignature` already handles both cases automatically, so the hint is an opt-in optimisation, not a required flag.
