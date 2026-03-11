---
name: pmm-debug-sig
description: Debug PMM RFQ order signatures and Permit2 signatures. Use when signature verification fails (RFQ_BadSignature), Permit2 transfers revert, digest mismatch, or any EIP-712 signing issue in the PMM protocol. Trigger words - "signature failed", "bad signature", "digest mismatch", "permit2 revert", "签名失败", "签名调试", "debug signature", "debug sign", "pmm debug".
version: 1.0.0
user-invocable: true
allowed-tools: Read(**), Bash(**), Grep(**), Glob(**), Write(**), Edit(**), Agent(**)
---

# Skill: PMM Signature Debugger

Diagnose and fix EIP-712 signature issues in OKX PMM RFQ Protocol, including OrderRFQ signatures and Permit2 signatures.

## When to Use

- `RFQ_BadSignature` error on-chain
- Permit2 `permitTransferFrom` or `permitWitnessTransferFrom` reverts
- Digest computed off-chain doesn't match on-chain expectation
- Recovered signer doesn't match `order.makerAddress`
- Signature works on one chain but fails on another

## Diagnostic Procedure

When the user reports a signature issue, follow this systematic checklist:

### Step 1: Identify Which Signature Failed

There are **TWO independent signatures** in a Permit2 flow:

| Signature | Domain | Signed By | Verified By |
|-----------|--------|-----------|-------------|
| **OrderRFQ signature** | PmmProtocol domain | Maker EOA | PmmProtocol contract (ECDSA.recover) |
| **Permit2 signature** | Permit2 domain | Maker EOA | Permit2 contract |

**Ask the user:** Which signature is failing? OrderRFQ or Permit2? Or both?

### Step 2: Verify OrderRFQ Signature

#### 2a. Domain Separator

```javascript
// MUST match the deployed contract's domain (PmmProtocol.sol:58-59)
const domain = {
  name: "OKX Labs PMM Protocol",     // PmmProtocol.sol:58
  version: "1.1",                    // PmmProtocol.sol:59
  chainId: <CORRECT_CHAIN_ID>,       // <-- Must match deployment chain
  verifyingContract: <PmmProtocol>   // <-- Must match actual contract address
};
```

**Script status (updated 2026-03-11):**
- `script/signOrderRFQ.js` — FIXED: version corrected to `"1.1"`
- `script/verifyDigest.js` — removed from repo (was outdated: wrong domain name, missing confidence fields)

**Common errors:**
- Wrong `version` string (contract uses `"1.1"`, older code may use `"1.0"`)
- Wrong domain name (was renamed from `"OnChain Labs"` to `"OKX Labs"`)
- Wrong `chainId` (e.g., using mainnet chainId on testnet)
- Wrong `verifyingContract` (using Adaptor address instead of PmmProtocol)

**Verification:** Read `src/EIP712.sol` to confirm the domain parameters:
```bash
# Check domain name and version in contract
grep -n "PMM Protocol\|version" src/EIP712.sol
```

#### 2b. Typehash

```
OrderRFQ(uint256 rfqId,uint256 expiry,address makerAsset,address takerAsset,address makerAddress,uint256 makerAmount,uint256 takerAmount,bool usePermit2,uint256 confidenceT,uint256 confidenceWeight,uint256 confidenceCap,bytes permit2Signature,bytes32 permit2Witness,string permit2WitnessType)
```

**Common errors:**
- Missing fields (e.g., old code without confidence fields)
- Wrong field order
- Extra spaces or commas in the type string

**Verification:** Compare with `src/OrderRFQLib.sol` lines 29-42.

#### 2c. Struct Hash Encoding

```javascript
abi.encode(
  TYPEHASH,
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
  keccak256(order.permit2Signature),              // bytes -> hash first!
  order.permit2Witness,                            // bytes32 -> as-is
  keccak256(toUtf8Bytes(order.permit2WitnessType)) // string -> hash first!
)
```

**Critical encoding rules:**
1. `bytes` type (`permit2Signature`): MUST `keccak256()` before encoding
2. `string` type (`permit2WitnessType`): MUST `keccak256(toUtf8Bytes())` before encoding
3. `bytes32` type (`permit2Witness`): Encode directly, NO hashing
4. `bool` type (`usePermit2`): Encoded as `uint256(0)` or `uint256(1)`
5. `address` type: Left-padded to 32 bytes

**Common errors:**
- Forgetting to hash `permit2Signature` bytes
- Forgetting to hash `permit2WitnessType` string
- Hashing `permit2Witness` (bytes32 should NOT be hashed)
- Using empty string `""` vs empty bytes `"0x"` inconsistently

#### 2d. Signature Format

```javascript
// CORRECT: Sign raw digest, pack as r + s + v
const sig = wallet.signingKey.sign(digest);
const signature = concat([sig.r, sig.s, toBeHex(sig.v, 1)]);  // 65 bytes

// WRONG: Using signMessage() adds Ethereum prefix!
// const signature = await wallet.signMessage(digest);  // DO NOT USE
```

**Common errors:**
- Using `wallet.signMessage()` which adds `\x19Ethereum Signed Message:\n32` prefix
- Wrong v value (should be 27 or 28)
- Swapped r/s/v order
- Using compact signature (64 bytes) when 65 bytes expected (or vice versa)

### Step 3: Verify Permit2 Signature

#### 3a. Permit2 Domain Separator

**CRITICAL:** Permit2's EIP712Domain has only **3 fields** (NO `version`!), unlike PmmProtocol's 4-field domain:

```javascript
// Permit2 domain type — note NO version field!
const PERMIT2_DOMAIN_TYPE = "EIP712Domain(string name,uint256 chainId,address verifyingContract)";

// Compute (from verifyDigest.js:150-163):
const permit2DomainSeparator = keccak256(abi.encode(
  keccak256(toUtf8Bytes(PERMIT2_DOMAIN_TYPE)),  // 3-field type hash
  keccak256(toUtf8Bytes("Permit2")),
  chainId,
  "0x000000000022D473030F116dDEE9F6B43aC78BA3"
));

// Compare:
// PmmProtocol domain: EIP712Domain(string name, string version, uint256 chainId, address verifyingContract) — 4 fields
// Permit2 domain:     EIP712Domain(string name, uint256 chainId, address verifyingContract)                  — 3 fields
```

**Common errors:**
- Using PmmProtocol's domain separator instead of Permit2's
- Including `version` in Permit2 domain (Permit2 has no version field)
- Wrong Permit2 address (same on all EVM chains: `0x000000000022D473030F116dDEE9F6B43aC78BA3`)

#### 3b. PermitTransferFrom (without witness)

```
PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)
```

Parameters:
- `permitted.token` = `order.makerAsset`
- `permitted.amount` = `order.makerAmount`
- `spender` = PmmProtocol contract address
- `nonce` = `order.rfqId`
- `deadline` = `order.expiry`

#### 3c. PermitWitnessTransferFrom (with witness)

```
PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,<WitnessType> witness)<WitnessType>(<fields>)TokenPermissions(address token,uint256 amount)
```

**Witness type string format is critical:**

```javascript
// For Consideration witness:
const witnessTypeString =
  "Consideration witness)Consideration(address token,uint256 amount,address counterparty)TokenPermissions(address token,uint256 amount)";
//  ^-- starts with member declaration, NO opening paren for PermitWitnessTransferFrom
```

**How the full typehash is constructed:**
```javascript
const fullType = `PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,${witnessTypeString}`;
// Result: "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Consideration witness)Consideration(address token,uint256 amount,address counterparty)TokenPermissions(address token,uint256 amount)"
```

**Common errors:**
- Adding opening paren before witness type name
- Missing `TokenPermissions(address token,uint256 amount)` at the end
- Wrong alphabetical order of referenced types
- Typo in witness type name or fields
- Witness hash doesn't match the witness type string

#### 3d. Witness Hash Computation

```javascript
// For Consideration struct:
const CONSIDERATION_TYPEHASH = keccak256(toUtf8Bytes(
  "Consideration(address token,uint256 amount,address counterparty)"
));

const witnessHash = keccak256(abi.encode(
  CONSIDERATION_TYPEHASH,
  consideration.token,
  consideration.amount,
  consideration.counterparty
));
```

**Common errors:**
- Typehash doesn't match the fields being encoded
- Field order in encode doesn't match type definition
- Using wrong data for witness fields

### Step 4: Cross-Check Tool

**WARNING:** `script/verifyDigest.js` is outdated (as of 2026-03-11) — it uses wrong domain name, wrong version, and missing confidence fields. Use it only for Permit2 signing logic reference, NOT for OrderRFQ verification.

**Test vectors from verifyDigest.js** (useful for Permit2 signing validation):
```javascript
// Hardhat #0 private key
const PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
// Expected hashes (for the OLD domain/typehash, but Permit2 witness hash is still valid):
const EXPECTED_PERMIT2_WITNESS = "0x951f9706fd39d6a67e130deab708eb03c7fbd0df5fc94466f7011f3ff8bd9b49";
```

**Signing order matters:**
1. Sign Permit2 FIRST (produces `permit2Signature` bytes)
2. Then sign OrderRFQ (which includes `keccak256(permit2Signature)` in its struct hash)

Run verification:
```bash
cd /Users/comcatli/Downloads/Web3-DEX-EVM-PMM
node script/verifyDigest.js  # outdated but useful for Permit2 step validation
```

### Step 5: On-Chain Verification

```bash
# Check domain separator on deployed contract
cast call <PmmProtocol> "DOMAIN_SEPARATOR()(bytes32)" --rpc-url <RPC>

# Check Permit2 domain separator
cast call 0x000000000022D473030F116dDEE9F6B43aC78BA3 "DOMAIN_SEPARATOR()(bytes32)" --rpc-url <RPC>

# Recover signer from signature
cast wallet verify --address <expected_signer> <message_hash> <signature>
```

## Common Failure Patterns

### Pattern 1: "Works locally, fails on-chain"
**Cause:** Domain separator mismatch (wrong chainId or verifyingContract)
**Fix:** Ensure chainId and contract address match the deployment

### Pattern 2: "OrderRFQ sig works, Permit2 sig fails"
**Cause:** Using PmmProtocol domain for Permit2 signature
**Fix:** Use Permit2's own domain separator

### Pattern 3: "Worked before, now fails after upgrade"
**Cause:** OrderRFQ struct changed (new fields added)
**Fix:** Update typehash to include all current fields (confidenceT/Weight/Cap)

### Pattern 4: "Permit2 witness sig fails"
**Cause:** Witness type string format error
**Fix:** Verify the exact format: `"<Type> witness)<Type>(<fields>)TokenPermissions(address token,uint256 amount)"`

### Pattern 5: "Signature valid but wrong signer recovered"
**Cause:** Different field values between signing and verification
**Fix:** Log every field value on both sides and compare byte-by-byte

### Pattern 6: "Empty permit2Signature handling"
**Cause:** `"0x"` vs `""` vs `new Uint8Array(0)` encode differently
**Fix:** For empty bytes, use `"0x"` consistently. When hashing: `keccak256("0x")` = `keccak256(bytes(""))` = `0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`

## Debug Output Template

When debugging, output results in this format:

```
=== PMM Signature Debug Report ===

1. Signature Type: [OrderRFQ / Permit2 / Both]
2. Chain: [chainId] ([network name])

--- OrderRFQ Signature ---
Domain Name:        "OKX Labs PMM Protocol"
Domain Version:     "1.1"
Domain ChainId:     [value]
Domain Contract:    [address]
Domain Separator:   [computed hash]
Typehash:           [computed hash]
Struct Hash:        [computed hash]
Digest:             [computed hash]
Expected Signer:    [order.makerAddress]
Recovered Signer:   [recovered from signature]
Match:              [YES/NO]

--- Permit2 Signature (if applicable) ---
Permit2 Domain Sep: [computed hash]
Permit Type:        [PermitTransferFrom / PermitWitnessTransferFrom]
Token:              [order.makerAsset]
Amount:             [order.makerAmount]
Spender:            [PmmProtocol address]
Nonce:              [order.rfqId]
Deadline:           [order.expiry]
Witness Hash:       [computed hash or N/A]
Witness Type:       [string or N/A]
Permit2 Digest:     [computed hash]
Expected Signer:    [order.makerAddress]
Recovered Signer:   [recovered from signature]
Match:              [YES/NO]

--- Diagnosis ---
[Root cause explanation and fix]
```
