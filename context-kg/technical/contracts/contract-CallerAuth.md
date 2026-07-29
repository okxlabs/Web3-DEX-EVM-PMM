---
name: "contract-CallerAuth"
description: "Signed caller-binding base (abstract) — immutable AUTH_SIGNER, payload-scoped EIP-191/EIP-2098 signature verification, Permit2-style nonce bitmap, and _extractDexRouterCaller for the anti-toxic-flow"
type: "design"
title: "Contract: CallerAuth"
tags: ["CallerAuth", "caller-binding", "AUTH_SIGNER", "nonce-bitmap", "EIP-2098", "EIP-191", "dexRouterCaller", "anti-toxic-flow"]
sources: ["src/libraries/CallerAuth.sol", "src/libraries/Constants.sol", "src/libraries/ECDSA.sol"]
last_updated: "2026-07-27"
---

# Contract: CallerAuth

Source: `src/libraries/CallerAuth.sol` (pragma `^0.8.0`). This abstract base contract is inherited by both `PMMProtocol` and `PMMAdapter`.

## Purpose

`CallerAuth` binds a swap to a signature over the payload hash and authorized on-chain caller set. It also exposes a helper for extracting the outermost router caller from calldata. It has **no owner, no setter, and no registry**; the signer is fixed at deploy time.

## Inheritance

None. `abstract contract CallerAuth`. Uses `ECDSA` (recover / EIP-191) and the file-level constants from `Constants.sol`.

## State Variables

Verified via `forge inspect CallerAuth storageLayout`.

| Variable | Type | Slot | Mutable | Purpose |
|----------|------|------|---------|---------|
| `_callerAuthNonceBitmap` | `mapping(uint256 => uint256)` | 0 | Yes (set bits monotonically) | Per-instance single-use nonce bitmap (Permit2-style): word = `nonce >> 8`, bit = `1 << (nonce & 0xff)`. Append-only. |
| `AUTH_SIGNER` | `address` (immutable) | — | No | Authorization signer. Set once in the constructor; a zero address is rejected (`AUTH_ZeroSigner`, fail-closed deploy). |

Because `CallerAuth` is inherited **before** `ReentrancyGuard` in both `PMMProtocol` and `PMMAdapter`, its `_callerAuthNonceBitmap` occupies **storage slot 0** in the derived contracts (shifting `_status` to slot 1).

## Constructor

```solidity
constructor(address authSigner) {
    if (authSigner == address(0)) revert AUTH_ZeroSigner();
    AUTH_SIGNER = authSigner;
}
```

## Functions

| Function | Visibility | Description |
|----------|-----------|-------------|
| `_verifyCallerAuth(bytes32 payloadHash, address[] allowedCallers, uint256 nonce, bytes authSig)` | internal | Computes `inner = keccak256(abi.encode(address(this), payloadHash, allowedCallers, nonce, block.chainid))` and delegates to `_verifyAuthCommon`. PMMProtocol/PMMAdapter pass `keccak256(abi.encode(order))`. |
| `_verifyAuthCommon(bytes32 inner, address[] allowedCallers, uint256 nonce, bytes authSig)` | internal | Shared verification core (see ordering below). |
| `_isAllowedCaller(address[] allowedCallers)` | private view | Linear membership test: `msg.sender ∈ allowedCallers`. |
| `_useNonce(uint256 nonce)` | private | Consumes the nonce in the bitmap; reverts `AUTH_NonceUsed` on reuse. |
| `isNonceUsed(uint256 nonce)` | external view | Read whether a nonce is already consumed. Selector `0x5d00bb12`. |
| `_extractDexRouterCaller()` | internal pure | Reads the calldata word at `-64`; if `word & MARKER_MASK == DEX_ROUTER_CALLER_MARKER` (exact match), returns `word & _ADDRESS_MASK` (low 20 bytes); otherwise `address(0)` (fail-closed). |
| `AUTH_SIGNER()` | external view (auto) | Public immutable getter. Selector `0x0a5c9024`. |

### Verification order (`_verifyAuthCommon`)

```
1. authSig.length != 64                         → AUTH_BadSigLen   (EIP-2098 compact required)
2. digest = ECDSA.toEthSignedMessageHash(inner) (EIP-191 "\x19Ethereum Signed Message:\n32")
   signer = ECDSA.recover(digest, r, vs)         (r, vs read from the 64-byte sig)
   signer != AUTH_SIGNER                        → AUTH_BadAuthSig
   (failed recovery yields signer == 0, which never equals the non-zero AUTH_SIGNER)
3. msg.sender ∉ allowedCallers                    → AUTH_UntrustedCaller
4. _useNonce(nonce)  (nonce already set)          → AUTH_NonceUsed
```

The nonce is consumed **before** the inheriting contract performs any external call/transfer (CEI), so a reentrant replay of the same nonce reverts.

## Custom Errors

All parameterless. Verified present in both PMMProtocol and PMMAdapter ABIs.

| Error | Thrown When |
|-------|-------------|
| `AUTH_ZeroSigner` | `authSigner == address(0)` at construction. |
| `AUTH_UntrustedCaller` | `msg.sender` is not in the signed `allowedCallers`. |
| `AUTH_BadAuthSig` | Recovered signer `!= AUTH_SIGNER` (covers failed recovery, which yields the zero address). |
| `AUTH_BadSigLen` | `authSig.length != 64`. |
| `AUTH_NonceUsed` | The nonce was already consumed. |
| `AUTH_BadCallersLength` | Declared here; thrown by `PMMProtocol.fillOrderRFQTo` when `allowedCallers.length != 1` (the protocol segment authorizes exactly one caller). Not thrown by `CallerAuth` itself or by `PMMAdapter` (whose own segment legitimately carries two callers). |

## Digest Construction

```
payloadHash = keccak256(abi.encode(order))        // PMM Adapter/Protocol orderType=4
inner  = keccak256(abi.encode(address(this), payloadHash, allowedCallers, nonce, block.chainid))
digest = ECDSA.toEthSignedMessageHash(inner)      // EIP-191 personal-sign prefix
signer = ECDSA.recover(digest, r, vs)             // EIP-2098 compact 64-byte
```

- Binding `address(this)` gives cross-contract replay protection; binding `block.chainid` gives cross-chain replay protection.
- Binding `payloadHash` gives cross-order replay protection for PMM caller-auth; a signature for one `OrderRFQ` cannot authorize a modified order.
- The signature is **not** EIP-712 typed data — it is an EIP-191 personal-sign over the ABI-encoded tuple. It is a distinct signature from the maker's OrderRFQ EIP-712 signature.

## allowedCallers by contract

| Contract | Signed `allowedCallers` | Meaning |
|----------|-------------------------|---------|
| `PMMProtocol` | `[PmmAdapter]` | Only the adapter may reach settlement (checked early in `fillOrderRFQTo`, right after the rfqId range check). |
| `PMMAdapter` | `[DexRouter, DynamicRoute]` | Only these routers may drive the orderType=4 path. |

(Signer and caller addresses are deployment or integration configuration; tests derive local values with `makeAddrAndKey`.)

## Key Invariants

- [Rule] `AUTH_SIGNER` is immutable and non-zero (deploy fails closed on zero). No setter exists.
- [Rule] `authSig` MUST be EIP-2098 64-byte compact; 65-byte legacy signatures are rejected (`AUTH_BadSigLen`).
- [Rule] Each `nonce` is single-use per contract instance; the bitmap is monotonic (bits set, never cleared).
- [Rule] `_extractDexRouterCaller` uses **exact** marker matching (`== DEX_ROUTER_CALLER_MARKER`), not a subset/wildcard match, and fail-closes to `address(0)` on a missing or forged marker.
- [Rule] The nonce is consumed inside `_verify*` before the caller's external swap/transfer (CEI), preventing same-nonce reentrant replay.

## Related

- [[contract-PMMProtocol]] — caller binding on `fillOrderRFQTo`.
- [[contract-PMMAdapter]] — caller binding + `allowedSender` check on orderType=4.
- [[pmm_anti_toxic_flow]] — business-domain description of the anti-toxic-flow mechanism.
- [[eip712-signature-design]] — the separate maker OrderRFQ signature.
