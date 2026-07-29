---
domain: pmm
sub_domain: pmm_settlement
title: PMM RFQ Settlement (On-Chain)
source_docs: ["README.md", "src/PmmProtocol.sol", "src/OrderRFQLib.sol", "src/EIP712.sol", "src/libraries/CallerAuth.sol", "src/libraries/SafeERC20.sol", "src/helpers/AmountCalculator.sol", "src/libraries/Errors.sol"]
concept_keys: [PmmProtocol, OrderRFQ, RfqId, AllowedSender, CallerAuth, AuthSigner, MakerLeg, TakerLeg, SettlementLimit, ConfidenceWindow, ConfidenceCap, Permit2AllowancePath, Permit2SignaturePath, Permit2WitnessPath, WethUnwrap, InvalidatorBitmap, CancelOrderRfq, FlagsAndAmount]
last_updated: 2026-07-27
---

# PMM RFQ Settlement (On-Chain)

## One-line Summary

`PMMProtocol` settles maker-signed RFQ orders on-chain — verifies an EIP-712 OrderRFQ signature, enforces single-use `rfqId`, applies a 60% minimum-fill guardrail and an optional time-decay (confidence) reduction capped at 5%, then performs the maker leg via standard ERC-20 or one of three Permit2 modes, optionally unwrapping WETH for native-ETH delivery, and pulls the taker leg from `msg.sender`.

---

## 1. Business Background & Scope

- **Positioning**: This contract is the on-chain leg of the OKX DEX aggregator's PMM RFQ flow. Off-chain market makers stream signed `OrderRFQ` structs; takers (or the aggregator via `PMMAdapter`) submit them on-chain to receive maker assets and deliver taker assets in a single atomic transaction.
- **Boundary notes**:
  - **In scope (this doc)**: caller authorization, maker signature verification, RFQ-ID replay protection, fill-amount math, settlement-limit guardrail, time-slippage reduction, maker-leg transfer modes, WETH wrap/unwrap, and maker cancellation.
  - **Related**: adapter dispatch over multiple OrderRFQ versions is documented in [[pmm_adapter_migration]].
  - **Not implemented**: fee-on-transfer maker assets are explicitly unsupported — the protocol uses the calculated transfer amount, not a balance-of-before/after delta. Documented in `src/PmmProtocol.sol:103-105`.

## 2. Core Content

### 2.1 OrderRFQ Struct & EIP-712 Signing (`OrderRFQ`)

**Struct** (**15 fields**, declared in `src/OrderRFQLib.sol:8-24`):

| # | Field | Type | Purpose |
|---|-------|------|---------|
| 1 | `rfqId` | `uint256` | Replay-protection ID; MUST be ≤ `uint64.max` on-chain or the fill reverts `RFQ_InvalidRfqId` |
| 2 | `expiry` | `uint256` | Unix timestamp; reused as Permit2 `deadline` |
| 3 | `makerAsset` | `address` | Token the maker sends |
| 4 | `takerAsset` | `address` | Token the taker sends |
| 5 | `makerAddress` | `address` | Signer + fund owner |
| 6 | `makerAmount` | `uint256` | Quoted maker size |
| 7 | `takerAmount` | `uint256` | Quoted taker size |
| 8 | `usePermit2` | `bool` | If true, maker leg uses Permit2 |
| 9 | `allowedSender` | `address` | Required non-zero address the maker quoted for; checked in PMMAdapter orderType=4 as `allowedSender == dexRouterCaller`. |
| 10 | `confidenceT` | `uint256` | Unix timestamp where time-slippage activates (0 disables) |
| 11 | `confidenceWeight` | `uint256` | Reduction rate per second in 1e6 units |
| 12 | `confidenceCap` | `uint256` | Max cumulative reduction (1e6 units); hard-capped at 50000 (5%) |
| 13 | `permit2Signature` | `bytes` | Optional inline Permit2 signature |
| 14 | `permit2Witness` | `bytes32` | Pre-hashed witness data |
| 15 | `permit2WitnessType` | `string` | Canonical witness type string |

**Domain**: `name="OKX Labs PMM Protocol"`, `version="1.2"` (bumped from `1.1` for `allowedSender`), `chainId=block.chainid`, `verifyingContract=address(this)` (`src/PmmProtocol.sol:61-62`, `:78-80`, `src/EIP712.sol:52-63`).

**Main flow** (single fill entry → `_fillOrderRFQTo`):

0. Caller invokes the single caller-bound `fillOrderRFQTo(order, signature, flagsAndAmount, target, allowedCallers, nonce, authSig)`; the function's first statement validates `order.rfqId <= type(uint64).max`, otherwise it reverts `RFQ_InvalidRfqId(rfqId)`. The prior `fillOrderRFQ` / `fillOrderRFQCompact` / `fillOrderRFQToWithPermit` variants were removed. (Source: src/PmmProtocol.sol:106-117)
1. Immediately after the rfqId check: `_verifyCallerAuth(keccak256(abi.encode(order)), allowedCallers, nonce, authSig)` (caller binding, `allowedCallers == [PmmAdapter]`; else `AUTH_*`). (Source: src/PmmProtocol.sol:118)
2. Compute `orderHash = OrderRFQLib.hash(order, _domainSeparatorV4())` over 15 fields. (Source: src/PmmProtocol.sol:120)
3. Verify the maker signature: ECDSA recover (EOA) or ERC-1271 `isValidSignature` (contract signer), gated by bits 254/253 of `flagsAndAmount`. Failure → `RFQ_BadSignature(rfqId)`. (Source: src/PmmProtocol.sol:121-132)
4. Run `_fillOrderRFQTo` — see Section 2.2 through Section 2.7. (Source: src/PmmProtocol.sol:133)

**Key constraints**:
- [Rule] `permit2Signature` (`bytes`) and `permit2WitnessType` (`string`) MUST be hashed via `keccak256` before being placed into the EIP-712 struct hash; `permit2Witness` (`bytes32`) is encoded directly. (Source: src/OrderRFQLib.sol:48-72)
- [Rule] `allowedSender` MUST be a non-zero address and is part of the signed digest; the equality check against the DexRouter caller is enforced in PMMAdapter, not here. (Source: src/OrderRFQLib.sol:17, src/PmmAdaptor.sol:291)
- [Rule] When `usePermit2 = true` and `permit2Signature` is non-empty, the Permit2 signature MUST be signed FIRST (against the Permit2 domain, no `version` field), then embedded into `order.permit2Signature` before computing the OrderRFQ digest. The OrderRFQ struct hash depends on `keccak256(permit2Signature)`. (Source: src/OrderRFQLib.sol:66 + Permit2 EIP-712 spec)
- [Rule] Changing `_NAME` or `_VERSION` invalidates every outstanding maker signature (the `1.1 → 1.2` bump already did). (Source: src/PmmProtocol.sol:61-62, src/EIP712.sol:52-63)
- [Rule] Reaching settlement requires a signed caller-auth (`authSig`) in addition to the maker signature; only `[PmmAdapter]` may call `fillOrderRFQTo`, and the auth must be signed over `payloadHash = keccak256(abi.encode(order))`. (Source: src/PmmProtocol.sol:118, [[contract-CallerAuth]])

### 2.2 RFQ-ID Replay Protection (`InvalidatorBitmap`, `RfqId`)

**Storage** (`src/PmmProtocol.sol:76`):

```solidity
mapping(address => mapping(uint256 => uint256)) private _invalidator;
```

**Math** (`src/PmmProtocol.sol:96-101`, `:291-305`):

- Slot = `uint64(rfqId) >> 8`
- Bit position = `1 << (uint8(rfqId) & 0xff)`

Each maker has their own bitmap. `fillOrderRFQTo` rejects `rfqId > type(uint64).max` upfront (`RFQ_InvalidRfqId`, src/PmmProtocol.sol:115-117), so every `rfqId` that reaches this math fits in 64 bits.

**Main flow**:
1. `_fillOrderRFQTo` calls `_invalidateOrder(maker, rfqId, 0)` BEFORE any external transfer (CEI). (Source: src/PmmProtocol.sol:169)
2. If the bit is already set → `RFQ_InvalidatedOrder(rfqId)`. (Source: src/PmmProtocol.sol:300-302)
3. Otherwise the bit is flipped on. (Source: src/PmmProtocol.sol:304)

**Key constraints**:
- [Rule] An `rfqId` can be consumed at most once per `maker`; the bit is monotonically set and never cleared. (Source: src/PmmProtocol.sol:291-305)
- [Rule] `_invalidateOrder` MUST be called before any maker-leg transfer (checks-effects-interactions). (Source: src/PmmProtocol.sol:169 before :237-268)

### 2.3 Fill Amount Derivation (`FlagsAndAmount`)

`flagsAndAmount` (`uint256`) carries flags in the high bits and the requested fill amount in the low 160 bits (`src/PmmProtocol.sol:64-73`).

| Bit | Constant | Meaning |
|-----|----------|---------|
| 255 | `_MAKER_AMOUNT_FLAG` | If set, low bits = maker-side amount; else taker-side |
| 254 | `_SIGNER_SMART_CONTRACT_HINT` | Maker uses ERC-1271 |
| 253 | `_IS_VALID_SIGNATURE_65_BYTES` | Enforce signature length == 65 (paired with bit 254) |
| 252 | `_UNWRAP_WETH_FLAG` | Unwrap WETH to native ETH on the maker leg |
| 0–159 | `_AMOUNT_MASK` | Requested amount; 0 means full fill |

**Calculation rules** (`src/PmmProtocol.sol:172-199` + `src/helpers/AmountCalculator.sol`):

- **Full fill** (`amount == 0`): take quoted `makerAmount` and `takerAmount` as-is.
- **Maker-side partial** (`_MAKER_AMOUNT_FLAG` set, `amount > 0`): `takerAmount = (amount * orderTakerAmount + orderMakerAmount - 1) / orderMakerAmount` (ceiled). (Source: src/helpers/AmountCalculator.sol:19-25)
- **Taker-side partial** (`_MAKER_AMOUNT_FLAG` not set, `amount > 0`): `makerAmount = (amount * orderMakerAmount) / orderTakerAmount` (floored). (Source: src/helpers/AmountCalculator.sol:8-14)
- Bounds: maker-side `amount > orderMakerAmount` → `RFQ_MakerAmountExceeded`; taker-side `amount > orderTakerAmount` → `RFQ_TakerAmountExceeded`. (Source: src/PmmProtocol.sol:186-195)
- Full-fill with `usePermit2 = true` AND `orderMakerAmount > uint160.max` → `RFQ_AmountTooLarge`. (Source: src/PmmProtocol.sol:183-185)

**Key constraints**:
- [Rule] Taker amount is rounded UP (ceil) to prevent under-payment for partial fills. (Source: src/helpers/AmountCalculator.sol:17-25)
- [Rule] Maker amount is rounded DOWN (floor). (Source: src/helpers/AmountCalculator.sol:6-14)

### 2.4 Settlement-Limit Guardrail (`SettlementLimit`)

**Rule** (`src/PmmProtocol.sol:206-211`):

```solidity
if (
    makerAmount < (order.makerAmount * _SETTLE_LIMIT) / _SETTLE_LIMIT_BASE
        || takerAmount < (order.takerAmount * _SETTLE_LIMIT) / _SETTLE_LIMIT_BASE
) {
    revert Errors.RFQ_SettlementAmountTooSmall(order.rfqId);
}
```

Constants: `_SETTLE_LIMIT = 6000`, `_SETTLE_LIMIT_BASE = 10000` (`src/PmmProtocol.sol:69-70`).

**Main flow**:
1. After amount derivation (Section 2.3) and before confidence reduction (Section 2.5), assert both legs are at least 60% of quote. (Source: src/PmmProtocol.sol:206-211)
2. Below 60% → revert `RFQ_SettlementAmountTooSmall(rfqId)`.

**Key constraints**:
- [Rule] Minimum fill is **60%** of the quoted maker AND quoted taker amounts. (Source: src/PmmProtocol.sol:69-70, :206-211)
- [Rule] The 60% check is evaluated on the **pre-confidence-reduction** maker amount; the confidence reduction afterwards may bring the actually-transferred maker amount slightly below 60% (capped at 5% reduction, so the realized minimum is ~57%). (Source: src/PmmProtocol.sol:206-231 ordering)

### 2.5 Time-Slippage / Confidence Reduction (`ConfidenceWindow`, `ConfidenceCap`)

**Purpose**: protect makers from stale quotes by reducing the maker amount linearly after a configured timestamp.

**Formula** (`src/PmmProtocol.sol:213-231`):

```
if confidenceT != 0 && block.timestamp > confidenceT:
    if confidenceWeight != 0 && confidenceCap != 0:
        if confidenceCap > 50_000: revert RFQ_ConfidenceCapExceeded
        timeDiff             = block.timestamp - confidenceT
        cutdownPercentageX6  = min(timeDiff * confidenceWeight, confidenceCap)   // 1e6 units
        makerAmount         -= makerAmount * cutdownPercentageX6 / 1e6
```

`_CONFIDENCE_CAP_LIMIT = 50000` = 5% in 1e6 units (`src/PmmProtocol.sol:72`).

**Disabling rule**: if ANY of `confidenceT`, `confidenceWeight`, `confidenceCap` is `0`, the mechanism is fully disabled and the maker amount is unchanged.

**Main flow**:
1. Read `confidenceT`. If `0` or `block.timestamp <= confidenceT` → no reduction. (Source: src/PmmProtocol.sol:216-217)
2. Read `confidenceWeight` and `confidenceCap`. If either is `0` → no reduction. (Source: src/PmmProtocol.sol:218-219)
3. If `confidenceCap > 50000` → revert `RFQ_ConfidenceCapExceeded`. (Source: src/PmmProtocol.sol:220-222)
4. Compute `cutdownPercentageX6 = min(timeDiff * confidenceWeight, confidenceCap)`. (Source: src/PmmProtocol.sol:223-227)
5. Reduce maker amount by that percentage. Taker amount is unchanged. (Source: src/PmmProtocol.sol:228)

**Key constraints**:
- [Rule] `confidenceCap` MUST be ≤ `50000` (5%); larger values revert. (Source: src/PmmProtocol.sol:220-222)
- [Rule] Only the maker amount is reduced; the taker still pays the full `takerAmount`. (Source: src/PmmProtocol.sol:228 only modifies makerAmount)
- [Rule] The reduction is applied AFTER the 60% settlement check, so a maker may receive ~57% net (60% × 95%) in the worst case. (Source: src/PmmProtocol.sol:206-231 ordering)
- [Pitfall] All three confidence params MUST be set together; setting only `confidenceT` without weight/cap silently disables the protection. (Source: src/PmmProtocol.sol:217-219)

### 2.6 Maker-Leg Transfer (4 modes)

After amount derivation and confidence reduction, the maker leg is transferred via one of four paths, selected by `order.usePermit2`, `order.permit2Signature.length`, and `order.permit2WitnessType.length` (`src/PmmProtocol.sol:233-268`).

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
Permit2 `nonce = order.rfqId`, `deadline = order.expiry`. (Source: src/PmmProtocol.sol:240-244, :257-261)

**Mode D — Permit2 signature + witness** (`usePermit2 = true`, both `permit2Signature` and `permit2WitnessType` non-empty):
```solidity
IPermit2.permitWitnessTransferFrom(permitTransferFrom, signatureTransferDetails, maker,
                                   order.permit2Witness, order.permit2WitnessType, order.permit2Signature)
```
Used when the maker needs the Permit2 signature to bind to extra structured data (e.g., the taker address). (Source: src/PmmProtocol.sol:248-256)

**Receiver selection**: when `_UNWRAP_WETH_FLAG` is set AND `order.makerAsset == WETH`, the receiver is `address(this)` (the contract holds WETH transiently before unwrapping). Otherwise the receiver is `target`. (Source: src/PmmProtocol.sol:233-236)

**Key constraints**:
- [Rule] Permit2 `nonce` MUST equal `order.rfqId`; `deadline` MUST equal `order.expiry`. Off-chain signers that use different values will produce digests that fail. (Source: src/PmmProtocol.sol:240-244)
- [Rule] In Mode B (Permit2 allowance), maker amount > `uint160.max` reverts; this is also pre-checked on the full-fill path at `src/PmmProtocol.sol:183-185`. (Source: src/libraries/SafeERC20.sol:33)

### 2.7 WETH Wrap / Unwrap

**Maker-leg unwrap** (`src/PmmProtocol.sol:269-274`): if `_UNWRAP_WETH_FLAG` is set and `order.makerAsset == _WETH`, the contract calls `_WETH.withdraw(makerAmount)` then forwards native ETH to `target` via a low-level call with `gas = _RAW_CALL_GAS_LIMIT (5000)`. Failure → `RFQ_ETHTransferFailed`.

**Taker-leg wrap** (`src/PmmProtocol.sol:277-286`): if `takerAsset == _WETH` AND `msg.value > 0`:
- `msg.value != takerAmount` → `RFQ_InvalidMsgValue`.
- Otherwise wrap the ETH (`_WETH.deposit{value: takerAmount}()`) and `_WETH.transfer(maker, takerAmount)`.

Otherwise (non-WETH taker, OR WETH taker with `msg.value == 0`):
- `msg.value != 0` → `RFQ_InvalidMsgValue`.
- `IERC20(order.takerAsset).safeTransferFrom(msg.sender, maker, takerAmount)`.

**`receive()` guard** (`src/PmmProtocol.sol:82-86`): the contract accepts ETH ONLY when `msg.sender == address(_WETH)` (i.e., during WETH withdraw). Any other sender reverts `RFQ_EthDepositRejected`.

**Key constraints**:
- [Rule] Native ETH on the maker leg requires both `_UNWRAP_WETH_FLAG` set AND `makerAsset == WETH`; setting only the flag does nothing. (Source: src/PmmProtocol.sol:233)
- [Rule] Native ETH on the taker leg requires `takerAsset == WETH` AND `msg.value == takerAmount` exactly; off-by-one reverts. (Source: src/PmmProtocol.sol:277-280)
- [Rule] The unwrap-forward `.call` has a `5000`-gas stipend; `target` must accept ETH within that budget or the fill reverts. (Source: src/PmmProtocol.sol:64, :272)
- [Pitfall] `_WETH.transfer` on the taker-leg wrap does not check the return value (lint warning suppressed because WETH9 is a known-good contract). (Source: src/PmmProtocol.sol:282)

### 2.8 Taker Approval

The current contract has no permit-and-fill entry. A taker that needs an ERC-20 permit must execute it separately before the adapter-driven fill.

### 2.9 Maker Cancellation (`CancelOrderRfq`)

`cancelOrderRFQ(uint64 rfqId)` lets a maker invalidate their own `rfqId` before any taker fills it (`src/PmmProtocol.sol:307-317`).

**Main flow**:
1. `maker = msg.sender` is bound — the caller can only cancel their own bitmap. (Source: src/PmmProtocol.sol:308)
2. If `isRfqIdUsed(maker, rfqId)` is already true → `RFQ_OrderAlreadyCancelledOrUsed(rfqId)`. (Source: src/PmmProtocol.sol:310-312)
3. Flip the bit in `_invalidator[msg.sender][slot]`. (Source: src/PmmProtocol.sol:314)
4. Emit `OrderCancelledRFQ(rfqId, maker)`. (Source: src/PmmProtocol.sol:316)

**Key constraints**:
- [Rule] Cancellation is per-maker — a maker cannot cancel another maker's `rfqId`. (Source: src/PmmProtocol.sol:308)
- [Rule] No signature is required — the EOA control of `msg.sender` is the only authorization. (Source: src/PmmProtocol.sol:307-317)
- [Rule] `cancelOrderRFQ` is NOT `nonReentrant` because it makes no external calls. (Source: src/PmmProtocol.sol:307 lacks modifier)

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
UNUSED ──── fill succeeds (fillOrderRFQTo) ────────►  CONSUMED
UNUSED ──── maker calls cancelOrderRFQ(rfqId) ────►   CONSUMED

CONSUMED ─── (terminal — no transition out)

Failure paths from UNUSED (no state change):
  - rfqId > uint64.max                    → RFQ_InvalidRfqId (triggered before caller-auth)
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

- **`orderHash`** = `ECDSA.toTypedDataHash(domainSeparator, keccak256(abi.encode(_LIMIT_ORDER_RFQ_TYPEHASH, ...15 fields incl. allowedSender...)))`. (Source: src/OrderRFQLib.sol:48-72)
- **`makerAmount`** (taker-side fill) = `(swapTakerAmount * orderMakerAmount) / orderTakerAmount` — floored. (Source: src/helpers/AmountCalculator.sol:8-14)
- **`takerAmount`** (maker-side fill) = `(swapMakerAmount * orderTakerAmount + orderMakerAmount - 1) / orderMakerAmount` — ceiled. (Source: src/helpers/AmountCalculator.sol:19-25)
- **Settlement minimum** = `order.{maker,taker}Amount × 0.60`; both legs must satisfy. (Source: src/PmmProtocol.sol:69-70, :206-211)
- **Confidence reduction** = `makerAmount × min(timeDiff × confidenceWeight, confidenceCap) / 1e6`, with hard cap `confidenceCap ≤ 50000` (5%). (Source: src/PmmProtocol.sol:72, :213-231)
- **Invalidator slot/bit** = `slot = uint64(rfqId) >> 8`, `bit = 1 << (uint8(rfqId) & 0xff)`. (Source: src/PmmProtocol.sol:97-98, :292-294)

---

## 5. Access Control

| Role | Permitted Actions | Constraints |
|------|-------------------|-------------|
| Maker (any EOA or ERC-1271 contract) | Sign `OrderRFQ`; call `cancelOrderRFQ(uint64)` to invalidate own `rfqId` | Authorization is the EIP-712 signature (for fills) or `msg.sender == makerAddress` (for cancellation). Cannot cancel another maker's IDs. `cancelOrderRFQ` is NOT caller-bound. |
| Caller of `fillOrderRFQTo` | Must be in the signed `allowedCallers` with a valid `authSig` | A maker signature alone is insufficient; the caller authorization is also required. |
| `AUTH_SIGNER` | Immutable, set at deploy | Off-chain authorizes the caller set (`CallerAuth`). No mutable admin. See [[contract-CallerAuth]]. |
| `_WETH` only | Send ETH to the contract (during `withdraw`) | Any other ETH sender → `RFQ_EthDepositRejected`. (Source: src/PmmProtocol.sol:82-86) |
| Aggregator router | Call `PMMAdapter.sellBase` / `sellQuote`; see [[pmm_adapter_migration]] / [[pmm_anti_toxic_flow]] | Adapter now inherits `CallerAuth`+`ReentrancyGuard` (not stateless); it calls `PMMProtocol.fillOrderRFQTo` (must be in `allowedCallers`). |

- **Immutable roles**: `_WETH` (set in constructor, no setter — redeploy to change). No owner / admin role exists.
- **Zero-address validation**: `target == address(0)` → `RFQ_ZeroTargetIsForbidden`. (Source: src/PmmProtocol.sol:156-158)

---

## 6. Events

| Event Name | Trigger Condition | Key Parameters |
|------------|-------------------|----------------|
| `OrderFilledRFQ` | A successful fill via `fillOrderRFQTo` (the single fill entry) | `rfqId` (indexed), `expiry`, `makerAsset` (indexed), `takerAsset` (indexed), `makerAddress`, `allowedSender`, `expectedMakerAmount`, `expectedTakerAmount`, `filledMakerAmount`, `filledTakerAmount`, `usePermit2`, `permit2Signature`, `permit2Witness`, `permit2WitnessType` (Source: src/PmmProtocol.sol:35-50; emit at :134-149) |
| `OrderCancelledRFQ` | Maker invalidates an unused `rfqId` via `cancelOrderRFQ` | `rfqId` (indexed), `maker` (indexed) (Source: src/PmmProtocol.sol:59) |

**Observation note**: there is no event for failed fills; reverts surface as named custom errors from `src/libraries/Errors.sol`.

---

## 7. Constraints & Risk Rules

- [Rule] The single `fillOrderRFQTo` entry is `nonReentrant` (OpenZeppelin `ReentrancyGuard`) and caller-bound (`_verifyCallerAuth` as the second step, immediately after the `rfqId ≤ uint64.max` validation). External token transfers and a low-level ETH `.call` are the reentrancy surface. (Source: src/PmmProtocol.sol:114, :115-118)
- [Rule] `_invalidator` is updated BEFORE any token transfer (CEI pattern). (Source: src/PmmProtocol.sol:169 vs :237-268)
- [Rule] `_WETH` is `immutable` — set once in the constructor, no setter exists. (Source: src/PmmProtocol.sol:75, :78-80)
- [Rule] `_NAME = "OKX Labs PMM Protocol"` and `_VERSION = "1.2"` are `constant`. Any change is a breaking redeploy because the cached domain separator depends on them (the `1.1 → 1.2` bump for `allowedSender` already invalidated old signatures). (Source: src/PmmProtocol.sol:61-62)
- [Rule] All ERC-20 transfers from `PMMProtocol` use the project's local `SafeERC20` (`src/libraries/SafeERC20.sol`) — never bare `IERC20.transfer` / `transferFrom`.
- [Rule] Fee-on-transfer (deflationary / rebasing) tokens are NOT supported — the protocol uses calculated transfer amounts, not balance deltas. (Source: src/PmmProtocol.sol:103-105)
- [Rule] Maker amount > `uint160.max` is rejected at full-fill time when `usePermit2 = true` (`RFQ_AmountTooLarge`). (Source: src/PmmProtocol.sol:183-185)
- [Rule] `confidenceCap > 50000` (5% in 1e6 units) is rejected at fill time (`RFQ_ConfidenceCapExceeded`). (Source: src/PmmProtocol.sol:72, :220-222)
- [Rule] `receive()` accepts ETH only from `_WETH`. (Source: src/PmmProtocol.sol:82-86)
- [Pitfall] The settlement-limit (60%) check is run BEFORE confidence reduction, so the worst-case net maker amount delivered to the taker can be ~57% of the original quote (60% × 95%). (Source: src/PmmProtocol.sol:206-231 ordering)
- [Pitfall] Bit 252 (`_UNWRAP_WETH_FLAG`) is silently ignored if `order.makerAsset != _WETH`. (Source: src/PmmProtocol.sol:233)
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
- [ ] Reentrancy attempt via a malicious ERC-1271 maker contract that re-enters `fillOrderRFQTo`: must be blocked by `nonReentrant`.
- [ ] Permit2 signature ordering: a maker signs OrderRFQ first then changes `permit2Signature` — fill must revert (digest depends on `keccak256(permit2Signature)`).
- [ ] Confidence params set only partially (e.g., `confidenceT > 0`, `confidenceWeight = 0`): mechanism silently disabled — verify no reduction applied even after `confidenceT`.
- [ ] EIP-2098 compact signature replay vs canonical 65-byte signature for the same `(maker, rfqId)`: the second attempt must revert due to invalidator.
- [ ] Maker upgrades from ERC-1271 contract to a different implementation while orders are outstanding: existing signatures may stop validating — surface via integration test.
- [ ] Chain fork (`block.chainid` changes after deployment): `EIP712._domainSeparatorV4` must rebuild (`src/EIP712.sol:68-74`); old signatures should not validate on the fork.
- [ ] `OrderRFQ.rfqId` greater than `uint64.max`: `fillOrderRFQTo` reverts `RFQ_InvalidRfqId(rfqId)` up front — before caller-auth and before any `_invalidator` math — so no truncation or bitmap collision is reachable. Covered by `testFillOrderRejectsRfqIdAboveUint64` in `test/PmmProtocol.t.sol`. (Source: src/PmmProtocol.sol:115-117)

---

## 9. Integration Model

The current `PMMProtocol` settlement entry requires two independent authorization layers: a valid maker EIP-712 signature and a valid caller authorization whose `allowedCallers` contains `msg.sender`. The standard current route uses `PMMAdapter` orderType=4.

**Key constraints**:
- [Rule] `target` is a function parameter, not part of `OrderRFQ`; caller authorization is scoped to the order but does not include `target`.
- [Rule] `PMMAdapter` orderType=4 verifies its own caller authorization and the signed `allowedSender` before forwarding the protocol authorization.
- [Rule] `PMMProtocol` pulls the taker leg from its immediate caller. In the adapter route, the adapter must be funded and must approve the protocol first.
- [Pitfall] Residual refund handling is an adapter feature. `PMMProtocol` itself has no taker-asset refund branch.

---

## 10. Terminology

| Term | Definition |
|------|------------|
| `PmmProtocol` | Main on-chain settlement contract. Inherits `EIP712`, `CallerAuth`, and `ReentrancyGuard`. |
| `OrderRFQ` | **15-field** struct defined in `src/OrderRFQLib.sol` (incl. `allowedSender`); the unit a maker signs and the adapter fills. |
| `AllowedSender` | Required non-zero `OrderRFQ` field; the address the maker priced for. Checked against `dexRouterCaller` in PMMAdapter orderType=4 (else `RFQ_BadSender`). |
| `CallerAuth` | Caller-authorization base inherited by `PMMProtocol` and `PMMAdapter`. |
| `rfqId` | RFQ identifier; declared as a `uint256` struct field, but the chain enforces `rfqId ≤ uint64.max` — larger values revert `RFQ_InvalidRfqId` at fill entry. |
| `MakerLeg` | The maker-asset transfer from the maker to the taker (or `target`); may use 4 different paths (Section 2.6). |
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
