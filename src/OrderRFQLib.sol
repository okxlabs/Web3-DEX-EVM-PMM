// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "./libraries/ECDSA.sol";

library OrderRFQLib {
    struct OrderRFQ {
        uint256 rfqId; // 0x00
        uint256 expiry; // 0x20
        address makerAsset; // 0x40
        address takerAsset; // 0x60
        address makerAddress; // 0x80
        uint256 makerAmount; // 0xa0
        uint256 takerAmount; // 0xc0
        bool usePermit2; // 0xe0;
    }

    bytes32 internal constant _LIMIT_ORDER_RFQ_TYPEHASH = keccak256(
        "OrderRFQ(" "uint256 rfqId," "uint256 expiry," "address makerAsset," "address takerAsset,"
        "address makerAddress," "uint256 makerAmount," "uint256 takerAmount," "bool usePermit2" ")"
    );

    function hash(OrderRFQ memory order, bytes32 domainSeparator) internal pure returns (bytes32 result) {
        // Manually encoding each field instead of abi.encode(..., order)
        // to avoid Yul "stack too deep" errors caused by expanding memory structs.
        bytes32 structHash = keccak256(
            abi.encode(
                _LIMIT_ORDER_RFQ_TYPEHASH,
                order.rfqId,
                order.expiry,
                order.makerAsset,
                order.takerAsset,
                order.makerAddress,
                order.makerAmount,
                order.takerAmount,
                order.usePermit2
            )
        );
        return ECDSA.toTypedDataHash(domainSeparator, structHash);
    }
}
