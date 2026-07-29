---
name: "eip712-signature-design"
description: "EIP-712 typed-data signing architecture for OrderRFQ — domain separator, struct hash (15 fields incl. allowedSender), domain version 1.2, off-chain generation, and on-chain verification order"
type: "design"
title: "EIP-712 Signature Design"
tags: ["eip712", "orderrfq", "typehash", "domain-separator", "allowedSender", "version-1.2", "anti-toxic-flow"]
sources: ["src/OrderRFQLib.sol", "src/EIP712.sol", "src/PmmProtocol.sol"]
last_updated: "2026-07-27"
---

# EIP-712 Signature Design

`PMMProtocol` uses EIP-712 typed-data signatures as the maker-quote authorization mechanism. This document is the authority on how signatures are constructed, what each field covers, and how the contract verifies them.

`OrderRFQ` contains a required `address allowedSender` field (15 fields total), inserted between `usePermit2` and `confidenceT`. The EIP-712 domain version is `1.2`; signatures made for version `1.1` are invalid against the current contract. Maker authorization remains EIP-712, while settlement also requires caller authorization through `CallerAuth._verifyCallerAuth`.

---

## 1. Domain Separator

Built once at deploy time by the inherited `EIP712` constructor (see `EIP712.sol:52-63`), and rebuilt on the fly if `block.chainid` or `address(this)` ever differs (post-fork safety).

```solidity
string private constant _NAME    = "OKX Labs PMM Protocol";   // PmmProtocol.sol:61
string private constant _VERSION = "1.2";                      // PmmProtocol.sol:62 (was "1.1")
```

Effective domain:

```
EIP712Domain(
    string name               = "OKX Labs PMM Protocol"
    string version            = "1.2"                (bumped from "1.1" for the allowedSender field)
    uint256 chainId           = block.chainid    (at construction)
    address verifyingContract = address(this)
)
```

| Field | Prevents |
|-------|----------|
| `name` | Phishing via lookalike contracts that use a different name |
| `version` | Replay after a contract upgrade that changes typehash semantics. Bumped `1.1 → 1.2` for the `allowedSender` field, so `1.1` signatures no longer validate. |
| `chainId` | Cross-chain replay |
| `verifyingContract` | Cross-contract replay across PMMProtocol instances on the same chain |

The on-chain accessor is `DOMAIN_SEPARATOR()` (selector `0x3644e515`).

---

## 2. OrderRFQ Typehash (`OrderRFQLib.sol`)

`OrderRFQLib._LIMIT_ORDER_RFQ_TYPEHASH` (**15 fields** — V4 / anti-toxic-flow format; `allowedSender` inserted after `usePermit2`, `src/OrderRFQLib.sol:26-45`):

```solidity
bytes32 internal constant _LIMIT_ORDER_RFQ_TYPEHASH =
    keccak256(
        "OrderRFQ("
        "uint256 rfqId,"
        "uint256 expiry,"
        "address makerAsset,"
        "address takerAsset,"
        "address makerAddress,"
        "uint256 makerAmount,"
        "uint256 takerAmount,"
        "bool usePermit2,"
        "address allowedSender,"
        "uint256 confidenceT,"
        "uint256 confidenceWeight,"
        "uint256 confidenceCap,"
        "bytes permit2Signature,"
        "bytes32 permit2Witness,"
        "string permit2WitnessType"
        ")"
    );
```

| # | Field | Type | Encoding in struct hash | Purpose |
|---|-------|------|-------------------------|---------|
| 1 | `rfqId` | `uint256` | direct | Replay protection (also Permit2 `nonce`). |
| 2 | `expiry` | `uint256` | direct | Time bound (also Permit2 `deadline`). |
| 3 | `makerAsset` | `address` | direct (padded to 32 bytes) | Token sent by maker. |
| 4 | `takerAsset` | `address` | direct | Token sent by taker. |
| 5 | `makerAddress` | `address` | direct | Signer / fund owner. |
| 6 | `makerAmount` | `uint256` | direct | Quoted maker size. |
| 7 | `takerAmount` | `uint256` | direct | Quoted taker size. |
| 8 | `usePermit2` | `bool` | direct (padded to 32 bytes) | Switches maker leg between standard `safeTransferFrom` and Permit2. |
| 9 | `allowedSender` | `address` | direct (padded to 32 bytes) | The address for which the maker quoted; required non-zero by PMMAdapter orderType=4 and compared with the outermost router caller. |
| 10 | `confidenceT` | `uint256` | direct | Time-slippage activation timestamp. |
| 11 | `confidenceWeight` | `uint256` | direct | Reduction rate per second (1e6 units). |
| 12 | `confidenceCap` | `uint256` | direct | Maximum reduction (1e6 units; on-chain cap 50000 = 5%). |
| 13 | `permit2Signature` | `bytes` | `keccak256(permit2Signature)` | Optional inline Permit2 signature. **Bound** so a swap to a different Permit2 sig invalidates the OrderRFQ digest. |
| 14 | `permit2Witness` | `bytes32` | direct | Pre-hashed witness payload (already a hash). |
| 15 | `permit2WitnessType` | `string` | `keccak256(bytes(permit2WitnessType))` | Canonical witness type string for `permitWitnessTransferFrom`. |

Struct hash construction (`OrderRFQLib.hash`, `src/OrderRFQLib.sol:48-72`):

```solidity
bytes32 structHash = keccak256(
    abi.encode(
        _LIMIT_ORDER_RFQ_TYPEHASH,
        order.rfqId,
        order.expiry,
        order.makerAsset,
        order.takerAsset,
        order.makerAddress,
        order.makerAmount,
        order.takerAmount,
        order.usePermit2,
        order.allowedSender,          // NEW — position must match the typehash & struct
        order.confidenceT,
        order.confidenceWeight,
        order.confidenceCap,
        keccak256(order.permit2Signature),
        order.permit2Witness,
        keccak256(bytes(order.permit2WitnessType))
    )
);
bytes32 digest = ECDSA.toTypedDataHash(domainSeparator, structHash);  // "\x19\x01" || ds || sh
```

> [Rule] The `allowedSender` position (index 8, between `usePermit2` and `confidenceT`) must be identical in **all three** places — the `struct` declaration, the typehash string, and the `abi.encode` in `hash()`. A mismatch produces a digest that never recovers the maker → every fill reverts `RFQ_BadSignature`.

---

## 3. Off-Chain Signature Generation

Reference JS implementation: `script/signOrderRFQ.js` (mirrors the Solidity hashing logic). Steps:

```
1. Build domainSeparator (matches contract: NAME="OKX Labs PMM Protocol", VERSION="1.2", chainId, verifyingContract)
2. Build structHash from all 15 OrderRFQ fields (incl. allowedSender) with the encoding rules above
3. digest = keccak256("\x19\x01" || domainSeparator || structHash)
4. (v, r, s) = sign(digest, makerPrivateKey)
5. signature = abi.encodePacked(r, s, v)   // 65 bytes
```

> The **caller-auth** signature (`authSig`) is a separate signature over `(address(this), payloadHash, allowedCallers, nonce, block.chainid)`, EIP-191 prefixed and EIP-2098 64-byte compact. For PMM Adapter/Protocol, `payloadHash = keccak256(abi.encode(order))`. It is NOT the maker OrderRFQ signature and does NOT use this EIP-712 domain. See [[contract-CallerAuth]].

If the maker is a smart-contract signer (ERC-1271), set bit 254 (`_SIGNER_SMART_CONTRACT_HINT`) on `flagsAndAmount` so the protocol skips `ecrecover` and calls `IERC1271.isValidSignature(orderHash, signature)`. Set bit 253 (`_IS_VALID_SIGNATURE_65_BYTES`) only when the contract expects exactly 65 bytes — the protocol then enforces `signature.length == 65`.

### Two-Signature Permit2 Flow

When `usePermit2 = true` **and** `permit2Signature` is non-empty:

1. **Sign the Permit2 message FIRST** against the Permit2 domain (3 fields: `name`, `chainId`, `verifyingContract` — **no `version`**).
2. Embed that 65-byte Permit2 signature into `order.permit2Signature`.
3. **Then** compute the OrderRFQ struct hash — which depends on `keccak256(order.permit2Signature)`.
4. Maker signs the OrderRFQ digest against the PMMProtocol domain (4 fields, `version = "1.2"`).

Reversing the order produces a Permit2 signature that does not match the OrderRFQ binding and the fill will revert (the Permit2 call inside `_fillOrderRFQTo` reverts before any other state change observable to the maker).

---

## 4. Confidence (Time-Slippage) Semantics

`confidenceT`, `confidenceWeight`, `confidenceCap` are all part of the signed order — a maker cannot retroactively widen the cap after signing. On-chain logic (`PmmProtocol.sol:213-231`):

```
if (confidenceT != 0 && block.timestamp > confidenceT) {
    if (confidenceWeight != 0 && confidenceCap != 0) {
        if (confidenceCap > 50_000) revert RFQ_ConfidenceCapExceeded;
        timeDiff             = block.timestamp - confidenceT
        cutdownPercentageX6  = min(timeDiff * confidenceWeight, confidenceCap)
        makerAmount         -= makerAmount * cutdownPercentageX6 / 1e6
    }
}
```

Only `makerAmount` is reduced; `takerAmount` is unchanged. The settlement-limit check (60%) is evaluated **before** the reduction.

---

## 5. Verification Order (On-Chain)

The settlement entry is the **single** `fillOrderRFQTo(order, signature, flagsAndAmount, target, address[] allowedCallers, uint256 nonce, bytes authSig)`. `fillOrderRFQ`, `fillOrderRFQCompact`, and `fillOrderRFQToWithPermit` are not present in the current interface.

```
-1. rfqId range check (entry first statement, PmmProtocol.sol:115-117)
   - order.rfqId > type(uint64).max                      → RFQ_InvalidRfqId(rfqId)
0. _verifyCallerAuth(keccak256(abi.encode(order)), allowedCallers, nonce, authSig)
                                                             // Caller authorization, after the rfqId range check
   - authSig.length != 64                                → AUTH_BadSigLen
   - recover(authSig) != AUTH_SIGNER                     → AUTH_BadAuthSig
   - msg.sender ∉ allowedCallers (== [PmmAdapter])         → AUTH_UntrustedCaller
   - nonce already consumed                               → AUTH_NonceUsed
1. orderHash = order.hash(_domainSeparatorV4())          // EIP-712 digest
2. Signature path (selected by flagsAndAmount):
   - SIGNER_SMART_CONTRACT_HINT set + IS_VALID_SIGNATURE_65_BYTES set + signature.length != 65 → RFQ_BadSignature
   - SIGNER_SMART_CONTRACT_HINT set → ECDSA.isValidSignature(makerAddress, orderHash, signature)
                                       (65-byte enforcement is done by the _IS_VALID_SIGNATURE_65_BYTES
                                        flag inside this single entrypoint — there is no separate
                                        compact entrypoint or isValidSignature65 call)
   - Otherwise → ECDSA.recoverOrIsValidSignature(makerAddress, orderHash, signature)
   - Any failure → RFQ_BadSignature(rfqId)
3. Enter _fillOrderRFQTo:
   3a. target == 0                                       → RFQ_ZeroTargetIsForbidden
   3b. block.timestamp > order.expiry                    → RFQ_OrderExpired
   3c. _invalidateOrder(maker, rfqId, 0)                 → RFQ_InvalidatedOrder if bit already set
   3d. derive (makerAmount, takerAmount) from flagsAndAmount via AmountCalculator
        - amount > makerAmount                           → RFQ_MakerAmountExceeded
        - amount > takerAmount                           → RFQ_TakerAmountExceeded
        - full-fill && usePermit2 && makerAmount > uint160.max → RFQ_AmountTooLarge
   3e. makerAmount == 0 || takerAmount == 0              → RFQ_SwapWithZeroAmount
   3f. fill < 60% of quoted maker OR taker               → RFQ_SettlementAmountTooSmall
   3g. confidenceCap > 50000                             → RFQ_ConfidenceCapExceeded
   3h. apply confidence reduction (maker only)
```

State update and transfer last (CEI):

```
4. Maker leg transfer
   - usePermit2 && permit2Signature.length > 0 && permit2WitnessType.length > 0
                                       → IPermit2.permitWitnessTransferFrom
   - usePermit2 && permit2Signature.length > 0
                                       → IPermit2.permitTransferFrom
   - usePermit2 && permit2Signature empty
                                       → SafeERC20.safeTransferFromPermit2 (uint160 cap enforced)
   - else                              → SafeERC20.safeTransferFrom
5. WETH unwrap if flagged
   - _WETH.withdraw(makerAmount)
   - target.call{value: makerAmount, gas: 5000}("")     → RFQ_ETHTransferFailed on false
6. Taker leg transfer
   - takerAsset == WETH && msg.value > 0
       - msg.value != takerAmount      → RFQ_InvalidMsgValue
       - _WETH.deposit{value: takerAmount}()
       - _WETH.transfer(maker, takerAmount)
   - else
       - msg.value != 0                → RFQ_InvalidMsgValue
       - SafeERC20.safeTransferFrom(takerAsset, msg.sender, maker, takerAmount)
7. emit OrderFilledRFQ(...)
```

`nonReentrant` (from OpenZeppelin `ReentrancyGuard`) wraps every fill path.

---

## 6. Key Constraints

- [Rule] Changing `_NAME` or `_VERSION` invalidates **every** outstanding maker signature and requires coordinated signer updates. The `1.1 → 1.2` bump invalidated all `1.1` signatures.
- [Rule] `allowedSender` is part of the signed struct — a maker signs a quote for a specific taker address; it cannot be altered after signing without breaking the digest. The equality check `allowedSender == dexRouterCaller` is enforced in PMMAdapter, not in this EIP-712 layer (see [[pmm_anti_toxic_flow]]).
- [Rule] Reaching settlement requires TWO independent authorizations: the maker's EIP-712 OrderRFQ signature AND the caller-auth `authSig` (verified first, before the maker sig). See [[contract-CallerAuth]].
- [Rule] Each `PMMProtocol` deployment has its own domain separator (bound to `address(this)`) — signatures are not portable across chains or instances.
- [Rule] `keccak256(permit2Signature)` is part of the OrderRFQ struct hash, so the Permit2 signature **must** be signed before the OrderRFQ signature.
- [Rule] If `flagsAndAmount` sets `_SIGNER_SMART_CONTRACT_HINT`, the contract calls `IERC1271.isValidSignature(orderHash, signature)` on `order.makerAddress` — the contract signer **must** return the `0x1626ba7e` magic value.
- [Rule] The 64-vs-65-byte ECDSA signature malleability documented in `ECDSA.recover` is not exploitable here because each `(maker, rfqId)` pair is single-use via `_invalidator`.
- [Rule] `permit2Witness` is the keccak256 hash of the ABI-encoded witness fields. `permit2WitnessType` is a separate type string and is hashed independently in the OrderRFQ struct hash.
