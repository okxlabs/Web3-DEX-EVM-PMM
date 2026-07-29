// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {CallerAuth} from "../src/libraries/CallerAuth.sol";
import {DEX_ROUTER_CALLER_MARKER, MARKER_MASK, ORIGIN_PAYER, _ADDRESS_MASK} from "../src/libraries/Constants.sol";

/*//////////////////////////////////////////////////////////////
                            TEST HARNESS
//////////////////////////////////////////////////////////////*/

/// @dev Minimal concrete subclass exposing the internal CallerAuth surface so caller binding and the
///      -64 dexRouterCaller marker extraction are testable in isolation, without settlement flow.
contract CallerAuthHarness is CallerAuth {
    constructor(address authSigner) CallerAuth(authSigner) {}

    /// External wrapper for `_verifyCallerAuth` — reverts propagate to the caller.
    function verify(bytes32 payloadHash, address[] memory allowedCallers, uint256 nonce, bytes memory authSig) external {
        _verifyCallerAuth(payloadHash, allowedCallers, nonce, authSig);
    }

    /// External wrapper for the pure `_extractDexRouterCaller`; reads the -64 calldata
    /// word of THIS call, so callers append the trailing marker word via a raw `.call`.
    function extract() external pure returns (address) {
        return _extractDexRouterCaller();
    }
}

/*//////////////////////////////////////////////////////////////
                                TESTS
//////////////////////////////////////////////////////////////*/

/// @notice Unit coverage for the CallerAuth base and the `_extractDexRouterCaller` exact-marker
///         read. Signatures are produced with `vm.sign`; the authorization signer key is derived
///         with `makeAddrAndKey`.
contract CallerAuthTest is Test {
    CallerAuthHarness internal auth;

    uint256 internal authSignerKey;
    address internal authSigner;

    address internal dexRouter = makeAddr("dexRouter");
    address internal dynamicRoute = makeAddr("dynamicRoute");
    address internal attacker = makeAddr("attacker");
    address internal dexUser = makeAddr("dexUser");
    bytes32 internal constant PAYLOAD_HASH = bytes32(uint256(0x1234));

    function setUp() public {
        (authSigner, authSignerKey) = makeAddrAndKey("authSigner");
        auth = new CallerAuthHarness(authSigner);
        vm.warp(1_000_000); // deterministic non-zero base timestamp
    }

    /*//////////////////////////////////////////////////////////////
                          SIGNING / HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reproduces CallerAuth._verifyCallerAuth `inner` preimage exactly and signs it
    /// EIP-191 with `key`, returning an EIP-2098 compact 64-byte signature.
    function _signAuth(
        address verifyingContract,
        bytes32 payloadHash,
        address[] memory allowedCallers,
        uint256 nonce,
        uint256 key
    ) internal view returns (bytes memory) {
        bytes32 inner = keccak256(abi.encode(verifyingContract, payloadHash, allowedCallers, nonce, block.chainid));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ethSignedHash);
        bytes32 vs = s | bytes32(uint256(v - 27) << 255);
        return abi.encodePacked(r, vs); // 64 bytes, EIP-2098 compact
    }

    function _single(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _pair(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    /// @dev Build the marked -64 calldata word for `caller` (marker | address).
    function _markCaller(address caller) internal pure returns (uint256) {
        return DEX_ROUTER_CALLER_MARKER | uint256(uint160(caller));
    }

    /// @dev Invoke `extract()` with the two trailing calldata words injected by DexRouter
    /// (`dexRouterCaller[-64]`, `refundTo[-32]`) so `_extractDexRouterCaller` reads `word64`
    /// at calldatasize-64. The -32 slot is an arbitrary filler here. Returns the decoded
    /// dexRouterCaller.
    function _extractWith(uint256 word64) internal returns (address) {
        bytes memory data = abi.encodePacked(auth.extract.selector, word64, uint256(0));
        (bool ok, bytes memory ret) = address(auth).call(data);
        assertTrue(ok, "extract call reverted");
        return abi.decode(ret, (address));
    }

    /*//////////////////////////////////////////////////////////////
                    CONSTRUCTOR FAIL-CLOSED
    //////////////////////////////////////////////////////////////*/

    // A zero authorization signer is rejected at construction, so the fail-closed condition is
    // enforced at deploy time rather than at verify time.
    function testConstructorRejectsZeroSigner() public {
        vm.expectRevert(CallerAuth.AUTH_ZeroSigner.selector);
        new CallerAuthHarness(address(0));
    }

    function testConstructorStoresSigner() public view {
        assertEq(auth.AUTH_SIGNER(), authSigner);
    }

    /*//////////////////////////////////////////////////////////////
                    CALLER BINDING (happy path)
    //////////////////////////////////////////////////////////////*/

    // A signed authorization whose msg.sender is in allowedCallers passes and consumes the nonce.
    function testVerifyValidAuthConsumesNonce() public {
        address[] memory callers = _pair(dexRouter, dynamicRoute);
        uint256 nonce = 1;
        bytes memory sig = _signAuth(address(auth), PAYLOAD_HASH, callers, nonce, authSignerKey);

        assertFalse(auth.isNonceUsed(nonce));
        vm.prank(dexRouter);
        auth.verify(PAYLOAD_HASH, callers, nonce, sig);
        assertTrue(auth.isNonceUsed(nonce));
    }

    // Membership is by exact address; the second entry in the set is also accepted.
    function testVerifyAcceptsSecondAllowedCaller() public {
        address[] memory callers = _pair(dexRouter, dynamicRoute);
        bytes memory sig = _signAuth(address(auth), PAYLOAD_HASH, callers, 2, authSignerKey);

        vm.prank(dynamicRoute);
        auth.verify(PAYLOAD_HASH, callers, 2, sig);
        assertTrue(auth.isNonceUsed(2));
    }

    /*//////////////////////////////////////////////////////////////
                    CALLER BINDING (revert paths)
    //////////////////////////////////////////////////////////////*/

    // msg.sender not in the signed allowedCallers set -> AUTH_UntrustedCaller.
    function testVerifyRejectsUntrustedCaller() public {
        address[] memory callers = _single(dexRouter);
        bytes memory sig = _signAuth(address(auth), PAYLOAD_HASH, callers, 3, authSignerKey);

        vm.prank(attacker);
        vm.expectRevert(CallerAuth.AUTH_UntrustedCaller.selector);
        auth.verify(PAYLOAD_HASH, callers, 3, sig);
    }

    // Reusing a consumed nonce -> AUTH_NonceUsed.
    function testVerifyRejectsReusedNonce() public {
        address[] memory callers = _single(dexRouter);
        bytes memory sig = _signAuth(address(auth), PAYLOAD_HASH, callers, 4, authSignerKey);

        vm.prank(dexRouter);
        auth.verify(PAYLOAD_HASH, callers, 4, sig);

        // Re-sign the identical preimage (same nonce): signature is valid, but the nonce
        // bitmap already has the bit set.
        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.AUTH_NonceUsed.selector);
        auth.verify(PAYLOAD_HASH, callers, 4, sig);
    }

    // Signature length other than the EIP-2098 compact 64 bytes -> AUTH_BadSigLen.
    function testVerifyRejectsBadSigLen() public {
        address[] memory callers = _single(dexRouter);
        // 65-byte (r,s,v) legacy signature is not accepted; base is compact-only.
        bytes memory sig65 = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));
        assertEq(sig65.length, 65);

        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.AUTH_BadSigLen.selector);
        auth.verify(PAYLOAD_HASH, callers, 6, sig65);
    }

    // Valid-length signature but signed by a key other than the authorization signer ->
    // AUTH_BadAuthSig.
    function testVerifyRejectsWrongSigner() public {
        (, uint256 wrongKey) = makeAddrAndKey("notAuthSigner");
        address[] memory callers = _single(dexRouter);
        bytes memory sig = _signAuth(address(auth), PAYLOAD_HASH, callers, 7, wrongKey);

        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.AUTH_BadAuthSig.selector);
        auth.verify(PAYLOAD_HASH, callers, 7, sig);
    }

    // A malformed signature whose `s` is in the upper half order makes ECDSA.recover fail closed
    // to address(0) -> AUTH_BadAuthSig.
    function testVerifyRejectsMalformedSignatureRecoverZero() public {
        address[] memory callers = _single(dexRouter);
        // vs with all low-255 bits set -> s == _COMPACT_S_MASK, far above the s-boundary,
        // so recover() takes the `signer stays 0` path.
        bytes32 r = bytes32(uint256(1));
        bytes32 vs = bytes32(uint256((1 << 255) - 1));
        bytes memory sig = abi.encodePacked(r, vs);
        assertEq(sig.length, 64);

        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.AUTH_BadAuthSig.selector);
        auth.verify(PAYLOAD_HASH, callers, 8, sig);
    }

    // A signature bound to a different verifyingContract does not verify against this instance.
    function testVerifyRejectsCrossContractReplay() public {
        address[] memory callers = _single(dexRouter);
        // Sign for some OTHER contract address, then present to `auth`.
        bytes memory sig = _signAuth(address(0xDEAD), PAYLOAD_HASH, callers, 9, authSignerKey);

        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.AUTH_BadAuthSig.selector);
        auth.verify(PAYLOAD_HASH, callers, 9, sig);
    }

    function testVerifyRejectsPayloadReplay() public {
        address[] memory callers = _single(dexRouter);
        bytes memory sig = _signAuth(address(auth), PAYLOAD_HASH, callers, 10, authSignerKey);

        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.AUTH_BadAuthSig.selector);
        auth.verify(bytes32(uint256(0x5678)), callers, 10, sig);
    }

    /*//////////////////////////////////////////////////////////////
        _extractDexRouterCaller EXACT marker match
    //////////////////////////////////////////////////////////////*/

    // A valid DexRouter marker word at -64 returns the embedded address.
    function testExtractValidMarkerReturnsAddress() public {
        address got = _extractWith(_markCaller(dexUser));
        assertEq(got, dexUser);
    }

    // Missing marker (plain address word, no marker bits) fails closed to address(0).
    function testExtractMissingMarkerReturnsZero() public {
        uint256 word = uint256(uint160(dexUser)); // no marker in high bytes
        assertEq(_extractWith(word), address(0));
    }

    // Forged marker: high 48 bits all set does not equal DEX_ROUTER_CALLER_MARKER under the
    // exact-match test, so extraction fails closed to address(0).
    function testExtractForgedFullBitsMarkerReturnsZero() public {
        uint256 word = MARKER_MASK | uint256(uint160(attacker));
        assertEq(_extractWith(word), address(0));
    }

    // The ORIGIN_PAYER marker (`...ccc...`, used for the -32 refund word) must NOT be accepted
    // as a dexRouterCaller marker (`...ddd...`), proving the two trailing words never collide.
    function testExtractOriginPayerMarkerReturnsZero() public {
        uint256 word = ORIGIN_PAYER | uint256(uint160(dexUser));
        assertEq(_extractWith(word), address(0));
    }

    // Marker present but embedded address is zero → returns address(0) (still fail-closed for
    // the downstream `allowedSender != 0` check).
    function testExtractMarkerWithZeroAddressReturnsZero() public {
        assertEq(_extractWith(DEX_ROUTER_CALLER_MARKER), address(0));
    }
}
