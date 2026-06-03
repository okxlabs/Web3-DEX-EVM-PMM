---
name: "architecture-overview"
description: "Contract system architecture, role model, and component relationships for OKX Labs PMM Protocol"
---

# Architecture Overview

## System Purpose

OKX Labs PMM is the on-chain settlement layer for an RFQ (request-for-quote) routing stack. Off-chain market makers sign `OrderRFQ` structs that takers — directly or via an aggregator — fill on-chain through `PMMProtocol`. The system enforces EIP-712 maker authentication, RFQ-ID replay protection, Permit2-based maker transfers, optional WETH unwrap, and a time-based slippage ("confidence") mechanism for stale quotes.

## Contract Inventory

| Contract | Pragma | Inherits | Role in System |
|----------|--------|----------|----------------|
| `PMMProtocol` | `0.8.17` | `EIP712`, `ReentrancyGuard` | Main settlement contract. Verifies maker signatures, transfers maker/taker funds, applies confidence reduction, tracks RFQ-ID invalidator bitmap. |
| `PMMAdapter` | `0.8.17` | _none_ | Aggregator-side adapter. `sellBase` / `sellQuote` decode `OrderRFQ` (V1/V2/V3) and forward to a `PMMProtocol` (called `pool`) instance via `_call`; handles refund of unused taker balance. |
| `EIP712` (abstract) | `0.8.17` | _none_ | Provides the cached EIP-712 domain separator and `_hashTypedDataV4`. Inherited by `PMMProtocol`. |
| `OrderRFQLib` (library) | `0.8.17` | _none_ | Defines the `OrderRFQ` struct (14 fields) and `_LIMIT_ORDER_RFQ_TYPEHASH`; computes the EIP-712 struct hash via `hash(order, domainSeparator)`. |
| `ECDSA` (library) | `^0.8.0` | _none_ | Signature recovery (65-byte and EIP-2098 64-byte), ERC-1271 fallback (`isValidSignature` variants), and `toTypedDataHash`. |
| `SafeERC20` (library) | `^0.8.0` | _none_ | Safe ERC-20 wrappers + `safeTransferFromPermit2` + `safePermit` (auto-detects EIP-2612 vs Dai-style). Defines the `_PERMIT2` canonical address. |
| `AmountCalculator` (library) | `0.8.17` | _none_ | Floored maker / ceiled taker amount derivation for partial fills. |
| `Errors` (library) | `0.8.17` | _none_ | All `RFQ_*` custom error definitions used by `PMMProtocol`. |
| `RevertReasonForwarder` (library) | `0.8.17` | _none_ | Bubbles up the original revert reason from `safePermit`. |

## Role & Permission Matrix

The protocol has **no privileged roles** — there is no owner, no admin, and no role-based access control (no custom modifiers, no `Ownable`). Authorization is enforced entirely through EIP-712 signatures and per-maker invalidator bitmaps.

| Role | How Granted | Contract | Permitted Operations |
|------|-------------|----------|---------------------|
| Maker | Signs `OrderRFQ` against `PMMProtocol` domain | `PMMProtocol` | Authorize fills of their own quotes; call `cancelOrderRFQ(uint64)` to invalidate their own RFQ IDs |
| Taker | Calls `fillOrderRFQ*` with a valid maker signature | `PMMProtocol` | Trigger a fill against any in-force maker quote |
| Anyone | — | `PMMProtocol` | Read `DOMAIN_SEPARATOR()`, `invalidatorForOrderRFQ(maker, slot)`, `isRfqIdUsed(maker, rfqId)` |
| Aggregator | Calls `PMMAdapter.sellBase` / `sellQuote` | `PMMAdapter` | Decode V1/V2/V3 orders and call `PMMProtocol.fillOrderRFQTo` |
| `_WETH` only | Identified by `address(_WETH)` | `PMMProtocol::receive` | Send ETH to the protocol (any other sender reverts `RFQ_EthDepositRejected`) |

<!-- TODO: Document whether the aggregator address is fixed or whether any contract may legitimately call PMMAdapter -->

## Contract Interaction Diagram

```
                          ┌─────────────────────┐
                          │ Off-chain Maker     │
                          │ (signs OrderRFQ)    │
                          └─────────┬───────────┘
                                    │ signature
                                    ▼
 ┌──────────────┐ sellBase/  ┌──────────────┐  fillOrderRFQTo  ┌──────────────────┐
 │ Aggregator   │ sellQuote  │ PMMAdapter   │ ───────────────► │ PMMProtocol      │
 │ (router)     │ ──────────►│ (V1/V2/V3)   │                  │ - EIP712         │
 └──────────────┘            └──────────────┘                  │ - ReentrancyGuard│
                                                               └────────┬─────────┘
                                                                        │
                                                                        │ uses
                                                                        ▼
                                       ┌─────────────────────────────────────────────┐
                                       │  OrderRFQLib (hash)                         │
                                       │  ECDSA (recover/isValidSignature)           │
                                       │  SafeERC20 (transferFrom, Permit2 transfer) │
                                       │  AmountCalculator (partial-fill math)       │
                                       │  Errors (RFQ_*)                             │
                                       └─────────────────────────────────────────────┘

 Direct path (no aggregator):

 ┌──────────────┐    fillOrderRFQ*    ┌──────────────────┐
 │ Taker EOA    │ ──────────────────► │ PMMProtocol      │
 └──────────────┘                     └──────────────────┘

 External dependencies:
   - WETH9 (immutable address per chain)
   - Uniswap Permit2 (0x000000000022D473030F116dDEE9F6B43aC78BA3)
```

## Key Invariants

- After a successful fill of `order.rfqId` for a given `maker`, `isRfqIdUsed(maker, rfqId)` returns `true` and any subsequent fill or cancel for the same `(maker, rfqId)` reverts with `RFQ_InvalidatedOrder` or `RFQ_OrderAlreadyCancelledOrUsed`.
- `block.timestamp <= order.expiry` for every accepted fill.
- For every accepted fill, both legs satisfy `filledMakerAmount ≥ 60% * order.makerAmount` and `filledTakerAmount ≥ 60% * order.takerAmount` evaluated **before** confidence reduction.
- Confidence reduction is applied only when `confidenceT > 0`, `block.timestamp > confidenceT`, and `confidenceWeight, confidenceCap` are both non-zero; the reduction never exceeds `confidenceCap`, which itself is bounded by `_CONFIDENCE_CAP_LIMIT = 50000` (5%).
- `_invalidator[maker][slot]` is monotonically increasing in popcount — bits can be set but never cleared.
- `PMMProtocol` holds no ERC-20 balance between transactions (CEI: maker leg in, taker leg out within a single `_fillOrderRFQTo`). The only transient balance is the WETH it withdraws into native ETH before forwarding to `target`.

## Deployment Parameters

`PMMProtocol`:

| Parameter | Contract | Mutable After Deploy | Set By |
|-----------|----------|---------------------|--------|
| `weth` (constructor) | `PMMProtocol` | No (`immutable _WETH`) | Deployer |
| `_NAME` | `PMMProtocol` | No (`constant`) | Source code (`"OKX Labs PMM Protocol"`) |
| `_VERSION` | `PMMProtocol` | No (`constant`) | Source code (`"1.1"`) |

`PMMAdapter`:

| Parameter | Contract | Mutable After Deploy | Set By |
|-----------|----------|---------------------|--------|
| — | `PMMAdapter` | — | Constructor takes no arguments; the `pool` address (a `PMMProtocol`) is supplied per-call by the aggregator |

Deployment scripts: `scripts/Deploy.s.sol`. Live address table maintained in `DEPLOYMENT.md` (V1/V2/V3 history).
