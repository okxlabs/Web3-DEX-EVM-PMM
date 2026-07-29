---
squad: web3-dex
domain: pmm
sub_domain: pmm_anti_toxic_flow
title: PMM Anti-Toxic-Flow (allowedSender + Caller Binding)
source_docs: ["docs/research-design-note.md (SCDEX-1157, EVM-RFQ-anti-toxic-flow-PRD-v0.2)", "src/PmmAdaptor.sol", "src/PmmProtocol.sol", "src/OrderRFQLib.sol", "src/libraries/CallerAuth.sol", "src/libraries/Constants.sol", "src/libraries/Errors.sol"]
concept_keys: [AllowedSender, DexRouterCaller, CallerAuth, OkxSigner, AllowedCallers, OrderType4, RFQ_BadSender, NonceBitmap, AddressDecoupling, AntiToxicFlow]
organized_at: 2026-07-05T00:00:00Z
last_updated: 2026-07-05
---

# PMM Anti-Toxic-Flow (allowedSender + Caller Binding)

> Business line: Web3 DEX (PMM Integration) · Requirement: SCDEX-1157

## One-line Summary

The anti-toxic-flow feature stops the "address-decoupling" arbitrage against PMM firm quotes by (1) adding a required `allowedSender` to the signed `OrderRFQ`, (2) checking `allowedSender == dexRouterCaller` in `PMMAdapter` (orderType=4), and (3) binding both `PMMAdapter` and `PMMProtocol` to an OKX-backend caller signature, converging settlement onto a single caller-bound entry.

## 1. Business Background & Scope

- **The attack (address decoupling).** In firm-quote RFQ mode, a market maker prices for a specific "clean" address, but an arbitrageur can settle the same signed quote from a *different*, unvetted address. Because the swap reaches `PMMProtocol` through an adapter, the `msg.sender` the protocol sees is the adapter — so the maker's `allowedSender` / blacklist / fee risk controls are all bypassed. The maker fills toxic flow it never intended to serve.
- **The fix.** Bind the quote to the address it was priced for (`allowedSender`), and verify at settlement time that the *actual outermost DexRouter caller* matches it — while also cryptographically restricting *who may relay* the settlement (OKX-signed caller binding).
- **In scope (this repo, `GitHub-Web3-DEX-EVM-PMM`)**: FR-5 (the `allowedSender` check on the adapter + protocol caller convergence), FR-3 on `PMMAdapter`/`PMMProtocol` (caller binding), FR-6-AC-1 (legacy regression). See [[pmm_settlement]] for the underlying fill mechanics.
- **Out of scope (other repos / later)**: DexRouter's injection of the `dexRouterCaller` calldata word (`Web3-DEX-EVM`), DynamicRoute / NativePmmAdapter landing, FR-1/FR-2/FR-4. In this repo, tests mock the `-64` injection.

## 2. Core Mechanism

### 2.1 `allowedSender` (required, signed)

`OrderRFQ` gains a required `address allowedSender` (15th field, inserted between `usePermit2` and `confidenceT`). It is part of the EIP-712 digest, so a maker cannot have it swapped after signing. Because the typehash changed, the EIP-712 **domain version was bumped `1.1 → 1.2`** — every outstanding `1.1` maker signature is now invalid (replay protection). Zero `allowedSender` is treated as "unset" and always fails closed.

### 2.2 The `dexRouterCaller` check (PMMAdapter, orderType=4)

DexRouter injects the outermost directly-calling address into the calldata word at offset `-64`, stamped with `DEX_ROUTER_CALLER_MARKER`. `CallerAuth._extractDexRouterCaller()` reads it with an **exact** marker match (`word & MARKER_MASK == DEX_ROUTER_CALLER_MARKER`) and fail-closes to `address(0)` on any missing/forged marker. The adapter then enforces:

```
if (order.allowedSender == address(0) || order.allowedSender != dexRouterCaller)
    revert RFQ_BadSender(rfqId);
```

Both direct-to-DexRouter and via-DynamicRoute paths resolve `dexRouterCaller` to the outermost address directly calling DexRouter.

### 2.3 OKX caller binding (`CallerAuth`)

Both contracts inherit `CallerAuth` and verify an OKX-backend signature over `(address(this), allowedCallers, nonce, expiry, chainId)` (EIP-191, EIP-2098 64-byte compact, single-use nonce bitmap):

| Contract | Signed `allowedCallers` | Effect |
|----------|-------------------------|--------|
| `PMMAdapter` (orderType=4) | `[DexRouter, DynamicRoute]` | Only these routers may drive the anti-toxic path. |
| `PMMProtocol` (`fillOrderRFQTo` first line) | `[PmmAdapter]` | Only the adapter may reach settlement — direct standalone calls now revert `OSA_UntrustedCaller`. |

Settlement is converged onto the **single** `fillOrderRFQTo`; the legacy `fillOrderRFQ` / `fillOrderRFQCompact` / `fillOrderRFQToWithPermit` were removed. See [[contract-CallerAuth]], [[contract-PMMAdapter]], [[contract-PMMProtocol]].

## 3. Business Rules (Acceptance Criteria)

- [Rule FR-5-AC-1] `allowedSender != 0` and `== dexRouterCaller` → fill proceeds.
- [Rule FR-5-AC-2] `allowedSender != 0` and `!= dexRouterCaller` → revert `RFQ_BadSender`.
- [Rule FR-5-AC-3] `allowedSender == address(0)` → revert (fail-closed).
- [Rule FR-5-AC-4] Direct-to-DexRouter and via-DynamicRoute both resolve `dexRouterCaller` to the outermost DexRouter caller.
- [Rule FR-5-AC-5] Bypassing the adapter to call `PMMProtocol.fillOrderRFQTo` directly reverts (`OSA_UntrustedCaller`).
- [Rule FR-5-AC-7] A missing/forged `-64` marker yields `dexRouterCaller == 0` → hits the fail-closed case → `RFQ_BadSender`.
- [Rule FR-5-AC-8] `PMMProtocol` performs **no** `allowedSender` check — it lives only in `PMMAdapter`.
- [Rule FR-3] Caller binding: untrusted caller → `OSA_UntrustedCaller`; expired → `OSA_Expired`; bad OKX sig → `OSA_BadOkxSig`; wrong length → `OSA_BadSigLen`; replayed nonce → `OSA_NonceUsed`; zero signer at deploy → `OSA_ZeroSigner`.
- [Rule FR-6-AC-1] Legacy V1/V2/V3 orderType paths, success paths, existing error/event semantics, and refund `-32` logic are unchanged.

## 4. Errors (business-visible)

| Error | Meaning |
|-------|---------|
| `RFQ_BadSender(rfqId)` | The order's `allowedSender` is unset or does not match the actual DexRouter caller — the quote is being filled from an address it was not priced for. |
| `OSA_UntrustedCaller` | The relaying contract is not in the OKX-signed allowed set (e.g. a direct call bypassing the adapter). |
| `OSA_Expired` / `OSA_BadOkxSig` / `OSA_BadSigLen` / `OSA_NonceUsed` / `OSA_ZeroSigner` | OKX caller-auth authorization failures — see [[contract-CallerAuth]]. |

## 5. Cross-Repo / Backend Dependencies

- **DexRouter injection** of the `dexRouterCaller@-64` word (with `DEX_ROUTER_CALLER_MARKER`) is implemented in `Web3-DEX-EVM`; this repo only reads it (tests mock it).
- **OKX backend** allocates caller-auth nonces and constructs the `allowedCallers` segment; `CallerAuth.sol` is the canonical two-repo signature contract that fixes the `okxSig` preimage layout.
- Deploy-time addresses (`okxSigner`, per-chain DexRouter/DynamicRoute/PmmAdapter/PMMProtocol) are constructor/config inputs, not code-level blockers.

## Related

- [[pmm_settlement]] — the underlying on-chain settlement flow this feature guards.
- [[pmm_adapter_migration]] — the multi-version adapter dispatch (orderType=4 is the new sibling of V1/V2/V3).
