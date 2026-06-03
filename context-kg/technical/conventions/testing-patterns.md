---
name: "testing-patterns"
description: "Foundry testing conventions for OKX Labs PMM Protocol"
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

- [Rule] Signature generation MUST use `vm.sign(privateKey, digest)` — never hardcode signature bytes. See `test/PmmProtocolPermitWitnessFork.t.sol:155` for the pattern.
- [Rule] Tests MUST cover at minimum: valid fill, expired signature, wrong signer (`RFQ_BadSignature`), and replay attempt (`RFQ_InvalidatedOrder`). The current `PmmProtocol.t.sol` already covers these — preserve when refactoring.
- [Rule] When testing ERC-1271 paths, the test contract must implement `isValidSignature(bytes32, bytes) returns (bytes4)` returning `0x1626ba7e` for an accepted digest.

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

## Out-of-Sync Test Files

> **Heads up (2026-05):** the V4 struct introduces 3 new fields (`confidenceT`, `confidenceWeight`, `confidenceCap`). At the time this knowledge base was generated, `test/mocks/MockMarketMaker.sol`, `test/PmmProtocolPermitWitnessFork.t.sol`, and `scripts/Deploy.s.sol` still construct the 11-field V3 `OrderRFQ` shape and do not compile against `src/`. Production `src/` builds clean. Before running the full suite, either update the test mocks to the 14-field struct or temporarily build with `forge build --skip 'test/**' --skip 'scripts/**'`.

<!-- TODO: When the test suite is updated, remove the "Out-of-Sync Test Files" block above and add fuzz-test conventions if testFuzz_ functions are introduced -->

## Not Currently Used

The following Foundry test classes are **not** in use today; add the matching convention block if introduced:

- Fuzz testing (`testFuzz_*`) — no occurrences in `test/`.
- Invariant testing (`InvariantHandler`, ghost state) — no occurrences in `test/`.
