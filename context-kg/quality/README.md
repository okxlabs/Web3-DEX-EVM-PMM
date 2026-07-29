# Quality

## Validation Checklist

- `forge build` completes with the repository compiler configuration.
- Non-fork tests pass with `forge test --no-match-path 'test/*Fork*'`.
- Fork tests run with their documented RPC and signer environment variables.
- `node script/testSignOrder.js` verifies the current 15-field OrderRFQ type and domain version `1.2`.
- Caller-authorization tests cover wrong signer, wrong payload, wrong caller, cross-contract replay, and nonce replay.
- Adapter tests cover legacy order types 1-3, orderType=4, sender-marker validation, and exact refund-marker matching.
- Any change to `OrderRFQ`, the EIP-712 name/version, or caller-authorization preimage is treated as a breaking signing change.
- Deployment review verifies constructor arguments, bytecode, proxy/admin configuration where applicable, and immutable signer/WETH values.
