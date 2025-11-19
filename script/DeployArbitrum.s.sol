// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/PmmProtocol.sol";
import "../src/interfaces/IWETH.sol";

contract DeployArbitrum is Script {
    // Arbitrum One WETH address
    address constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // Arbitrum One Chain ID
    uint256 constant ARBITRUM_CHAIN_ID = 42161;

    function run() external {
        // Get deployment parameters from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_DEPLOYER");
        address deployer = vm.addr(deployerPrivateKey);
        vm.createSelectFork("https://arb1.arbitrum.io/rpc");
        // "https://rpc.owlracle.info/arb/70d38ce1826c4a60bb2a8e05a6c8b20f"

        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);
        console.log("Chain ID:", block.chainid);

        // Verify we're on Arbitrum One
        require(block.chainid == ARBITRUM_CHAIN_ID, "Not on Arbitrum One");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy PmmProtocol
        console.log("Deploying PmmProtocol...");
        console.log("Using WETH address:", ARBITRUM_WETH);

        PMMProtocol pmmProtocol = new PMMProtocol(IWETH(ARBITRUM_WETH));

        vm.stopBroadcast();

        // Log deployment information
        console.log("=== Deployment Summary ===");
        console.log("PmmProtocol deployed at:", address(pmmProtocol));
        console.log("WETH address used:", ARBITRUM_WETH);
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);

        // Verify deployment
        console.log("\n=== Verification ===");
        console.log("Domain separator:", vm.toString(pmmProtocol.DOMAIN_SEPARATOR()));

        // Save deployment info to file
        string memory deploymentInfo = string(
            abi.encodePacked(
                "PmmProtocol deployed on Arbitrum One\n",
                "Contract Address: ",
                vm.toString(address(pmmProtocol)),
                "\n",
                "WETH Address: ",
                vm.toString(ARBITRUM_WETH),
                "\n",
                "Chain ID: ",
                vm.toString(block.chainid),
                "\n",
                "Deployer: ",
                vm.toString(deployer),
                "\n",
                "Block Number: ",
                vm.toString(block.number),
                "\n",
                "Domain Separator: ",
                vm.toString(pmmProtocol.DOMAIN_SEPARATOR())
            )
        );

        vm.writeFile("deployment-arbitrum.txt", deploymentInfo);
        console.log("Deployment info saved to deployment-arbitrum.txt");

        // Prepare verification command
        console.log("\n=== Verification Command ===");
        console.log("To verify the contract, run:");
        console.log(
            string(
                abi.encodePacked(
                    "forge verify-contract ",
                    vm.toString(address(pmmProtocol)),
                    " src/PmmProtocol.sol:PmmProtocol --chain-id ",
                    vm.toString(block.chainid),
                    " --constructor-args ",
                    vm.toString(abi.encode(ARBITRUM_WETH)),
                    " --etherscan-api-key $ARBISCAN_API_KEY"
                )
            )
        );
    }
}
