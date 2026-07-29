// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Script.sol";
import "../src/PmmAdaptor.sol";

/**
 * @title DeployAdaptor
 * @notice Deploys the PMMAdapter (adapter layer).
 * @dev PMMAdapter takes the authorization signer as its sole constructor argument,
 *      provided via the AUTH_SIGNER env var.
 */
contract DeployAdaptor is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY_DEPLOYER");
        address authSigner = vm.envAddress("AUTH_SIGNER");
        require(authSigner != address(0), "DeployAdaptor: AUTH_SIGNER unset");

        console.log("Chain ID:", block.chainid);
        console.log("Deploying PMMAdapter (adapter only; PmmProtocol unchanged)");

        vm.startBroadcast(deployerKey);
        PMMAdapter adapter = new PMMAdapter(authSigner);
        vm.stopBroadcast();

        console.log("PMMAdapter deployed at:", address(adapter));
    }
}
