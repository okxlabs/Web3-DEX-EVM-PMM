---
name: "contract-PMMProtocol"
description: "Main RFQ settlement contract — verifies maker signatures, transfers funds, tracks invalidator bitmap, applies time-slippage"
---

# Contract: PMMProtocol

Source: `src/PmmProtocol.sol` (pragma `0.8.17`).

## Purpose

`PMMProtocol` is the on-chain settlement endpoint for OKX Labs PMM RFQ orders. Takers (or aggregators) submit a signed `OrderRFQ` and the contract verifies the maker signature, applies amount math + settlement guardrails + time-slippage, transfers the maker leg (via standard ERC-20, Permit2 allowance, Permit2 signature, or Permit2 witness), optionally unwraps WETH for the maker leg, and transfers the taker leg.

## Inheritance

| Parent | Provides |
|--------|----------|
| `EIP712` (abstract) | Cached EIP-712 domain separator, `_domainSeparatorV4`, `_hashTypedDataV4` |
| `ReentrancyGuard` (OpenZeppelin 4.8.1) | `nonReentrant` modifier — `_status` storage slot 0 |

## State Variables

| Variable | Type | Slot | Mutable | Purpose |
|----------|------|------|---------|---------|
| `_status` | `uint256` | 0 | Yes (within tx) | Inherited from `ReentrancyGuard`. |
| `_invalidator` | `mapping(address => mapping(uint256 => uint256))` | 1 | Yes (set bits monotonically) | Per-maker 256-bit bitmap of used / cancelled rfqIds. Inner key = `rfqId >> 8`; bit = `uint8(rfqId)`. |
| `_WETH` | `IWETH` | immutable | No | WETH9 address for this chain. |

Constants (`PmmProtocol.sol:58-70`):

| Constant | Value | Purpose |
|----------|-------|---------|
| `_NAME` | `"OKX Labs PMM Protocol"` | EIP-712 domain name |
| `_VERSION` | `"1.1"` | EIP-712 domain version |
| `_RAW_CALL_GAS_LIMIT` | `5000` | Gas stipend for WETH-unwrap forwarding `.call` |
| `_MAKER_AMOUNT_FLAG` | `1 << 255` | flagsAndAmount bit 255 |
| `_SIGNER_SMART_CONTRACT_HINT` | `1 << 254` | flagsAndAmount bit 254 (ERC-1271) |
| `_IS_VALID_SIGNATURE_65_BYTES` | `1 << 253` | flagsAndAmount bit 253 (length pin) |
| `_UNWRAP_WETH_FLAG` | `1 << 252` | flagsAndAmount bit 252 (WETH unwrap) |
| `_SETTLE_LIMIT` / `_SETTLE_LIMIT_BASE` | `6000` / `10000` | 60% minimum fill ratio |
| `_CONFIDENCE_CAP_LIMIT` | `50000` | 5% hard cap on confidenceCap (1e6 units) |
| `_AMOUNT_MASK` | `uint160.max` | flagsAndAmount low-160-bit amount mask |

## Access Control

There are **no custom modifiers** beyond OpenZeppelin's `nonReentrant`. Authorization is enforced entirely via the maker's EIP-712 signature (verified inside each fill entrypoint) and the per-maker invalidator bitmap.

| Modifier | Condition | Protects |
|----------|-----------|----------|
| `nonReentrant` (OZ) | `_status != _ENTERED` | `fillOrderRFQTo`, `fillOrderRFQCompact`; `fillOrderRFQ` and `fillOrderRFQToWithPermit` inherit it transitively because they call `fillOrderRFQTo`. |

`cancelOrderRFQ` is **not** `nonReentrant`; it only writes to `_invalidator[msg.sender][...]` and emits an event, with no external calls.

## Functions

External / public:

| Function | Mutability | Modifiers | Description |
|----------|-----------|-----------|-------------|
| `DOMAIN_SEPARATOR()` | view | — | Returns `_domainSeparatorV4()` (EIP-712 domain separator). Selector `0x3644e515`. |
| `invalidatorForOrderRFQ(address maker, uint256 slot)` | view | — | Returns the raw 256-bit invalidator slot for a maker. |
| `isRfqIdUsed(address maker, uint64 rfqId)` | view | — | Returns `true` if the bit for `(maker, rfqId)` is set. |
| `fillOrderRFQ(OrderRFQ order, bytes signature, uint256 flagsAndAmount)` | payable | (via `fillOrderRFQTo`) | Convenience — fills to `msg.sender`. |
| `fillOrderRFQTo(OrderRFQ order, bytes signature, uint256 flagsAndAmount, address target)` | payable | `nonReentrant` | Primary fill entrypoint. Verifies the maker sig (EOA or ERC-1271), settles, emits `OrderFilledRFQ`. |
| `fillOrderRFQCompact(OrderRFQ order, bytes32 r, bytes32 vs, uint256 flagsAndAmount)` | payable | `nonReentrant` | EIP-2098 64-byte compact signature variant; fills to `msg.sender`. |
| `fillOrderRFQToWithPermit(OrderRFQ order, bytes signature, uint256 flagsAndAmount, address target, bytes permit)` | nonpayable | (via `fillOrderRFQTo`) | Executes an ERC-20 permit (EIP-2612 or Dai-style) on the taker asset, then calls `fillOrderRFQTo`. |
| `cancelOrderRFQ(uint64 rfqId)` | nonpayable | — | Maker (`msg.sender`) flips the bit for `rfqId`. Reverts `RFQ_OrderAlreadyCancelledOrUsed` if already set. Emits `OrderCancelledRFQ`. |
| `receive()` | payable | — | Accepts ETH **only** when `msg.sender == address(_WETH)` (i.e., WETH refund during unwrap). Otherwise reverts `RFQ_EthDepositRejected`. |

Private:

| Function | Description |
|----------|-------------|
| `_fillOrderRFQTo(OrderRFQ order, uint256 flagsAndAmount, address target)` | Core settlement logic — see `core-flows/pmm-fill-order.md`. |
| `_invalidateOrder(address maker, uint256 orderInfo, uint256 additionalMask)` | Marks the bit in `_invalidator[maker][slot]`. Reverts `RFQ_InvalidatedOrder(orderInfo)` if already set. |

## Events

| Event | Emitted When | Indexed Fields |
|-------|--------------|----------------|
| `OrderFilledRFQ(uint256 rfqId, uint256 expiry, address makerAsset, address takerAsset, address makerAddress, uint256 expectedMakerAmount, uint256 expectedTakerAmount, uint256 filledMakerAmount, uint256 filledTakerAmount, bool usePermit2, bytes permit2Signature, bytes32 permit2Witness, string permit2WitnessType)` | A fill succeeds in `fillOrderRFQTo` or `fillOrderRFQCompact`. Both quoted and actual filled amounts are reported. | `rfqId`, `makerAsset`, `takerAsset` |
| `OrderCancelledRFQ(uint256 rfqId, address maker)` | Maker successfully invalidates an rfqId via `cancelOrderRFQ`. | `rfqId`, `maker` |

## Custom Errors

See `terminology.md` for the complete `Errors.sol` table. All errors that originate in `PMMProtocol` carry `uint256 rfqId`, except `RFQ_EthDepositRejected()` (no parameters).

## Security Patterns Used

- `ReentrancyGuard` (OpenZeppelin) — `fillOrderRFQTo` and `fillOrderRFQCompact` are `nonReentrant`; needed because `_fillOrderRFQTo` performs external token transfers and a low-level ETH `.call` to `target`.
- EIP-712 typed-data signing — cached domain separator from `EIP712.sol`, struct hash from `OrderRFQLib`.
- ECDSA + ERC-1271 fan-out — `ECDSA.recoverOrIsValidSignature` accepts both EOA and contract signers; bits 254/253 of `flagsAndAmount` allow callers to opt into pure ERC-1271 verification and 65-byte length enforcement.
- `SafeERC20` from `src/libraries/SafeERC20.sol` (not OpenZeppelin's) — handles non-standard ERC-20s and Permit2 transfers (`safeTransferFromPermit2`, `safePermit` with EIP-2612/Dai-like auto-detect).
- RFQ-ID invalidator bitmap — single-use enforcement per `(maker, rfqId)`.
- Settlement guardrail — 60% minimum fill prevents dust attacks / price manipulation through tiny partial fills.
- Confidence reduction — bounded by `_CONFIDENCE_CAP_LIMIT = 5%` so makers cannot encode unbounded slippage.
- `msg.value` reconciled per leg — non-WETH taker asset requires `msg.value == 0`; WETH taker asset requires `msg.value == takerAmount`.

## Key Invariants

- [Rule] `_invalidator[maker][rfqId >> 8] & (1 << uint8(rfqId)) == 0` before a fill or cancel; `== 1` after.
- [Rule] Domain separator is bound to `(NAME, VERSION, block.chainid, address(this))` — never rebuilt with different inputs except via the immutable cached values.
- [Rule] `_fillOrderRFQTo` invalidates the rfqId **before** transferring any funds.
- [Rule] `receive()` accepts ETH only from `_WETH` — every other caller reverts with `RFQ_EthDepositRejected`.
- [Rule] `nonReentrant` guards every state-changing fill path; `cancelOrderRFQ` does not need it (no external calls).
