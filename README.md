# Web3 Trade PMM - RFQ Onboarding Guide

This document explains how OKX Labs onboards private market makers (PMMs) to its RFQ routing stack. It covers the end-to-end workflow—from API expectations through smart-contract semantics—so teams can plug into the aggregator without reverse-engineering the contracts or scripts in this repository.

## 1. Terminology

| Term | Description |
|------|-------------|
| PMM | Private Market Maker that streams bespoke RFQ liquidity through OKX Labs routing |
| RFQ ID | `uint64` identifier embedded in `OrderRFQ.rfqId`; used for replay protection |
| flagsAndAmount | `uint256` passed into fill methods; high bits encode execution flags, low 160 bits encode the desired maker or taker amount |
| Settlement limit | 60% minimum fill ratio enforced against `makerAmount` and `takerAmount` to avoid dust fills |
| Permit2 witness | Extra typed data blob signed by makers when using `permitWitnessTransferFrom` |
| Permit2 witness type | Canonical string describing the custom witness struct (e.g., `ExampleWitness witness)ExampleWitness(address user)TokenPermissions(address token,uint256 amount)`) |
| WETH unwrap flag | Bit 252 in `flagsAndAmount`; when set, the maker leg unwraps WETH and sends native ETH |
| Order invalidator | Bitmask stored per maker address to flag consumed or cancelled RFQ IDs |

## 2. Background

The OKX Labs DEX aggregator traditionally relied on AMM liquidity. Large trades experienced slippage and MEV exposure, so RFQ connectivity on EVM chains was prioritized to deliver tighter spreads and deterministic settlement. The Solidity contracts in this repository implement the on-chain leg of that RFQ flow, while off-chain makers expose pricing and signing services.

### 2.1 Document Versions

- **v2.0** - Added Permit2-based maker transfers.
- **v3.0 (Nov 2025)** - Explicit `OrderRFQ` struct, inline Permit2 signatures + witness data, cancellable RFQ IDs, settlement guardrails, and updated EIP-712 domain `"OKX Labs PMM Protocol"`.
- **v4.0 (Feb 2026)** - Added time-slippage (confidence) mechanism: `confidenceT`, `confidenceWeight`, and `confidenceCap` fields in `OrderRFQ`, enabling makers to encode automatic price decay for stale quotes (capped at 5%). This is the baseline for the current public release.

## 3. Overview

Private market makers plug into the OKX Labs DEX aggregator by returning signed RFQ orders that can be filled on-chain via `PMMProtocol`. The router compares PMM quotes against AMM and CEX-style order books and selects the path with the best expected outcome.

### 3.1 Trading Workflow

1. **API activation** - Makers expose REST/WebSocket feeds for `/levels` and `/order`.
2. **Data sync** - Once the feeds pass integration tests, the router polls them per chain for live depth.
3. **Price aggregation** - RFQ quotes are merged with AMM books to build an aggregated execution graph.
4. **Path selection** - During quote requests, the router simulates all paths and picks PMM legs when they win on price + gas.
5. **Quote delivery** - Users review the combined quote and request calldata for the selected PMM order.
6. **Order signature** - The maker service signs the `OrderRFQ` struct and, if needed, embeds a Permit2 witness signature.
7. **Execution** - The taker broadcasts `fillOrderRFQ*` along with the maker signature (and optionally a Permit2 signature and/or ERC20 permit for the taker asset).
8. **Settlement flow** - Maker funds move directly to the taker (or a specified target). Taker funds move to the maker, optionally wrapping/unwrapping WETH as dictated by the flags.

### 3.2 Key Characteristics

- **Replay protection** - RFQ IDs are tracked per maker via bitmask invalidators and can also be cancelled on-chain.
- **Deterministic signatures** - All fills rely on the `OrderRFQLib.hash` helper and the domain `"OKX Labs PMM Protocol" / v1.0`.
- **Partial fills** - Supported through `flagsAndAmount`, including maker- or taker-denominated inputs, while enforcing a 60% minimum settlement ratio.
- **Permit2-native maker leg** - Makers can set `usePermit2=true` and optionally ship inline Permit2 signatures + witness metadata; otherwise standard `transferFrom` is used.
- **WETH unwrap option** - Bit 252 unwraps WETH before forwarding funds, enabling native ETH settlement.
- **Taker ERC20 permits** - `fillOrderRFQToWithPermit` can execute an ERC20 permit (EIP-2612 or Dai-like) before consuming the order.
- **Time-slippage (confidence)** - Orders may include `confidenceT`, `confidenceWeight`, and `confidenceCap` fields. If `block.timestamp` exceeds `confidenceT`, the maker amount is reduced linearly over time (up to a 5% hard cap), giving makers built-in price protection against stale quotes.
- **Security hardening** - Contract inherits `ReentrancyGuard`, validates signatures for EOAs or smart-contract signers, and rejects unexpected `msg.value`.

## 4. Smart Contract Integration

### 4.1 `OrderRFQ` Structure

```solidity
struct OrderRFQ {
    uint256 rfqId;            // 64-bit ID used for invalidation tracking
    uint256 expiry;           // Unix timestamp; block.timestamp must be <= expiry
    address makerAsset;       // Token sent by the maker
    address takerAsset;       // Token sent by the taker
    address makerAddress;     // Signer and fund owner
    uint256 makerAmount;      // Quoted maker size
    uint256 takerAmount;      // Quoted taker size
    bool usePermit2;          // Toggles Permit2 transfers on the maker leg
    uint256 confidenceT;      // Unix timestamp after which time-slippage begins (0 = disabled)
    uint256 confidenceWeight; // Reduction rate per second in 1e6 units (0 = disabled)
    uint256 confidenceCap;    // Maximum cumulative reduction in 1e6 units (0 = disabled, max 50000 = 5%)
    bytes permit2Signature;   // Optional inline Permit2 signature (65 bytes if present)
    bytes32 permit2Witness;   // Packed witness hash when using Permit2 witnesses
    string permit2WitnessType;// Canonical witness type string for Permit2
}
```

Field notes:
- `rfqId` should fit within 64 bits; higher bits are truncated when the invalidator slot is computed.
- `makerAmount`/`takerAmount` are capped by the settlement limit check (>= 60% when partially filling) and by the Permit2 `uint160` ceiling when `usePermit2` is true.
- `confidenceT` / `confidenceWeight` / `confidenceCap` control the time-slippage mechanism. Setting any of them to zero disables slippage entirely. See [section 4.9](#49-time-slippage-confidence-mechanism) for details.
- `permit2Signature` can be empty if the maker relies on pre-approved allowances with Permit2; if populated, it must encode either a standard `permitTransferFrom` (no witness data) or a `permitWitnessTransferFrom` payload whose witness fields match the values supplied alongside the order.

### 4.2 `flagsAndAmount`

`flagsAndAmount` is a compact instruction word used across the fill functions.

| Bit | Constant | Description |
|-----|----------|-------------|
| 255 | `_MAKER_AMOUNT_FLAG` | Interpret the low bits as a maker-denominated amount; otherwise as taker amount. Zero means "fill the entire order".
| 254 | `_SIGNER_SMART_CONTRACT_HINT` | Set when the maker signature originates from a contract implementing ERC-1271.
| 253 | `_IS_VALID_SIGNATURE_65_BYTES` | When combined with the hint bit, enforces that the calldata signature is exactly 65 bytes.
| 252 | `_UNWRAP_WETH_FLAG` | Unwraps WETH into native ETH before forwarding to the taker/target.

The lower 160 bits (`_AMOUNT_MASK`) carry the requested fill amount. If that amount exceeds the quoted maker or taker totals, the fill reverts with `RFQ_MakerAmountExceeded` or `RFQ_TakerAmountExceeded`. Amount calculations rely on `AmountCalculator.getMakerAmount` and `AmountCalculator.getTakerAmount`:

```
makerAmount = (takerAmount * orderMakerAmount) / orderTakerAmount

takerAmount = (makerAmount * orderTakerAmount + orderMakerAmount - 1) / orderMakerAmount
```

### 4.3 Events

```solidity
// Emitted on every successful fill
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

// Emitted when makers cancel IDs manually
event OrderCancelledRFQ(uint256 indexed rfqId, address indexed maker);
```

### 4.4 Public Methods

- `DOMAIN_SEPARATOR()` - Returns the current EIP-712 domain separator.
- `invalidatorForOrderRFQ(address maker, uint256 slot)` - Exposes the raw 256-bit bitmap for a given maker/slot.
- `isRfqIdUsed(address maker, uint64 rfqId)` - Convenience helper to check whether an RFQ ID is consumed.
- `fillOrderRFQ(...)` - Fills to `msg.sender` using a standard signature.
- `fillOrderRFQCompact(...)` - Accepts a compact signature `(r, vs)` and optimizes calldata for EOAs.
- `fillOrderRFQTo(...)` - Same as `fillOrderRFQ` but forwards maker funds to `target`.
- `fillOrderRFQToWithPermit(...)` - Executes an ERC20 permit for the taker asset before calling `_fillOrderRFQTo`.
- `cancelOrderRFQ(uint64 rfqId)` - Allows makers to invalidate quotes on-chain.

All fill variants are `nonReentrant`, validate signature length hints, and revert with descriptive errors from `libraries/Errors.sol` when preconditions fail.

### 4.5 Fill Lifecycle & Guardrails

1. **Target check** - Zero addresses are rejected via `RFQ_ZeroTargetIsForbidden`.
2. **Expiry** - `block.timestamp` must be <= `order.expiry`.
3. **Invalidation** - `_invalidateOrder` sets the relevant bit in the maker's bitmap and fails if already set.
4. **Amount derivation** - If the masked amount is zero, the full quote is used. Otherwise the contract derives the complementary side via `AmountCalculator` and enforces upper bounds.
5. **Settlement limit** - Both maker and taker sides must be at least 60% of their quoted values (`_SETTLE_LIMIT / _SETTLE_LIMIT_BASE`). This blocks dust fills.
6. **Time-slippage (confidence)** - If `confidenceT > 0` and `block.timestamp > confidenceT`, the maker amount is reduced by `min(timeDiff * confidenceWeight, confidenceCap) / 1e6`. The taker amount is not affected. The settlement limit is evaluated **before** this reduction, so the order can still pass the 60% check even though the taker ultimately receives a slightly smaller maker amount.
7. **Maker leg transfer** - If `order.usePermit2` is true, the contract either executes a Permit2 transfer with the inline signature (witness-aware) or calls `transferFrom` on Permit2 using prior allowances. Otherwise, `SafeERC20.safeTransferFrom` pulls funds directly from the maker.
8. **WETH unwrap (optional)** - When `_UNWRAP_WETH_FLAG` is set and `makerAsset` equals the configured WETH, funds are sent to the protocol, unwrapped, and forwarded as native ETH with a 5k gas stipend.
9. **Taker leg transfer** - If the taker asset is WETH and `msg.value == takerAmount`, the protocol wraps the ETH and pushes WETH to the maker. Otherwise, it requires `msg.value == 0` and executes `safeTransferFrom` from the taker.
10. **Event emission** - `OrderFilledRFQ` is emitted with expected and actual amounts along with the Permit2 usage flag.

### 4.6 Maker Permit2 Flows

`order.usePermit2` switches the maker leg to Uniswap's Permit2 contract (`0x000000000022D473030F116dDEE9F6B43aC78BA3`). Two options exist:

1. **Allowance-based** - Makers pre-approve Permit2 and leave `permit2Signature` empty. During settlement the contract invokes `safeTransferFromPermit2`, which enforces the `uint160` amount ceiling.
2. **Signature-based** - Makers embed a signature in `permit2Signature`. The protocol builds `IPermit2.PermitTransferFrom` using `order.rfqId` as the nonce and `order.expiry` as the deadline. If `permit2WitnessType` is non-empty, it calls `permitWitnessTransferFrom` with the supplied witness hash; otherwise it calls `permitTransferFrom`.

Witness workflow:
- `permit2Witness` must equal the keccak256 hash of the witness data (see `script/signOrderRFQ.js::calculateWitness`).
- `permit2WitnessType` must include the entire custom type string concatenated with the Permit2 base types, exactly as required by Permit2's typed data format.

### 4.7 Taker ERC20 Permits

`fillOrderRFQToWithPermit` accepts an arbitrary `permit` blob before calling `fillOrderRFQTo`. `SafeERC20.safePermit` auto-detects EIP-2612 (7-word payload) vs Dai-style (8-word payload) permits, enabling gas-efficient taker approvals.

### 4.8 Order Cancellation & Invalidators

RFQ IDs are tracked via a two-level bitmap:
- Slot index = `rfqId >> 8`.
- Bit position = `rfqId & 0xff`.

`cancelOrderRFQ` sets the corresponding bit and emits `OrderCancelledRFQ`. The same helper is used internally when orders are filled. Any attempt to reuse an RFQ ID triggers `RFQ_InvalidatedOrder` or `RFQ_OrderAlreadyCancelledOrUsed`.

### 4.9 Time-Slippage (Confidence) Mechanism

Makers can embed time-based slippage parameters in their orders so that stale quotes automatically give the taker a smaller maker amount the longer the order sits unfilled. This replaces the need for short expiry windows and gives makers continuous price protection.

**Parameters**

| Field | Type | Description |
|-------|------|-------------|
| `confidenceT` | `uint256` | Unix timestamp marking the start of the slippage window. Before this time (or if set to `0`) no reduction is applied. |
| `confidenceWeight` | `uint256` | Reduction rate per second expressed in parts-per-million (1e6 = 100%). E.g. `1000` means 0.1% per second. Set to `0` to disable. |
| `confidenceCap` | `uint256` | Maximum cumulative reduction in parts-per-million. Capped at `_CONFIDENCE_CAP_LIMIT` (50 000 = 5%). Set to `0` to disable. |

**Formula**

When `block.timestamp > confidenceT` and all three parameters are non-zero:

```
timeDiff            = block.timestamp - confidenceT
cutdownPercentageX6 = min(timeDiff * confidenceWeight, confidenceCap)
adjustedMakerAmount = makerAmount - makerAmount * cutdownPercentageX6 / 1e6
```

**Behaviour summary**

- If any of `confidenceT`, `confidenceWeight`, or `confidenceCap` is `0`, the mechanism is fully disabled and the maker amount is unmodified.
- At or before `confidenceT`, no reduction is applied (`block.timestamp > confidenceT` is strict).
- Once active, the reduction grows linearly at `confidenceWeight` per second until it hits `confidenceCap`.
- Only the maker amount is reduced; the taker amount remains unchanged.
- The 60% settlement limit is evaluated **before** the confidence reduction, so the settlement check passes on the original amounts.
- If `confidenceCap > _CONFIDENCE_CAP_LIMIT` (50 000), the transaction reverts with `RFQ_ConfidenceCapExceeded`.

**Example**

A maker quotes 100 USDC with `confidenceT = T+10 min`, `confidenceWeight = 1000` (0.1%/s), `confidenceCap = 50000` (5%). If the order is filled 50 seconds after `confidenceT`:

```
cutdown = min(50 * 1000, 50000) = 50000   → 5% (capped)
adjusted = 100 - 100 * 50000 / 1e6 = 95 USDC
```

The taker receives 95 USDC instead of 100.

## 5. API Specification

refer to: https://web3.okx.com/zh-hant/build/dev-docs/wallet-api/dex-api-market-maker

### 5.3 Permit2 Inline Signature Payload

When returning `permit2Signature`, makers should also provide the witness metadata used to construct the signature. Example witness JSON handed to the signing stack:

```json
{
  "witness": {
    "user": "0xexampletaker"
  },
  "witnessTypeString": "ExampleWitness witness)ExampleWitness(address user)TokenPermissions(address token,uint256 amount)"
}
```

The contract hashes `permit2Signature` and `permit2WitnessType` internally to remain consistent with `OrderRFQLib.hash`.

## 6. Signing Toolkit

The repository ships `script/signOrderRFQ.js`, which mirrors the Solidity hashing logic.

```javascript
import { signOrderRFQ, calculateWitness, WITNESS_TYPE_STRING } from "./script/signOrderRFQ.js";

const order = {
  rfqId: 123456789n,
  expiry: BigInt(Math.floor(Date.now() / 1000) + 90),
  makerAsset: addresses.USDT,
  takerAsset: addresses.WETH,
  makerAddress: makerWallet.address,
  makerAmount: 22_723_800n,
  takerAmount: 6_000_000_000_000_000n,
  usePermit2: true,
  confidenceT: BigInt(Math.floor(Date.now() / 1000) + 30),  // slippage starts 30s from now
  confidenceWeight: 1000n,                                    // 0.1% per second
  confidenceCap: 50000n,                                      // max 5% reduction
  permit2Signature: permitSigHex,            // 0x prefixed or "0x"
  permit2Witness: calculateWitness({ user: takerAddress }),
  permit2WitnessType: WITNESS_TYPE_STRING
};

const signature = await signOrderRFQ({
  privateKey: makerPrivateKey,
  verifyingContract: pmmProtocolAddress,
  chainId: 42161,
  order
});
```

The helper also exports `signPermit2WithWitness`, which produces the Permit2 signature expected in `order.permit2Signature`.

## 7. Testing & Deployment Checklist

- `forge test` - Runs the Foundry test-suite (`test/`), including fork tests for Permit2 witness flows and WETH unwrap scenarios.
- `broadcast/Deploy*.s.sol` - Contains deployment artifacts generated via Foundry Scripts; review them before mainnet pushes.


## 8. Document Metadata

- **Document version**: v4.0
- **Last updated**: Feb 2026
- **Language**: English
