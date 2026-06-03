# Business Domain

## Index

| File | Purpose |
|------|---------|
| `pmm_settlement.md` | PMM RFQ Settlement (On-Chain) — `PMMProtocol` fill flow, EIP-712 signing, single-use invalidator, settlement guardrail, confidence reduction, Permit2 modes, WETH wrap/unwrap, maker cancellation. |
| `pmm_adapter_migration.md` | PMMAdapter V1/V2/V3 OrderRFQ Migration — aggregator-side dispatch over three OrderRFQ shapes for backward compatibility during protocol upgrades. |

<!-- TODO: Describe the product and user-facing purpose of this protocol in more detail (target users, commercial drivers, integration partners) -->

## Protocol Summary

OKX Labs PMM is the on-chain leg of an RFQ (request-for-quote) routing stack used by the OKX DEX aggregator. Private market makers stream signed `OrderRFQ` quotes off-chain; takers settle them on-chain through `PMMProtocol` (or via the aggregator using `PMMAdapter`) to obtain tighter spreads than AMM liquidity provides.

## Key User Journeys

- **Maker onboarding** — A PMM exposes `/levels` and `/order` REST/WebSocket feeds, then signs `OrderRFQ` structs against the `"OKX Labs PMM Protocol" / 1.1` EIP-712 domain.
- **Taker fill** — Aggregator selects a PMM leg, taker broadcasts `fillOrderRFQ*` with the maker's signature (and optionally a Permit2 signature or ERC-20 permit for the taker asset).
- **Maker cancellation** — Maker may invalidate an RFQ ID on-chain via `cancelOrderRFQ` before a taker fills it.

<!-- TODO: Document SLAs / pricing commitments expected of PMMs -->
<!-- TODO: Document any per-chain rollout or onboarding constraints -->
