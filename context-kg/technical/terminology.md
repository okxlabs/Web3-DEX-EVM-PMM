---
name: "terminology"
description: "Canonical term definitions — roles, OrderRFQ parameters, flag bits, errors, and storage slots for OKX Labs PMM Protocol"
---

# Terminology

## Roles

| Term | Description | Defined In |
|------|-------------|------------|
| Maker | Off-chain PMM that signs `OrderRFQ` structs; owns the maker-asset funds. Identified by `order.makerAddress`. | `PmmProtocol.sol` (order field) |
| Taker | Caller of `fillOrderRFQ*` — pays the taker asset and receives the maker asset. Identified by `msg.sender`. | `PmmProtocol.sol::_fillOrderRFQTo` |
| Target | Recipient of the maker leg, used when the taker wants to forward funds (e.g., aggregator). Passed as `target` to `fillOrderRFQTo`. | `PmmProtocol.sol::fillOrderRFQTo` |
| Aggregator | Calls `PMMAdapter.sellBase` / `sellQuote` from a swap router; the adapter then calls `PMMProtocol.fillOrderRFQTo`. | `PmmAdaptor.sol::sellBase`, `sellQuote` |

## OrderRFQ Fields

`OrderRFQLib.OrderRFQ` (14 fields — V3 format):

| Term | Solidity Type | Description | Used In |
|------|---------------|-------------|---------|
| `rfqId` | `uint256` | 64-bit-sized ID used for invalidation (`uint8` is the bit, `uint64 >> 8` is the slot). | `_invalidateOrder`, `cancelOrderRFQ`, `isRfqIdUsed` |
| `expiry` | `uint256` | Unix timestamp; `block.timestamp > expiry → RFQ_OrderExpired`. Also used as Permit2 `deadline`. | `_fillOrderRFQTo` |
| `makerAsset` | `address` | Token the maker sends to taker/target. | `_fillOrderRFQTo` |
| `takerAsset` | `address` | Token the taker sends to the maker. | `_fillOrderRFQTo` |
| `makerAddress` | `address` | Signer of the OrderRFQ EIP-712 digest; fund owner. | `ECDSA.recoverOrIsValidSignature`, `_invalidator` key |
| `makerAmount` | `uint256` | Quoted maker size (capped to `uint160.max` when `usePermit2 = true` for a full fill). | `_fillOrderRFQTo` |
| `takerAmount` | `uint256` | Quoted taker size. | `_fillOrderRFQTo`, `AmountCalculator` |
| `usePermit2` | `bool` | When `true`, maker leg uses Uniswap Permit2 transfer; otherwise standard `safeTransferFrom`. | `_fillOrderRFQTo` |
| `confidenceT` | `uint256` | Unix timestamp after which time-slippage activates (`0` disables). | `_fillOrderRFQTo` confidence block |
| `confidenceWeight` | `uint256` | Reduction rate per second in 1e6 units (e.g., `1000` = 0.1%/s). | `_fillOrderRFQTo` confidence block |
| `confidenceCap` | `uint256` | Max cumulative reduction in 1e6 units; hard cap `_CONFIDENCE_CAP_LIMIT = 50000` (5%). | `_fillOrderRFQTo` confidence block |
| `permit2Signature` | `bytes` | Optional inline Permit2 signature (65 bytes when present). Hashed with `keccak256` for the OrderRFQ struct hash. | `_fillOrderRFQTo`, `OrderRFQLib.hash` |
| `permit2Witness` | `bytes32` | Pre-hashed witness payload for `permitWitnessTransferFrom`. Encoded directly in the struct hash (no extra keccak). | `_fillOrderRFQTo`, `OrderRFQLib.hash` |
| `permit2WitnessType` | `string` | Canonical witness type string for Permit2. Hashed with `keccak256(bytes(...))` for the struct hash. | `_fillOrderRFQTo`, `OrderRFQLib.hash` |

## `flagsAndAmount` Bits

| Bit | Constant | Description |
|-----|----------|-------------|
| 255 | `_MAKER_AMOUNT_FLAG` (`1 << 255`) | If set, the masked amount is interpreted as a maker-side fill; otherwise as a taker-side fill. Ignored when amount is `0` (full fill). |
| 254 | `_SIGNER_SMART_CONTRACT_HINT` (`1 << 254`) | Maker signature originates from an ERC-1271 contract; skip `ecrecover` path. |
| 253 | `_IS_VALID_SIGNATURE_65_BYTES` (`1 << 253`) | Combined with hint bit, enforces the calldata signature length is exactly 65 bytes. |
| 252 | `_UNWRAP_WETH_FLAG` (`1 << 252`) | When `makerAsset == WETH`, unwrap and forward native ETH to the taker / target. |
| 0–159 | `_AMOUNT_MASK` (`uint160.max`) | Requested fill amount; `0` means full order. |

## Settlement Constants

| Term | Value | Defined In | Description |
|------|-------|-----------|-------------|
| `_SETTLE_LIMIT` | `6000` | `PmmProtocol.sol:66` | Numerator of the minimum-fill ratio. |
| `_SETTLE_LIMIT_BASE` | `10000` | `PmmProtocol.sol:67` | Denominator → minimum fill = 60%. |
| `_CONFIDENCE_CAP_LIMIT` | `50000` | `PmmProtocol.sol:69` | Hard cap on `confidenceCap`, 5% in 1e6 units. |
| `_RAW_CALL_GAS_LIMIT` | `5000` | `PmmProtocol.sol:61` | Gas stipend for the WETH-unwrap `.call`. |
| `_PERMIT2` | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | `SafeERC20.sol:20` | Canonical Permit2 address (same across chains). |

## Events

| Term | Kind | Description |
|------|------|-------------|
| `OrderFilledRFQ` | Event | Emitted in `fillOrderRFQTo` and `fillOrderRFQCompact` after the order is settled. Includes both quoted and filled amounts and full Permit2 metadata. |
| `OrderCancelledRFQ` | Event | Emitted in `cancelOrderRFQ` after the maker's bitmap is updated. |

## Custom Errors

`Errors.sol` (all `uint256 rfqId` unless noted):

| Term | Thrown When |
|------|------------|
| `RFQ_InvalidMsgValue` | `msg.value` is non-zero when taker asset is not WETH, or != `takerAmount` when it is. |
| `RFQ_ETHTransferFailed` | The low-level `.call` that forwards unwrapped ETH to `target` returns `false`. |
| `RFQ_EthDepositRejected` | `receive()` is hit by any sender other than `_WETH`. (no rfqId) |
| `RFQ_ZeroTargetIsForbidden` | `target == address(0)` in `_fillOrderRFQTo`. |
| `RFQ_BadSignature` | Maker signature fails ECDSA recovery / ERC-1271 / length checks. |
| `RFQ_OrderExpired` | `block.timestamp > order.expiry`. |
| `RFQ_MakerAmountExceeded` | Requested maker amount > `order.makerAmount`. |
| `RFQ_TakerAmountExceeded` | Requested taker amount > `order.takerAmount`. |
| `RFQ_SwapWithZeroAmount` | Derived `makerAmount` or `takerAmount` is zero (e.g., taker-side fill rounding to zero). |
| `RFQ_InvalidatedOrder` | `_invalidateOrder` finds the bit already set. |
| `RFQ_AmountTooLarge` | Full-fill maker amount > `uint160.max` while `usePermit2 = true`. |
| `RFQ_SettlementAmountTooSmall` | Maker or taker fill < 60% of the quoted amount (before confidence reduction). |
| `RFQ_OrderAlreadyCancelledOrUsed` | `cancelOrderRFQ` called for an rfqId already consumed. |
| `RFQ_ConfidenceCapExceeded` | `order.confidenceCap > _CONFIDENCE_CAP_LIMIT` (50000). |

Additional errors from `SafeERC20.sol` may surface through fill flows: `SafeTransferFailed`, `SafeTransferFromFailed`, `ForceApproveFailed`, `SafeIncreaseAllowanceFailed`, `SafeDecreaseAllowanceFailed`, `SafePermitBadLength`, `Permit2TransferAmountTooHigh`.

## Storage Slots

`PMMProtocol` (from `forge inspect`):

| Variable | Type | Slot | Description |
|----------|------|------|-------------|
| `_status` | `uint256` | 0 | Inherited from OpenZeppelin `ReentrancyGuard`. |
| `_invalidator` | `mapping(address => mapping(uint256 => uint256))` | 1 | Outer key: maker. Inner key: `rfqId >> 8`. Value: 256-bit bitmap of used rfqIds (bit position = `uint8(rfqId)`). |

`EIP712` (inherited by `PMMProtocol`):

| Variable | Type | Slot | Description |
|----------|------|------|-------------|
| `_CACHED_DOMAIN_SEPARATOR` | `bytes32` | immutable | Domain separator built at construction; bypassed on chain-id fork. |
| `_CACHED_CHAIN_ID` | `uint256` | immutable | `block.chainid` at construction; trigger to rebuild domain. |
| `_CACHED_THIS` | `address` | immutable | `address(this)` at construction; trigger to rebuild domain. |
| `_HASHED_NAME` | `bytes32` | immutable | `keccak256("OKX Labs PMM Protocol")`. |
| `_HASHED_VERSION` | `bytes32` | immutable | `keccak256("1.1")`. |
| `_TYPE_HASH` | `bytes32` | immutable | `keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")`. |

`PMMProtocol` immutables (not in storage layout):

| Variable | Type | Description |
|----------|------|-------------|
| `_WETH` | `IWETH` | WETH9 address for the deployed chain; used for wrap/unwrap. |

`PMMAdapter`: no state variables. Only `internal constant ORIGIN_PAYER` and `constant ADDRESS_MASK`.
