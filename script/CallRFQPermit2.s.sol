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
        bool usePermit2;
    }

    function fillOrderRFQTo(OrderRFQ memory order, bytes memory signature, uint256 flagsAndAmount, address target)
        external
        returns (uint256, uint256, bytes32);
}

contract CallRFQPermit2 is Script {
    function run() external {
        // 真实私钥通过 .env 加载或直接写入（开发测试）
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);

        IRouter.OrderRFQ memory order = IRouter.OrderRFQ({
            rfqId: 13578,
            expiry: 2068195245,
            makerAsset: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            takerAsset: 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9,
            makerAddress: 0x80C0664922CF70a9c38e131861403c428F36C035,
            makerAmount: 101000,
            takerAmount: 100000,
            usePermit2: true
        });

        address contractAddr = 0x8C3D3bbE4D5a41349Db248fc2436442d4968Cb7b;
        IRouter router = IRouter(contractAddr);

        bytes memory sig =
            hex"ff4cad1f96187ddb47102dd2b800150e8533b0d0f009e86474fcbd3576d07afa4b89d3028bc23781416b1573282552c35f8462923550599724cb2fd2e85d79751c";
        address adapter = 0x19244841F215b6FB016736C5c735B9B065d9890B;

        (uint256 a, uint256 b, bytes32 c) = router.fillOrderRFQTo(order, sig, 100000, adapter);

        // console2.log("Result:", a, b, c);
        vm.stopBroadcast();
    }
}
