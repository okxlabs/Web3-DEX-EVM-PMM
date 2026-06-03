# Context Knowledge Graph — OKX Labs PMM (Private Market Maker) RFQ Protocol

This directory is the context knowledge base for `GitHub-Web3-DEX-EVM-PMM`.
It is read by AI Skills before writing, reviewing, or auditing smart contract code.

## Structure

| Directory | Purpose |
|-----------|---------|
| `technical/` | Contract architecture, rules, and coding conventions |
| `business/` | Business domain and product context |
| `quality/` | Quality standards and audit checklists |

## Scope & Boundaries

This knowledge base covers domain-level rules and facts. It does NOT duplicate:

| What | Lives in | Contains |
|------|----------|----------|
| AI behavior rules | `.claude/CLAUDE.md` / project `CLAUDE.md` | Build/test commands, project conventions |
| Contract specification | `README.md` | RFQ workflow, OrderRFQ struct, fill semantics |
| Deployment addresses | `DEPLOYMENT.md` | V1/V2/V3 contract addresses per chain |
| Skill / agent definitions | `.claude/skills/` | `/pmm-settle`, `/pmm-debug-sig` |
| **Domain rules** | `context-kg/technical/` | Architecture, invariants, pitfalls, conventions |
| **Business context** | `context-kg/business/` | Product purpose, RFQ trading workflow |
| **Quality gates** | `context-kg/quality/` | Audit checklists, coverage requirements |
