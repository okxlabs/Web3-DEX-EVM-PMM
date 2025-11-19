// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "./EIP712.sol";
import "./helpers/AmountCalculator.sol";
import "./interfaces/IWETH.sol";
import "./libraries/Errors.sol";
import "./libraries/SafeERC20.sol";
import "./OrderRFQLib.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PMMProtocol is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using OrderRFQLib for OrderRFQLib.OrderRFQ;

    /**
     * @notice Emitted when RFQ gets filled
     * @param rfqId RFQ order id
     * @param expiry Expiration timestamp of the order
     * @param makerAsset Address of the maker asset
     * @param takerAsset Address of the taker asset
     * @param makerAddress Address of the maker
     * @param expectedMakerAmount Expected amount of maker asset
     * @param expectedTakerAmount Expected amount of taker asset
     * @param filledMakerAmount Actual amount of maker asset that was transferred
     * @param filledTakerAmount Actual amount of taker asset that was transferred
     */
    event OrderFilledRFQ(
        uint256 indexed rfqId,
        uint256 expiry,
        address indexed makerAsset,
        address indexed takerAsset,
        address makerAddress,
        uint256 expectedMakerAmount,
        uint256 expectedTakerAmount,
        uint256 filledMakerAmount,
        uint256 filledTakerAmount,
        bool usePermit2
    );

    /**
     * @notice Emitted when RFQ gets cancelled
     *
     * @param rfqId RFQ order id
     *
     * @param maker Maker address
     */
    event OrderCancelledRFQ(uint256 indexed rfqId, address indexed maker);

    string private constant _NAME = "OKX Lab PMM Protocol";
    string private constant _VERSION = "1.0";

    uint256 private constant _RAW_CALL_GAS_LIMIT = 5000;
    uint256 private constant _MAKER_AMOUNT_FLAG = 1 << 255;
    uint256 private constant _SIGNER_SMART_CONTRACT_HINT = 1 << 254;
    uint256 private constant _IS_VALID_SIGNATURE_65_BYTES = 1 << 253;
    uint256 private constant _UNWRAP_WETH_FLAG = 1 << 252;
    uint256 private constant _SETTLE_LIMIT = 6000;
    uint256 private constant _SETTLE_LIMIT_BASE = 10000;

    uint256 private constant _AMOUNT_MASK = 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff; // max uint160

    IWETH private immutable _WETH;
    mapping(address => mapping(uint256 => uint256)) private _invalidator;

    constructor(IWETH weth) EIP712(_NAME, _VERSION) {
        _WETH = weth;
    }

    receive() external payable {
        if (msg.sender != address(_WETH)) {
            revert Errors.RFQ_EthDepositRejected();
        }
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function invalidatorForOrderRFQ(address maker, uint256 slot) external view returns (uint256 /* result */ ) {
        return _invalidator[maker][slot];
    }

    function isRfqIdUsed(address maker, uint64 rfqId) public view returns (bool) {
        uint256 invalidatorSlot = uint64(rfqId) >> 8;
        uint256 invalidatorBits = 1 << (uint8(rfqId) & 0xff);
        uint256 bitMap = _invalidator[maker][invalidatorSlot];
        return (bitMap & invalidatorBits) != 0;
    }

    function fillOrderRFQ(OrderRFQLib.OrderRFQ memory order, bytes calldata signature, uint256 flagsAndAmount)
        external
        payable
        returns (uint256, /* filledMakerAmount */ uint256, /* filledTakerAmount */ bytes32 /* orderHash */ )
    {
        return fillOrderRFQTo(order, signature, flagsAndAmount, msg.sender);
    }

    function fillOrderRFQCompact(OrderRFQLib.OrderRFQ memory order, bytes32 r, bytes32 vs, uint256 flagsAndAmount)
        external
        payable
        nonReentrant
        returns (uint256 filledMakerAmount, uint256 filledTakerAmount, bytes32 orderHash)
    {
        orderHash = order.hash(_domainSeparatorV4());
        if (flagsAndAmount & _SIGNER_SMART_CONTRACT_HINT != 0) {
            if (flagsAndAmount & _IS_VALID_SIGNATURE_65_BYTES != 0) {
                if (!ECDSA.isValidSignature65(order.makerAddress, orderHash, r, vs)) {
                    revert Errors.RFQ_BadSignature(order.rfqId);
                }
            } else {
                if (!ECDSA.isValidSignature(order.makerAddress, orderHash, r, vs)) {
                    revert Errors.RFQ_BadSignature(order.rfqId);
                }
            }
        } else {
            if (!ECDSA.recoverOrIsValidSignature(order.makerAddress, orderHash, r, vs)) {
                revert Errors.RFQ_BadSignature(order.rfqId);
            }
        }

        (filledMakerAmount, filledTakerAmount) = _fillOrderRFQTo(order, flagsAndAmount, msg.sender);
        emit OrderFilledRFQ(
            order.rfqId,
            order.expiry,
            order.makerAsset,
            order.takerAsset,
            order.makerAddress,
            order.makerAmount,
            order.takerAmount,
            filledMakerAmount,
            filledTakerAmount,
            order.usePermit2
        );
    }

    function fillOrderRFQToWithPermit(
        OrderRFQLib.OrderRFQ memory order,
        bytes calldata signature,
        uint256 flagsAndAmount,
        address target,
        bytes calldata permit
    ) external returns (uint256, /* filledMakerAmount */ uint256, /* filledTakerAmount */ bytes32 /* orderHash */ ) {
        IERC20(order.takerAsset).safePermit(permit);
        return fillOrderRFQTo(order, signature, flagsAndAmount, target);
    }
    // Anyone can fill the order, including via front-running.
    // This is acceptable by design and does not cause any loss to the maker.

    // This function does not support deflationary or rebasing tokens.
    // The protocol assumes standard token behavior with exact transfer amounts,
    // which is valid for mainstream tokens typically used by market makers.
    function fillOrderRFQTo(
        OrderRFQLib.OrderRFQ memory order,
        bytes calldata signature,
        uint256 flagsAndAmount,
        address target
    ) public payable nonReentrant returns (uint256 filledMakerAmount, uint256 filledTakerAmount, bytes32 orderHash) {
        orderHash = order.hash(_domainSeparatorV4());
        if (flagsAndAmount & _SIGNER_SMART_CONTRACT_HINT != 0) {
            if (flagsAndAmount & _IS_VALID_SIGNATURE_65_BYTES != 0 && signature.length != 65) {
                revert Errors.RFQ_BadSignature(order.rfqId);
            }
            if (!ECDSA.isValidSignature(order.makerAddress, orderHash, signature)) {
                revert Errors.RFQ_BadSignature(order.rfqId);
            }
        } else {
            if (!ECDSA.recoverOrIsValidSignature(order.makerAddress, orderHash, signature)) {
                revert Errors.RFQ_BadSignature(order.rfqId);
            }
        }
        (filledMakerAmount, filledTakerAmount) = _fillOrderRFQTo(order, flagsAndAmount, target);
        emit OrderFilledRFQ(
            order.rfqId,
            order.expiry,
            order.makerAsset,
            order.takerAsset,
            order.makerAddress,
            order.makerAmount,
            order.takerAmount,
            filledMakerAmount,
            filledTakerAmount,
            order.usePermit2
        );
    }

    function _fillOrderRFQTo(OrderRFQLib.OrderRFQ memory order, uint256 flagsAndAmount, address target)
        private
        returns (uint256 makerAmount, uint256 takerAmount)
    {
        if (target == address(0)) {
            revert Errors.RFQ_ZeroTargetIsForbidden(order.rfqId);
        }

        address maker = order.makerAddress;

        {
            // Stack too deep
            // Check time expiration
            uint256 expiration = order.expiry;
            if (expiration != 0 && block.timestamp > expiration) {
                revert Errors.RFQ_OrderExpired(order.rfqId);
            } // solhint-disable-line not-rely-on-time
            _invalidateOrder(maker, order.rfqId, 0);
        }
        // user: AMM->PMM
        {
            // Stack too deep
            uint256 orderMakerAmount = order.makerAmount;
            uint256 orderTakerAmount = order.takerAmount;
            uint256 amount = flagsAndAmount & _AMOUNT_MASK;
            // Compute partial fill if needed
            if (amount == 0) {
                // zero amount means whole order
                // Check if order amounts exceed uint160.max limit for Permit2 transfers
                makerAmount = orderMakerAmount;
                takerAmount = orderTakerAmount;
                if (order.usePermit2 && makerAmount > type(uint160).max) {
                    revert Errors.RFQ_AmountTooLarge(order.rfqId);
                }
            } else if (flagsAndAmount & _MAKER_AMOUNT_FLAG != 0) {
                if (amount > orderMakerAmount) {
                    revert Errors.RFQ_MakerAmountExceeded(order.rfqId);
                }
                makerAmount = amount;
                takerAmount = AmountCalculator.getTakerAmount(orderMakerAmount, orderTakerAmount, makerAmount);
            } else {
                if (amount > orderTakerAmount) {
                    revert Errors.RFQ_TakerAmountExceeded(order.rfqId);
                }
                takerAmount = amount;
                makerAmount = AmountCalculator.getMakerAmount(orderMakerAmount, orderTakerAmount, takerAmount);
            }
        }

        if (makerAmount == 0 || takerAmount == 0) {
            revert Errors.RFQ_SwapWithZeroAmount(order.rfqId);
        }

        // Check if settlement amounts meet minimum limit (60%)
        if (
            makerAmount < (order.makerAmount * _SETTLE_LIMIT) / _SETTLE_LIMIT_BASE
                || takerAmount < (order.takerAmount * _SETTLE_LIMIT) / _SETTLE_LIMIT_BASE
        ) {
            revert Errors.RFQ_SettlementAmountTooSmall(order.rfqId);
        }

        bool needUnwrap = order.makerAsset == address(_WETH) && flagsAndAmount & _UNWRAP_WETH_FLAG != 0;

        // Maker => Taker
        address receiver = needUnwrap ? address(this) : target;
        if (order.usePermit2) {
            IERC20(order.makerAsset).safeTransferFromPermit2(maker, receiver, makerAmount);
        } else {
            IERC20(order.makerAsset).safeTransferFrom(maker, receiver, makerAmount);
        }
        if (needUnwrap) {
            _WETH.withdraw(makerAmount);
            // solhint-disable-next-line avoid-low-level-calls
            (bool success,) = target.call{value: makerAmount, gas: _RAW_CALL_GAS_LIMIT}("");
            if (!success) revert Errors.RFQ_ETHTransferFailed(order.rfqId);
        }

        // Taker => Maker
        if (order.takerAsset == address(_WETH) && msg.value > 0) {
            if (msg.value != takerAmount) {
                revert Errors.RFQ_InvalidMsgValue(order.rfqId);
            }
            _WETH.deposit{value: takerAmount}();
            _WETH.transfer(maker, takerAmount);
        } else {
            if (msg.value != 0) revert Errors.RFQ_InvalidMsgValue(order.rfqId);
            IERC20(order.takerAsset).safeTransferFrom(msg.sender, maker, takerAmount);
        }
    }

    /// @dev Prevents replay of RFQ orders by tracking used rfqIds with a bitmask per maker.

    function _invalidateOrder(address maker, uint256 orderInfo, uint256 additionalMask) private {
        uint256 invalidatorSlot = uint64(orderInfo) >> 8;

        uint256 invalidatorBits = (1 << uint8(orderInfo)) | additionalMask;

        mapping(uint256 => uint256) storage invalidatorStorage = _invalidator[maker];

        uint256 invalidator = invalidatorStorage[invalidatorSlot];

        if (invalidator & invalidatorBits == invalidatorBits) {
            revert Errors.RFQ_InvalidatedOrder(orderInfo);
        }

        invalidatorStorage[invalidatorSlot] = invalidator | invalidatorBits;
    }

    function cancelOrderRFQ(uint64 rfqId) external {
        address maker = msg.sender;

        if (isRfqIdUsed(maker, rfqId)) {
            revert Errors.RFQ_OrderAlreadyCancelledOrUsed(rfqId);
        }

        _invalidateOrder(maker, rfqId, 0);

        emit OrderCancelledRFQ(rfqId, maker);
    }
}
