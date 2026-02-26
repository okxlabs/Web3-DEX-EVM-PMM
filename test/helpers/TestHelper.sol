// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../../src/OrderRFQLib.sol";
import "../../src/interfaces/IPermit2.sol";

contract TestHelper is Test {
    using OrderRFQLib for OrderRFQLib.OrderRFQ;

    // Test private keys (these are test keys, never use in production)
    uint256 public constant MAKER_PRIVATE_KEY = uint256(keccak256("maker-test-seed"));
    uint256 public constant TAKER_PRIVATE_KEY = uint256(keccak256("taker-test-seed"));

    bytes32 public constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    bytes32 public constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

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
        bool usePermit2,
        uint256 confidenceT,
        uint256 confidenceWeight,
        uint256 confidenceCap
    ) internal pure returns (OrderRFQLib.OrderRFQ memory) {
        return OrderRFQLib.OrderRFQ({
            rfqId: rfqId,
            expiry: expiry,
            makerAsset: makerAsset,
            takerAsset: takerAsset,
            makerAddress: makerAddress,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            usePermit2: usePermit2,
            confidenceT: confidenceT,
            confidenceWeight: confidenceWeight,
            confidenceCap: confidenceCap,
            permit2Signature: "",
            permit2Witness: bytes32(0),
            permit2WitnessType: ""
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

    function getPermit2Signature(
        IPermit2.PermitTransferFrom memory permit,
        address pmmProtocolAddress,
        uint256 privateKey,
        bytes32 domainSeparator
    ) internal pure returns (bytes memory sig) {
        bytes32 tokenPermissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        PERMIT_TRANSFER_FROM_TYPEHASH,
                        tokenPermissions,
                        pmmProtocolAddress,
                        permit.nonce,
                        permit.deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function getFutureTimestamp(uint256 offset) internal view returns (uint256) {
        return block.timestamp + offset;
    }

    function getCurrentTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }
}
