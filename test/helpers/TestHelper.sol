// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../../src/OrderRFQLib.sol";
import "../../src/PmmProtocol.sol";
import "../../src/interfaces/IPermit2.sol";

contract TestHelper is Test {
    using OrderRFQLib for OrderRFQLib.OrderRFQ;

    // Test private keys (these are test keys, never use in production)
    uint256 public constant MAKER_PRIVATE_KEY = uint256(keccak256("maker-test-seed"));
    uint256 public constant TAKER_PRIVATE_KEY = uint256(keccak256("taker-test-seed"));

    // Authorization signer used to authorise caller-bound settlement.
    // Test-only key.
    uint256 public constant AUTH_SIGNER_KEY = uint256(keccak256("auth-signer-test-seed"));

    bytes32 public constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    bytes32 public constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    // Generate addresses from private keys
    address public immutable MAKER_ADDRESS;
    address public immutable TAKER_ADDRESS;
    address public immutable AUTH_SIGNER_ADDRESS;

    // Monotonic nonce source so each caller-auth signature uses a fresh nonce.
    uint256 internal _testAuthNonce;

    constructor() {
        MAKER_ADDRESS = vm.addr(MAKER_PRIVATE_KEY);
        TAKER_ADDRESS = vm.addr(TAKER_PRIVATE_KEY);
        AUTH_SIGNER_ADDRESS = vm.addr(AUTH_SIGNER_KEY);
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
            allowedSender: address(0),
            confidenceT: confidenceT,
            confidenceWeight: confidenceWeight,
            confidenceCap: confidenceCap,
            permit2Signature: "",
            permit2Witness: bytes32(0),
            permit2WitnessType: ""
        });
    }

    /// @dev Builds a valid caller-auth tuple for `caller` against `verifyingContract`,
    /// signed by the test authorization key (EIP-191 personal-sign, EIP-2098 compact 64-byte). Uses a
    /// fresh monotonic nonce each call.
    function _callerAuth(address caller, address verifyingContract, bytes32 payloadHash)
        internal
        returns (address[] memory allowedCallers, uint256 nonce, bytes memory authSig)
    {
        allowedCallers = new address[](1);
        allowedCallers[0] = caller;
        nonce = _testAuthNonce++;

        // Must match CallerAuth._verifyCallerAuth `inner` preimage exactly.
        bytes32 inner = keccak256(abi.encode(verifyingContract, payloadHash, allowedCallers, nonce, block.chainid));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AUTH_SIGNER_KEY, ethSignedHash);
        // EIP-2098 compact: pack the recovery bit (v-27) into the top bit of s.
        bytes32 vs = s | bytes32(uint256(v - 27) << 255);
        authSig = abi.encodePacked(r, vs);
    }

    /// @dev Regression helper mirroring the removed `fillOrderRFQ`: fills to `caller` and
    /// supplies a valid caller-auth tuple bound to `caller`. Preserves any active `vm.prank`
    /// (the auth build only invokes cheatcodes, which do not consume the prank), so callers
    /// keep their existing `vm.prank(caller)` line before invoking this.
    function _fillAs(
        PMMProtocol p,
        address caller,
        OrderRFQLib.OrderRFQ memory order,
        bytes memory signature,
        uint256 flagsAndAmount
    ) internal returns (uint256, uint256, bytes32) {
        (address[] memory allowedCallers, uint256 nonce, bytes memory authSig) =
            _callerAuth(caller, address(p), keccak256(abi.encode(order)));
        return p.fillOrderRFQTo(order, signature, flagsAndAmount, caller, allowedCallers, nonce, authSig);
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
