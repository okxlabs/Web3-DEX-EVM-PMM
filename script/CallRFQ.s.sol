// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

interface IRouter {
    struct OrderRFQ {
        uint256 rfqId;
        uint256 expiry;
        address makerAsset;
        address takerAsset;
        address makerAddress;
        uint256 makerAmount;
        uint256 takerAmount;
    }

    function fillOrderRFQTo(OrderRFQ memory order, bytes memory signature, uint256 flagsAndAmount, address target)
        external
        returns (uint256, uint256, bytes32);
}

contract CallRFQ is Script {
    function run() external {
        // 真实私钥通过 .env 加载或直接写入（开发测试）
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);

        IRouter.OrderRFQ memory order = IRouter.OrderRFQ({
            rfqId: 13579,
            expiry: 1752508800,
            makerAsset: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            takerAsset: 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9,
            makerAddress: 0x80C0664922CF70a9c38e131861403c428F36C035,
            makerAmount: 99000,
            takerAmount: 100000
        });

        address contractAddr = 0x49D1552890a39F7bD8Af29142e4EB780e90a216a;
        IRouter router = IRouter(contractAddr);

        bytes memory sig =
            hex"c09e1c273e878a69608e516ee103072dfccc3ca65845ed65da27abb87bf4057b2ad83ac7480ac9882c231b802b61715d8ba5401bc2cb05dec764565e0d8bc0931b";
        address adapter = 0x19244841F215b6FB016736C5c735B9B065d9890B;

        (uint256 a, uint256 b, bytes32 c) = router.fillOrderRFQTo(order, sig, 100000, adapter);

        // console2.log("Result:", a, b, c);
        vm.stopBroadcast();
    }
}
