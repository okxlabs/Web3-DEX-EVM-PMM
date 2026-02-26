// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../../src/interfaces/IPermit2.sol";
import "../../src/interfaces/IERC20.sol";

/// @notice Lightweight Permit2 mock that skips signature validation but moves tokens like the real contract.
contract MockPermit2 is IPermit2 {
    struct Allowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    mapping(address => mapping(address => mapping(address => Allowance))) private _allowances;

    event AllowanceSet(address indexed owner, address indexed token, address indexed spender, uint160 amount);
    event PermitTransfer(address indexed owner, address indexed token, uint256 amount, address to, bool witnessUsed);
    event AllowanceTransfer(address indexed owner, address indexed token, uint256 amount, address to);

    function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
        return keccak256("MockPermit2");
    }

    function transferFrom(address user, address to, uint160 amount, address token) external override {
        Allowance storage allowance_ = _allowances[user][token][msg.sender];
        if (allowance_.expiration != 0 && block.timestamp > allowance_.expiration) {
            revert("MockPermit2: allowance expired");
        }
        if (allowance_.amount < amount) {
            revert("MockPermit2: insufficient allowance");
        }
        allowance_.amount -= amount;
        IERC20(token).transferFrom(user, to, amount);
        emit AllowanceTransfer(user, token, amount, to);
    }

    function permit(address, PermitSingle memory, bytes calldata) external pure override {
        revert("MockPermit2: unused");
    }

    function permitTransferFrom(
        PermitTransferFrom memory permitData,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata
    ) external override {
        _executePermitTransfer(permitData, transferDetails, owner, bytes32(0), "", false);
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom memory permitData,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata
    ) external override {
        _executePermitTransfer(permitData, transferDetails, owner, witness, witnessTypeString, true);
    }

    function allowance(address user, address token, address spender)
        external
        view
        override
        returns (PackedAllowance memory)
    {
        Allowance memory allowance_ = _allowances[user][token][spender];
        return PackedAllowance({amount: allowance_.amount, expiration: allowance_.expiration, nonce: allowance_.nonce});
    }

    function approve(address token, address spender, uint160 amount, uint48 expiration) external override {
        Allowance storage allowance_ = _allowances[msg.sender][token][spender];
        allowance_.amount = amount;
        allowance_.expiration = expiration;
        emit AllowanceSet(msg.sender, token, spender, amount);
    }

    function _executePermitTransfer(
        PermitTransferFrom memory permitData,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32, /* witness */
        string memory, /* witnessTypeString */
        bool witnessUsed
    ) private {
        if (block.timestamp > permitData.deadline) {
            revert("MockPermit2: permit expired");
        }
        if (transferDetails.requestedAmount > permitData.permitted.amount) {
            revert("MockPermit2: exceeds permit");
        }
        IERC20(permitData.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
        emit PermitTransfer(
            owner, permitData.permitted.token, transferDetails.requestedAmount, transferDetails.to, witnessUsed
        );
    }
}
