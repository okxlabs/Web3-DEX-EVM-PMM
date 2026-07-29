---
name: "contract-EIP712"
description: "Abstract base providing a cached EIP-712 domain separator and _hashTypedDataV4 — inherited by PMMProtocol"
---

# Contract: EIP712

Source: `src/EIP712.sol` (pragma `0.8.17`). This is the project's local copy of OpenZeppelin's classic EIP-712 base, derived from `_Available since v3.4._`.

## Purpose

`EIP712` is an `abstract contract` that builds and caches an EIP-712 domain separator at construction time, and rebuilds it on the fly if `block.chainid` or `address(this)` changes (defensive against chain forks). It exposes two internal helpers used by `PMMProtocol`:

- `_domainSeparatorV4()` — returns the cached separator when safe, otherwise rebuilds.
- `_hashTypedDataV4(bytes32 structHash)` — returns `ECDSA.toTypedDataHash(_domainSeparatorV4(), structHash)`.

`PMMProtocol.DOMAIN_SEPARATOR()` is a thin external accessor over `_domainSeparatorV4()`. Order hashing happens in `OrderRFQLib.hash`, which calls `ECDSA.toTypedDataHash` directly with the domain separator returned by `_domainSeparatorV4` — `_hashTypedDataV4` itself is not invoked from the fill path in this project.

## Inheritance

None. `EIP712` is the root of its own inheritance chain.

## State Variables

All `immutable`, set in the constructor — none of them appear in `storage-layout` (immutables live in code, not storage).

| Variable | Type | Mutable | Purpose |
|----------|------|---------|---------|
| `_CACHED_DOMAIN_SEPARATOR` | `bytes32` | No | Domain separator computed at construction. |
| `_CACHED_CHAIN_ID` | `uint256` | No | `block.chainid` at construction; rebuild trigger. |
| `_CACHED_THIS` | `address` | No | `address(this)` at construction; rebuild trigger. |
| `_HASHED_NAME` | `bytes32` | No | `keccak256(bytes(name))` — set by inheritor (`PMMProtocol` passes `"OKX Labs PMM Protocol"`). |
| `_HASHED_VERSION` | `bytes32` | No | `keccak256(bytes(version))` — set by inheritor (`PMMProtocol` passes `"1.2"` as of SCDEX-1157; was `"1.1"`). |
| `_TYPE_HASH` | `bytes32` | No | `keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")`. |

## Access Control

None. All non-constructor logic is `internal view`.

## Functions

| Function | Mutability | Description |
|----------|-----------|-------------|
| `constructor(string name, string version)` | nonpayable | Hashes `name` and `version`, caches `block.chainid` and `address(this)`, builds the initial domain separator. Called by `PMMProtocol`'s constructor with `EIP712(_NAME, _VERSION)`. |
| `_domainSeparatorV4()` | internal view | Returns `_CACHED_DOMAIN_SEPARATOR` when `address(this) == _CACHED_THIS && block.chainid == _CACHED_CHAIN_ID`; otherwise rebuilds via `_buildDomainSeparator`. |
| `_buildDomainSeparator(bytes32 typeHash, bytes32 nameHash, bytes32 versionHash)` | private view | `keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(this)))`. |
| `_hashTypedDataV4(bytes32 structHash)` | internal view virtual | `ECDSA.toTypedDataHash(_domainSeparatorV4(), structHash)`. |

## Events

None.

## Custom Errors

None.

## Security Patterns Used

- Immutable cache — cheap reads on the hot path while remaining safe against chain forks (any change to `block.chainid` or `address(this)` triggers a full rebuild).
- Defence-in-depth against contract relocation — `_CACHED_THIS` ensures the separator is invalidated if the contract is `DELEGATECALL`ed from another address (not a deployed scenario for `PMMProtocol`, which is non-upgradeable, but a useful guarantee).

## Key Invariants

- [Rule] The domain separator returned by `_domainSeparatorV4()` always encodes the **current** `block.chainid` and `address(this)`, even after a chain fork that diverges from the original `_CACHED_CHAIN_ID`.
- [Rule] `_HASHED_NAME` and `_HASHED_VERSION` are immutable post-construction — changing them requires redeploying the inheritor.
