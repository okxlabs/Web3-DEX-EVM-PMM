---
squad: web3-dex
domain: pmm
sub_domain: pmm_settlement
title: PMM RFQ Settlement (On-Chain)
source_docs: ["README.md (v4.0 — Feb 2026)", "src/PmmProtocol.sol", "src/OrderRFQLib.sol", "src/EIP712.sol", "src/libraries/SafeERC20.sol", "src/helpers/AmountCalculator.sol", "src/libraries/Errors.sol"]
concept_keys: [PmmProtocol, OrderRFQ, RfqId, MakerLeg, TakerLeg, SettlementLimit, ConfidenceWindow, ConfidenceCap, Permit2AllowancePath, Permit2SignaturePath, Permit2WitnessPath, WethUnwrap, InvalidatorBitmap, CancelOrderRfq, FlagsAndAmount]
organized_at: 2026-06-01T00:00:00Z
---

# PMM RFQ Settlement (On-Chain)

> Business line: Web3 DEX (PMM Integration)

## One-line Summary

`PMMProtocol` settles maker-signed RFQ orders on-chain — verifies an EIP-712 OrderRFQ signature, enforces single-use `rfqId`, applies a 60% minimum-fill guardrail and an optional time-decay (confidence) reduction capped at 5%, then performs the maker leg via standard ERC-20 or one of three Permit2 modes, optionally unwrapping WETH for native-ETH delivery, and pulls the taker leg from `msg.sender`.

---

## 1. Business Background & Scope

- **Positioning**: This contract is the on-chain leg of the OKX DEX aggregator's PMM RFQ flow. Off-chain market makers stream signed `OrderRFQ` structs; takers (or the aggregator via `PMMAdapter`) submit them on-chain to receive maker assets and deliver taker assets in a single atomic transaction.
- **Boundary notes**:
  - **In scope (this doc)**: maker signature verification, RFQ-ID replay protection, fill-amount math, settlement-limit guardrail, time-slippage (confidence) reduction, four maker-leg transfer modes (standard / Permit2 allowance / Permit2 signature / Permit2 signature + witness), WETH wrap/unwrap, taker-leg permit-then-fill, manual maker cancellation.
  - **Out of scope (here)**: off-chain backend monitoring and auto-offline of misbehaving PMMs (see [[pmm_auto_offline]]); aggregator-side adapter dispatch over multiple OrderRFQ versions (see [[pmm_adapter_migration]]).
  - **Not implemented**: fee-on-transfer maker assets are explicitly unsupported — the protocol uses the calculated transfer amount, not a balance-of-before/after delta. Documented in `src/PmmProtocol.sol:162-164`.

## 2. Core Content

### 2.1 OrderRFQ Struct & EIP-712 Signing (`OrderRFQ`)

**Struct** (14 fields, declared in `src/OrderRFQLib.sol:7-23`):

| # | Field | Type | Purpose |
|---|-------|------|---------|
| 1 | `rfqId` | `uint256` | Replay-protection ID; only low 64 bits significant on-chain |
| 2 | `expiry` | `uint256` | Unix timestamp; reused as Permit2 `deadline` |
| 3 | `makerAsset` | `address` | Token the maker sends |
| 4 | `takerAsset` | `address` | Token the taker sends |
| 5 | `makerAddress` | `address` | Signer + fund owner |
| 6 | `makerAmount` | `uint256` | Quoted maker size |
| 7 | `takerAmount` | `uint256` | Quoted taker size |
| 8 | `usePermit2` | `bool` | If true, maker leg uses Permit2 |
| 9 | `confidenceT` | `uint256` | Unix timestamp where time-slippage activates (0 disables) |
| 10 | `confidenceWeight` | `uint256` | Reduction rate per second in 1e6 units |
| 11 | `confidenceCap` | `uint256` | Max cumulative reduction (1e6 units); hard-capped at 50000 (5%) |
| 12 | `permit2Signature` | `bytes` | Optional inline Permit2 signature |
| 13 | `permit2Witness` | `bytes32` | Pre-hashed witness data |
| 14 | `permit2WitnessType` | `string` | Canonical witness type string |

**Domain**: `name="OKX Labs PMM Protocol"`, `version="1.1"`, `chainId=block.chainid`, `verifyingContract=address(this)` (`src/PmmProtocol.sol:58-75`, `src/EIP712.sol:52-63`).

**Main flow** (fill entrypoint → `_fillOrderRFQTo`):

1. Caller invokes one of `fillOrderRFQ` / `fillOrderRFQTo` / `fillOrderRFQCompact` / `fillOrderRFQToWithPermit`. (Source: src/PmmProtocol.sol:100-200)
2. Compute `orderHash = OrderRFQLib.hash(order, _domainSeparatorV4())`. (Source: src/PmmProtocol.sol:114, :171)
3. Verify the maker signature: ECDSA recover (EOA) or ERC-1271 `isValidSignature` (contract signer), gated by bits 254/253 of `flagsAndAmount`. Failure → `RFQ_BadSignature(rfqId)`. (Source: src/PmmProtocol.sol:115-129, :172-183)
4. Run `_fillOrderRFQTo` — see §2.2 through §2.7. (Source: src/PmmProtocol.sol:202)

**Key constraints**:
- [Rule] `permit2Signature` (`bytes`) and `permit2WitnessType` (`string`) MUST be hashed via `keccak256` before being placed into the EIP-712 struct hash; `permit2Witness` (`bytes32`) is encoded directly. (Source: src/OrderRFQLib.sol:46-69)
- [Rule] When `usePermit2 = true` and `permit2Signature` is non-empty, the Permit2 signature MUST be signed FIRST (against the Permit2 domain, no `version` field), then embedded into `order.permit2Signature` before computing the OrderRFQ digest. The OrderRFQ struct hash depends on `keccak256(permit2Signature)`. (Source: derived from src/OrderRFQLib.sol:63 + Permit2 EIP-712 spec)
- [Rule] Changing `_NAME` or `_VERSION` invalidates every outstanding maker signature. (Source: src/PmmProtocol.sol:58-59, src/EIP712.sol:52-63)

### 2.2 RFQ-ID Replay Protection (`InvalidatorBitmap`, `RfqId`)

**Storage** (`src/PmmProtocol.sol:73`):

```solidity
mapping(address => mapping(uint256 => uint256)) private _invalidator;
```

**Math** (`src/PmmProtocol.sol:93-98`, `:341-355`):

- Slot = `uint64(rfqId) >> 8`
- Bit position = `1 << (uint8(rfqId) & 0xff)`

Each maker has their own bitmap; only the low 64 bits of `rfqId` participate in the math.

**Main flow**:
1. `_fillOrderRFQTo` calls `_invalidateOrder(maker, rfqId, 0)` BEFORE any external transfer (CEI). (Source: src/PmmProtocol.sol:219)
2. If the bit is already set → `RFQ_InvalidatedOrder(rfqId)`. (Source: src/PmmProtocol.sol:350-352)
3. Otherwise the bit is flipped on. (Source: src/PmmProtocol.sol:354)

**Key constraints**:
- [Rule] An `rfqId` can be consumed at most once per `maker`; the bit is monotonically set and never cleared. (Source: src/PmmProtocol.sol:341-355)
- [Rule] `_invalidateOrder` MUST be called before any maker-leg transfer (checks-effects-interactions). (Source: src/PmmProtocol.sol:219 before :287-318)

### 2.3 Fill Amount Derivation (`FlagsAndAmount`)

`flagsAndAmount` (`uint256`) carries flags in the high bits and the requested fill amount in the low 160 bits (`src/PmmProtocol.sol:61-70`).

| Bit | Constant | Meaning |
|-----|----------|---------|
| 255 | `_MAKER_AMOUNT_FLAG` | If set, low bits = maker-side amount; else taker-side |
| 254 | `_SIGNER_SMART_CONTRACT_HINT` | Maker uses ERC-1271 |
| 253 | `_IS_VALID_SIGNATURE_65_BYTES` | Enforce signature length == 65 (paired with bit 254) |
| 252 | `_UNWRAP_WETH_FLAG` | Unwrap WETH to native ETH on the maker leg |
| 0–159 | `_AMOUNT_MASK` | Requested amount; 0 means full fill |

**Calculation rules** (`src/PmmProtocol.sol:222-249` + `src/helpers/AmountCalculator.sol`):

- **Full fill** (`amount == 0`): take quoted `makerAmount` and `takerAmount` as-is.
- **Maker-side partial** (`_MAKER_AMOUNT_FLAG` set, `amount > 0`): `takerAmount = (amount * orderTakerAmount + orderMakerAmount - 1) / orderMakerAmount` (ceiled). (Source: src/helpers/AmountCalculator.sol:19-25)
- **Taker-side partial** (`_MAKER_AMOUNT_FLAG` not set, `amount > 0`): `makerAmount = (amount * orderMakerAmount) / orderTakerAmount` (floored). (Source: src/helpers/AmountCalculator.sol:8-14)
- Bounds: maker-side `amount > orderMakerAmount` → `RFQ_MakerAmountExceeded`; taker-side `amount > orderTakerAmount` → `RFQ_TakerAmountExceeded`. (Source: src/PmmProtocol.sol:237-244)
- Full-fill with `usePermit2 = true` AND `orderMakerAmount > uint160.max` → `RFQ_AmountTooLarge`. (Source: src/PmmProtocol.sol:233-235)

**Key constraints**:
- [Rule] Taker amount is rounded UP (ceil) to prevent under-payment for partial fills. (Source: src/helpers/AmountCalculator.sol:17-25)
- [Rule] Maker amount is rounded DOWN (floor). (Source: src/helpers/AmountCalculator.sol:6-14)

### 2.4 Settlement-Limit Guardrail (`SettlementLimit`)

**Rule** (`src/PmmProtocol.sol:256-261`):

```solidity
if (
    makerAmount < (order.makerAmount * _SETTLE_LIMIT) / _SETTLE_LIMIT_BASE
        || takerAmount < (order.takerAmount * _SETTLE_LIMIT) / _SETTLE_LIMIT_BASE
) {
    revert Errors.RFQ_SettlementAmountTooSmall(order.rfqId);
}
```

Constants: `_SETTLE_LIMIT = 6000`, `_SETTLE_LIMIT_BASE = 10000` (`src/PmmProtocol.sol:66-67`).

**Main flow**:
1. After amount derivation (§2.3) and before confidence reduction (§2.5), assert both legs are at least 60% of quote. (Source: src/PmmProtocol.sol:256-261)
2. Below 60% → revert `RFQ_SettlementAmountTooSmall(rfqId)`.

**Key constraints**:
- [Rule] Minimum fill is **60%** of the quoted maker AND quoted taker amounts. (Source: src/PmmProtocol.sol:66-67, :256-261)
- [Rule] The 60% check is evaluated on the **pre-confidence-reduction** maker amount; the confidence reduction afterwards may bring the actually-transferred maker amount slightly below 60% (capped at 5% reduction, so the realized minimum is ~57%). (Source: src/PmmProtocol.sol:256-281 ordering)

### 2.5 Time-Slippage / Confidence Reduction (`ConfidenceWindow`, `ConfidenceCap`)

**Purpose**: protect makers from stale quotes by reducing the maker amount linearly after a configured timestamp.

**Formula** (`src/PmmProtocol.sol:265-281`):

```
if confidenceT != 0 && block.timestamp > confidenceT:
    if confidenceWeight != 0 && confidenceCap != 0:
        if confidenceCap > 50_000: revert RFQ_ConfidenceCapExceeded
        timeDiff             = block.timestamp - confidenceT
        cutdownPercentageX6  = min(timeDiff * confidenceWeight, confidenceCap)   // 1e6 units
        makerAmount         -= makerAmount * cutdownPercentageX6 / 1e6
```

`_CONFIDENCE_CAP_LIMIT = 50000` = 5% in 1e6 units (`src/PmmProtocol.sol:69`).

**Disabling rule**: if ANY of `confidenceT`, `confidenceWeight`, `confidenceCap` is `0`, the mechanism is fully disabled and the maker amount is unchanged.

**Main flow**:
1. Read `confidenceT`. If `0` or `block.timestamp <= confidenceT` → no reduction. (Source: src/PmmProtocol.sol:266-267)
2. Read `confidenceWeight` and `confidenceCap`. If either is `0` → no reduction. (Source: src/PmmProtocol.sol:268-269)
3. If `confidenceCap > 50000` → revert `RFQ_ConfidenceCapExceeded`. (Source: src/PmmProtocol.sol:270-272)
4. Compute `cutdownPercentageX6 = min(timeDiff * confidenceWeight, confidenceCap)`. (Source: src/PmmProtocol.sol:273-277)
5. Reduce maker amount by that percentage. Taker amount is unchanged. (Source: src/PmmProtocol.sol:278)

**Key constraints**:
- [Rule] `confidenceCap` MUST be ≤ `50000` (5%); larger values revert. (Source: src/PmmProtocol.sol:270-272)
- [Rule] Only the maker amount is reduced; the taker still pays the full `takerAmount`. (Source: src/PmmProtocol.sol:278 only modifies makerAmount)
- [Rule] The reduction is applied AFTER the 60% settlement check, so a maker may receive ~57% net (60% × 95%) in the worst case. (Source: src/PmmProtocol.sol:256-281 ordering)
- [Pitfall] All three confidence params MUST be set together; setting only `confidenceT` without weight/cap silently disables the protection. (Source: src/PmmProtocol.sol:267-269)

### 2.6 Maker-Leg Transfer (4 modes)

After amount derivation and confidence reduction, the maker leg is transferred via one of four paths, selected by `order.usePermit2`, `order.permit2Signature.length`, and `order.permit2WitnessType.length` (`src/PmmProtocol.sol:287-318`).

**Mode A — Standard ERC-20** (`usePermit2 = false`):
```solidity
IERC20(order.makerAsset).safeTransferFrom(maker, receiver, makerAmount);
```
Uses the project's local `src/libraries/SafeERC20.sol` (assembly-level `transferFrom` with bool / extcodesize fallback).

**Mode B — Permit2 allowance** (`usePermit2 = true`, `permit2Signature` empty):
```solidity
IERC20(order.makerAsset).safeTransferFromPermit2(maker, receiver, makerAmount);
```
Requires maker to have pre-approved Permit2. Enforces `amount ≤ uint160.max` or reverts `Permit2TransferAmountTooHigh`. (Source: src/libraries/SafeERC20.sol:32-49)

**Mode C — Permit2 signature** (`usePermit2 = true`, `permit2Signature` non-empty, `permit2WitnessType` empty):
```solidity
IPermit2.permitTransferFrom(permitTransferFrom, signatureTransferDetails, maker, order.permit2Signature)
```
Permit2 `nonce = order.rfqId`, `deadline = order.expiry`. (Source: src/PmmProtocol.sol:290-294, :308-310)

**Mode D — Permit2 signature + witness** (`usePermit2 = true`, both `permit2Signature` and `permit2WitnessType` non-empty):
```solidity
IPermit2.permitWitnessTransferFrom(permitTransferFrom, signatureTransferDetails, maker,
                                   order.permit2Witness, order.permit2WitnessType, order.permit2Signature)
```
Used when the maker needs the Permit2 signature to bind to extra structured data (e.g., the taker address). (Source: src/PmmProtocol.sol:298-306)

**Receiver selection**: when `_UNWRAP_WETH_FLAG` is set AND `order.makerAsset == WETH`, the receiver is `address(this)` (the contract holds WETH transiently before unwrapping). Otherwise the receiver is `target`. (Source: src/PmmProtocol.sol:283-286)

**Key constraints**:
- [Rule] Permit2 `nonce` MUST equal `order.rfqId`; `deadline` MUST equal `order.expiry`. Off-chain signers that use different values will produce digests that fail. (Source: src/PmmProtocol.sol:290-294)
- [Rule] In Mode B (Permit2 allowance), maker amount > `uint160.max` reverts; this is also pre-checked on the full-fill path at `src/PmmProtocol.sol:233-235`. (Source: src/libraries/SafeERC20.sol:33)

### 2.7 WETH Wrap / Unwrap

**Maker-leg unwrap** (`src/PmmProtocol.sol:319-324`): if `_UNWRAP_WETH_FLAG` is set and `order.makerAsset == _WETH`, the contract calls `_WETH.withdraw(makerAmount)` then forwards native ETH to `target` via a low-level call with `gas = _RAW_CALL_GAS_LIMIT (5000)`. Failure → `RFQ_ETHTransferFailed`.

**Taker-leg wrap** (`src/PmmProtocol.sol:327-336`): if `takerAsset == _WETH` AND `msg.value > 0`:
- `msg.value != takerAmount` → `RFQ_InvalidMsgValue`.
- Otherwise wrap the ETH (`_WETH.deposit{value: takerAmount}()`) and `_WETH.transfer(maker, takerAmount)`.

Otherwise (non-WETH taker, OR WETH taker with `msg.value == 0`):
- `msg.value != 0` → `RFQ_InvalidMsgValue`.
- `IERC20(order.takerAsset).safeTransferFrom(msg.sender, maker, takerAmount)`.

**`receive()` guard** (`src/PmmProtocol.sol:79-83`): the contract accepts ETH ONLY when `msg.sender == address(_WETH)` (i.e., during WETH withdraw). Any other sender reverts `RFQ_EthDepositRejected`.

**Key constraints**:
- [Rule] Native ETH on the maker leg requires both `_UNWRAP_WETH_FLAG` set AND `makerAsset == WETH`; setting only the flag does nothing. (Source: src/PmmProtocol.sol:283)
- [Rule] Native ETH on the taker leg requires `takerAsset == WETH` AND `msg.value == takerAmount` exactly; off-by-one reverts. (Source: src/PmmProtocol.sol:327-330)
- [Rule] The unwrap-forward `.call` has a `5000`-gas stipend; `target` must accept ETH within that budget or the fill reverts. (Source: src/PmmProtocol.sol:61, :322)
- [Pitfall] `_WETH.transfer` on the taker-leg wrap does not check the return value (lint warning suppressed because WETH9 is a known-good contract). (Source: src/PmmProtocol.sol:332)

### 2.8 Taker Permit (EIP-2612 / Dai-Style)

`fillOrderRFQToWithPermit` accepts an ERC-20 permit blob for the taker asset and consumes it before settling (`src/PmmProtocol.sol:149-158`). `SafeERC20.safePermit` auto-detects:
- `permit.length == 32 * 7` → EIP-2612 `permit`. (Source: src/libraries/SafeERC20.sol:109-110)
- `permit.length == 32 * 8` → Dai-style `permit`. (Source: src/libraries/SafeERC20.sol:111-112)
- Any other length → `SafePermitBadLength`. (Source: src/libraries/SafeERC20.sol:113-114)

This allows gasless taker approval without a separate transaction.

### 2.9 Maker Cancellation (`CancelOrderRfq`)

`cancelOrderRFQ(uint64 rfqId)` lets a maker invalidate their own `rfqId` before any taker fills it (`src/PmmProtocol.sol:357-367`).

**Main flow**:
1. `maker = msg.sender` is bound — the caller can only cancel their own bitmap. (Source: src/PmmProtocol.sol:358)
2. If `isRfqIdUsed(maker, rfqId)` is already true → `RFQ_OrderAlreadyCancelledOrUsed(rfqId)`. (Source: src/PmmProtocol.sol:360-362)
3. Flip the bit in `_invalidator[msg.sender][slot]`. (Source: src/PmmProtocol.sol:364)
4. Emit `OrderCancelledRFQ(rfqId, maker)`. (Source: src/PmmProtocol.sol:366)

**Key constraints**:
- [Rule] Cancellation is per-maker — a maker cannot cancel another maker's `rfqId`. (Source: src/PmmProtocol.sol:358)
- [Rule] No signature is required — the EOA control of `msg.sender` is the only authorization. (Source: src/PmmProtocol.sol:357-367)
- [Rule] `cancelOrderRFQ` is NOT `nonReentrant` because it makes no external calls. (Source: src/PmmProtocol.sol:357 lacks modifier)

---

## 3. State Machine

### 3.1 OrderRFQ State Enum

The state of an `(maker, rfqId)` pair is captured implicitly in the `_invalidator` bitmap. There are only two states.

| State | Description |
|-------|-------------|
| `UNUSED` | Bit `(maker, rfqId)` is `0` in `_invalidator`. Either never seen or never created. Eligible for a fill or cancel. |
| `CONSUMED` | Bit `(maker, rfqId)` is `1`. Set by either a successful fill (`_fillOrderRFQTo`) or an explicit cancellation (`cancelOrderRFQ`). Terminal — bits are never cleared. |

### 3.2 OrderRFQ State Transitions

```
UNUSED ──── fill succeeds (fillOrderRFQ*) ─────────►  CONSUMED
UNUSED ──── maker calls cancelOrderRFQ(rfqId) ────►   CONSUMED

CONSUMED ─── (terminal — no transition out)

Failure paths from UNUSED (no state change):
  - block.timestamp > expiry              → RFQ_OrderExpired
  - signature invalid                     → RFQ_BadSignature
  - target == address(0)                  → RFQ_ZeroTargetIsForbidden
  - fill < 60% of quote                   → RFQ_SettlementAmountTooSmall
  - confidenceCap > 50000                 → RFQ_ConfidenceCapExceeded
  - msg.value mismatch                    → RFQ_InvalidMsgValue
  - amount > order bound                  → RFQ_MakerAmountExceeded / RFQ_TakerAmountExceeded
  - usePermit2 full-fill amount > 2^160-1 → RFQ_AmountTooLarge
  - WETH unwrap .call returns false       → RFQ_ETHTransferFailed

Failure path from CONSUMED:
  - any fill or cancel attempt → RFQ_InvalidatedOrder / RFQ_OrderAlreadyCancelledOrUsed
```

---

## 4. Core Calculation Rules

- **`orderHash`** = `ECDSA.toTypedDataHash(domainSeparator, keccak256(abi.encode(_LIMIT_ORDER_RFQ_TYPEHASH, ...14 fields...)))`. (Source: src/OrderRFQLib.sol:46-69)
- **`makerAmount`** (taker-side fill) = `(swapTakerAmount * orderMakerAmount) / orderTakerAmount` — floored. (Source: src/helpers/AmountCalculator.sol:8-14)
- **`takerAmount`** (maker-side fill) = `(swapMakerAmount * orderTakerAmount + orderMakerAmount - 1) / orderMakerAmount` — ceiled. (Source: src/helpers/AmountCalculator.sol:19-25)
- **Settlement minimum** = `order.{maker,taker}Amount × 0.60`; both legs must satisfy. (Source: src/PmmProtocol.sol:66-67, :256-261)
- **Confidence reduction** = `makerAmount × min(timeDiff × confidenceWeight, confidenceCap) / 1e6`, with hard cap `confidenceCap ≤ 50000` (5%). (Source: src/PmmProtocol.sol:69, :265-281)
- **Invalidator slot/bit** = `slot = uint64(rfqId) >> 8`, `bit = 1 << (uint8(rfqId) & 0xff)`. (Source: src/PmmProtocol.sol:93-95, :342-344)

---

## 5. Access Control

| Role | Permitted Actions | Constraints |
|------|-------------------|-------------|
| Maker (any EOA or ERC-1271 contract) | Sign `OrderRFQ`; call `cancelOrderRFQ(uint64)` to invalidate own `rfqId` | Authorization is the EIP-712 signature (for fills) or `msg.sender == makerAddress` (for cancellation). Cannot cancel another maker's IDs. |
| Taker / anyone | Call any `fillOrderRFQ*` with a valid maker signature | The maker signature is the only authorization. No anti-front-run protection — front-running is acceptable by design (src/PmmProtocol.sol:159-160). |
| `_WETH` only | Send ETH to the contract (during `withdraw`) | Any other ETH sender → `RFQ_EthDepositRejected`. (Source: src/PmmProtocol.sol:79-83) |
| Aggregator router | Call `PMMAdapter.sellBase` / `sellQuote`; see [[pmm_adapter_migration]] | Adapter is stateless; downstream calls `PMMProtocol.fillOrderRFQTo`. |

- **Immutable roles**: `_WETH` (set in constructor, no setter — redeploy to change). No owner / admin role exists.
- **Zero-address validation**: `target == address(0)` → `RFQ_ZeroTargetIsForbidden`. (Source: src/PmmProtocol.sol:206-208)

---

## 6. Events

| Event Name | Trigger Condition | Key Parameters |
|------------|-------------------|----------------|
| `OrderFilledRFQ` | A successful fill via `fillOrderRFQTo` or `fillOrderRFQCompact` | `rfqId` (indexed), `expiry`, `makerAsset` (indexed), `takerAsset` (indexed), `makerAddress`, `expectedMakerAmount`, `expectedTakerAmount`, `filledMakerAmount`, `filledTakerAmount`, `usePermit2`, `permit2Signature`, `permit2Witness`, `permit2WitnessType` (Source: src/PmmProtocol.sol:33-47) |
| `OrderCancelledRFQ` | Maker invalidates an unused `rfqId` via `cancelOrderRFQ` | `rfqId` (indexed), `maker` (indexed) (Source: src/PmmProtocol.sol:56) |

**Observation note**: there is no event for failed fills; reverts surface as named custom errors from `src/libraries/Errors.sol`.

---

## 7. Constraints & Risk Rules

- [Rule] `fillOrderRFQTo` and `fillOrderRFQCompact` are `nonReentrant` (OpenZeppelin `ReentrancyGuard`). External token transfers and a low-level ETH `.call` are the reentrancy surface. (Source: src/PmmProtocol.sol:111, :170)
- [Rule] `_invalidator` is updated BEFORE any token transfer (CEI pattern). (Source: src/PmmProtocol.sol:219 vs :287)
- [Rule] `_WETH` is `immutable` — set once in the constructor, no setter exists. (Source: src/PmmProtocol.sol:72, :75-77)
- [Rule] `_NAME = "OKX Labs PMM Protocol"` and `_VERSION = "1.1"` are `constant`. Any change is a breaking redeploy because the cached domain separator depends on them. (Source: src/PmmProtocol.sol:58-59)
- [Rule] All ERC-20 transfers from `PMMProtocol` use the project's local `SafeERC20` (`src/libraries/SafeERC20.sol`) — never bare `IERC20.transfer` / `transferFrom`.
- [Rule] Fee-on-transfer (deflationary / rebasing) tokens are NOT supported — the protocol uses calculated transfer amounts, not balance deltas. (Source: src/PmmProtocol.sol:162-164)
- [Rule] Maker amount > `uint160.max` is rejected at full-fill time when `usePermit2 = true` (`RFQ_AmountTooLarge`). (Source: src/PmmProtocol.sol:233-235)
- [Rule] `confidenceCap > 50000` (5% in 1e6 units) is rejected at fill time (`RFQ_ConfidenceCapExceeded`). (Source: src/PmmProtocol.sol:69-70, :270-272)
- [Rule] `receive()` accepts ETH only from `_WETH`. (Source: src/PmmProtocol.sol:79-83)
- [Pitfall] The settlement-limit (60%) check is run BEFORE confidence reduction, so the worst-case net maker amount delivered to the taker can be ~57% of the original quote (60% × 95%). (Source: src/PmmProtocol.sol:256-281 ordering)
- [Pitfall] Bit 252 (`_UNWRAP_WETH_FLAG`) is silently ignored if `order.makerAsset != _WETH`. (Source: src/PmmProtocol.sol:283)
- [Pitfall] EIP-2098 64-byte vs canonical 65-byte signature malleability is known but mitigated by the per-`(maker, rfqId)` single-use bitmap. (Source: src/libraries/ECDSA.sol:57-64)

---

## 8. Test Focus

### Happy Path
- [ ] Full fill with `amount = 0`, standard ERC-20 maker leg: transfers exactly `order.makerAmount` and `order.takerAmount`, emits `OrderFilledRFQ`, sets bit in `_invalidator`.
- [ ] Maker-side partial fill at 60% of quote: succeeds, taker amount is ceiled, settlement check passes.
- [ ] Taker-side partial fill at 60% of quote: succeeds, maker amount is floored.
- [ ] Fill with confidence params unset (`confidenceT = 0`): no reduction applied.
- [ ] Fill with all three confidence params set, after `confidenceT`: maker amount reduced by `min(timeDiff × weight, cap) / 1e6`; taker amount unchanged.
- [ ] Permit2 allowance path (`usePermit2 = true`, `permit2Signature` empty): `safeTransferFromPermit2` succeeds for amount ≤ `uint160.max`.
- [ ] Permit2 signature path (no witness): `IPermit2.permitTransferFrom` called with `nonce = rfqId`, `deadline = expiry`.
- [ ] Permit2 signature + witness path: `IPermit2.permitWitnessTransferFrom` called with `permit2Witness` and `permit2WitnessType`.
- [ ] WETH unwrap on maker leg: `_WETH.withdraw` succeeds, native ETH reaches `target` within 5000 gas.
- [ ] WETH wrap on taker leg with `msg.value == takerAmount`: ETH wrapped, WETH transferred to maker.
- [ ] `fillOrderRFQToWithPermit` with EIP-2612 permit (7×32 bytes) and Dai-style permit (8×32 bytes): both succeed.
- [ ] Cancel an unused `rfqId`: bit set, `OrderCancelledRFQ` emitted.

### Unhappy Path
- [ ] Expired order (`block.timestamp > expiry`) → `RFQ_OrderExpired(rfqId)`.
- [ ] Replay (`rfqId` already used) → `RFQ_InvalidatedOrder(rfqId)`.
- [ ] Cancel already-used `rfqId` → `RFQ_OrderAlreadyCancelledOrUsed(rfqId)`.
- [ ] Wrong signer / malformed signature → `RFQ_BadSignature(rfqId)`.
- [ ] `target == address(0)` → `RFQ_ZeroTargetIsForbidden(rfqId)`.
- [ ] Maker-side amount > `order.makerAmount` → `RFQ_MakerAmountExceeded(rfqId)`.
- [ ] Taker-side amount > `order.takerAmount` → `RFQ_TakerAmountExceeded(rfqId)`.
- [ ] Fill < 60% on either leg → `RFQ_SettlementAmountTooSmall(rfqId)`.
- [ ] `confidenceCap > 50000` → `RFQ_ConfidenceCapExceeded(rfqId)`.
- [ ] `usePermit2 = true` full-fill with `makerAmount > uint160.max` → `RFQ_AmountTooLarge(rfqId)`.
- [ ] Non-WETH taker asset with `msg.value > 0` → `RFQ_InvalidMsgValue(rfqId)`.
- [ ] WETH taker asset with `msg.value != takerAmount` → `RFQ_InvalidMsgValue(rfqId)`.
- [ ] WETH unwrap to a `target` contract whose `receive()` consumes > 5000 gas → `RFQ_ETHTransferFailed(rfqId)`.
- [ ] Random EOA sends ETH to `receive()` → `RFQ_EthDepositRejected()`.
- [ ] Maker A tries to cancel Maker B's `rfqId` — silently flips A's own bit; B's bit untouched (verify bit isolation).

### High-Risk Scenarios
- [ ] Reentrancy attempt via a malicious ERC-1271 maker contract that re-enters `fillOrderRFQ`: must be blocked by `nonReentrant`.
- [ ] Permit2 signature ordering: a maker signs OrderRFQ first then changes `permit2Signature` — fill must revert (digest depends on `keccak256(permit2Signature)`).
- [ ] Confidence params set only partially (e.g., `confidenceT > 0`, `confidenceWeight = 0`): mechanism silently disabled — verify no reduction applied even after `confidenceT`.
- [ ] EIP-2098 compact signature replay vs canonical 65-byte signature for the same `(maker, rfqId)`: the second attempt must revert due to invalidator.
- [ ] Maker upgrades from ERC-1271 contract to a different implementation while orders are outstanding: existing signatures may stop validating — surface via integration test.
- [ ] Chain fork (`block.chainid` changes after deployment): `EIP712._domainSeparatorV4` must rebuild (`src/EIP712.sol:68-74`); old signatures should not validate on the fork.
- [ ] `OrderRFQ.rfqId` greater than `uint64.max`: high bits are truncated in `_invalidator` math — two different `rfqId` values that share low 64 bits collide on the same bitmap bit. Verify maker tooling stays within 64 bits.

---

## 9. Integration Modes (Standalone vs Aggregator)

`PMMProtocol` is **not** coupled to OKX's DexRouter. The only on-chain authorization is the maker's EIP-712 signature; `msg.sender` is unrestricted. Three integration modes:

| Mode | Caller of `fillOrderRFQ*` | Funds flow | When to use |
|------|---------------------------|------------|-------------|
| **Standalone (direct)** | Any EOA or contract | Caller's `msg.sender` balance → maker for the taker leg; maker → `target` for the maker leg | Direct wallet UI, arbitrage bots, custom integrations that don't need an aggregator |
| **Via OKX DexRouter** | OKX `SmartSwapRouter` → `PMMAdapter` → `PMMProtocol` | Router transfers taker asset to `PMMAdapter` first; adapter `safeApprove`s `PMMProtocol`; protocol pulls from adapter | Production default path (see [[pmm_adapter_migration]] §2.6) |
| **Via 3rd-party aggregator** | Their adapter shim (must conform to their adapter ABI) → `PMMProtocol` | Whatever the 3rd-party aggregator decides | 1inch / Paraswap / etc. — `PMMProtocol` itself is aggregator-agnostic |

**Authorization model is aggregator-agnostic** — `PMMProtocol` has no owner, no admin, no role gating. The only privileged data flow is the maker signature, which the contract verifies via `ECDSA.recoverOrIsValidSignature` or `ECDSA.isValidSignature` (ERC-1271). Whoever holds a valid signature can fill the order. (Source: src/PmmProtocol.sol — `grep -n "modifier\|onlyOwner"` returns only OZ's `nonReentrant`.)

**Key constraints**:
- [Rule] `fillOrderRFQ*` is callable by ANY address; no whitelist. (Source: src/PmmProtocol.sol:100-200)
- [Rule] `target` (maker-leg recipient) is a function parameter, NOT part of `OrderRFQ`; the maker did not sign a specific recipient. The taker decides where the maker leg lands. (Source: src/PmmProtocol.sol:165-170 — `target` is the 4th arg of `fillOrderRFQTo`, not a struct field)
- [Rule] `PMMAdapter` is one valid taker path among many — its existence is convenience, not a protocol requirement. The same `PMMProtocol` instance accepts fills from any caller. (Source: derived from the unrestricted `msg.sender` semantics above.)
- [Pitfall] Standalone integrators are responsible for delivering exactly `takerAmount` of `takerAsset` to the protocol (or `msg.value == takerAmount` for WETH legs). There is no built-in refund — the leftover-refund behaviour in [[pmm_adapter_migration]] §2.4 is an adapter-side convenience, not a protocol feature. (Source: src/PmmProtocol.sol:327-336 — no refund branch)
- [Pitfall] If a third-party aggregator copies the OKX `ORIGIN_PAYER` trailing-word convention without implementing the refund step, they will silently lose taker-asset dust on partial fills. The convention is OKX-adapter-specific, not part of `PMMProtocol`. (Source: contrast src/PmmProtocol.sol against [[pmm_adapter_migration]] §2.6)

---

## 10. Terminology

| Term | Definition |
|------|------------|
| `PmmProtocol` | Main on-chain settlement contract. Inherits `EIP712` and `ReentrancyGuard`. |
| `OrderRFQ` | 14-field struct defined in `src/OrderRFQLib.sol`; the unit a maker signs and a taker fills. |
| `rfqId` | RFQ identifier; `uint256` field but only the low 64 bits are significant on-chain. |
| `MakerLeg` | The maker-asset transfer from the maker to the taker (or `target`); may use 4 different paths (§2.6). |
| `TakerLeg` | The taker-asset transfer from `msg.sender` to the maker; may wrap native ETH into WETH. |
| `SettlementLimit` | 60% minimum-fill ratio (`_SETTLE_LIMIT / _SETTLE_LIMIT_BASE = 6000 / 10000`); enforced before confidence reduction. |
| `ConfidenceWindow` | Time after which time-slippage activates (`confidenceT`); before this, no reduction. |
| `ConfidenceCap` | Maximum cumulative reduction (`confidenceCap`); hard-capped at `50000` (5%) by `_CONFIDENCE_CAP_LIMIT`. |
| `Permit2AllowancePath` | Maker leg mode where Permit2 was pre-approved by the maker; `permit2Signature` is empty. |
| `Permit2SignaturePath` | Maker leg mode where Permit2 signature is provided inline; no witness data. |
| `Permit2WitnessPath` | Maker leg mode where Permit2 signature + witness data are provided inline. |
| `WethUnwrap` | Bit 252 of `flagsAndAmount` triggers unwrap and native-ETH delivery to `target` on the maker leg. |
| `InvalidatorBitmap` | Per-maker `mapping(uint256 => uint256)` storing single-use bits for each `rfqId`. |
| `CancelOrderRfq` | Maker-initiated invalidation; sets the bit without any transfer. |
| `FlagsAndAmount` | `uint256` packed instruction word: bits 252-255 reserved flags, bits 0-159 are the requested fill amount. |
| `OrderFilledRFQ` | Event emitted on every successful fill; carries both quoted and actual amounts plus Permit2 metadata. |
| `OrderCancelledRFQ` | Event emitted on maker cancellation. |
| `RFQ_*` errors | Custom errors defined in `src/libraries/Errors.sol`; all carry `uint256 rfqId` except `RFQ_EthDepositRejected()`. |
