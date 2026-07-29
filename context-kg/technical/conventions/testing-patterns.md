---
name: "testing-patterns"
description: "Foundry testing conventions for OKX Labs PMM Protocol — incl. caller-auth (okxSigner) and anti-toxic-flow (allowedSender/dexRouterCaller) test patterns"
type: "design"
title: "Testing Patterns"
tags: ["testing", "foundry", "forge", "caller-auth", "okxSigner", "allowedSender", "anti-toxic-flow", "SCDEX-1157"]
sources: ["test/helpers/TestHelper.sol", "test/PmmProtocol.t.sol", "test/PmmProtocolTimeSlippage.t.sol", "test/PmmAdaptor.t.sol", "test/mocks/MockMarketMaker.sol"]
last_updated: "2026-07-05"
---

# Testing Patterns

## Framework

The project uses Foundry (`forge test`). All tests live in `test/`. Helpers and mocks live under `test/helpers/` and `test/mocks/`.

Suite layout:

| File | Purpose |
|------|---------|
| `test/PmmProtocol.t.sol` | Unit tests for the main fill / cancel paths against `MockERC20` and `MockWETH`. |
| `test/PmmProtocolTimeSlippage.t.sol` | Focused tests for the confidence (time-slippage) parameters. |
| `test/PmmProtocolPermitWitnessFork.t.sol` | Arbitrum fork tests exercising Permit2 + witness flows against real USDC/USDT contracts and the real Permit2 deployment. |
| `test/helpers/TestHelper.sol` | Shared `setUp` helpers, signer/maker deployment, `createOrder(...)` factory. |
| `test/mocks/*.sol` | `MockERC20`, `MockWETH`, `MockMarketMaker`, `MockPMMSettler`, `MockPermit2`. |

## Test Structure

- [Rule] Every test file has a `setUp()` that deploys `PMMProtocol`, the test ERC-20s, and grants approvals for the test maker / taker pair.
- [Rule] Test function names follow `test{Scenario}` for passing cases and `test{Scenario}Reverts` (or include the error name) for revert cases — see `testFillOrderRejectsExpiredOrder`, `testFillOrderRejectsBadSignature`.
- [Rule] Reusable scaffolding (maker/taker addresses, asset deployment, order factory) lives in `test/helpers/TestHelper.sol`; never duplicate setup across test files.

## Signature Testing

- [Rule] Signature generation MUST use `vm.sign(privateKey, digest)` — never hardcode signature bytes. See `test/PmmProtocolPermitWitnessFork.t.sol` for the pattern.
- [Rule] Tests MUST cover at minimum: valid fill, expired signature, wrong signer (`RFQ_BadSignature`), and replay attempt (`RFQ_InvalidatedOrder`). The current `PmmProtocol.t.sol` already covers these — preserve when refactoring.
- [Rule] When testing ERC-1271 paths, the test contract must implement `isValidSignature(bytes32, bytes) returns (bytes4)` returning `0x1626ba7e` for an accepted digest.

### Caller-Auth (OKX signer) Testing — SCDEX-1157

`test/helpers/TestHelper.sol` provides the caller-auth scaffolding used by the single caller-bound `fillOrderRFQTo`:

- `OKX_SIGNER_KEY` (a deterministic test key) and `OKX_SIGNER_ADDRESS = vm.addr(OKX_SIGNER_KEY)`. Deploy `PMMProtocol`/`PMMAdapter` with this signer.
- `_callerAuth(caller, verifyingContract)` — builds and signs the `(address(this), allowedCallers, nonce, expiry, chainId)` tuple with `OKX_SIGNER_KEY` via `vm.sign`, EIP-191 personal-sign, EIP-2098 compact 64-byte.
- `_fillAs(protocol, caller, …)` — regression wrapper that supplies a valid caller-auth tuple so tests exercising the old `fillOrderRFQ(...)` shape keep passing against the new signature.
- [Rule] Caller-auth signatures MUST also use `vm.sign(OKX_SIGNER_KEY, …)`; never hardcode `okxSig`. AC-D-2 recommends `makeAddrAndKey("okxSigner")` — Stage 3 may switch `OKX_SIGNER_KEY` to that form.
- [Rule] Caller-auth revert coverage MUST assert the specific `OSA_*` selector: `OSA_UntrustedCaller`, `OSA_Expired`, `OSA_BadOkxSig`, `OSA_BadSigLen`, `OSA_NonceUsed`, and the constructor `OSA_ZeroSigner` (deploy with `address(0)` signer).

### Anti-Toxic-Flow (allowedSender / dexRouterCaller) Testing — SCDEX-1157

- [Rule] The `-64` `dexRouterCaller` word must be injected in tests via a mock (DexRouter injection is out-of-scope for this repo). Cover: happy path (`allowedSender == dexRouterCaller` → fill), mismatch (`!=` → `RFQ_BadSender`), zero `allowedSender` (fail-closed → `RFQ_BadSender`), and marker exact-match (forged/missing marker → `dexRouterCaller == 0` → `RFQ_BadSender`).
- [Rule] `createOrder(...)` in `TestHelper.sol` now populates `allowedSender` (defaults to `address(0)`); set it explicitly for anti-toxic happy-path tests.

## Access Control Testing

- [Rule] Use `vm.prank(unauthorizedCaller)` for the taker / maker side of every fill. The current tests prank both `maker` (for cancellation, approvals) and `taker` (for fills) — preserve this discipline.
- [Rule] There are no custom access-control modifiers in `PMMProtocol`, so "access control" tests reduce to: signature mismatch (`RFQ_BadSignature`), wrong-maker cancel (cancellation is bound to `msg.sender` by design, so a different maker simply flips a different bit — no revert; test the bit-isolation invariant explicitly).

## State Isolation

- [Rule] Tests MUST NOT depend on execution order — each test sets up its own order via `createOrder(...)` and `vm.sign`.
- [Rule] Use `vm.deal(addr, amount)` for native ETH funding and explicit `mint(...)` on the test ERC-20s for token balances; do not rely on `deal(...)` cheatcodes against forked tokens unless inside a fork test.

## Fork Tests

- [Rule] Fork tests use the named RPC `arbitrum` from `foundry.toml` (`vm.createSelectFork("arbitrum")`). Other chain forks should be added as named endpoints in `foundry.toml` first.
- [Rule] Fork-dependent tests live in dedicated files (`*Fork.t.sol`) so the unit suite runs without RPC dependencies. The default `forge test` invocation MUST work offline; fork suites are opt-in via `--match-path` or `--fork-url`.
- [Rule] Whenever a fork test exercises Permit2, it must use the real Permit2 deployment at `0x000000000022D473030F116dDEE9F6B43aC78BA3`, not a mock — see `test/PmmProtocolPermitWitnessFork.t.sol`.

## Coverage Targets (Recommended)

- [Rule] Every `RFQ_*` error in `src/libraries/Errors.sol` MUST have at least one `testRevert*` case that asserts the specific selector via `vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_X.selector, rfqId))`. Never use bare `vm.expectRevert()` when the path emits a custom error.
- [Rule] Each branch of the fill flow's amount-derivation logic (full fill, maker-side partial, taker-side partial) MUST have a dedicated test asserting both `filledMakerAmount` and `filledTakerAmount`.
- [Rule] Time-slippage tests cover at minimum: before `confidenceT` (no reduction), after `confidenceT` mid-window, after `confidenceT` past the cap, and `confidenceCap > _CONFIDENCE_CAP_LIMIT` revert. These already exist in `PmmProtocolTimeSlippage.t.sol`.

## Struct-Sync Status (SCDEX-1157)

> **Updated 2026-07-05:** the OrderRFQ struct is now **15 fields** (`allowedSender` added between `usePermit2` and `confidenceT`). The test helpers/mocks were updated to the 15-field shape: `test/helpers/TestHelper.sol::createOrder` and `test/mocks/MockMarketMaker.sol` both carry `allowedSender`, and `test/*.t.sol` deploy the protocol/adapter with an `okxSigner` and route fills through `_fillAs` / `_callerAuth`. `forge build` compiles `src/`, `test/`, and `scripts/` clean. The non-fork suite passes as a coherence check; full anti-toxic + caller-auth coverage (FR-5 / FR-3, PRD §D AC-D-3) is Stage 3's remit and may add a dedicated `test/PmmProtocol*AntiToxic*.t.sol`.

<!-- TODO: add fuzz-test conventions if testFuzz_ functions are introduced -->

## Not Currently Used

The following Foundry test classes are **not** in use today; add the matching convention block if introduced:

- Fuzz testing (`testFuzz_*`) — no occurrences in `test/`.
- Invariant testing (`InvariantHandler`, ghost state) — no occurrences in `test/`.
