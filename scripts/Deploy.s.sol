// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Script.sol";
import "../src/PmmProtocol.sol";
import "../src/interfaces/IWETH.sol";

/**
 * @title Deploy
 * @notice Deployment script for PMMProtocol
 * @dev Usage:
 *   forge script scripts/Deploy.s.sol:Deploy \
 *     --rpc-url $RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify
 */

contract Deploy is Script {
    // Canonical WETH addresses per chain
    address constant WETH_MAINNET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WETH_ARBITRUM = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address constant WETH_BSC = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // WBNB
    address constant WOKB_XLAYER = 0xe538905cf8410324e03A5A23C1c177a474D59b2b; // WOKB on XLayer
    address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY_DEPLOYER"));

    function run() external {
        address weth = _getWeth();
        require(weth != address(0), "Deploy: unsupported chain");

        console.log("Chain ID:", block.chainid);
        console.log("Wrapped native used:", weth);

        // Authorization signer used for caller binding.
        // Provided at deploy time via the AUTH_SIGNER env var.
        address authSigner = vm.envAddress("AUTH_SIGNER");
        require(authSigner != address(0), "Deploy: AUTH_SIGNER unset");

        vm.startBroadcast(deployer);

        PMMProtocol protocol = new PMMProtocol(IWETH(weth), authSigner);

        // Append the constructor arg (authSigner) to the adapter creation bytecode.
        bytes memory adapterBytecode =
            abi.encodePacked(vm.getCode("PmmAdaptor.sol:PMMAdapter"), abi.encode(authSigner));
        address adapter;
        assembly {
            adapter := create(0, add(adapterBytecode, 0x20), mload(adapterBytecode))
        }
        require(adapter != address(0), "Deploy: PMMAdapter deployment failed");

        vm.stopBroadcast();

        console.log("PMMProtocol deployed at:", address(protocol));
        console.log("PMMAdapter deployed at:", adapter);
    }

    function _getWeth() internal view returns (address) {
        if (block.chainid == 1) return WETH_MAINNET;
        if (block.chainid == 42161) return WETH_ARBITRUM;
        if (block.chainid == 8453) return WETH_BASE;
        if (block.chainid == 56) return WETH_BSC;
        if (block.chainid == 196) return WOKB_XLAYER;
        revert("Deploy: unsupported chain");
    }
}
