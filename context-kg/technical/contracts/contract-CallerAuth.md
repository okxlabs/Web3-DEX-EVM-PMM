---
name: "contract-CallerAuth"
description: "OKX-signed caller-binding base (abstract) — immutable OKX_SIGNER, EIP-191/EIP-2098 signature verification, Permit2-style nonce bitmap, and _extractDexRouterCaller for the anti-toxic-flow"
type: "design"
title: "Contract: CallerAuth"
tags: ["CallerAuth", "caller-binding", "OKX_SIGNER", "nonce-bitmap", "EIP-2098", "EIP-191", "dexRouterCaller", "anti-toxic-flow", "SCDEX-1157"]
sources: ["src/libraries/CallerAuth.sol", "src/libraries/Constants.sol", "src/libraries/ECDSA.sol"]
last_updated: "2026-07-05"
---

# Contract: CallerAuth

Source: `src/libraries/CallerAuth.sol` (pragma `^0.8.0`). **Abstract** base contract introduced by SCDEX-1157 (EVM RFQ anti-toxic-flow). Inherited by both `PMMProtocol` and `PMMAdapter`, and designed to be shared byte-for-byte with the Web3-DEX-EVM repo (canonical two-repo file).

## Purpose

`CallerAuth` closes the "address-decoupling" arbitrage: a market maker quotes for a clean address, but the swap is settled from a different (unvetted) address that bypasses the maker's `allowedSender` / fee / blacklist controls. It binds a swap to (a) an **OKX-backend signature** over the authorized on-chain caller set, and (b) the outermost DexRouter caller read from calldata. It has **no owner, no setter, no registry** — the signer is fixed at deploy time.

## Inheritance

None. `abstract contract CallerAuth`. Uses `ECDSA` (recover / EIP-191) and the file-level constants from `Constants.sol`.

## State Variables

Verified via `forge inspect CallerAuth storageLayout`.

| Variable | Type | Slot | Mutable | Purpose |
|----------|------|------|---------|---------|
| `_callerAuthNonceBitmap` | `mapping(uint256 => uint256)` | 0 | Yes (set bits monotonically) | Per-instance single-use nonce bitmap (Permit2-style): word = `nonce >> 8`, bit = `1 << (nonce & 0xff)`. Append-only. |
| `OKX_SIGNER` | `address` (immutable) | — | No | OKX authorization signer. Set once in the constructor; a zero address is rejected (`OSA_ZeroSigner`, fail-closed deploy). |

Because `CallerAuth` is inherited **before** `ReentrancyGuard` in both `PMMProtocol` and `PMMAdapter`, its `_callerAuthNonceBitmap` occupies **storage slot 0** in the derived contracts (shifting `_status` to slot 1).

## Constructor

```solidity
constructor(address okxSigner) {
    if (okxSigner == address(0)) revert OSA_ZeroSigner();
    OKX_SIGNER = okxSigner;
}
```

## Functions

| Function | Visibility | Description |
|----------|-----------|-------------|
| `_verifyCallerAuth(address[] allowedCallers, uint256 nonce, uint256 expiry, bytes okxSig)` | internal | Computes `inner = keccak256(abi.encode(address(this), allowedCallers, nonce, expiry, block.chainid))` and delegates to `_verifyAuthCommon`. The primary entry used by PMMProtocol/PMMAdapter. |
| `_verifyAuthCommon(bytes32 inner, address[] allowedCallers, uint256 nonce, uint256 expiry, bytes okxSig)` | internal | Shared verification core (see ordering below). |
| `_isAllowedCaller(address[] allowedCallers)` | private view | Linear membership test: `msg.sender ∈ allowedCallers`. |
| `_useNonce(uint256 nonce)` | private | Consumes the nonce in the bitmap; reverts `OSA_NonceUsed` on reuse. |
| `isNonceUsed(uint256 nonce)` | external view | Read whether a nonce is already consumed. Selector `0x5d00bb12`. |
| `_extractDexRouterCaller()` | internal pure | Reads the calldata word at `-64`; if `word & MARKER_MASK == DEX_ROUTER_CALLER_MARKER` (exact match), returns `word & _ADDRESS_MASK` (low 20 bytes); otherwise `address(0)` (fail-closed). |
| `OKX_SIGNER()` | external view (auto) | Public immutable getter. Selector `0x6c26f9cc`. |

### Verification order (`_verifyAuthCommon`)

```
1. okxSig.length != 64                          → OSA_BadSigLen   (EIP-2098 compact required)
2. digest = ECDSA.toEthSignedMessageHash(inner) (EIP-191 "\x19Ethereum Signed Message:\n32")
   signer = ECDSA.recover(digest, r, vs)         (r, vs read from the 64-byte sig)
   signer == 0 || signer != OKX_SIGNER          → OSA_BadOkxSig
3. block.timestamp > expiry                      → OSA_Expired
4. msg.sender ∉ allowedCallers                    → OSA_UntrustedCaller
5. _useNonce(nonce)  (nonce already set)          → OSA_NonceUsed
```

The nonce is consumed **before** the inheriting contract performs any external call/transfer (CEI), so a reentrant replay of the same nonce reverts.

## Custom Errors

All parameterless. Verified present in both PMMProtocol and PMMAdapter ABIs.

| Error | Thrown When |
|-------|-------------|
| `OSA_ZeroSigner` | `okxSigner == address(0)` at construction. |
| `OSA_Expired` | `block.timestamp > expiry`. |
| `OSA_UntrustedCaller` | `msg.sender` is not in the signed `allowedCallers`. |
| `OSA_BadOkxSig` | Recovered signer is zero or `!= OKX_SIGNER`. |
| `OSA_BadSigLen` | `okxSig.length != 64`. |
| `OSA_NonceUsed` | The nonce was already consumed. |

## Digest Construction

```
inner  = keccak256(abi.encode(address(this), allowedCallers, nonce, expiry, block.chainid))
digest = ECDSA.toEthSignedMessageHash(inner)      // EIP-191 personal-sign prefix
signer = ECDSA.recover(digest, r, vs)             // EIP-2098 compact 64-byte
```

- Binding `address(this)` gives cross-contract replay protection; binding `block.chainid` gives cross-chain replay protection.
- The signature is **not** EIP-712 typed data — it is an EIP-191 personal-sign over the ABI-encoded tuple. It is a distinct signature from the maker's OrderRFQ EIP-712 signature.

## allowedCallers by contract

| Contract | Signed `allowedCallers` | Meaning |
|----------|-------------------------|---------|
| `PMMProtocol` | `[PmmAdapter]` | Only the adapter may reach settlement (`fillOrderRFQTo` first line). |
| `PMMAdapter` | `[DexRouter, DynamicRoute]` | Only these routers may drive the orderType=4 path. |

(Real per-chain addresses are deploy-time config injected via the OKX backend; tests derive them via `makeAddrAndKey`.)

## Key Invariants

- [Rule] `OKX_SIGNER` is immutable and non-zero (deploy fails closed on zero). No setter exists.
- [Rule] `okxSig` MUST be EIP-2098 64-byte compact; 65-byte legacy signatures are rejected (`OSA_BadSigLen`).
- [Rule] Each `nonce` is single-use per contract instance; the bitmap is monotonic (bits set, never cleared).
- [Rule] `_extractDexRouterCaller` uses **exact** marker matching (`== DEX_ROUTER_CALLER_MARKER`), not a subset/wildcard match, and fail-closes to `address(0)` on a missing or forged marker.
- [Rule] The nonce is consumed inside `_verify*` before the caller's external swap/transfer (CEI), preventing same-nonce reentrant replay.

## Related

- [[contract-PMMProtocol]] — caller binding on `fillOrderRFQTo`.
- [[contract-PMMAdapter]] — caller binding + `allowedSender` check on orderType=4.
- [[pmm_anti_toxic_flow]] — business-domain description of the anti-toxic-flow mechanism.
- [[eip712-signature-design]] — the separate maker OrderRFQ signature.
