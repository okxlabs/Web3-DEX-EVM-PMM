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

//  forge verify-contract 0xa016a3c082e780c096cfa7e70018c7257c071f64 src/PmmProtocol.sol:PMMProtocol --chain-id 56 --etherscan-api-key 18KMMG7MBYD4P4HJ6ICMZS7NJ95UTGRB7H

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

        // OKX backend signer used for the anti-toxic-flow caller binding (SCDEX-1157).
        // Provided at deploy time via the OKX_SIGNER env var.
        address okxSigner = vm.envAddress("OKX_SIGNER");
        require(okxSigner != address(0), "Deploy: OKX_SIGNER unset");

        vm.startBroadcast(deployer);

        PMMProtocol protocol = new PMMProtocol(IWETH(weth), okxSigner);

        // Append the constructor arg (okxSigner) to the adapter creation bytecode.
        bytes memory adapterBytecode =
            abi.encodePacked(vm.getCode("PmmAdaptor.sol:PMMAdapter"), abi.encode(okxSigner));
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
