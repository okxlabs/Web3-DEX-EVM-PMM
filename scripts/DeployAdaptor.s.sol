// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Script.sol";
import "../src/PmmAdaptor.sol";

/**
 * @title DeployAdaptor
 * @notice Deploys ONLY the V3 PMMAdapter (adapter layer). The PmmProtocol settlement
 *         contract is NOT redeployed — it already exists and is unchanged on all 5 chains
 *         (see DEPLOYMENT.md / DEPLOY_V3_ADAPTOR.md). This change (SCDEX-1154) only touches
 *         src/PmmAdaptor.sol, so a standalone Adaptor deploy keeps the protocol address stable.
 *
 * @dev PMMAdapter has a no-arg constructor, so no constructor parameters are required.
 *      Dry-run (simulation only, NO on-chain broadcast):
 *        forge script scripts/DeployAdaptor.s.sol:DeployAdaptor
 *
 *      Real deployment (executed MANUALLY by an operator after MR merge — NOT inside Oli):
 *        forge script scripts/DeployAdaptor.s.sol:DeployAdaptor \
 *          --rpc-url $RPC_URL \
 *          --private-key $PRIVATE_KEY \
 *          --broadcast \
 *          --verify
 */
contract DeployAdaptor is Script {
    function run() external {
        // PRIVATE_KEY is only consumed on a real --broadcast run. For a pure dry-run
        // (no --broadcast), vm.envOr falls back to a deterministic non-secret test key so
        // the simulation can construct the contract without any real credential present.
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0x0000000000000000000000000000000000000000000000000000000000000001)
        );

        console.log("Chain ID:", block.chainid);
        console.log("Deploying PMMAdapter (V3 adapter only; PmmProtocol unchanged)");

        vm.startBroadcast(deployerKey);
        PMMAdapter adapter = new PMMAdapter();
        vm.stopBroadcast();

        console.log("PMMAdapter deployed at:", address(adapter));
    }
}
