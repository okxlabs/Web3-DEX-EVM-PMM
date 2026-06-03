---
name: "eip712-signature-design"
description: "EIP-712 typed-data signing architecture for OrderRFQ — domain separator, struct hash, backend generation, and on-chain verification order"
---

# EIP-712 Signature Design

`PMMProtocol` uses EIP-712 typed-data signatures as the sole authorization mechanism for maker quotes. This document is the authority on how signatures are constructed, what each field covers, and how the contract verifies them.

---

## 1. Domain Separator

Built once at deploy time by the inherited `EIP712` constructor (see `EIP712.sol:52-63`), and rebuilt on the fly if `block.chainid` or `address(this)` ever differs (post-fork safety).

```solidity
string private constant _NAME    = "OKX Labs PMM Protocol";   // PmmProtocol.sol:58
string private constant _VERSION = "1.1";                      // PmmProtocol.sol:59
```

Effective domain:

```
EIP712Domain(
    string name               = "OKX Labs PMM Protocol"
    string version            = "1.1"
    uint256 chainId           = block.chainid    (at construction)
    address verifyingContract = address(this)
)
```

| Field | Prevents |
|-------|----------|
| `name` | Phishing via lookalike contracts that use a different name |
| `version` | Replay after a contract upgrade that changes typehash semantics |
| `chainId` | Cross-chain replay |
| `verifyingContract` | Cross-contract replay across PMMProtocol instances on the same chain |

The on-chain accessor is `DOMAIN_SEPARATOR()` (selector `0x3644e515`).

---

## 2. OrderRFQ Typehash (`OrderRFQLib.sol`)

`OrderRFQLib._LIMIT_ORDER_RFQ_TYPEHASH` (V3 format, 14 fields):

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
| 9 | `confidenceT` | `uint256` | direct | Time-slippage activation timestamp. |
| 10 | `confidenceWeight` | `uint256` | direct | Reduction rate per second (1e6 units). |
| 11 | `confidenceCap` | `uint256` | direct | Maximum reduction (1e6 units; on-chain cap 50000 = 5%). |
| 12 | `permit2Signature` | `bytes` | `keccak256(permit2Signature)` | Optional inline Permit2 signature. **Bound** so a swap to a different Permit2 sig invalidates the OrderRFQ digest. |
| 13 | `permit2Witness` | `bytes32` | direct | Pre-hashed witness payload (already a hash). |
| 14 | `permit2WitnessType` | `string` | `keccak256(bytes(permit2WitnessType))` | Canonical witness type string for `permitWitnessTransferFrom`. |

Struct hash construction (`OrderRFQLib.hash`):

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

---

## 3. Backend Signature Generation

Reference JS implementation: `script/signOrderRFQ.js` (mirrors the Solidity hashing logic). Steps:

```
1. Build domainSeparator (matches contract: NAME="OKX Labs PMM Protocol", VERSION="1.1", chainId, verifyingContract)
2. Build structHash from all 14 OrderRFQ fields with the encoding rules above
3. digest = keccak256("\x19\x01" || domainSeparator || structHash)
4. (v, r, s) = sign(digest, makerPrivateKey)
5. signature = abi.encodePacked(r, s, v)   // 65 bytes
```

If the maker is a smart-contract signer (ERC-1271), set bit 254 (`_SIGNER_SMART_CONTRACT_HINT`) on `flagsAndAmount` so the protocol skips `ecrecover` and calls `IERC1271.isValidSignature(orderHash, signature)`. Set bit 253 (`_IS_VALID_SIGNATURE_65_BYTES`) only when the contract expects exactly 65 bytes — the protocol then enforces `signature.length == 65`.

### Two-Signature Permit2 Flow

When `usePermit2 = true` **and** `permit2Signature` is non-empty:

1. **Sign the Permit2 message FIRST** against the Permit2 domain (3 fields: `name`, `chainId`, `verifyingContract` — **no `version`**).
2. Embed that 65-byte Permit2 signature into `order.permit2Signature`.
3. **Then** compute the OrderRFQ struct hash — which depends on `keccak256(order.permit2Signature)`.
4. Maker signs the OrderRFQ digest against the PMMProtocol domain (4 fields, `version = "1.1"`).

Reversing the order produces a Permit2 signature that does not match the OrderRFQ binding and the fill will revert (the Permit2 call inside `_fillOrderRFQTo` reverts before any other state change observable to the maker).

---

## 4. Confidence (Time-Slippage) Semantics

`confidenceT`, `confidenceWeight`, `confidenceCap` are all part of the signed order — a maker cannot retroactively widen the cap after signing. On-chain logic (`PmmProtocol.sol:265-281`):

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

In `fillOrderRFQTo` / `fillOrderRFQCompact` (`PmmProtocol.sol:165-200`):

```
1. orderHash = order.hash(_domainSeparatorV4())          // EIP-712 digest
2. Signature path (selected by flagsAndAmount):
   - SIGNER_SMART_CONTRACT_HINT set + IS_VALID_SIGNATURE_65_BYTES set + signature.length != 65 → RFQ_BadSignature
   - SIGNER_SMART_CONTRACT_HINT set → ECDSA.isValidSignature(makerAddress, orderHash, signature)
                                       (or .isValidSignature65 for the compact entrypoint)
   - Otherwise → ECDSA.recoverOrIsValidSignature(makerAddress, orderHash, signature)
   - Any failure → RFQ_BadSignature(rfqId)
3. Enter _fillOrderRFQTo:
   3a. target == 0                                       → RFQ_ZeroTargetIsForbidden
   3b. block.timestamp > expiry                          → RFQ_OrderExpired
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

- [Rule] Changing `_NAME` or `_VERSION` invalidates **every** outstanding maker signature — coordinate with backend before deploying any new domain.
- [Rule] Each `PMMProtocol` deployment has its own domain separator (bound to `address(this)`) — signatures are not portable across chains or instances.
- [Rule] `keccak256(permit2Signature)` is part of the OrderRFQ struct hash, so the Permit2 signature **must** be signed before the OrderRFQ signature.
- [Rule] If `flagsAndAmount` sets `_SIGNER_SMART_CONTRACT_HINT`, the contract calls `IERC1271.isValidSignature(orderHash, signature)` on `order.makerAddress` — the contract signer **must** return the `0x1626ba7e` magic value.
- [Rule] The 64-vs-65-byte ECDSA signature malleability documented in `ECDSA.recover` is not exploitable here because each `(maker, rfqId)` pair is single-use via `_invalidator`.

<!-- TODO: Confirm the exact Permit2 typed-data witness construction used by the off-chain signer matches keccak256 of the witness fields, not the witness type string itself -->
