// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ECDSA.sol";
import "./Constants.sol";

/// @title CallerAuth — stateless OKX-signed caller-binding base for anti-arbitrage adapters.
///
/// @notice Authorization base that binds a swap to (a) an OKX-signed authorization and (b) the set
///         of on-chain callers allowed to relay it. It exists to close the "address-decoupling"
///         arbitrage: a market maker quotes for a clean address but the swap is settled from a
///         different address that bypasses allowedSender / fee controls.
///
/// @dev Design contract (see A-02 design note §A0):
///        - No owner, no setter, no registry. The signer is fixed at deploy time (immutable).
///        - Append-only per-instance nonce bitmap (Permit2-style wordPos -> bitmap). CEI: the nonce
///          is consumed inside `_verify*` BEFORE the caller performs any external swap/transfer, so a
///          reentrant replay of the same nonce reverts.
///        - Signatures are EIP-2098 64-byte compact only, verified via the repo's ECDSA library
///          (upper-half `s` rejected, recover==0 fails closed). Digest is EIP-191 prefixed.
///        - The digest binds `address(this)` and `block.chainid`, giving cross-contract and
///          cross-chain replay protection.
///      Meant to be inherited by NON-proxy adapters (DynamicRoute / NativePmmAdapterV4). It carries
///      only append-only nonce storage and immutable config, so it introduces no value/routing state.
abstract contract CallerAuth {
    /// @notice OKX authorization signer. Set once at construction, never mutable.
    address public immutable OKX_SIGNER;

    /// @dev Per-instance single-use nonce bitmap: wordPos (nonce >> 8) -> 256-bit word.
    mapping(uint256 => uint256) private _callerAuthNonceBitmap;

    // =========================== Errors ===========================

    error OSA_ZeroSigner();
    error OSA_Expired();
    error OSA_UntrustedCaller();
    error OSA_BadOkxSig();
    error OSA_BadSigLen();
    error OSA_NonceUsed();

    /// @param okxSigner Authorization signer address; zero address is rejected (fail-closed deploy).
    constructor(address okxSigner) {
        if (okxSigner == address(0)) revert OSA_ZeroSigner();
        OKX_SIGNER = okxSigner;
    }

    // =========================== Verification ===========================

    /// @notice Verify a plain caller-binding authorization.
    /// @dev inner = keccak256(abi.encode(address(this), allowedCallers, nonce, expiry, block.chainid)).
    function _verifyCallerAuth(
        address[] memory allowedCallers,
        uint256 nonce,
        uint256 expiry,
        bytes memory okxSig
    ) internal {
        bytes32 inner = keccak256(
            abi.encode(address(this), allowedCallers, nonce, expiry, block.chainid)
        );
        _verifyAuthCommon(inner, allowedCallers, nonce, expiry, okxSig);
    }

    /// @dev Shared verification core. Order mirrors the design note: sig length -> signer -> expiry
    ///      -> caller membership -> nonce consumption (nonce consumed last but still before any
    ///      external call the caller makes after `_verify*` returns, preserving CEI).
    function _verifyAuthCommon(
        bytes32 inner,
        address[] memory allowedCallers,
        uint256 nonce,
        uint256 expiry,
        bytes memory okxSig
    ) internal {
        if (okxSig.length != 64) revert OSA_BadSigLen();

        bytes32 r;
        bytes32 vs;
        /// @solidity memory-safe-assembly
        assembly {
            r := mload(add(okxSig, 0x20))
            vs := mload(add(okxSig, 0x40))
        }

        bytes32 digest = ECDSA.toEthSignedMessageHash(inner);
        address signer = ECDSA.recover(digest, r, vs);
        if (signer == address(0) || signer != OKX_SIGNER) revert OSA_BadOkxSig();

        if (block.timestamp > expiry) revert OSA_Expired();

        if (!_isAllowedCaller(allowedCallers)) revert OSA_UntrustedCaller();

        _useNonce(nonce);
    }

    // =========================== Internal helpers ===========================

    /// @dev msg.sender membership test against the signed allowedCallers set.
    function _isAllowedCaller(address[] memory allowedCallers) private view returns (bool) {
        uint256 len = allowedCallers.length;
        for (uint256 i; i < len; ++i) {
            if (allowedCallers[i] == msg.sender) return true;
        }
        return false;
    }

    /// @dev Consume a single-use nonce (Permit2-style bitmap). Reverts OSA_NonceUsed on reuse.
    ///      Called before the inheriting adapter performs any external call/transfer (CEI).
    function _useNonce(uint256 nonce) private {
        uint256 wordPos = nonce >> 8;
        uint256 bit = 1 << (nonce & 0xff);
        uint256 word = _callerAuthNonceBitmap[wordPos];
        if (word & bit != 0) revert OSA_NonceUsed();
        _callerAuthNonceBitmap[wordPos] = word | bit;
    }

    /// @notice Read whether a nonce has already been consumed (test / off-chain observability).
    function isNonceUsed(uint256 nonce) external view returns (bool) {
        uint256 bit = 1 << (nonce & 0xff);
        return _callerAuthNonceBitmap[nonce >> 8] & bit != 0;
    }

    /// @dev Reads the -64 calldata word injected by CommonLib.exeAdapter and returns the original
    ///      outermost DexRouter caller using EXACT-match marker validation:
    ///      `word & MARKER_MASK == DEX_ROUTER_CALLER_MARKER`. Unlike the legacy ORIGIN_PAYER subset
    ///      match (which treats 0 bits as wildcards), a forged high-48-bit-all-1 word cannot pass, so a
    ///      missing or spoofed marker fails closed to address(0). Shared by every caller-bound adapter
    ///      (DynamicRoute, NativePmmAdapterV4). MARKER_MASK / DEX_ROUTER_CALLER_MARKER / _ADDRESS_MASK
    ///      are the file-level constants from Constants.sol.
    function _extractDexRouterCaller() internal pure returns (address dexRouterCaller) {
        /// @solidity memory-safe-assembly
        assembly {
            let word := calldataload(sub(calldatasize(), 64))
            if eq(and(word, MARKER_MASK), DEX_ROUTER_CALLER_MARKER) {
                dexRouterCaller := and(word, _ADDRESS_MASK)
            }
        }
    }
}
