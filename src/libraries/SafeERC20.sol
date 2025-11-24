// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IERC20.sol";
import "../interfaces/IERC20Permit.sol";
import "../interfaces/IDaiLikePermit.sol";
import "../interfaces/IPermit2.sol";
import "../libraries/RevertReasonForwarder.sol";

/// @title Implements efficient safe methods for ERC20 interface.
library SafeERC20 {
    error SafeTransferFailed();
    error SafeTransferFromFailed();
    error ForceApproveFailed();
    error SafeIncreaseAllowanceFailed();
    error SafeDecreaseAllowanceFailed();
    error SafePermitBadLength();
    error Permit2TransferAmountTooHigh();

    address public constant _PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /**
     * @notice Attempts to safely transfer tokens from one address to another using the Permit2 standard.
     * @dev Either requires `true` in return data, or requires target to be smart-contract and empty return data.
     * Note that the implementation does not perform dirty bits cleaning, so it is the responsibility of
     * the caller to make sure that the higher 96 bits of the `from` and `to` parameters are clean.
     * @param token The IERC20 token contract from which the tokens will be transferred.
     * @param from The address from which the tokens will be transferred.
     * @param to The address to which the tokens will be transferred.
     * @param amount The amount of tokens to transfer.
     */

    function safeTransferFromPermit2(IERC20 token, address from, address to, uint256 amount) internal {
        if (amount > type(uint160).max) revert Permit2TransferAmountTooHigh();
        bytes4 selector = IPermit2.transferFrom.selector;
        bool success;
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
            let data := mload(0x40)

            mstore(data, selector)
            mstore(add(data, 0x04), from)
            mstore(add(data, 0x24), to)
            mstore(add(data, 0x44), amount)
            mstore(add(data, 0x64), token)
            success := call(gas(), _PERMIT2, 0, data, 0x84, 0x0, 0x0)
            if success { success := gt(extcodesize(_PERMIT2), 0) }
        }
        if (!success) revert SafeTransferFromFailed();
    }

    // Ensures method do not revert or return boolean `true`, admits call to non-smart-contract
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        bytes4 selector = token.transferFrom.selector;
        bool success;
        /// @solidity memory-safe-assembly
        assembly {
            // solhint-disable-line no-inline-assembly
            let data := mload(0x40)

            mstore(data, selector)
            mstore(add(data, 0x04), from)
            mstore(add(data, 0x24), to)
            mstore(add(data, 0x44), amount)
            success := call(gas(), token, 0, data, 100, 0x0, 0x20)
            if success {
                switch returndatasize()
                case 0 { success := gt(extcodesize(token), 0) }
                default { success := and(gt(returndatasize(), 31), eq(mload(0), 1)) }
            }
        }
        if (!success) revert SafeTransferFromFailed();
    }

    // Ensures method do not revert or return boolean `true`, admits call to non-smart-contract
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        if (!_makeCall(token, token.transfer.selector, to, value)) {
            revert SafeTransferFailed();
        }
    }

    // If `approve(from, to, amount)` fails, try to `approve(from, to, 0)` before retry
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        if (!_makeCall(token, token.approve.selector, spender, value)) {
            if (
                !_makeCall(token, token.approve.selector, spender, 0)
                    || !_makeCall(token, token.approve.selector, spender, value)
            ) {
                revert ForceApproveFailed();
            }
        }
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (value > type(uint256).max - allowance) {
            revert SafeIncreaseAllowanceFailed();
        }
        forceApprove(token, spender, allowance + value);
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (value > allowance) revert SafeDecreaseAllowanceFailed();
        forceApprove(token, spender, allowance - value);
    }

    function safePermit(IERC20 token, bytes calldata permit) internal {
        bool success;
        if (permit.length == 32 * 7) {
            success = _makeCalldataCall(token, IERC20Permit.permit.selector, permit);
        } else if (permit.length == 32 * 8) {
            success = _makeCalldataCall(token, IDaiLikePermit.permit.selector, permit);
        } else {
            revert SafePermitBadLength();
        }
        if (!success) RevertReasonForwarder.reRevert();
    }

    function _makeCall(IERC20 token, bytes4 selector, address to, uint256 amount) private returns (bool success) {
        /// @solidity memory-safe-assembly
        assembly {
            // solhint-disable-line no-inline-assembly
            let data := mload(0x40)

            mstore(data, selector)
            mstore(add(data, 0x04), to)
            mstore(add(data, 0x24), amount)
            success := call(gas(), token, 0, data, 0x44, 0x0, 0x20)
            if success {
                switch returndatasize()
                case 0 { success := gt(extcodesize(token), 0) }
                default { success := and(gt(returndatasize(), 31), eq(mload(0), 1)) }
            }
        }
    }

    function _makeCalldataCall(IERC20 token, bytes4 selector, bytes calldata args) private returns (bool success) {
        /// @solidity memory-safe-assembly
        assembly {
            // solhint-disable-line no-inline-assembly
            let len := add(4, args.length)
            let data := mload(0x40)

            mstore(data, selector)
            calldatacopy(add(data, 0x04), args.offset, args.length)
            success := call(gas(), token, 0, data, len, 0x0, 0x20)
            if success {
                switch returndatasize()
                case 0 { success := gt(extcodesize(token), 0) }
                default { success := and(gt(returndatasize(), 31), eq(mload(0), 1)) }
            }
        }
    }
}
