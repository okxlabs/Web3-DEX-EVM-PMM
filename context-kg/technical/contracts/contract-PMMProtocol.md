---
name: "contract-PMMProtocol"
description: "Main RFQ settlement contract — caller authorization on the single fillOrderRFQTo entry, maker signature verification, fund transfer, invalidator bitmap, and time-slippage"
type: "design"
title: "Contract: PMMProtocol"
tags: ["PMMProtocol", "settlement", "CallerAuth", "caller-binding", "fillOrderRFQTo", "orderType-4", "version-1.2", "anti-toxic-flow"]
sources: ["src/PmmProtocol.sol", "src/libraries/CallerAuth.sol", "src/OrderRFQLib.sol", "src/libraries/Errors.sol"]
last_updated: "2026-07-27"
---

# Contract: PMMProtocol

Source: `src/PmmProtocol.sol` (pragma `0.8.17`). Solidity name: `contract PMMProtocol`.

## Purpose

`PMMProtocol` is the on-chain settlement endpoint for PMM RFQ orders. Its single settlement function, `fillOrderRFQTo`, first validates `order.rfqId <= type(uint64).max` (else `RFQ_InvalidRfqId`), then verifies caller authorization over the exact order. It then verifies the maker signature, applies amount math, settlement guardrails and time-slippage, transfers the maker leg, optionally unwraps WETH, and transfers the taker leg. The protocol performs **no** `allowedSender` check; that check lives in `PMMAdapter` orderType=4.

## Inheritance

`contract PMMProtocol is EIP712, CallerAuth, ReentrancyGuard`.

| Parent | Provides |
|--------|----------|
| `EIP712` (abstract) | Cached EIP-712 domain separator, `_domainSeparatorV4`, `_hashTypedDataV4`. Only immutables, no storage slots. |
| `CallerAuth` (abstract) | Caller authorization: immutable `AUTH_SIGNER`, `_verifyCallerAuth`, `isNonceUsed`, append-only nonce bitmap (`_callerAuthNonceBitmap`, slot 0). See [[contract-CallerAuth]]. |
| `ReentrancyGuard` (OpenZeppelin 4.8.1) | `nonReentrant` modifier — `_status` storage slot 1 |

## State Variables

Storage layout verified via `forge inspect PMMProtocol storageLayout` — note the slots **shifted** because `CallerAuth` (inherited before `ReentrancyGuard`) contributes slot 0.

| Variable | Type | Slot | Mutable | Purpose |
|----------|------|------|---------|---------|
| `_callerAuthNonceBitmap` | `mapping(uint256 => uint256)` | 0 | Yes (set bits monotonically) | Inherited from `CallerAuth`. Permit2-style single-use nonce bitmap for caller-auth. Word = `nonce >> 8`, bit = `nonce & 0xff`. |
| `_status` | `uint256` | 1 | Yes (within tx) | Inherited from `ReentrancyGuard`. |
| `_invalidator` | `mapping(address => mapping(uint256 => uint256))` | 2 | Yes (set bits monotonically) | Per-maker 256-bit bitmap of used / cancelled rfqIds. Inner key = `rfqId >> 8`; bit = `uint8(rfqId)`. |
| `AUTH_SIGNER` | `address` | immutable | No | Inherited from `CallerAuth`. Caller-auth signer; zero rejected at deploy (`AUTH_ZeroSigner`). |
| `_WETH` | `IWETH` | immutable | No | WETH9 address for this chain. |

Constants (`PmmProtocol.sol:61-73`):

| Constant | Value | Purpose |
|----------|-------|---------|
| `_NAME` | `"OKX Labs PMM Protocol"` | EIP-712 domain name |
| `_VERSION` | `"1.2"` | EIP-712 domain version (bumped from `"1.1"` for the `allowedSender` field; old `1.1` maker sigs rejected) |
| `_RAW_CALL_GAS_LIMIT` | `5000` | Gas stipend for WETH-unwrap forwarding `.call` |
| `_MAKER_AMOUNT_FLAG` | `1 << 255` | flagsAndAmount bit 255 |
| `_SIGNER_SMART_CONTRACT_HINT` | `1 << 254` | flagsAndAmount bit 254 (ERC-1271) |
| `_IS_VALID_SIGNATURE_65_BYTES` | `1 << 253` | flagsAndAmount bit 253 (length pin) |
| `_UNWRAP_WETH_FLAG` | `1 << 252` | flagsAndAmount bit 252 (WETH unwrap) |
| `_SETTLE_LIMIT` / `_SETTLE_LIMIT_BASE` | `6000` / `10000` | 60% minimum fill ratio |
| `_CONFIDENCE_CAP_LIMIT` | `50000` | 5% hard cap on confidenceCap (1e6 units) |
| `_AMOUNT_MASK` | `uint160.max` | flagsAndAmount low-160-bit amount mask |

## Access Control

Besides OpenZeppelin's `nonReentrant`, settlement is now gated by the inherited **caller binding** — `fillOrderRFQTo` calls `_verifyCallerAuth(keccak256(abi.encode(order)), allowedCallers, nonce, authSig)` early, right after the initial `order.rfqId` range check. Authorization therefore has two axes: *who may call* (signed `allowedCallers == [PmmAdapter]`, enforced by `CallerAuth`) and *which exact order may be settled* (`payloadHash = keccak256(abi.encode(order))`, plus the maker's EIP-712 signature + per-maker invalidator bitmap). There is still no owner/admin role.

| Guard | Condition | Protects |
|-------|-----------|----------|
| `nonReentrant` (OZ) | `_status != _ENTERED` | `fillOrderRFQTo` |
| `_verifyCallerAuth` (CallerAuth) | `msg.sender ∈ allowedCallers` + valid unused `authSig` bound to `keccak256(abi.encode(order))` | `fillOrderRFQTo` — early, after the rfqId range check; else `AUTH_UntrustedCaller` / `AUTH_BadAuthSig` / `AUTH_NonceUsed` / `AUTH_BadSigLen` |

`cancelOrderRFQ` is **not** `nonReentrant` and is **not** caller-bound; it only writes to `_invalidator[msg.sender][...]` and emits an event, with no external calls (a maker cancels their own rfqId directly).

## Functions

External / public:

| Function | Mutability | Modifiers | Description |
|----------|-----------|-----------|-------------|
| `DOMAIN_SEPARATOR()` | view | — | Returns `_domainSeparatorV4()` (EIP-712 domain separator). Selector `0x3644e515`. |
| `AUTH_SIGNER()` | view | — | Inherited from `CallerAuth`. Immutable caller-auth signer. Selector `0x0a5c9024`. |
| `isNonceUsed(uint256 nonce)` | view | — | Inherited from `CallerAuth`. `true` if the caller-auth nonce is already consumed. Selector `0x5d00bb12`. |
| `invalidatorForOrderRFQ(address maker, uint256 slot)` | view | — | Returns the raw 256-bit invalidator slot for a maker. Selector `0x56f16124`. |
| `isRfqIdUsed(address maker, uint64 rfqId)` | view | — | Returns `true` if the bit for `(maker, rfqId)` is set. Selector `0x2154dec0`. |
| `fillOrderRFQTo(OrderRFQ order, bytes signature, uint256 flagsAndAmount, address target, address[] allowedCallers, uint256 nonce, bytes authSig)` | payable | `nonReentrant` | **The single settlement entry**. First rejects `order.rfqId > type(uint64).max` (`RFQ_InvalidRfqId`, before caller auth so no nonce is consumed), then `_verifyCallerAuth(keccak256(abi.encode(order)), allowedCallers, nonce, authSig)` (caller binding scoped to the exact order). Then verifies the maker sig (EOA or ERC-1271), settles, emits `OrderFilledRFQ`. Returns `(filledMakerAmount, filledTakerAmount, orderHash)`. **`order` is the 15-field OrderRFQ (incl. `allowedSender`)**; the protocol does not itself check `allowedSender`. |
| `cancelOrderRFQ(uint64 rfqId)` | nonpayable | — | Maker (`msg.sender`) flips the bit for `rfqId`. Reverts `RFQ_OrderAlreadyCancelledOrUsed` if already set. Emits `OrderCancelledRFQ`. Selector `0x76ef573a`. Not caller-bound. |
| `receive()` | payable | — | Accepts ETH **only** when `msg.sender == address(_WETH)` (i.e., WETH refund during unwrap). Otherwise reverts `RFQ_EthDepositRejected`. |

`fillOrderRFQ`, `fillOrderRFQCompact`, and `fillOrderRFQToWithPermit` do not exist in the current interface. Settlement uses the single caller-bound `fillOrderRFQTo` above.

Private:

| Function | Description |
|----------|-------------|
| `_fillOrderRFQTo(OrderRFQ order, uint256 flagsAndAmount, address target)` | Core settlement logic — see `core-flows/pmm-fill-order.md`. |
| `_invalidateOrder(address maker, uint256 orderInfo, uint256 additionalMask)` | Marks the bit in `_invalidator[maker][slot]`. Reverts `RFQ_InvalidatedOrder(orderInfo)` if already set. |

## Events

| Event | Emitted When | Indexed Fields |
|-------|--------------|----------------|
| `OrderFilledRFQ(uint256 rfqId, uint256 expiry, address makerAsset, address takerAsset, address makerAddress, address allowedSender, uint256 expectedMakerAmount, uint256 expectedTakerAmount, uint256 filledMakerAmount, uint256 filledTakerAmount, bool usePermit2, bytes permit2Signature, bytes32 permit2Witness, string permit2WitnessType)` | A fill succeeds in `fillOrderRFQTo`. Both quoted and actual filled amounts are reported, along with the order's `allowedSender` binding (non-indexed; enforcement happens in the adapter). | `rfqId`, `makerAsset`, `takerAsset` |
| `OrderCancelledRFQ(uint256 rfqId, address maker)` | Maker successfully invalidates an rfqId via `cancelOrderRFQ`. | `rfqId`, `maker` |

## Custom Errors

See `terminology.md` for the complete `Errors.sol` table. All `RFQ_*` errors that originate in `PMMProtocol` carry `uint256 rfqId`, except `RFQ_EthDepositRejected()` (no parameters). `RFQ_InvalidRfqId(uint256 rfqId)` is thrown first thing in `fillOrderRFQTo` when `order.rfqId > type(uint64).max` (the invalidator bitmap keys off the low 64 bits only).

Inherited from `CallerAuth` (all parameterless), surfaced by the early `_verifyCallerAuth`: `AUTH_ZeroSigner` (deploy-time), `AUTH_BadSigLen`, `AUTH_BadAuthSig`, `AUTH_UntrustedCaller`, `AUTH_NonceUsed`.

Note: **`RFQ_BadSender` is NOT thrown by `PMMProtocol`** — it is confirmed absent from the PMMProtocol ABI. The `allowedSender` anti-toxic check lives only in `PMMAdapter` (orderType=4).

## Security Patterns Used

- **Caller authorization (`CallerAuth`)** — `fillOrderRFQTo` verifies the signed `(payloadHash, allowedCallers, nonce)` tuple right after the rfqId range check; `payloadHash = keccak256(abi.encode(order))`. The nonce is consumed before any transfer.
- `ReentrancyGuard` (OpenZeppelin) — `fillOrderRFQTo` is `nonReentrant`; needed because `_fillOrderRFQTo` performs external token transfers and a low-level ETH `.call` to `target`.
- EIP-712 typed-data signing — cached domain separator from `EIP712.sol`, struct hash from `OrderRFQLib`.
- ECDSA + ERC-1271 fan-out — `ECDSA.recoverOrIsValidSignature` accepts both EOA and contract signers; bits 254/253 of `flagsAndAmount` allow callers to opt into pure ERC-1271 verification and 65-byte length enforcement.
- `SafeERC20` from `src/libraries/SafeERC20.sol` (not OpenZeppelin's) — handles non-standard ERC-20s and Permit2 transfers (`safeTransferFromPermit2`, `safePermit` with EIP-2612/Dai-like auto-detect).
- RFQ-ID invalidator bitmap — single-use enforcement per `(maker, rfqId)`.
- Settlement guardrail — 60% minimum fill prevents dust attacks / price manipulation through tiny partial fills.
- Confidence reduction — bounded by `_CONFIDENCE_CAP_LIMIT = 5%` so makers cannot encode unbounded slippage.
- `msg.value` reconciled per leg — non-WETH taker asset requires `msg.value == 0`; WETH taker asset paid with native ETH (`msg.value > 0`) requires `msg.value == takerAmount`, otherwise (`msg.value == 0`) WETH is pulled as a plain ERC-20.

## Key Invariants

- [Rule] `_invalidator[maker][rfqId >> 8] & (1 << uint8(rfqId)) == 0` before a fill or cancel; `== 1` after.
- [Rule] Domain separator is bound to `(NAME, VERSION, block.chainid, address(this))` — never rebuilt with different inputs except via the immutable cached values.
- [Rule] `_fillOrderRFQTo` invalidates the rfqId **before** transferring any funds.
- [Rule] `receive()` accepts ETH only from `_WETH` — every other caller reverts with `RFQ_EthDepositRejected`.
- [Rule] `nonReentrant` guards the fill path; `cancelOrderRFQ` does not need it (no external calls).
- [Rule] `fillOrderRFQTo` runs `_verifyCallerAuth` **before** computing the order hash or touching funds; `msg.sender` must be in the signed `allowedCallers` (`[PmmAdapter]`).
- [Rule] `AUTH_SIGNER` is immutable and non-zero (deploy rejects zero via `AUTH_ZeroSigner`); there is no setter.
- [Rule] The protocol performs **no** `allowedSender` check — `RFQ_BadSender` is not in the PMMProtocol ABI. The `allowedSender == dexRouterCaller` check is `PMMAdapter`'s responsibility.
