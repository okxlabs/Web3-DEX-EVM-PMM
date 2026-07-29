# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OKX Labs PMM (Private Market Maker) RFQ settlement protocol. Solidity smart contracts enabling on-chain RFQ order filling with EIP-712 signatures, Uniswap Permit2 integration, and time-based slippage (confidence) mechanism.

## Tech Stack

- **Contracts**: Solidity 0.8.17, Foundry (forge/cast), EVM target: london
- **Scripts**: JavaScript (ES Module), ethers.js v6
- **Dependencies**: OpenZeppelin 4.8.1, 1inch solidity-utils 2.2.15

## Build & Test Commands

```bash
# Build contracts
forge build

# Run all tests
forge test

# Run a single test file
forge test --match-path test/PmmProtocolTimeSlippage.t.sol

# Run a single test function
forge test --match-test testSlippageAppliesAfterConfidenceT

# Run tests with verbosity
forge test -vvvv

# Run fork tests (requires ARBITRUM_RPC_URL in .env)
forge test --match-path test/PmmProtocolPermitWitnessFork.t.sol --fork-url $ARBITRUM_RPC_URL

# Run JS signing scripts
node script/testSignOrder.js
```

## Architecture

### Core Contracts

- **`PmmProtocol.sol`** — Main settlement contract. Inherits `EIP712` + `CallerAuth` + `ReentrancyGuard`. Handles caller-bound order filling, signature verification (EOA + ERC-1271), Permit2 transfers, WETH unwrapping, and time-slippage.
- **`OrderRFQLib.sol`** — Defines the `OrderRFQ` struct (15 fields, including `allowedSender`) and its EIP-712 hash computation. The typehash and encoding logic must stay in sync with off-chain signing code.
- **`PmmAdaptor.sol`** — DEX aggregator adapter. Supports legacy V1/V2/V3 and caller-bound V4 order formats. Implements `sellBase()`/`sellQuote()` interface.
- **`EIP712.sol`** — Domain separator with immutable caching. Domain: `name="OKX Labs PMM Protocol"`, `version="1.2"`.

### Key Mechanisms

**Two independent EIP-712 signatures** are needed for Permit2 flows:
1. **OrderRFQ signature** — signed against PmmProtocol domain (4-field: name, version, chainId, verifyingContract)
2. **Permit2 signature** — signed against Permit2 domain (3-field: name, chainId, verifyingContract — **NO version field**)

Permit2 must be signed FIRST because the OrderRFQ struct hash includes `keccak256(permit2Signature)`.

**Time-slippage (confidence)** uses parts-per-million (1e6 = 100%). Convert from bps: `value_1e6 = bps * 100`. Hard cap: 50000 (5%). Only reduces makerAmount; takerAmount unchanged. Settlement limit (60%) checked before reduction.

**flagsAndAmount** encodes bit flags (bits 252-255) and fill amount (bits 0-159) in a single uint256.

### EIP-712 Encoding Rules for OrderRFQ

- `bytes` fields (`permit2Signature`): hash with `keccak256()` before encoding
- `string` fields (`permit2WitnessType`): hash with `keccak256(toUtf8Bytes())` before encoding
- `bytes32` fields (`permit2Witness`): encode directly, NO hashing

## Skills

Project-level skills in `.claude/skills/`:
- **`/pmm-settle`** — Integration guide: struct, signing, Permit2, time-slippage, fill flow
- **`/pmm-debug-sig`** — Signature debugging: 5-step diagnostic, common failure patterns

## Deployment Addresses

See [DEPLOYMENT.md](DEPLOYMENT.md) for full V1/V2/V3 address list.

**V4 (Current):**

| Chain | PmmProtocol | Adaptor |
|-------|-------------|---------|
| Ethereum | `0x73b920dC64ab6156f2D22b85AB9A9b06E597e154` | `0x4ecD468E1010E006f768EC034e5a6d8803183469` |
| Arbitrum | `0x2C5486E06dB4F72E3eFd6bdd891Af50ee75b7e9e` | `0x34fDA863Bfef0F976F5d0a0e366BC44883296Cf7` |
| Base | `0x9ECb5cf09eBb1Cb844b8e2C8cc7cB8b57643C6C8` | `0x22eef0C15678c482DcAC05c0d102363fc31f8C81` |
| BNB Chain | `0x8A35eE6d2d533e6b2934ceD4aff0aDd0C7af1769` | `0x9a8d68089aDBe8428f79c244d34276a9f4251070` |
| XLayer | `0x31d7BCA06a0143ABc7c93418792Aae8AA69183b0` | `0xa6566f0689a9ec2fdff3f6fd3ed58b227246765c` |

Permit2 (all chains): `0x000000000022D473030F116dDEE9F6B43aC78BA3`
