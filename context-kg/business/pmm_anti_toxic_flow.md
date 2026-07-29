---
domain: pmm
sub_domain: pmm_anti_toxic_flow
title: PMM Anti-Toxic-Flow (allowedSender + Caller Authorization)
source_docs: ["src/PmmAdaptor.sol", "src/PmmProtocol.sol", "src/OrderRFQLib.sol", "src/libraries/CallerAuth.sol", "src/libraries/Constants.sol", "src/libraries/Errors.sol"]
concept_keys: [AllowedSender, DexRouterCaller, CallerAuth, AuthSigner, AllowedCallers, OrderType4, RFQ_BadSender, NonceBitmap, AddressDecoupling, AntiToxicFlow]
last_updated: 2026-07-27
---

# PMM Anti-Toxic-Flow

## Summary

The current V4 flow binds a maker quote to the address for which it was issued and separately restricts which contracts may relay it:

1. `allowedSender` is included in the maker-signed `OrderRFQ`.
2. `PMMAdapter` orderType=4 requires `allowedSender` to match the outermost router caller.
3. `PMMAdapter` and `PMMProtocol` each verify caller authorization over the exact encoded order.

## Address Binding

`PMMAdapter._executeV4Order` decodes the 15-field `OrderRFQ` and reads the router caller with `_extractDexRouterCaller()`. The helper reads the calldata word at `-64` only when its high bits exactly match `DEX_ROUTER_CALLER_MARKER`; otherwise it returns `address(0)`.

The adapter then applies:

```solidity
if (order.allowedSender == address(0) || order.allowedSender != _extractDexRouterCaller()) {
    revert Errors.RFQ_BadSender(order.rfqId);
}
```

Because `allowedSender` is part of the EIP-712 order digest, neither the relayer nor the adapter can replace it without invalidating the maker signature.

## Caller Authorization

Both contracts call `_verifyCallerAuth` with:

```text
payloadHash = keccak256(abi.encode(order))
inner = keccak256(abi.encode(verifyingContract, payloadHash, allowedCallers, nonce, chainId))
```

The authorization signature is EIP-191 over `inner` and encoded as a 64-byte EIP-2098 compact signature. Verification also requires `msg.sender` to be in `allowedCallers` and consumes a verifier-specific nonce.

`PMMAdapter` and `PMMProtocol` use separate authorization records because they are different verifiers with independent nonce bitmaps.

## V4 Payload

```solidity
struct CallerAuthData {
    address[] allowedCallers;
    uint256 nonce;
    bytes authSig;
}

orderInfo = abi.encode(order, adaptorAuth, protocolAuth);
moreInfo = abi.encode(orderInfo, makerSignature, signatureType, uint256(4));
```

The adapter verifies `adaptorAuth`, performs the sender check, and forwards `protocolAuth` to `PMMProtocol.fillOrderRFQTo`.

## Security Properties

- A missing or malformed router-caller marker resolves to zero and fails the non-zero sender check.
- Changing any order field invalidates both the maker signature and caller authorization.
- Changing `allowedCallers`, nonce, verifier, or chain ID invalidates caller authorization.
- Reusing an authorization nonce on the same verifier reverts `AUTH_NonceUsed`.
- Calling the protocol from an address absent from its signed caller set reverts `AUTH_UntrustedCaller`.
- `PMMProtocol` intentionally does not re-check `allowedSender`; the V4 adapter owns that check.
- Legacy order types 1-3 retain their historical encoding and behavior.

## Errors

| Error | Meaning |
|-------|---------|
| `RFQ_BadSender` | `allowedSender` is zero or differs from the extracted router caller |
| `AUTH_BadAuthSig` | Authorization digest or signer is invalid |
| `AUTH_BadSigLen` | Authorization signature is not 64 bytes |
| `AUTH_UntrustedCaller` | Runtime caller is absent from `allowedCallers` |
| `AUTH_NonceUsed` | Authorization nonce was already consumed on this verifier |
| `AUTH_ZeroSigner` | Constructor received a zero authorization signer |

## References

- [[contract-CallerAuth]]
- [[contract-PMMAdapter]]
- [[contract-PMMProtocol]]
- [[pmm-adapter-route]]
- [[pmm-fill-order]]
