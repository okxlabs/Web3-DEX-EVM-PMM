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

- **`PmmProtocol.sol`** — Main settlement contract. Inherits `EIP712` + `ReentrancyGuard`. Handles order filling, signature verification (EOA + ERC-1271), Permit2 transfers, WETH unwrapping, and time-slippage.
- **`OrderRFQLib.sol`** — Defines the `OrderRFQ` struct (14 fields) and its EIP-712 hash computation. The typehash and encoding logic must stay in sync with off-chain signing code.
- **`PmmAdaptor.sol`** — DEX aggregator adapter. Supports V1/V2/V3 order formats for backward compatibility. Implements `sellBase()`/`sellQuote()` interface.
- **`EIP712.sol`** — Domain separator with immutable caching. Domain: `name="OKX Labs PMM Protocol"`, `version="1.1"`.

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

**V3 (Current):**

| Chain | PmmProtocol | Adaptor |
|-------|-------------|---------|
| Ethereum | `0x5035D128ef482276Aa3bCce4307ffF8961ba30F9` | `0x10C40FEc71F6cd0F85613467eBa1857eCB1D1308` |
| Arbitrum | `0xcdC09a6B5211bb51F18A1Af7691B6725bB024434` | `0xF2326e58A265f7020ED6D342A9Be4076B9fCF701` |
| Base | `0x4EFBd630205DD9B987c3BcbEe257600abC1e3C11` | `0xa16f075B61d379708485F66e15075C4b638dC554` |
| BNB Chain | `0xdD30339C4b2f7bac319Ef4Fa5c6963cc9F470B2d` | `0x85E569247f1c9b34E1d39Be41ae5194FB8f73156` |
| XLayer | `0x5E18E052517Af66575105ACff6A7f17DED3f10F2` | `0x5670035CAf2Da294Af4BCdC48fB68E9E6157a02e` |

Permit2 (all chains): `0x000000000022D473030F116dDEE9F6B43aC78BA3`
