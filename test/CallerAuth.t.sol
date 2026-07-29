// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {CallerAuth} from "../src/libraries/CallerAuth.sol";
import {DEX_ROUTER_CALLER_MARKER, MARKER_MASK, ORIGIN_PAYER, _ADDRESS_MASK} from "../src/libraries/Constants.sol";

/*//////////////////////////////////////////////////////////////
                            TEST HARNESS
//////////////////////////////////////////////////////////////*/

/// @dev Minimal concrete subclass exposing the internal CallerAuth surface so the
///      OKX-signed caller-binding (FR-3) and the -64 dexRouterCaller marker extraction
///      (FR-5 mechanism) are testable in isolation, without the full settlement flow.
contract CallerAuthHarness is CallerAuth {
    constructor(address okxSigner) CallerAuth(okxSigner) {}

    /// External wrapper for `_verifyCallerAuth` — reverts propagate to the caller.
    function verify(address[] memory allowedCallers, uint256 nonce, uint256 expiry, bytes memory okxSig) external {
        _verifyCallerAuth(allowedCallers, nonce, expiry, okxSig);
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

/// @notice Unit coverage for the CallerAuth base (SCDEX-1157 FR-3 caller binding + the
///         `_extractDexRouterCaller` exact-marker read that FR-5 relies on). All signatures
///         are produced with `vm.sign` (PRD §D: no hardcoded keys); the OKX signer key is
///         derived with `makeAddrAndKey`.
contract CallerAuthTest is Test {
    CallerAuthHarness internal auth;

    uint256 internal okxSignerKey;
    address internal okxSigner;

    address internal dexRouter = makeAddr("dexRouter");
    address internal dynamicRoute = makeAddr("dynamicRoute");
    address internal attacker = makeAddr("attacker");
    address internal dexUser = makeAddr("dexUser");

    uint256 internal constant DEFAULT_EXPIRY_OFFSET = 1 hours;

    function setUp() public {
        (okxSigner, okxSignerKey) = makeAddrAndKey("okxSigner");
        auth = new CallerAuthHarness(okxSigner);
        vm.warp(1_000_000); // deterministic non-zero base timestamp
    }

    /*//////////////////////////////////////////////////////////////
                          SIGNING / HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reproduces CallerAuth._verifyCallerAuth `inner` preimage exactly and signs it
    /// EIP-191 with `key`, returning an EIP-2098 compact 64-byte signature.
    function _signAuth(
        address verifyingContract,
        address[] memory allowedCallers,
        uint256 nonce,
        uint256 expiry,
        uint256 key
    ) internal view returns (bytes memory) {
        bytes32 inner = keccak256(abi.encode(verifyingContract, allowedCallers, nonce, expiry, block.chainid));
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
                    FR-3 / A0 — CONSTRUCTOR FAIL-CLOSED
    //////////////////////////////////////////////////////////////*/

    // A-02 §A0 / FR-3-AC-7: a zero OKX signer is rejected at construction (fail-closed deploy),
    // so the "zero signer" condition is enforced at deploy time rather than at verify time.
    function testConstructorRejectsZeroSigner() public {
        vm.expectRevert(CallerAuth.OSA_ZeroSigner.selector);
        new CallerAuthHarness(address(0));
    }

    function testConstructorStoresSigner() public view {
        assertEq(auth.OKX_SIGNER(), okxSigner);
    }

    /*//////////////////////////////////////////////////////////////
                    FR-3 — CALLER BINDING (happy path)
    //////////////////////////////////////////////////////////////*/

    // FR-3: an OKX-signed authorization whose msg.sender is in allowedCallers passes and
    // consumes the nonce.
    function testVerifyValidAuthConsumesNonce() public {
        address[] memory callers = _pair(dexRouter, dynamicRoute);
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + DEFAULT_EXPIRY_OFFSET;
        bytes memory sig = _signAuth(address(auth), callers, nonce, expiry, okxSignerKey);

        assertFalse(auth.isNonceUsed(nonce));
        vm.prank(dexRouter);
        auth.verify(callers, nonce, expiry, sig);
        assertTrue(auth.isNonceUsed(nonce));
    }

    // FR-3: membership is by exact address; the SECOND entry in the set is also accepted
    // (covers the DynamicRoute route as well as the direct DexRouter route).
    function testVerifyAcceptsSecondAllowedCaller() public {
        address[] memory callers = _pair(dexRouter, dynamicRoute);
        uint256 expiry = block.timestamp + DEFAULT_EXPIRY_OFFSET;
        bytes memory sig = _signAuth(address(auth), callers, 2, expiry, okxSignerKey);

        vm.prank(dynamicRoute);
        auth.verify(callers, 2, expiry, sig);
        assertTrue(auth.isNonceUsed(2));
    }

    /*//////////////////////////////////////////////////////////////
                    FR-3 — CALLER BINDING (revert paths)
    //////////////////////////////////////////////////////////////*/

    // FR-3: msg.sender not in the signed allowedCallers set → OSA_UntrustedCaller.
    function testVerifyRejectsUntrustedCaller() public {
        address[] memory callers = _single(dexRouter);
        uint256 expiry = block.timestamp + DEFAULT_EXPIRY_OFFSET;
        bytes memory sig = _signAuth(address(auth), callers, 3, expiry, okxSignerKey);

        vm.prank(attacker);
        vm.expectRevert(CallerAuth.OSA_UntrustedCaller.selector);
        auth.verify(callers, 3, expiry, sig);
    }

    // FR-3 anti-replay: reusing a consumed nonce → OSA_NonceUsed.
    function testVerifyRejectsReusedNonce() public {
        address[] memory callers = _single(dexRouter);
        uint256 expiry = block.timestamp + DEFAULT_EXPIRY_OFFSET;
        bytes memory sig = _signAuth(address(auth), callers, 4, expiry, okxSignerKey);

        vm.prank(dexRouter);
        auth.verify(callers, 4, expiry, sig);

        // Re-sign the identical preimage (same nonce) — signature is valid, but the nonce
        // bitmap already has the bit set.
        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.OSA_NonceUsed.selector);
        auth.verify(callers, 4, expiry, sig);
    }

    // FR-3: expired authorization → OSA_Expired.
    function testVerifyRejectsExpired() public {
        address[] memory callers = _single(dexRouter);
        uint256 expiry = block.timestamp - 1; // already elapsed
        bytes memory sig = _signAuth(address(auth), callers, 5, expiry, okxSignerKey);

        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.OSA_Expired.selector);
        auth.verify(callers, 5, expiry, sig);
    }

    // FR-3: signature length other than the EIP-2098 compact 64 bytes → OSA_BadSigLen.
    function testVerifyRejectsBadSigLen() public {
        address[] memory callers = _single(dexRouter);
        uint256 expiry = block.timestamp + DEFAULT_EXPIRY_OFFSET;
        // 65-byte (r,s,v) legacy signature is not accepted — base is compact-only.
        bytes memory sig65 = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));
        assertEq(sig65.length, 65);

        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.OSA_BadSigLen.selector);
        auth.verify(callers, 6, expiry, sig65);
    }

    // FR-3: valid-length signature but signed by a key other than OKX_SIGNER → recovered
    // signer != OKX_SIGNER → OSA_BadOkxSig.
    function testVerifyRejectsWrongSigner() public {
        (, uint256 wrongKey) = makeAddrAndKey("notOkxSigner");
        address[] memory callers = _single(dexRouter);
        uint256 expiry = block.timestamp + DEFAULT_EXPIRY_OFFSET;
        bytes memory sig = _signAuth(address(auth), callers, 7, expiry, wrongKey);

        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.OSA_BadOkxSig.selector);
        auth.verify(callers, 7, expiry, sig);
    }

    // FR-3: a malformed signature whose `s` is in the upper half order makes ECDSA.recover
    // fail closed to address(0) → OSA_BadOkxSig (the `signer == address(0)` branch).
    function testVerifyRejectsMalformedSignatureRecoverZero() public {
        address[] memory callers = _single(dexRouter);
        uint256 expiry = block.timestamp + DEFAULT_EXPIRY_OFFSET;
        // vs with all low-255 bits set → s == _COMPACT_S_MASK, far above the s-boundary,
        // so recover() takes the `signer stays 0` path.
        bytes32 r = bytes32(uint256(1));
        bytes32 vs = bytes32(uint256((1 << 255) - 1));
        bytes memory sig = abi.encodePacked(r, vs);
        assertEq(sig.length, 64);

        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.OSA_BadOkxSig.selector);
        auth.verify(callers, 8, expiry, sig);
    }

    // FR-3: a signature bound to a DIFFERENT verifyingContract does not verify against this
    // instance (cross-contract replay protection — digest binds address(this)).
    function testVerifyRejectsCrossContractReplay() public {
        address[] memory callers = _single(dexRouter);
        uint256 expiry = block.timestamp + DEFAULT_EXPIRY_OFFSET;
        // Sign for some OTHER contract address, then present to `auth`.
        bytes memory sig = _signAuth(address(0xDEAD), callers, 9, expiry, okxSignerKey);

        vm.prank(dexRouter);
        vm.expectRevert(CallerAuth.OSA_BadOkxSig.selector);
        auth.verify(callers, 9, expiry, sig);
    }

    /*//////////////////////////////////////////////////////////////
        FR-5 mechanism — _extractDexRouterCaller EXACT marker match
    //////////////////////////////////////////////////////////////*/

    // A valid DexRouter marker word at -64 → returns the embedded address.
    function testExtractValidMarkerReturnsAddress() public {
        address got = _extractWith(_markCaller(dexUser));
        assertEq(got, dexUser);
    }

    // Missing marker (plain address word, no marker bits) → fail-closed to address(0).
    function testExtractMissingMarkerReturnsZero() public {
        uint256 word = uint256(uint160(dexUser)); // no marker in high bytes
        assertEq(_extractWith(word), address(0));
    }

    // Forged marker: high 48 bits all set (an attacker maximising the masked bits) does NOT
    // equal DEX_ROUTER_CALLER_MARKER under the exact-match test → fail-closed to address(0).
    function testExtractForgedFullBitsMarkerReturnsZero() public {
        uint256 word = MARKER_MASK | uint256(uint160(attacker));
        assertEq(_extractWith(word), address(0));
    }

    // The ORIGIN_PAYER marker (`...ccc...`, used for the -32 refund word) must NOT be accepted
    // as a dexRouterCaller marker (`...ddd...`) — proves the two trailing words never collide.
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
