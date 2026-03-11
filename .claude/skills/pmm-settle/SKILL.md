---
name: pmm-settle
description: PMM Settlement Contract integration skill. Use when the user asks about integrating with the OKX PMM RFQ protocol, signing orders, Permit2 witness flow, time-slippage parameters, or filling RFQ orders on-chain. Trigger words - "pmm", "rfq order", "permit2 sign", "confidence", "time slippage", "fillOrderRFQ", "settlement", "pmm settle", "pmm integration".
version: 1.0.0
user-invocable: true
allowed-tools: Read(**), Bash(**), Grep(**), Glob(**), Write(**), Edit(**), Agent(**)
---

# Skill: PMM Settlement Contract Integration

OKX Labs PMM (Private Market Maker) RFQ Settlement Protocol integration guide.

## Repository

`/Users/comcatli/Downloads/Web3-DEX-EVM-PMM`

## Architecture Overview

### Core Contracts

| File | Purpose |
|------|---------|
| `src/PmmProtocol.sol` | Main settlement contract - order fill, validation, transfers |
| `src/OrderRFQLib.sol` | OrderRFQ struct definition and EIP-712 hash computation |
| `src/PmmAdaptor.sol` | DEX aggregator adapter (supports V1/V2/V3 order formats) |
| `src/EIP712.sol` | EIP-712 domain separator |
| `src/helpers/AmountCalculator.sol` | Proportional amount derivation for partial fills |
| `src/libraries/Errors.sol` | All custom error definitions |
| `src/libraries/SafeERC20.sol` | Safe ERC20 + Permit2 transfer helpers |
| `src/libraries/ECDSA.sol` | Signature recovery (EOA + ERC-1271) |

### Deployment Addresses

| Chain | PmmProtocol | Adaptor |
|-------|-------------|---------|
| Ethereum | `0x5035D128ef482276Aa3bCce4307ffF8961ba30F9` | `0xce937da1ffd21673Aa1e063459873F30189A2193` |
| Arbitrum One | `0xcdC09a6B5211bb51F18A1Af7691B6725bB024434` | `0x50FEC44764EB2FBf86a212139213A743e299313c` |
| Base | `0x4EFBd630205DD9B987c3BcbEe257600abC1e3C11` | `0x4997a12D61520b0eB6D3758c8c0E97a6109B7995` |
| BNB Chain | `0xdD30339C4b2f7bac319Ef4Fa5c6963cc9F470B2d` | `0x61e3FcA605e2f0E29d5A176E1C9868d4f0ee817F` |

Permit2 (all chains): `0x000000000022D473030F116dDEE9F6B43aC78BA3`

## OrderRFQ Struct

```solidity
struct OrderRFQ {
    uint256 rfqId;            // 64-bit ID for replay protection (bitmap invalidation)
    uint256 expiry;           // Unix timestamp; block.timestamp must be <= expiry
    address makerAsset;       // Token sent by maker
    address takerAsset;       // Token sent by taker
    address makerAddress;     // Signer and fund owner
    uint256 makerAmount;      // Quoted maker size
    uint256 takerAmount;      // Quoted taker size
    bool usePermit2;          // Toggle Permit2 on maker leg
    uint256 confidenceT;      // Unix timestamp: slippage starts after this (0 = disabled)
    uint256 confidenceWeight; // Reduction rate per second in 1e6 units (0 = disabled)
    uint256 confidenceCap;    // Max cumulative reduction in 1e6 units (max 50000 = 5%, 0 = disabled)
    bytes permit2Signature;   // Inline Permit2 signature (65 bytes if present)
    bytes32 permit2Witness;   // Packed witness hash for Permit2
    string permit2WitnessType;// Canonical witness type string for Permit2
}
```

## EIP-712 Signing

### Domain

```javascript
// Source of truth: PmmProtocol.sol lines 58-59
const domain = {
  name: "OKX Labs PMM Protocol",   // PmmProtocol.sol:58
  version: "1.1",                   // PmmProtocol.sol:59
  chainId: <chainId>,
  verifyingContract: <PmmProtocol address>
};
```

**Script status (updated 2026-03-11):**
- `signOrderRFQ.js` — FIXED: version corrected to `"1.1"`
- `verifyDigest.js` — removed from repo (was outdated: wrong domain name, missing confidence fields)

### OrderRFQ Typehash

```
OrderRFQ(uint256 rfqId,uint256 expiry,address makerAsset,address takerAsset,address makerAddress,uint256 makerAmount,uint256 takerAmount,bool usePermit2,uint256 confidenceT,uint256 confidenceWeight,uint256 confidenceCap,bytes permit2Signature,bytes32 permit2Witness,string permit2WitnessType)
```

**IMPORTANT:** `bytes` fields are hashed with `keccak256()`, `string` fields are hashed with `keccak256(toUtf8Bytes())` before encoding.

### Struct Hash Encoding

```javascript
const structHash = keccak256(abi.encode(
  ORDER_RFQ_TYPEHASH,
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
  keccak256(order.permit2Signature),  // bytes -> keccak256
  order.permit2Witness,                // bytes32 as-is
  keccak256(toUtf8Bytes(order.permit2WitnessType))  // string -> keccak256
));
```

### Digest

```javascript
digest = keccak256(concat(["0x1901", domainSeparator, structHash]));
```

### Signature Format

```javascript
// Sign raw digest (NO Ethereum message prefix)
const sig = wallet.signingKey.sign(digest);
// Pack as r + s + v (65 bytes)
const signature = concat([sig.r, sig.s, toBeHex(sig.v, 1)]);
```

Reference implementation: `script/signOrderRFQ.js`

## Permit2 Integration

### Overview

The maker leg supports two Permit2 modes when `order.usePermit2 = true`:

### Mode 1: Allowance-based (no inline signature)

- Maker pre-approves Permit2 contract for the maker asset
- `permit2Signature` is empty (`"0x"` or `bytes("")`)
- Contract calls `safeTransferFromPermit2(makerAsset, maker, receiver, makerAmount)`
- Amount capped at `uint160.max`

### Mode 2: Signature-based (inline Permit2 signature)

- `permit2Signature` contains a 65-byte Permit2 signature
- Uses `order.rfqId` as Permit2 nonce
- Uses `order.expiry` as Permit2 deadline

#### Without Witness

When `permit2WitnessType` is empty:

```javascript
// Permit2 PermitTransferFrom
const permit = {
  permitted: { token: order.makerAsset, amount: order.makerAmount },
  nonce: order.rfqId,
  deadline: order.expiry
};
// Contract calls: permit2.permitTransferFrom(permit, transferDetails, maker, signature)
```

#### With Witness (recommended for production)

When `permit2WitnessType` is non-empty:

```javascript
// 1. Define witness struct (e.g., Consideration)
const CONSIDERATION_TYPEHASH = keccak256(toUtf8Bytes(
  "Consideration(address token,uint256 amount,address counterparty)"
));

// 2. Calculate witness hash
const witnessHash = keccak256(abi.encode(
  CONSIDERATION_TYPEHASH,
  consideration.token,     // e.g., takerAsset
  consideration.amount,    // e.g., takerAmount
  consideration.counterparty  // e.g., taker address
));

// 3. Set witness type string (MUST follow Permit2 EIP-712 format)
const witnessTypeString =
  "Consideration witness)Consideration(address token,uint256 amount,address counterparty)TokenPermissions(address token,uint256 amount)";

// 4. Sign Permit2 with witness
const PERMIT_WITNESS_TRANSFER_FROM_TYPEHASH = keccak256(toUtf8Bytes(
  `PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,${witnessTypeString}`
));

const tokenPermissionsHash = keccak256(abi.encode(
  TOKEN_PERMISSIONS_TYPEHASH,
  permit.permitted.token,
  permit.permitted.amount
));

const structHash = keccak256(abi.encode(
  PERMIT_WITNESS_TRANSFER_FROM_TYPEHASH,
  tokenPermissionsHash,
  spender,           // PmmProtocol address
  permit.nonce,      // order.rfqId
  permit.deadline,   // order.expiry
  witnessHash        // keccak256 of encoded witness data
));

const digest = keccak256(concat(["0x1901", permit2DomainSeparator, structHash]));
const sig = wallet.signingKey.sign(digest);
const permit2Signature = concat([sig.r, sig.s, toBeHex(sig.v, 1)]);

// 5. Populate order fields
order.permit2Signature = permit2Signature;
order.permit2Witness = witnessHash;
order.permit2WitnessType = witnessTypeString;
```

**Contract calls:** `permit2.permitWitnessTransferFrom(permit, transferDetails, maker, witness, witnessTypeString, signature)`

### Permit2 Domain Separator

The Permit2 contract has its own EIP-712 domain (separate from PmmProtocol's domain).

**IMPORTANT:** Permit2's EIP712Domain has only 3 fields (NO `version`), unlike PmmProtocol's 4-field domain:

```javascript
// Permit2 domain type (note: NO version field!)
const PERMIT2_DOMAIN_TYPE = "EIP712Domain(string name,uint256 chainId,address verifyingContract)";

// Compute manually (from verifyDigest.js:150-163):
const permit2DomainSeparator = keccak256(abi.encode(
  keccak256(toUtf8Bytes(PERMIT2_DOMAIN_TYPE)),
  keccak256(toUtf8Bytes("Permit2")),
  chainId,
  "0x000000000022D473030F116dDEE9F6B43aC78BA3"
));

// Or read from contract:
const permit2DomainSeparator = await permit2Contract.DOMAIN_SEPARATOR();
```

### Critical Notes on Permit2 Signing

1. **Two separate signatures required:** The order needs an EIP-712 OrderRFQ signature (signed against PmmProtocol domain), AND a Permit2 signature (signed against Permit2 domain). These are different digests with different domain separators.
2. **Nonce = rfqId:** Permit2 uses `order.rfqId` as the nonce. Each rfqId can only be used once.
3. **Deadline = expiry:** Permit2 deadline is set to `order.expiry`.
4. **Spender = PmmProtocol:** The spender in Permit2 is the PmmProtocol contract address.
5. **Witness type string format:** Must exactly follow Permit2's EIP-712 type concatenation rules. The string starts with the member name (`witness)`) then lists all referenced types alphabetically.
6. **Signature format:** Both signatures are 65 bytes: `r (32) + s (32) + v (1)`.

## Time-Slippage (Confidence) Mechanism

### Unit System

**Parts-per-million (1e6 = 100%)**

| Unit | Value | Equivalent |
|------|-------|------------|
| 1 in 1e6 | 0.0001% | 0.01 bps |
| 100 in 1e6 | 0.01% | 1 bps |
| 1000 in 1e6 | 0.1% | 10 bps |
| 10000 in 1e6 | 1% | 100 bps |
| 50000 in 1e6 | 5% | 500 bps (hard cap) |

### Conversion from bps

```
confidenceWeight = bps_per_second * 100
confidenceCap    = bps_cap * 100
```

Example: 0.75 bps/s rate, 12 bps cap:
- `confidenceWeight = 75`  (0.75 * 100)
- `confidenceCap = 1200`   (12 * 100)

### Formula

```
if block.timestamp > confidenceT && all three params != 0:
  timeDiff            = block.timestamp - confidenceT
  cutdownPercentageX6 = min(timeDiff * confidenceWeight, confidenceCap)
  adjustedMakerAmount = makerAmount - makerAmount * cutdownPercentageX6 / 1e6
```

### Rules

- Any param = 0 disables slippage entirely
- Only makerAmount is reduced; takerAmount unchanged
- Settlement limit (60%) checked BEFORE confidence reduction
- `confidenceCap > 50000` reverts with `RFQ_ConfidenceCapExceeded`

## Fill Flow (flagsAndAmount)

### Bit Flags

| Bit | Flag | Description |
|-----|------|-------------|
| 255 | `_MAKER_AMOUNT_FLAG` | Interpret amount as maker amount (else taker) |
| 254 | `_SIGNER_SMART_CONTRACT_HINT` | Signature from ERC-1271 contract |
| 253 | `_IS_VALID_SIGNATURE_65_BYTES` | Require 65-byte signature from contract |
| 252 | `_UNWRAP_WETH_FLAG` | Unwrap WETH to native ETH before sending to taker |
| 0-159 | `_AMOUNT_MASK` | Requested fill amount (0 = fill entire order) |

### Fill Functions

```solidity
// Fill to msg.sender
fillOrderRFQ(OrderRFQ order, bytes signature, uint256 flagsAndAmount)

// Fill to specific target
fillOrderRFQTo(OrderRFQ order, bytes signature, uint256 flagsAndAmount, address target)

// Execute ERC20 permit before filling
fillOrderRFQToWithPermit(OrderRFQ order, bytes signature, uint256 flagsAndAmount, address target, bytes permit)

// Compact signature (r, vs) format
fillOrderRFQCompact(OrderRFQ order, uint256 r, uint256 vs, uint256 flagsAndAmount)
```

### Settlement Limit

Both sides must be >= 60% of quoted amounts:
```
makerAmount >= order.makerAmount * 6000 / 10000
takerAmount >= order.takerAmount * 6000 / 10000
```

## Error Reference

| Error | Cause |
|-------|-------|
| `RFQ_ZeroTargetIsForbidden` | target address is 0x0 |
| `RFQ_OrderExpired` | block.timestamp > order.expiry |
| `RFQ_InvalidatedOrder` | rfqId already used or cancelled |
| `RFQ_BadSignature` | signature verification failed |
| `RFQ_SwapWithZeroAmount` | derived amount is 0 |
| `RFQ_MakerAmountExceeded` | requested > quoted maker |
| `RFQ_TakerAmountExceeded` | requested > quoted taker |
| `RFQ_SettlementAmountTooSmall` | fill < 60% of quote |
| `RFQ_ConfidenceCapExceeded` | confidenceCap > 50000 |
| `RFQ_AmountTooLarge` | Permit2 amount > uint160.max |
| `RFQ_InvalidMsgValue` | msg.value mismatch |
| `RFQ_ETHTransferFailed` | native ETH transfer failed |

## Event

```solidity
event OrderFilledRFQ(
    uint256 indexed rfqId,
    uint256 expiry,
    address indexed makerAsset,
    address indexed takerAsset,
    address makerAddress,
    uint256 expectedMakerAmount,
    uint256 expectedTakerAmount,
    uint256 filledMakerAmount,
    uint256 filledTakerAmount,
    bool usePermit2,
    bytes permit2Signature,
    bytes32 permit2Witness,
    string permit2WitnessType
);
```

## Order Scenarios (from testSignOrder.js)

### Scenario 1: No Permit2
```javascript
{ usePermit2: false, permit2Signature: "0x",
  permit2Witness: "0x0000...0000", permit2WitnessType: "" }
```

### Scenario 2: Permit2, no witness (allowance-based)
```javascript
{ usePermit2: true, permit2Signature: "0x",
  permit2Witness: "0x0000...0000", permit2WitnessType: "" }
```

### Scenario 3: Permit2 + ExampleWitness
```javascript
const WITNESS_TYPE_STRING = "ExampleWitness witness)ExampleWitness(address user)TokenPermissions(address token,uint256 amount)";
{ usePermit2: true,
  permit2Signature: signPermit2WithWitness({...witness: calculateWitness({user: MAKER_ADDRESS}), witnessTypeString: WITNESS_TYPE_STRING...}),
  permit2Witness: calculateWitness({user: MAKER_ADDRESS}),
  permit2WitnessType: WITNESS_TYPE_STRING }
```

### Scenario 4: Permit2 + Consideration witness (production)
```javascript
const CONSIDERATION_TYPE_STRING = "Consideration witness)Consideration(address token,uint256 amount,address counterparty)TokenPermissions(address token,uint256 amount)";
const CONSIDERATION = { token: MAKER_ASSET, amount: MAKER_AMOUNT, counterparty: TAKER_ADDRESS };
{ usePermit2: true,
  permit2Signature: signPermit2WithWitness({...witness: calculateWitnessConsideration(CONSIDERATION), witnessTypeString: CONSIDERATION_TYPE_STRING...}),
  permit2Witness: calculateWitnessConsideration(CONSIDERATION),
  permit2WitnessType: CONSIDERATION_TYPE_STRING }
```

## Quick Integration Checklist

1. Construct `OrderRFQ` struct with all 14 fields
2. If using Permit2 with inline signature:
   a. Compute witness hash (if using witness mode)
   b. Sign Permit2 PermitTransferFrom against **Permit2 domain** (3-field, NO version)
   c. Set `permit2Signature`, `permit2Witness`, `permit2WitnessType` on order
3. Sign OrderRFQ with maker's private key against **PmmProtocol domain** (4-field, version "1.1")
   - NOTE: OrderRFQ signature covers the Permit2 signature bytes (hashed), so Permit2 must be signed FIRST
4. Call `fillOrderRFQTo()` with order, OrderRFQ signature, flagsAndAmount, target
5. Handle events and errors appropriately

## Reference Files

- Order signing: `script/signOrderRFQ.js` (WARNING: version "1.0" should be "1.1")
- Sign test vectors: `script/testSignOrder.js` (4 scenarios: no-permit2, permit2-no-witness, ExampleWitness, Consideration)
- Digest verification: `script/verifyDigest.js` (WARNING: outdated — wrong domain name, missing confidence fields)
- Core contract: `src/PmmProtocol.sol`
- Order struct: `src/OrderRFQLib.sol`
- Tests: `test/PmmProtocol.t.sol`, `test/PmmProtocolTimeSlippage.t.sol`, `test/PmmProtocolPermitWitnessFork.t.sol`
