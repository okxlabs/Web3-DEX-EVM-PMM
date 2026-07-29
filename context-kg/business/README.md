# Business Domain

## Index

| File | Purpose |
|------|---------|
| `pmm_settlement.md` | PMM RFQ Settlement (On-Chain) — `PMMProtocol` fill flow, EIP-712 signing (domain v1.2), single-use invalidator, settlement guardrail, confidence reduction, Permit2 modes, WETH wrap/unwrap, maker cancellation. |
| `pmm_adapter_migration.md` | PMMAdapter V1/V2/V3 OrderRFQ Migration — aggregator-side dispatch over three legacy OrderRFQ shapes for backward compatibility (plus the new orderType=4, see below). |
| `pmm_anti_toxic_flow.md` | PMM Anti-Toxic-Flow (SCDEX-1157) — required `allowedSender`, `allowedSender == dexRouterCaller` check (orderType=4), and OKX caller binding on `PMMAdapter` + `PMMProtocol`. |

<!-- TODO: Describe the product and user-facing purpose of this protocol in more detail (target users, commercial drivers, integration partners) -->

## Protocol Summary

OKX Labs PMM is the on-chain leg of an RFQ (request-for-quote) routing stack used by the OKX DEX aggregator. Private market makers stream signed `OrderRFQ` quotes off-chain; takers settle them on-chain through `PMMProtocol` (or via the aggregator using `PMMAdapter`) to obtain tighter spreads than AMM liquidity provides.

## Key User Journeys

- **Maker onboarding** — A PMM exposes `/levels` and `/order` REST/WebSocket feeds, then signs 15-field `OrderRFQ` structs (incl. `allowedSender`) against the `"OKX Labs PMM Protocol" / 1.2` EIP-712 domain.
- **Taker fill** — The aggregator routes via `PMMAdapter` (orderType=4), which enforces `allowedSender == dexRouterCaller` and OKX caller binding, then calls the single `PMMProtocol.fillOrderRFQTo`.
- **Maker cancellation** — Maker may invalidate an RFQ ID on-chain via `cancelOrderRFQ` before a taker fills it.
- **Anti-toxic-flow protection** — a quote priced for a "clean" address can no longer be settled from a decoupled address; see `pmm_anti_toxic_flow.md`.

<!-- TODO: Document SLAs / pricing commitments expected of PMMs -->
<!-- TODO: Document any per-chain rollout or onboarding constraints -->
