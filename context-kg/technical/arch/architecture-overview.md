---
name: "architecture-overview"
description: "Contract system architecture, role model (EIP-712 maker auth + signed caller authorization), and component relationships for OKX Labs PMM Protocol"
type: "design"
title: "Architecture Overview"
tags: ["architecture", "contract-inventory", "role-model", "CallerAuth", "caller-binding", "anti-toxic-flow", "orderType-4"]
sources: ["src/PmmProtocol.sol", "src/PmmAdaptor.sol", "src/EIP712.sol", "src/OrderRFQLib.sol", "src/libraries/CallerAuth.sol", "src/libraries/Constants.sol", "src/libraries/Errors.sol"]
last_updated: "2026-07-27"
---

# Architecture Overview

## System Purpose

OKX Labs PMM is the on-chain settlement layer for an RFQ (request-for-quote) routing stack. Off-chain market makers sign `OrderRFQ` structs that takers fill on-chain through `PMMProtocol`. The system enforces EIP-712 maker authentication, RFQ-ID replay protection, Permit2-based maker transfers, optional WETH unwrap, a time-based slippage ("confidence") mechanism, signed **caller authorization**, and a per-order `allowedSender` check.

## Contract Inventory

| Contract | Pragma | Inherits | Role in System |
|----------|--------|----------|----------------|
| `PMMProtocol` | `0.8.17` | `EIP712`, `CallerAuth`, `ReentrancyGuard` | Main settlement contract. Binds the caller (`authSig`, allowedCallers=[PmmAdapter]) immediately after the rfqId-range check (`RFQ_InvalidRfqId`) in the single `fillOrderRFQTo` entry, before maker-signature verification, then verifies maker signatures, transfers maker/taker funds, applies confidence reduction, tracks RFQ-ID invalidator bitmap. |
| `PMMAdapter` | `0.8.17` | `CallerAuth`, `ReentrancyGuard` | Aggregator-side adapter. `sellBase` / `sellQuote` decode `OrderRFQ` (V1/V2/V3 legacy, V4/orderType=4 anti-toxic) and forward to a `PMMProtocol` (called `pool`) via `_call`; handles refund of unused taker balance. On orderType=4 it verifies caller-auth and the `allowedSender == dexRouterCaller` anti-toxic check. |
| `CallerAuth` (abstract) | `^0.8.0` | _none_ | Signed caller-authorization base. Immutable `AUTH_SIGNER`, append-only nonce bitmap, `_verifyCallerAuth`, `_extractDexRouterCaller` (reads calldata `-64`). Inherited by both `PMMProtocol` and `PMMAdapter`. See [[contract-CallerAuth]]. |
| `Constants` (file-level) | `^0.8.0` | _none_ | Calldata-marker constants: `DEX_ROUTER_CALLER_MARKER`, `MARKER_MASK`, `ORIGIN_PAYER`, `_ADDRESS_MASK`. Referenced by name inside `CallerAuth`/`PMMAdapter` assembly. |
| `EIP712` (abstract) | `0.8.17` | _none_ | Provides the cached EIP-712 domain separator and `_hashTypedDataV4`. Inherited by `PMMProtocol`. Unchanged; domain `version` flows in via `PMMProtocol._VERSION` (now `1.2`). |
| `OrderRFQLib` (library) | `0.8.17` | _none_ | Defines the `OrderRFQ` struct (**15 fields**, incl. `allowedSender`) and `_LIMIT_ORDER_RFQ_TYPEHASH`; computes the EIP-712 struct hash via `hash(order, domainSeparator)`. |
| `ECDSA` (library) | `^0.8.0` | _none_ | Signature recovery (65-byte and EIP-2098 64-byte), ERC-1271 fallback (`isValidSignature` variants), `toTypedDataHash`, and `toEthSignedMessageHash` (EIP-191, used by CallerAuth). |
| `SafeERC20` (library) | `^0.8.0` | _none_ | Safe ERC-20 wrappers + `safeTransferFromPermit2` + `safePermit` (auto-detects EIP-2612 vs Dai-style). Defines the `_PERMIT2` canonical address. |
| `AmountCalculator` (library) | `0.8.17` | _none_ | Floored maker / ceiled taker amount derivation for partial fills. |
| `Errors` (library) | `0.8.17` | _none_ | All `RFQ_*` custom error definitions (incl. `RFQ_BadSender`) used by `PMMProtocol` / `PMMAdapter`. |
| `RevertReasonForwarder` (library) | `0.8.17` | _none_ | Bubbles up the original revert reason from `safePermit`. |

## Role & Permission Matrix

The protocol has **no owner/admin role** (no `Ownable`, no setters). Authorization is enforced through **three** layers: (1) the maker's EIP-712 signature, (2) the per-maker invalidator bitmap, and (3) a signed caller authorization (`CallerAuth`) that restricts who may relay a settlement. `AUTH_SIGNER` is an immutable trust anchor set at deploy, not a mutable admin.

| Role | How Granted | Contract | Permitted Operations |
|------|-------------|----------|---------------------|
| Maker | Signs `OrderRFQ` (v1.2 domain, incl. `allowedSender`) against `PMMProtocol` domain | `PMMProtocol` | Authorize fills of their own quotes; call `cancelOrderRFQ(uint64)` to invalidate their own RFQ IDs |
| `AUTH_SIGNER` | Immutable, set in constructor of both `PMMProtocol` and `PMMAdapter` | `CallerAuth` | Off-chain signs `(address(this), payloadHash, allowedCallers, nonce, chainId)` authorizing a specific relay caller set for a specific payload. For PMM orderType=4, `payloadHash = keccak256(abi.encode(order))`. Cannot be changed post-deploy. |
| PmmAdapter | Member of the signed `allowedCallers` for `PMMProtocol` (`[PmmAdapter]`) | `PMMProtocol` | The caller authorized to reach `fillOrderRFQTo` |
| DexRouter / DynamicRoute | Members of the signed `allowedCallers` for `PMMAdapter` (`[DexRouter, DynamicRoute]`) | `PMMAdapter` | Callers authorized to drive the orderType=4 path |
| Anyone | — | `PMMProtocol` | Read `DOMAIN_SEPARATOR()`, `AUTH_SIGNER()`, `isNonceUsed(nonce)`, `invalidatorForOrderRFQ(maker, slot)`, `isRfqIdUsed(maker, rfqId)` |
| `_WETH` only | Identified by `address(_WETH)` | `PMMProtocol::receive` | Send ETH to the protocol (any other sender reverts `RFQ_EthDepositRejected`) |

> **Legacy V1/V2/V3 note.** The adapter's legacy `orderType ∈ {1,2,3}` paths are unchanged and do NOT perform caller-auth or `allowedSender` checks; only the new orderType=4 path is caller-bound. Direct standalone calls to `PMMProtocol` (bypassing the adapter) now revert `AUTH_UntrustedCaller` because `msg.sender` is not in `[PmmAdapter]`.

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

 Anti-toxic-flow (orderType=4) path:

 ┌────────────┐        ┌──────────────┐  orderType=4   ┌──────────────┐  fillOrderRFQTo(...  ┌──────────────┐
 │ DexRouter /│ inject │ PMMAdapter   │ _verifyCaller  │ CallerAuth   │  allowedCallers,     │ PMMProtocol  │
 │ DynamicRoute│ -64 ─►│ - CallerAuth │ Auth + check   │ (base)       │  nonce,authSig)      │ - CallerAuth │
 │ (caller)   │        │ - Reentrancy │ allowedSender  └──────────────┘  ───────────────────►│ after rfqId  │
 └────────────┘        │   Guard      │ ==dexRouterCaller                                    │ range check  │
                       └──────────────┘                                                      └──────────────┘

 In PMMProtocol, caller-auth runs immediately after the rfqId-range check (RFQ_InvalidRfqId),
 before maker-signature verification.

 Direct standalone calls to PMMProtocol now REVERT (AUTH_UntrustedCaller): the single
 fillOrderRFQTo entry is caller-bound to [PmmAdapter]; fillOrderRFQ / fillOrderRFQCompact /
 fillOrderRFQToWithPermit are not present in the current interface.

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

`PMMProtocol` — constructor `(IWETH weth, address authSigner)`:

| Parameter | Contract | Mutable After Deploy | Set By |
|-----------|----------|---------------------|--------|
| `weth` (constructor) | `PMMProtocol` | No (`immutable _WETH`) | Deployer |
| `authSigner` (constructor) | `CallerAuth` | No (`immutable AUTH_SIGNER`) | Deployer (**zero address rejected → `AUTH_ZeroSigner`**, fail-closed) |
| `_NAME` | `PMMProtocol` | No (`constant`) | Source code (`"OKX Labs PMM Protocol"`) |
| `_VERSION` | `PMMProtocol` | No (`constant`) | Source code (`"1.2"` — was `"1.1"`) |

`PMMAdapter` — constructor `(address authSigner)`:

| Parameter | Contract | Mutable After Deploy | Set By |
|-----------|----------|---------------------|--------|
| `authSigner` (constructor) | `CallerAuth` | No (`immutable AUTH_SIGNER`) | Deployer (**zero address rejected → `AUTH_ZeroSigner`**). The `pool` address (a `PMMProtocol`) is still supplied per-call by the caller. |

Deployment scripts: `scripts/Deploy.s.sol`, `scripts/DeployAdaptor.s.sol` (both pass `authSigner` from the `AUTH_SIGNER` env var). Live address table maintained in `DEPLOYMENT.md` (V4 current — anti-toxic caller-bound deployment on Ethereum/Arbitrum/Base/BNB Chain/XLayer; V1/V2/V3 history retained).
