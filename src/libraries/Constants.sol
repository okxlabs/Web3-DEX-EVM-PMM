// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Shared calldata-marker constants for the PMM anti-toxic-flow caller binding.
///      Trailing-word calldata layout injected by DexRouter: `... , dexRouterCaller[-64] , refundTo[-32]`.
///      These values are canonical and shared byte-for-byte with the Web3-DEX-EVM repo
///      (see cross-repo-sync). `DEX_ROUTER_CALLER_MARKER` / `ORIGIN_PAYER` differ only in the
///      3rd marker byte (`ddd` vs `ccc`) so the two trailing words never collide.
///
///      Declared as file-level constants (not a library) so they are usable directly by name
///      inside inline assembly (e.g. CallerAuth._extractDexRouterCaller).

/// @dev Marker stamped in the high 6 bytes of the calldata word at offset -64 that identifies
///      the outermost address directly calling DexRouter (dexRouterCaller).
uint256 constant DEX_ROUTER_CALLER_MARKER =
    0x3ca20afc2ddd0000000000000000000000000000000000000000000000000000;

/// @dev Mask selecting the marker (high 6 bytes) for exact-match validation.
uint256 constant MARKER_MASK =
    0xffffffffffff0000000000000000000000000000000000000000000000000000;

/// @dev Legacy marker for the refund payer-origin word at calldata offset -32.
uint256 constant ORIGIN_PAYER =
    0x3ca20afc2ccc0000000000000000000000000000000000000000000000000000;

/// @dev Mask selecting the low 20 bytes (an address) of a marked calldata word.
uint256 constant _ADDRESS_MASK =
    0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;
