---
domain: pmm
sub_domain: pmm_adapter_migration
title: PMMAdapter V1/V2/V3/V4 OrderRFQ Routing
source_docs: ["README.md", "src/PmmAdaptor.sol", "src/OrderRFQLib.sol", "src/libraries/CallerAuth.sol", "src/libraries/Errors.sol", "DEPLOYMENT.md"]
concept_keys: [PmmAdapter, OrderRFQV1, OrderRFQV2, OrderRFQV3, OrderType, OrderType4, SignatureType, SellBase, SellQuote, PayerOrigin, RefundFlow]
last_updated: 2026-07-27
---

# PMMAdapter V1/V2/V3/V4 OrderRFQ Routing

## One-line Summary

`PMMAdapter` accepts three legacy `OrderRFQ` payloads and the current V4 payload, approves the downstream `PMMProtocol` for the taker-asset balance it holds, forwards the fill, refunds eligible residuals, and translates downstream custom errors. It inherits `CallerAuth` and `ReentrancyGuard` and therefore carries nonce and reentrancy storage.

---

## 1. Business Background & Scope

- **Positioning**: As the PMM RFQ struct has evolved (v2 → v3 → v4 in the README's version history), maker tooling and live signed orders cannot all be migrated atomically. The adapter pins three concrete `OrderRFQ` shapes and dispatches based on a caller-supplied `orderType` so older signed quotes can still settle while makers upgrade.
- **Boundary notes**:
  - **In scope (this doc)**: the four order payload shapes (`IPMMProtocolV1.OrderRFQ`, `V2`, `V3`, plus the V4 route over `OrderRFQLib.OrderRFQ`); the `orderType` dispatch table; aggregator-side approval and refund flow; downstream error decoding.
  - **Out of scope (here)**: the actual settlement semantics that run inside `PMMProtocol` — see [[pmm_settlement]]; aggregator-side route selection, quoting, and pricing.

## 2. Core Content

### 2.1 OrderRFQ Version Shapes

The adapter declares four protocol interfaces in `src/PmmAdaptor.sol`: `IPMMProtocolV1` (:19-34), `IPMMProtocolV2` (:36-54), `IPMMProtocolV3` (:56-79), and `IPMMProtocolV4` (:81-91). V1-V3 each embed a frozen snapshot of the `OrderRFQ` struct at that protocol version; `IPMMProtocolV4` embeds no struct and reuses `OrderRFQLib.OrderRFQ` directly. A shared `struct CallerAuthData` (:13-17) carries the V4 caller-authorization tuples.

| Version | Field Count | Defined In | Adds vs Previous |
|---------|-------------|------------|------------------|
| V1 | 8 fields | `src/PmmAdaptor.sol:19-34` (interface `IPMMProtocolV1`) | Baseline: `rfqId, expiry, makerAsset, takerAsset, makerAddress, makerAmount, takerAmount, usePermit2`. (Source: src/PmmAdaptor.sol:21-28) |
| V2 | 11 fields | `src/PmmAdaptor.sol:36-54` (interface `IPMMProtocolV2`) | Adds inline Permit2 fields: `bytes permit2Signature, bytes32 permit2Witness, string permit2WitnessType`. (Source: src/PmmAdaptor.sol:46-48) |
| V3 | 14 fields | `src/PmmAdaptor.sol:56-79` (interface `IPMMProtocolV3`) | Adds time-slippage fields: `uint256 confidenceT, uint256 confidenceWeight, uint256 confidenceCap`. (Source: src/PmmAdaptor.sol:66-68) |

The current struct in `src/OrderRFQLib.sol` has **15 fields** (V3's 14 fields plus `allowedSender`) and is consumed by orderType=4 through `IPMMProtocolV4`. The three frozen `IPMMProtocolV{1,2,3}` interfaces remain for legacy orders.

### 2.2 Aggregator Dispatch Flow (`SellBase` / `SellQuote`)

**Entry points** (`src/PmmAdaptor.sol:319-335`):

```solidity
function sellBase(address to, address pool, bytes memory moreInfo)  external { ... }
function sellQuote(address to, address pool, bytes memory moreInfo) external { ... }
```

Both are structurally **byte-for-byte identical** — they both call `_PMMSwap(to, pool, moreInfo, payerOrigin)` after extracting `payerOrigin` from the trailing 32-byte calldata word via inline assembly.

**Direction is NOT determined by which entry-point is called.** In some other AMM-style aggregator adapters, `sellBase` means `token0 → token1` and `sellQuote` means `token1 → token0` — i.e., direction is encoded in the method name. PMM does not work that way: the swap direction is encoded explicitly in `OrderRFQ.makerAsset` / `OrderRFQ.takerAsset` inside `moreInfo`. The dual entry-points exist to satisfy the aggregator's interface contract (which expects every adapter to expose both `sellBase` and `sellQuote`), but routing through one vs the other has no semantic effect for PMM.

**Main flow**:
1. Aggregator calls `sellBase` or `sellQuote` with `(to, pool, moreInfo)` plus a trailing 32-byte `payerOrigin` word. (Source: src/PmmAdaptor.sol:319-335)
2. `_PMMSwap` decodes `moreInfo` as `(bytes orderInfo, bytes signature, uint256 signatureType, uint256 orderType)`. (Source: src/PmmAdaptor.sol:122-123)
3. Dispatch by `orderType`:
   - `1` → `_executeV1Order` (8-field decode)
   - `2` → `_executeV2Order` (11-field decode)
   - `3` → `_executeV3Order` (14-field decode)
   - `4` → `_executeV4Order` (15-field OrderRFQ + two `CallerAuthData` tuples; caller-auth + `allowedSender` check — see [[pmm_anti_toxic_flow]])
   - any other value → revert `"PMMAdapter: unsupported orderType"`.
4. Every `_executeV*Order` shares a common core — decode `orderInfo`; `amount = min(IERC20(takerAsset).balanceOf(adapter), order.takerAmount)`; `require(amount > 0, "Zero balance of PMM adapter")`; `SafeERC20.safeApprove(takerAsset, pool, amount)` (OpenZeppelin `SafeERC20`, not the project's local one); `flagsAndAmount = (signatureType == SignatureType.EIP1271 ? 1 << 254 : 0) + amount` — only bit 254 is ever set, never bits 252 / 253 / 255 — then `_call` into `pool.fillOrderRFQTo`. But the four versions are NOT identical:
   - **V1** is the plain five-step flow above, using the legacy 3-arg `_call` (maker-balance recheck disabled). (Source: src/PmmAdaptor.sol:138-165)
   - **V2 / V3** additionally compute `fillMakerAmount` (pro-rata maker payout) and build a `MakerBalanceCheck` struct — `enabled` only when `usePermit2 && permit2Signature.length > 0`; V2 zeroes the confidence fields, V3 passes them through — and call the 4-arg `_call` so the fallback can attribute maker-balance failures. (Source: src/PmmAdaptor.sol:167-209, :211-255)
   - **V4** decodes `(OrderRFQLib.OrderRFQ, CallerAuthData adaptorAuth, CallerAuthData protocolAuth)`, first runs `_verifyCallerAuth(keccak256(abi.encode(order)), adaptorAuth...)`, then requires `order.allowedSender` to be non-zero and equal to `_extractDexRouterCaller()` (else `RFQ_BadSender`), encodes with the 7-arg `IPMMProtocolV4.fillOrderRFQTo` selector, and forwards `protocolAuth` (`allowedCallers`, `nonce`, `authSig`) downstream. (Source: src/PmmAdaptor.sol:257-306)
5. `_handleRefund(takerAsset, payerOrigin)` — see Section 2.4. (Source: src/PmmAdaptor.sol:164, :208, :254, :305)

**Key constraints**:
- [Rule] `orderType` MUST be `1`, `2`, `3`, or `4`. Any other value reverts `"PMMAdapter: unsupported orderType"`. (Source: src/PmmAdaptor.sol:125-134)
- [Rule] The adapter MUST hold ≥ 1 unit of `takerAsset` when each `_executeV*Order` runs. Zero balance reverts `"Zero balance of PMM adapter"`. (Source: src/PmmAdaptor.sol:153, :183, :227, :285)
- [Rule] The adapter NEVER encodes bits 252 / 253 / 255 in `flagsAndAmount`. WETH-unwrap (bit 252), 65-byte signature pin (bit 253), and maker-side fill direction (bit 255) cannot be requested through this adapter — callers needing those must call `PMMProtocol` directly. (Source: src/PmmAdaptor.sol:155, :185, :229, :287)

### 2.3 Signature Type Selection (`SignatureType`)

```solidity
enum SignatureType { EIP712, EIP1271 }
```

(`src/PmmAdaptor.sol:101-104`)

The aggregator passes `signatureType` inside `moreInfo`:
- `EIP712` (value `0`) → bit 254 cleared; downstream `PMMProtocol` uses `ECDSA.recoverOrIsValidSignature`.
- `EIP1271` (value `1`) → bit 254 set; downstream `PMMProtocol` uses `ECDSA.isValidSignature` (ERC-1271 only path).

### 2.4 Refund Flow (`RefundFlow`, `PayerOrigin`)

After the fill returns, the adapter may still hold residual `takerAsset` (because the Section 2.2 balance cap set `amount = min(balance, takerAmount)`, but a downstream partial fill or rounding may consume less). `_handleRefund` recovers the address to refund from the trailing 32-byte calldata word.

**Main flow** (`_handleRefund`, `src/PmmAdaptor.sol:308-317`):
1. If `(payerOrigin & MARKER_MASK) == ORIGIN_PAYER`, extract `_payerOrigin = address(uint160(payerOrigin & _ADDRESS_MASK))`.
2. Otherwise `_payerOrigin = address(0)` and no refund happens. Marker aliases such as `DEX_ROUTER_CALLER_MARKER` are rejected.
3. `amountLeft = IERC20(takerAsset).balanceOf(adapter)`.
4. If `amountLeft > 0 && _payerOrigin != address(0)` → `SafeERC20.safeTransfer(takerAsset, _payerOrigin, amountLeft)`.

**Sentinel** (moved to `src/libraries/Constants.sol` — `MARKER_MASK` :9, `ORIGIN_PAYER` :13, `_ADDRESS_MASK` :17; imported by the adapter at `src/PmmAdaptor.sol:11`):
```solidity
uint256 constant MARKER_MASK = 0xffffffffffff0000000000000000000000000000000000000000000000000000;
uint256 constant ORIGIN_PAYER = 0x3ca20afc2ccc0000000000000000000000000000000000000000000000000000;
uint256 constant _ADDRESS_MASK = 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;
```

The high six bytes of the trailing word MUST exactly match `ORIGIN_PAYER` under `MARKER_MASK` for the refund to fire; otherwise the leftover stays in the adapter and could be consumed by the next caller's balance-of read.

**Key constraints**:
- [Rule] Aggregator MUST append a 32-byte trailing word whose high bits match `ORIGIN_PAYER` and whose low 160 bits are the payer address. Without it, leftover taker asset accumulates in the adapter and is "donated" to the next caller. (Source: src/PmmAdaptor.sol:308-317)
- [Pitfall] The adapter has no setter or owner; nobody can sweep stuck residuals. Aggregator-side hygiene is the only mitigation.

### 2.5 Downstream Error Decoding (`_call`)

`_call` (legacy 3-arg wrapper `src/PmmAdaptor.sol:339-341`, which forwards with the maker-balance recheck disabled; 4-arg implementation `:343-469`) wraps the low-level call to `pool.fillOrderRFQTo` and re-reverts known custom errors as human-readable strings of the form `"<ErrorName> <rfqId>"`.

**Recognised selectors** (one switch case per error, `src/PmmAdaptor.sol:360-439`):

| Selector | Error Name |
|----------|-----------|
| `0x7d0bdf81` | `RFQ_InvalidMsgValue` |
| `0x1952c5f3` | `RFQ_ETHTransferFailed` |
| `0x8fde5c60` | `RFQ_ZeroTargetIsForbidden` |
| `0x87a26f41` | `RFQ_BadSignature` |
| `0x84935d57` | `RFQ_OrderExpired` |
| `0x48872c38` | `RFQ_MakerAmountExceeded` |
| `0x51c6158e` | `RFQ_TakerAmountExceeded` |
| `0x94d42471` | `RFQ_SwapWithZeroAmount` |
| `0x6fe432b3` | `RFQ_InvalidatedOrder` |
| `0xf4a08977` | `RFQ_EthDepositRejected` (no rfqId in the error; re-thrown as plain `"RFQ_EthDepositRejected"` without rfqId, src/PmmAdaptor.sol:387-390) |
| `0xf4059071` | `SafeTransferFromFailed` (re-emitted as `RFQ_SafeTransferFromFailed`) |
| `0x8112e119` | `Permit2TransferAmountTooHigh` |
| `0xfb7f5079` | `SafeTransferFailed` |
| `0x19be9a90` | `ForceApproveFailed` |
| `0x8216cd1c` | `SafeIncreaseAllowanceFailed` |
| `0x840bdf26` | `SafeDecreaseAllowanceFailed` |
| `0x68275857` | `SafePermitBadLength` |
| `0xc6f643b2` | `RFQ_AmountTooLarge` |
| `0xa1475d7b` | `RFQ_SettlementAmountTooSmall` |
| `0x589584f5` | `RFQ_OrderAlreadyCancelledOrUsed` |
| `0x1204d22d` | `RFQ_ConfidenceCapExceeded` |
| `0x015333a0` | `RFQ_BadSender` |
| `0xc05bb6cf` | `RFQ_InvalidRfqId` |
| `0xb08bb943` | `AUTH_ZeroSigner` |
| `0x69b79ba5` | `AUTH_UntrustedCaller` |
| `0x8c843811` | `AUTH_BadAuthSig` |
| `0xba235405` | `AUTH_BadSigLen` |
| `0x62406192` | `AUTH_NonceUsed` |

The last seven entries (`RFQ_BadSender` :424, `RFQ_InvalidRfqId` :427, `AUTH_ZeroSigner` :430, `AUTH_UntrustedCaller` :432, `AUTH_BadAuthSig` :434, `AUTH_BadSigLen` :436, `AUTH_NonceUsed` :438) are matched in code via `Errors.X.selector` / `CallerAuth.X.selector` references rather than hardcoded hex, and each is re-thrown as `"<Name> <rfqId>"`.

Fallback cases:
- Revert data shorter than 4 bytes → `"RFQ: Unknown error <rfqId>"`. (Source: src/PmmAdaptor.sol:350-353)
- Unrecognised selector → NOT unconditionally `"RFQ_Failed"`. When the `MakerBalanceCheck` passed to the 4-arg `_call` is enabled (V2/V3 orders with `usePermit2 && permit2Signature.length > 0`), the fallback first runs a read-only maker-balance recheck: `_safeBalanceOf(makerAsset, maker)` via staticcall (`src/PmmAdaptor.sol:474-481`); if the balance is below the fill's `makerAmount`, it recomputes the confidence-adjusted (time-slippage) threshold with `_getMakerAmountForBalanceCheck` (`:487-503`, mirroring the protocol's reduction; V2's zeroed confidence inputs leave the amount unchanged) and, if the balance is below even that adjusted threshold, reverts `"RFQ_SafeTransferFromFailed <rfqId>"`. Otherwise (check disabled, staticcall failed/short return, or balance sufficient) it degrades to `"RFQ_Failed <rfqId>"`. (Source: src/PmmAdaptor.sol:440-468)

**Key constraints**:
- [Rule] Any new custom error added to `src/libraries/Errors.sol` MUST also be added to the `_call` switch — otherwise the adapter falls back to the generic `"RFQ_Failed"` message and downstream debugging suffers. (Source: src/PmmAdaptor.sol:343-469)

### 2.6 Adapter Calling Convention

Before `sellBase` or `sellQuote` executes, the adapter must already hold the taker asset. Each `_executeV*Order` reads `IERC20(takerAsset).balanceOf(address(this))`; it does not pull funds from `msg.sender`.

Both entry points read an optional trailing refund marker at calldata `-32`. OrderType=4 additionally reads the router-caller marker at `-64`. The two markers use exact, distinct masked constants.

**Key constraints**:
- [Rule] Do not infer PMM trade direction from `sellBase` versus `sellQuote`; direction comes from `OrderRFQ.makerAsset` and `takerAsset`.
- [Rule] Fund the adapter before entry. Refactoring it to pull from `msg.sender` changes the adapter contract.
- [Rule] Include a valid refund marker when residual taker assets must be returned. Without one, `_handleRefund` intentionally skips the transfer.
- [Rule] OrderType=4 requires a valid router-caller marker so `allowedSender` can be checked.

---

## 3. State Machine

The adapter stores caller-authorization nonce bits and the reentrancy status. Swap execution follows this flow:

```
ENTRY (sellBase / sellQuote)
  └─► decode moreInfo
        └─► dispatch by orderType (1/2/3/4)
              └─► approve pool, call pool.fillOrderRFQTo
                    └─► _handleRefund
                          └─► EXIT
```

Failure exits short-circuit at any step; no rollback logic needed because of EVM transactional semantics.

---

## 4. Core Calculation Rules

- **`amount`** (per-call cap) = `min(IERC20(takerAsset).balanceOf(adapter), order.takerAmount)`. (Source: src/PmmAdaptor.sol:149-152; same pattern at :179-182, :223-226, :281-284)
- **`flagsAndAmount`** = `(signatureType == EIP1271 ? 1 << 254 : 0) + amount`. (Source: src/PmmAdaptor.sol:155, :185, :229, :287)
- **`_payerOrigin`** = `address(uint160(payerOrigin & _ADDRESS_MASK))` when `(payerOrigin & MARKER_MASK) == ORIGIN_PAYER`, else `address(0)`. (Source: src/PmmAdaptor.sol:308-317)

---

## 5. Access Control

| Role | Permitted Actions | Constraints |
|------|-------------------|-------------|
| Adapter caller | `sellBase(to, pool, moreInfo)`, `sellQuote(to, pool, moreInfo)` | Legacy order types do not check caller authorization. OrderType=4 requires `msg.sender` in `adaptorAuth.allowedCallers`. `pool` is supplied per-call. |

- **Immutable roles**: `AUTH_SIGNER` is set at deploy and used by orderType=4. The adapter has no owner or admin.

---

## 6. Events

> `PMMAdapter` emits NO events of its own. All observability comes from the downstream `PMMProtocol.OrderFilledRFQ` (or `OrderCancelledRFQ`) event. (Source: src/PmmAdaptor.sol — `grep -n "event\|emit" src/PmmAdaptor.sol` returns no hits.)

---

## 7. Constraints & Risk Rules

- [Rule] `orderType ∈ {1, 2, 3, 4}` only. Extending the version set requires a matching protocol interface and execution branch.
- [Rule] The adapter MUST hold ≥ 1 unit of the taker asset at each `_executeV*Order` entry; this is enforced by `require(amount > 0, "Zero balance of PMM adapter")`. (Source: src/PmmAdaptor.sol:153, :183, :227, :285)
- [Rule] The adapter uses OpenZeppelin's `safeApprove` (not the project's local `forceApprove`). OpenZeppelin's `safeApprove` reverts on non-zero current allowance for USDT-style tokens. Aggregator must ensure approval is zero before each call OR the maker pre-cleans approvals externally. (Source: src/PmmAdaptor.sol:154, :184, :228, :286 vs src/libraries/SafeERC20.sol:82-91)
- [Rule] Refund only fires when the trailing calldata word matches `ORIGIN_PAYER`. (Source: src/PmmAdaptor.sol:308-317)
- [Rule] Every `RFQ_*` selector defined in `src/libraries/Errors.sol` MUST appear in `_call`'s switch. (Source: src/PmmAdaptor.sol:343-469)
- [Pitfall] `sellBase` and `sellQuote` have byte-for-byte identical bodies. In AMM-style aggregator adapters one method name conventionally encodes a swap direction (base→quote vs quote→base); **PMM does not follow that convention** — direction is encoded in `OrderRFQ.makerAsset` / `takerAsset`. The dual entry-points exist only to satisfy the aggregator's interface contract. Consumers MUST NOT depend on which method is called to infer direction. (Source: src/PmmAdaptor.sol:319-335)
- [Pitfall] The adapter encodes `flagsAndAmount` with at most bit 254. It does not expose WETH unwrap, signature-length pinning, or maker-side fill selection through its public entry points.
- [Pitfall] Residual `takerAsset` left in the adapter (when no `ORIGIN_PAYER` is set) is permanently "donated" — there is no sweep function. (Source: src/PmmAdaptor.sol:308-317)

---

## 8. Test Focus

### Happy Path
- [ ] `sellBase` with `orderType = 3`, valid V3 order, EIP-712 signature: forwards correctly, leftover refunded to payer.
- [ ] `sellQuote` produces the same output as `sellBase` for the same inputs.
- [ ] `orderType = 1` (V1) and `orderType = 2` (V2): both still execute correctly, exercising backward compatibility.
- [ ] `orderType = 4`: both caller authorizations validate, `allowedSender` matches, and the current protocol selector succeeds.
- [ ] EIP-1271 signature path (`signatureType = 1`): bit 254 is set on `flagsAndAmount`.
- [ ] Refund: when `ORIGIN_PAYER` sentinel matches, leftover `takerAsset` is transferred to the encoded payer address.

### Unhappy Path
- [ ] `orderType = 0` or `orderType = 5` → revert `"PMMAdapter: unsupported orderType"`.
- [ ] Adapter has zero `takerAsset` balance → revert `"Zero balance of PMM adapter"`.
- [ ] Downstream `RFQ_BadSignature` selector → string revert `"RFQ_BadSignature <rfqId>"`.
- [ ] Downstream `RFQ_OrderExpired` selector → string revert `"RFQ_OrderExpired <rfqId>"`.
- [ ] Downstream returns empty revert data → `"RFQ: Unknown error <rfqId>"`.
- [ ] Downstream returns unrecognised selector (balance recheck disabled, or maker balance sufficient) → `"RFQ_Failed <rfqId>"`.
- [ ] Downstream returns unrecognised selector on a V2/V3 Permit2 order (`usePermit2 && permit2Signature.length > 0`) whose maker balance is below the confidence-adjusted payout → `"RFQ_SafeTransferFromFailed <rfqId>"`.

### High-Risk Scenarios
- [ ] USDT-style token: aggregator does not pre-clear adapter's existing approval → `safeApprove` reverts. Verify aggregator hygiene.
- [ ] Trailing calldata word missing or malformed (no `ORIGIN_PAYER` sentinel) → refund silently skipped, leftover stays in adapter — verify donation-to-next-caller behaviour.
- [ ] Two consecutive aggregator calls where the first leaves residual and the second has a higher `order.takerAmount`: the second's `amount` is capped at the combined balance (donation effect).
- [ ] `pool` address points to a non-`PMMProtocol` contract: arbitrary behaviour — verify the adapter does not pin a single `pool`.

---

## 9. Terminology

| Term | Definition |
|------|------------|
| `PMMAdapter` | The dispatch contract in `src/PmmAdaptor.sol`; inherits `CallerAuth` and `ReentrancyGuard`. |
| `pool` | Per-call address of a `PMMProtocol` instance the adapter forwards into. |
| `orderType` | Caller-supplied dispatch tag: `1` = V1, `2` = V2, `3` = V3, `4` = current caller-bound V4. |
| `sellBase` / `sellQuote` | The two external entry-points exposed by `PMMAdapter`. Byte-for-byte identical bodies. In AMM-style adapters these names conventionally signal swap direction; in PMM they do not — direction comes from `OrderRFQ.makerAsset` / `takerAsset`. |
| `SignatureType.EIP712` | EOA / ECDSA signature path. |
| `SignatureType.EIP1271` | Smart-contract signer path; sets bit 254 of `flagsAndAmount`. |
| `IPMMProtocolV1.OrderRFQ` | 8-field shape (pre-Permit2 inline fields). |
| `IPMMProtocolV2.OrderRFQ` | 11-field shape (adds `permit2Signature`, `permit2Witness`, `permit2WitnessType`). |
| `IPMMProtocolV3.OrderRFQ` | 14-field legacy shape (adds `confidenceT`, `confidenceWeight`, `confidenceCap`). The current 15-field `OrderRFQLib.OrderRFQ` adds `allowedSender` and is used by orderType=4 through `IPMMProtocolV4`. |
| `PayerOrigin` | Trailing 32-byte calldata word; high bits sentinel + low 160 bits payer address. |
| `ORIGIN_PAYER` | `0x3ca20afc2ccc0000…`; sentinel high-bit pattern enabling refund flow. |
| `RefundFlow` | The `_handleRefund` step that returns any residual `takerAsset` to the payer. |
