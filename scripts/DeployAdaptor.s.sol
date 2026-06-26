// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Script.sol";
import "../src/PmmAdaptor.sol";

/**
 * @title DeployAdaptor
 * @notice Deploys the V3 PMMAdapter (adapter layer).
 * @dev PMMAdapter has a no-arg constructor, so no constructor parameters are required.
 */
contract DeployAdaptor is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY_DEPLOYER");

        console.log("Chain ID:", block.chainid);
        console.log("Deploying PMMAdapter (V3 adapter only; PmmProtocol unchanged)");

        vm.startBroadcast(deployerKey);
        PMMAdapter adapter = new PMMAdapter();
        vm.stopBroadcast();

        console.log("PMMAdapter deployed at:", address(adapter));
    }
}
