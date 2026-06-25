// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/PmmAdaptor.sol";
import "./mocks/MockERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/*//////////////////////////////////////////////////////////////
                            TEST HARNESS
//////////////////////////////////////////////////////////////*/

/// @dev Exposes the internal `_call` overloads so the maker-balance recheck logic
/// is observable at assertion level without driving the full sellBase/sellQuote path.
contract PMMAdapterHarness is PMMAdapter {
    /// 4-arg path (V2/V3) — caller controls the MakerBalanceCheck directly.
    function exposedCall4(
        address target,
        bytes memory data,
        uint256 rfqId,
        bool enabled,
        address makerAsset,
        address maker,
        uint256 makerAmount,
        uint256 confidenceT,
        uint256 confidenceWeight,
        uint256 confidenceCap
    ) external {
        _call(
            target,
            data,
            rfqId,
            MakerBalanceCheck(enabled, makerAsset, maker, makerAmount, confidenceT, confidenceWeight, confidenceCap)
        );
    }

    /// Legacy 3-arg path (V1 / non-Permit2 / partial-fill) — recheck disabled.
    function exposedCall3(address target, bytes memory data, uint256 rfqId) external {
        _call(target, data, rfqId);
    }
}

/*//////////////////////////////////////////////////////////////
                                MOCKS
//////////////////////////////////////////////////////////////*/

/// @dev A target whose calls revert with arbitrary, test-configured returndata,
/// so we can exercise every revert-selector branch of `_call` independent of the
/// real PmmProtocol. With `setSucceed()` it returns normally (success path).
contract MockRevertingPool {
    bytes private _revertData;
    bool private _succeed;

    function setRevertData(bytes memory d) external {
        _revertData = d;
        _succeed = false;
    }

    function setSucceed() external {
        _succeed = true;
    }

    fallback() external payable {
        if (_succeed) {
            return;
        }
        bytes memory d = _revertData;
        assembly {
            revert(add(d, 0x20), mload(d))
        }
    }

    receive() external payable {}
}

/// @dev ERC20 stub whose `balanceOf` can return a configured value, revert, or
/// return fewer than 32 bytes — to test `_safeBalanceOf` safe-degrade behaviour.
contract MockBalanceToken {
    uint8 internal constant MODE_NORMAL = 0;
    uint8 internal constant MODE_REVERT = 1;
    uint8 internal constant MODE_SHORT = 2;

    mapping(address => uint256) private _bal;
    uint8 private _mode;

    function setBalance(address account, uint256 value) external {
        _bal[account] = value;
    }

    function setRevertMode() external {
        _mode = MODE_REVERT;
    }

    function setShortReturnMode() external {
        _mode = MODE_SHORT;
    }

    function balanceOf(address account) external view returns (uint256) {
        if (_mode == MODE_REVERT) {
            revert("balanceOf: forced revert");
        }
        if (_mode == MODE_SHORT) {
            // Return only 16 bytes (< 32) so _safeBalanceOf degrades to ok=false.
            assembly {
                return(0, 16)
            }
        }
        return _bal[account];
    }
}

/*//////////////////////////////////////////////////////////////
                                TESTS
//////////////////////////////////////////////////////////////*/

contract PmmAdaptorTest is Test {
    PMMAdapterHarness internal harness;
    PMMAdapter internal adapter; // for end-to-end sellBase enable-flag tests
    MockRevertingPool internal pool;
    MockBalanceToken internal makerToken;
    MockERC20 internal takerToken;

    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");

    uint256 internal constant RFQ_ID = 7;
    uint256 internal constant MAKER_AMOUNT = 100 ether;
    uint256 internal constant TAKER_AMOUNT = 200 ether;

    // Dummy calldata forwarded to the mock pool (its fallback ignores the payload).
    bytes internal constant DUMMY_DATA = hex"aabbccdd";

    // Known PmmProtocol revert selectors (must keep their existing mapping).
    bytes4 internal constant SEL_SAFE_TRANSFER_FROM_FAILED = 0xf4059071; // SafeTransferFromFailed()
    bytes4 internal constant SEL_BAD_SIGNATURE = 0x87a26f41; // RFQ_BadSignature(uint256)
    bytes4 internal constant SEL_UNKNOWN = 0xdeadbeef; // not mapped → fallback branch

    function setUp() public {
        harness = new PMMAdapterHarness();
        adapter = new PMMAdapter();
        pool = new MockRevertingPool();
        makerToken = new MockBalanceToken();
        takerToken = new MockERC20("TakerToken", "TAKER", 18);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _expectRevertString(string memory message) internal {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", message));
    }

    function _stringError(string memory message) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", message);
    }

    function _safeTransferFromFailedMsg() internal pure returns (string memory) {
        return string(abi.encodePacked("RFQ_SafeTransferFromFailed ", Strings.toString(RFQ_ID)));
    }

    function _rfqFailedMsg() internal pure returns (string memory) {
        return string(abi.encodePacked("RFQ_Failed ", Strings.toString(RFQ_ID)));
    }

    /*//////////////////////////////////////////////////////////////
            FR-1  Permit2 full-fill maker-balance attribution
    //////////////////////////////////////////////////////////////*/

    // FR-1-AC-1: Permit2 full-fill, balance < makerAmount, underlying revert falls to
    // the fallback branch → attribute to RFQ_SafeTransferFromFailed.
    function testFR1_AC1_Permit2FullFillInsufficientBalanceAttributesSafeTransferFromFailed() public {
        makerToken.setBalance(maker, MAKER_AMOUNT - 1); // strictly below
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_safeTransferFromFailedMsg());
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, true, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    // FR-1-AC-2: Permit2 full-fill, balance >= makerAmount → must NOT be reattributed;
    // stays RFQ_Failed. Includes the strict-boundary case balance == makerAmount.
    function testFR1_AC2_BalanceEqualToMakerAmountStaysRfqFailed() public {
        makerToken.setBalance(maker, MAKER_AMOUNT); // balance == makerAmount (strict < is false)
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_rfqFailedMsg());
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, true, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    function testFR1_AC2_BalanceAboveMakerAmountStaysRfqFailed() public {
        makerToken.setBalance(maker, MAKER_AMOUNT + 1 ether);
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_rfqFailedMsg());
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, true, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    // FR-1-AC-3: attribution must not depend on the revert encoding. The same
    // insufficient-balance outcome is reached whether the underlying revert is the
    // Error(string) "ERC20: transfer amount exceeds balance" or an unknown selector.
    function testFR1_AC3_StringRevertInsufficientBalanceAttributesSafeTransferFromFailed() public {
        makerToken.setBalance(maker, MAKER_AMOUNT - 1);
        pool.setRevertData(_stringError("ERC20: transfer amount exceeds balance"));

        _expectRevertString(_safeTransferFromFailedMsg());
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, true, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    function testFR1_AC3_UnknownSelectorInsufficientBalanceAttributesSafeTransferFromFailed() public {
        makerToken.setBalance(maker, MAKER_AMOUNT - 1);
        pool.setRevertData(abi.encodePacked(bytes4(0x12345678))); // arbitrary unknown selector

        _expectRevertString(_safeTransferFromFailedMsg());
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, true, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    /*//////////////////////////////////////////////////////////////
            FR-2  V3 confidence (time-slippage) adjusted threshold
    //////////////////////////////////////////////////////////////*/
    // Scenario shared by FR-2 cases: confidenceT in the past, weight*timeDiff hits the
    // 5% cap (50000 ppm) → adjusted makerAmount = 100e18 * (1 - 0.05) = 95e18.

    uint256 internal constant CONF_TIME_DIFF = 10;
    uint256 internal constant CONF_WEIGHT = 5000; // 10 * 5000 = 50000 == cap
    uint256 internal constant CONF_CAP = 50000; // == _CONFIDENCE_CAP_LIMIT
    uint256 internal constant ADJUSTED_MAKER_AMOUNT = 95 ether;
    uint256 internal constant NOW_TS = 1_000_000;

    function _warpAndConfidenceT() internal returns (uint256 confidenceT) {
        vm.warp(NOW_TS);
        confidenceT = NOW_TS - CONF_TIME_DIFF;
    }

    // FR-2-AC-1: V3, block.timestamp > confidenceT, balance < adjusted makerAmount
    // → RFQ_SafeTransferFromFailed.
    function testFR2_AC1_V3BalanceBelowAdjustedAttributesSafeTransferFromFailed() public {
        uint256 confidenceT = _warpAndConfidenceT();
        makerToken.setBalance(maker, ADJUSTED_MAKER_AMOUNT - 1 ether); // 94e18 < 95e18
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_safeTransferFromFailedMsg());
        harness.exposedCall4(
            address(pool),
            DUMMY_DATA,
            RFQ_ID,
            true,
            address(makerToken),
            maker,
            MAKER_AMOUNT,
            confidenceT,
            CONF_WEIGHT,
            CONF_CAP
        );
    }

    // FR-2-AC-3: V3, adjusted <= balance < full makerAmount → RFQ_Failed (the protocol
    // would actually only transfer the adjusted amount, which the maker can cover, so the
    // failure is unrelated to balance and must not be misreported).
    function testFR2_AC3_V3BalanceAtOrAboveAdjustedStaysRfqFailed() public {
        uint256 confidenceT = _warpAndConfidenceT();
        makerToken.setBalance(maker, ADJUSTED_MAKER_AMOUNT + 1 ether); // 96e18 (>=95, <100)
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_rfqFailedMsg());
        harness.exposedCall4(
            address(pool),
            DUMMY_DATA,
            RFQ_ID,
            true,
            address(makerToken),
            maker,
            MAKER_AMOUNT,
            confidenceT,
            CONF_WEIGHT,
            CONF_CAP
        );
    }

    // FR-2-AC-3 boundary: balance exactly == adjusted threshold → strict `<` is false → RFQ_Failed.
    function testFR2_AC3_V3BalanceExactlyAdjustedStaysRfqFailed() public {
        uint256 confidenceT = _warpAndConfidenceT();
        makerToken.setBalance(maker, ADJUSTED_MAKER_AMOUNT); // 95e18 == adjusted
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_rfqFailedMsg());
        harness.exposedCall4(
            address(pool),
            DUMMY_DATA,
            RFQ_ID,
            true,
            address(makerToken),
            maker,
            MAKER_AMOUNT,
            confidenceT,
            CONF_WEIGHT,
            CONF_CAP
        );
    }

    // FR-2-AC-4: V2 has no confidence fields (passed as 0) → threshold is the full
    // order makerAmount. A balance that would be "covered" under V3 slippage (96e18 >= 95e18)
    // is still insufficient for V2 (96e18 < 100e18) → RFQ_SafeTransferFromFailed.
    function testFR2_AC4_V2ThresholdIsFullMakerAmount() public {
        makerToken.setBalance(maker, ADJUSTED_MAKER_AMOUNT + 1 ether); // 96e18 < 100e18
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_safeTransferFromFailedMsg());
        harness.exposedCall4(
            address(pool),
            DUMMY_DATA,
            RFQ_ID,
            true,
            address(makerToken),
            maker,
            MAKER_AMOUNT,
            0, // confidenceT = 0 → slippage disabled
            0,
            0
        );
    }

    // FR-2 (no slippage before confidenceT): block.timestamp <= confidenceT → no reduction,
    // threshold stays full makerAmount.
    function testFR2_NoSlippageBeforeConfidenceTUsesFullMakerAmount() public {
        vm.warp(NOW_TS);
        uint256 confidenceT = NOW_TS + 1 hours; // still in the future
        makerToken.setBalance(maker, MAKER_AMOUNT - 1 ether); // 99e18 < 100e18
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_safeTransferFromFailedMsg());
        harness.exposedCall4(
            address(pool),
            DUMMY_DATA,
            RFQ_ID,
            true,
            address(makerToken),
            maker,
            MAKER_AMOUNT,
            confidenceT,
            CONF_WEIGHT,
            CONF_CAP
        );
    }

    // FR-2 (cap guard): confidenceCap > _CONFIDENCE_CAP_LIMIT (50000) → helper leaves
    // makerAmount unchanged (mirrors PmmProtocol rejecting it), so threshold = full amount.
    function testFR2_ConfidenceCapAboveLimitFallsBackToFullMakerAmount() public {
        uint256 confidenceT = _warpAndConfidenceT();
        makerToken.setBalance(maker, MAKER_AMOUNT - 1 ether); // 99e18 < 100e18
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_safeTransferFromFailedMsg());
        harness.exposedCall4(
            address(pool),
            DUMMY_DATA,
            RFQ_ID,
            true,
            address(makerToken),
            maker,
            MAKER_AMOUNT,
            confidenceT,
            CONF_WEIGHT,
            CONF_CAP + 1 // 50001 > limit → no reduction applied
        );
    }

    /*//////////////////////////////////////////////////////////////
            FR-3  Backward compatibility & safe degrade
    //////////////////////////////////////////////////////////////*/

    // FR-3-AC-2: legacy 3-arg path (V1 / non-Permit2 / partial-fill) never enables the
    // recheck → even with zero maker balance the result is the unchanged RFQ_Failed.
    function testFR3_AC2_LegacyCallNeverReattributes() public {
        makerToken.setBalance(maker, 0);
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_rfqFailedMsg());
        harness.exposedCall3(address(pool), DUMMY_DATA, RFQ_ID);
    }

    // FR-3-AC-2: 4-arg path with enabled=false behaves identically to legacy.
    function testFR3_AC2_DisabledCheckNeverReattributes() public {
        makerToken.setBalance(maker, 0);
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_rfqFailedMsg());
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, false, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    // FR-3-AC: staticcall(balanceOf) reverts → _safeBalanceOf returns ok=false → safe
    // degrade to RFQ_Failed (no attribution, no propagation of the balanceOf revert).
    function testFR3_AC_BalanceOfRevertSafeDegradesToRfqFailed() public {
        makerToken.setRevertMode();
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_rfqFailedMsg());
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, true, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    // FR-3-AC: balanceOf returns < 32 bytes → ok=false → safe degrade to RFQ_Failed.
    function testFR3_AC_BalanceOfShortReturnSafeDegradesToRfqFailed() public {
        makerToken.setShortReturnMode();
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        _expectRevertString(_rfqFailedMsg());
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, true, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    /*//////////////////////////////////////////////////////////////
       FR-3  Existing error-code semantics MUST stay unchanged
    //////////////////////////////////////////////////////////////*/

    // Even with the recheck enabled and an insufficient balance, a *known* revert
    // selector must map to its existing error string — the recheck only runs in the
    // unknown-selector fallback branch.
    function testKnownSafeTransferFromFailedSelectorUnchangedWhenEnabled() public {
        makerToken.setBalance(maker, 0);
        pool.setRevertData(abi.encodePacked(SEL_SAFE_TRANSFER_FROM_FAILED));

        _expectRevertString(_safeTransferFromFailedMsg());
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, true, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    function testKnownBadSignatureSelectorNotReattributedWhenEnabled() public {
        makerToken.setBalance(maker, 0); // insufficient, but must NOT change a known error
        pool.setRevertData(abi.encodePacked(SEL_BAD_SIGNATURE));

        _expectRevertString(string(abi.encodePacked("RFQ_BadSignature ", Strings.toString(RFQ_ID))));
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, true, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    // Revert payload shorter than 4 bytes → unchanged "RFQ: Unknown error <id>".
    function testShortRevertDataMapsToUnknownError() public {
        makerToken.setBalance(maker, 0);
        pool.setRevertData(hex"0102"); // < 4 bytes

        _expectRevertString(string(abi.encodePacked("RFQ: Unknown error ", Strings.toString(RFQ_ID))));
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, true, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    // Success path: when the underlying call succeeds, `_call` returns without reverting,
    // regardless of the (enabled) balance check — success semantics unchanged.
    function testSuccessPathDoesNotRevertWithEnabledCheck() public {
        makerToken.setBalance(maker, 0);
        pool.setSucceed();

        // No expectRevert — this must simply not revert.
        harness.exposedCall4(
            address(pool), DUMMY_DATA, RFQ_ID, true, address(makerToken), maker, MAKER_AMOUNT, 0, 0, 0
        );
    }

    /*//////////////////////////////////////////////////////////////
       FR-3-AC-2 (end-to-end): enable-flag construction in _executeV*Order
    //////////////////////////////////////////////////////////////*/

    function _buildV3Order(bool usePermit2, bool withPermit2Sig)
        internal
        view
        returns (IPMMProtocolV3.OrderRFQ memory order)
    {
        order = IPMMProtocolV3.OrderRFQ({
            rfqId: RFQ_ID,
            expiry: block.timestamp + 1 hours,
            makerAsset: address(makerToken),
            takerAsset: address(takerToken),
            makerAddress: maker,
            makerAmount: MAKER_AMOUNT,
            takerAmount: TAKER_AMOUNT,
            usePermit2: usePermit2,
            confidenceT: 0,
            confidenceWeight: 0,
            confidenceCap: 0,
            permit2Signature: withPermit2Sig ? bytes(hex"01") : bytes(""),
            permit2Witness: bytes32(0),
            permit2WitnessType: ""
        });
    }

    function _moreInfoV3(IPMMProtocolV3.OrderRFQ memory order) internal pure returns (bytes memory) {
        return abi.encode(abi.encode(order), bytes(hex"02"), uint256(0), uint256(3));
    }

    // V3 Permit2 full-fill (adapter holds the full takerAmount) → recheck ENABLED.
    // Insufficient maker balance + unknown revert → RFQ_SafeTransferFromFailed.
    function testE2E_V3Permit2FullFillEnablesRecheck() public {
        takerToken.mint(address(adapter), TAKER_AMOUNT); // full-fill
        makerToken.setBalance(maker, MAKER_AMOUNT - 1);
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        IPMMProtocolV3.OrderRFQ memory order = _buildV3Order(true, true);
        _expectRevertString(_safeTransferFromFailedMsg());
        adapter.sellBase(taker, address(pool), _moreInfoV3(order));
    }

    // V3 Permit2 partial-fill (adapter holds < takerAmount) → fullFill=false → recheck DISABLED.
    function testE2E_V3Permit2PartialFillDisablesRecheck() public {
        takerToken.mint(address(adapter), TAKER_AMOUNT / 2); // partial-fill
        makerToken.setBalance(maker, 0);
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        IPMMProtocolV3.OrderRFQ memory order = _buildV3Order(true, true);
        _expectRevertString(_rfqFailedMsg());
        adapter.sellBase(taker, address(pool), _moreInfoV3(order));
    }

    // V3 non-Permit2 full-fill → usePermit2=false → recheck DISABLED.
    function testE2E_V3NonPermit2DisablesRecheck() public {
        takerToken.mint(address(adapter), TAKER_AMOUNT);
        makerToken.setBalance(maker, 0);
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        IPMMProtocolV3.OrderRFQ memory order = _buildV3Order(false, false);
        _expectRevertString(_rfqFailedMsg());
        adapter.sellBase(taker, address(pool), _moreInfoV3(order));
    }

    // V3 Permit2 full-fill but EMPTY permit2Signature → recheck DISABLED (allowance path).
    function testE2E_V3Permit2EmptySignatureDisablesRecheck() public {
        takerToken.mint(address(adapter), TAKER_AMOUNT);
        makerToken.setBalance(maker, 0);
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        IPMMProtocolV3.OrderRFQ memory order = _buildV3Order(true, false);
        _expectRevertString(_rfqFailedMsg());
        adapter.sellBase(taker, address(pool), _moreInfoV3(order));
    }

    // V1 order → legacy 3-arg `_call` path → recheck never enabled.
    function testE2E_V1OrderUsesLegacyPathNoRecheck() public {
        takerToken.mint(address(adapter), TAKER_AMOUNT);
        makerToken.setBalance(maker, 0);
        pool.setRevertData(abi.encodePacked(SEL_UNKNOWN));

        IPMMProtocolV1.OrderRFQ memory order = IPMMProtocolV1.OrderRFQ({
            rfqId: RFQ_ID,
            expiry: block.timestamp + 1 hours,
            makerAsset: address(makerToken),
            takerAsset: address(takerToken),
            makerAddress: maker,
            makerAmount: MAKER_AMOUNT,
            takerAmount: TAKER_AMOUNT,
            usePermit2: true
        });
        bytes memory moreInfo = abi.encode(abi.encode(order), bytes(hex"02"), uint256(0), uint256(1));

        _expectRevertString(_rfqFailedMsg());
        adapter.sellBase(taker, address(pool), moreInfo);
    }
}
