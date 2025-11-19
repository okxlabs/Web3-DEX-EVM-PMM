// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../../src/interfaces/IERC20.sol";
import {OrderRFQLib} from "../../src/OrderRFQLib.sol";
import {Test} from "forge-std/Test.sol";

contract MockMarketMaker is Test {
    bool usePermit2;
    bool useEIP1271;
    address signer = vm.rememberKey(vm.envUint("SIGNER_KEY"));
    address treasury;
    address settler;
    address allowedSender;
    address maker;
    address taker;

    constructor() {}

    function firmOrder(
        uint256 chainIndex,
        address baseToken,
        address quoteToken,
        uint256 amount,
        address _takerAddress,
        uint256 rfqId,
        uint256 expriryDuration,
        bytes32 domainSeparator,
        bytes32 orderTypeHash
    ) external returns (OrderRFQLib.OrderRFQ memory order, bytes memory signature, uint256 signatureType) {
        uint256 rfqInfo = uint256(uint64(rfqId));
        uint256 expiryInfo = uint256(block.timestamp + expriryDuration) << 64;
        order = OrderRFQLib.OrderRFQ({
            rfqId: rfqId,
            expiry: block.timestamp + expriryDuration,
            makerAsset: baseToken,
            takerAsset: quoteToken,
            makerAddress: address(this),
            makerAmount: amount,
            takerAmount: amount,
            usePermit2: true
        });

        // Return empty signature and signature type for now
        signature = new bytes(0);
        signatureType = 0;
    }
}
