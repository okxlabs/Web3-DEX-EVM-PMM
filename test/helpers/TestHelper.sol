// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../../src/OrderRFQLib.sol";

contract TestHelper is Test {
    using OrderRFQLib for OrderRFQLib.OrderRFQ;

    // Test private keys (these are test keys, never use in production)
    uint256 public constant MAKER_PRIVATE_KEY = 0x1234567890123456789012345678901234567890123456789012345678901234;
    uint256 public constant TAKER_PRIVATE_KEY = 0x9876543210987654321098765432109876543210987654321098765432109876;

    // Generate addresses from private keys
    address public immutable MAKER_ADDRESS;
    address public immutable TAKER_ADDRESS;

    constructor() {
        MAKER_ADDRESS = vm.addr(MAKER_PRIVATE_KEY);
        TAKER_ADDRESS = vm.addr(TAKER_PRIVATE_KEY);
    }

    function createOrder(
        uint256 rfqId,
        uint256 expiry,
        address makerAsset,
        address takerAsset,
        address makerAddress,
        uint256 makerAmount,
        uint256 takerAmount,
        bool usePermit2
    ) internal pure returns (OrderRFQLib.OrderRFQ memory) {
        return OrderRFQLib.OrderRFQ({
            rfqId: rfqId,
            expiry: expiry,
            makerAsset: makerAsset,
            takerAsset: takerAsset,
            makerAddress: makerAddress,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            usePermit2: usePermit2
        });
    }

    function signOrder(OrderRFQLib.OrderRFQ memory order, bytes32 domainSeparator, uint256 privateKey)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 orderHash = order.hash(domainSeparator);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, orderHash);
        return abi.encodePacked(r, s, v);
    }

    function getFutureTimestamp(uint256 offset) internal view returns (uint256) {
        return block.timestamp + offset;
    }

    function getCurrentTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }
}
