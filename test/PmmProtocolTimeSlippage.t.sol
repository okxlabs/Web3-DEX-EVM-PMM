// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/PmmProtocol.sol";
import "../src/OrderRFQLib.sol";
import "../src/interfaces/IWETH.sol";
import "../src/interfaces/IPermit2.sol";
import "../src/libraries/Errors.sol";
import "./helpers/TestHelper.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPermit2.sol";
import "./mocks/MockWETH.sol";

contract PmmProtocolTimeSlippageTest is TestHelper {
    PMMProtocol internal pmmProtocol;
    MockERC20 internal makerToken;
    MockERC20 internal takerToken;
    MockWETH internal weth;
    MockPermit2 internal permit2;

    address internal maker;
    address internal taker;

    uint256 internal constant INITIAL_BALANCE = 1_000 ether;
    uint256 internal constant MAKER_AMOUNT = 100 ether;
    uint256 internal constant TAKER_AMOUNT = 200 ether;
    uint256 internal constant ORDER_ID = 100;

    uint256 internal constant MAKER_AMOUNT_FLAG = 1 << 255;

    address internal constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {
        vm.etch(PERMIT2_ADDRESS, type(MockPermit2).runtimeCode);
        permit2 = MockPermit2(PERMIT2_ADDRESS);

        makerToken = new MockERC20("MakerToken", "MAKER", 18);
        takerToken = new MockERC20("TakerToken", "TAKER", 18);
        weth = new MockWETH();
        pmmProtocol = new PMMProtocol(IWETH(address(weth)));

        maker = MAKER_ADDRESS;
        taker = TAKER_ADDRESS;

        makerToken.mint(maker, INITIAL_BALANCE);
        takerToken.mint(taker, INITIAL_BALANCE);

        vm.prank(maker);
        makerToken.approve(address(pmmProtocol), type(uint256).max);

        vm.prank(taker);
        takerToken.approve(address(pmmProtocol), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Helper: create order with confidence parameters
    // ─────────────────────────────────────────────────────────────────

    function _orderWithConfidence(
        uint256 rfqId,
        uint256 expiry,
        uint256 confidenceT,
        uint256 confidenceWeight,
        uint256 confidenceCap
    ) internal view returns (OrderRFQLib.OrderRFQ memory) {
        return OrderRFQLib.OrderRFQ({
            rfqId: rfqId,
            expiry: expiry,
            makerAsset: address(makerToken),
            takerAsset: address(takerToken),
            makerAddress: maker,
            makerAmount: MAKER_AMOUNT,
            takerAmount: TAKER_AMOUNT,
            usePermit2: false,
            confidenceT: confidenceT,
            confidenceWeight: confidenceWeight,
            confidenceCap: confidenceCap,
            permit2Signature: "",
            permit2Witness: bytes32(0),
            permit2WitnessType: ""
        });
    }

    function _sign(OrderRFQLib.OrderRFQ memory order) internal view returns (bytes memory) {
        return signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);
    }

    // ═════════════════════════════════════════════════════════════════
    //  NO SLIPPAGE
    // ═════════════════════════════════════════════════════════════════

    // ─────────────────────────────────────────────────────────────────
    //  1. No slippage before confidenceT
    // ─────────────────────────────────────────────────────────────────

    function testNoSlippageBeforeConfidenceT() public {
        uint256 confidenceT = block.timestamp + 30 minutes;
        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(1, getFutureTimestamp(1 hours), confidenceT, 1000, 100_000);
        bytes memory signature = _sign(order);

        // fill before confidenceT — taker should receive full makerAmount
        vm.prank(taker);
        (uint256 makerFilled, uint256 takerFilled,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerFilled, MAKER_AMOUNT, "makerFilled should equal full makerAmount");
        assertEq(takerFilled, TAKER_AMOUNT, "takerFilled should equal full takerAmount");
    }

    // ─────────────────────────────────────────────────────────────────
    //  2. No slippage exactly at confidenceT
    // ─────────────────────────────────────────────────────────────────

    function testNoSlippageExactlyAtConfidenceT() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(2, getFutureTimestamp(1 hours), confidenceT, 1000, 100_000);
        bytes memory signature = _sign(order);

        // warp to exactly confidenceT — condition is `block.timestamp > confidenceT`, so no slippage
        vm.warp(confidenceT);

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerFilled, MAKER_AMOUNT, "no slippage at exactly confidenceT");
    }

    // ─────────────────────────────────────────────────────────────────
    //  3. No slippage when confidenceT is zero (disabled)
    // ─────────────────────────────────────────────────────────────────

    function testNoSlippageWhenConfidenceTIsZero() public {
        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(3, getFutureTimestamp(1 hours), 0, 1000, 100_000);
        bytes memory signature = _sign(order);

        vm.warp(block.timestamp + 30 minutes);

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerFilled, MAKER_AMOUNT, "no slippage when confidenceT is 0");
    }

    // ─────────────────────────────────────────────────────────────────
    //  4. No slippage when confidenceWeight is zero
    // ─────────────────────────────────────────────────────────────────

    function testNoSlippageWhenWeightIsZero() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(4, getFutureTimestamp(1 hours), confidenceT, 0, 100_000);
        bytes memory signature = _sign(order);

        vm.warp(confidenceT + 10 minutes);

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerFilled, MAKER_AMOUNT, "no slippage when weight is 0");
    }

    // ─────────────────────────────────────────────────────────────────
    //  5. No slippage when confidenceCap is zero
    // ─────────────────────────────────────────────────────────────────

    function testNoSlippageWhenCapIsZero() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(5, getFutureTimestamp(1 hours), confidenceT, 1000, 0);
        bytes memory signature = _sign(order);

        vm.warp(confidenceT + 10 minutes);

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerFilled, MAKER_AMOUNT, "no slippage when cap is 0");
    }

    // ═════════════════════════════════════════════════════════════════
    //  SLIPPAGE
    // ═════════════════════════════════════════════════════════════════

    // ─────────────────────────────────────────────────────────────────
    //  6. Slippage applies after confidenceT
    // ─────────────────────────────────────────────────────────────────

    function testSlippageAppliesAfterConfidenceT() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 1000; // 0.1% per second
        uint256 cap = 100_000; // max 10% reduction

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(6, getFutureTimestamp(1 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp 100 seconds past confidenceT
        uint256 timePastConfidence = 100;
        vm.warp(confidenceT + timePastConfidence);

        // cutdownPercentageX6 = 100 * 1000 = 100_000 (10%)
        // expected makerAmount = 100e18 - 100e18 * 100_000 / 1e6 = 90e18
        uint256 expectedMaker = MAKER_AMOUNT - MAKER_AMOUNT * 100_000 / 1e6;

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerFilled, expectedMaker, "makerFilled should reflect 10% confidence slippage");
    }

    // ─────────────────────────────────────────────────────────────────
    //  7. Slippage increases linearly with time
    // ─────────────────────────────────────────────────────────────────

    function testSlippageIncreasesLinearly() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 500; // 0.05% per second
        uint256 cap = 100_000; // max 10%

        // Test at 100 seconds past: cutdown = 100 * 500 = 50_000 (5%)
        OrderRFQLib.OrderRFQ memory order1 =
            _orderWithConfidence(7, getFutureTimestamp(2 hours), confidenceT, weight, cap);
        bytes memory sig1 = _sign(order1);

        vm.warp(confidenceT + 100);
        vm.prank(taker);
        (uint256 makerFilled1,,) = pmmProtocol.fillOrderRFQ(order1, sig1, 0);

        uint256 expected1 = MAKER_AMOUNT - MAKER_AMOUNT * 50_000 / 1e6; // 95e18
        assertEq(makerFilled1, expected1, "5% slippage at t+100s");

        // Test at 200 seconds past: cutdown = 200 * 500 = 100_000 (10%)
        OrderRFQLib.OrderRFQ memory order2 =
            _orderWithConfidence(8, getFutureTimestamp(2 hours), confidenceT, weight, cap);
        bytes memory sig2 = _sign(order2);

        vm.warp(confidenceT + 200);
        vm.prank(taker);
        (uint256 makerFilled2,,) = pmmProtocol.fillOrderRFQ(order2, sig2, 0);

        uint256 expected2 = MAKER_AMOUNT - MAKER_AMOUNT * 100_000 / 1e6; // 90e18
        assertEq(makerFilled2, expected2, "10% slippage at t+200s");

        // Verify linear relationship: reduction at 200s is exactly 2x reduction at 100s
        uint256 reduction1 = MAKER_AMOUNT - makerFilled1;
        uint256 reduction2 = MAKER_AMOUNT - makerFilled2;
        assertEq(reduction2, reduction1 * 2, "slippage should scale linearly with time");
    }

    // ─────────────────────────────────────────────────────────────────
    //  8. Slippage applied on top of partial fill
    // ─────────────────────────────────────────────────────────────────

    function testSlippageAppliedToPartialFill() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 1000;
        uint256 cap = 100_000; // 10%

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(9, getFutureTimestamp(1 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp 50 seconds past confidenceT: cutdown = 50 * 1000 = 50_000 (5%)
        vm.warp(confidenceT + 50);

        // partial fill: 80% of makerAmount
        uint256 partialMaker = MAKER_AMOUNT * 8 / 10; // 80e18
        uint256 flagsAndAmount = MAKER_AMOUNT_FLAG | partialMaker;

        // confidence applied to the partial amount: 80e18 - 80e18 * 50_000 / 1e6 = 76e18
        uint256 expectedMaker = partialMaker - partialMaker * 50_000 / 1e6;

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);

        assertEq(makerFilled, expectedMaker, "slippage should apply to partial fill amount");
    }

    // ─────────────────────────────────────────────────────────────────
    //  9. takerAmount is NOT affected by confidence
    // ─────────────────────────────────────────────────────────────────

    function testTakerAmountUnaffectedByConfidence() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 1000;
        uint256 cap = 100_000;

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(10, getFutureTimestamp(1 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        vm.warp(confidenceT + 300);

        uint256 takerBalanceBefore = takerToken.balanceOf(taker);

        vm.prank(taker);
        (, uint256 takerFilled,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        // takerAmount should remain unchanged regardless of confidence slippage
        assertEq(takerFilled, TAKER_AMOUNT, "takerAmount must not be reduced by confidence");
        assertEq(
            takerToken.balanceOf(taker),
            takerBalanceBefore - TAKER_AMOUNT,
            "taker should pay full takerAmount"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    //  10. Verify token balances after confidence slippage
    // ─────────────────────────────────────────────────────────────────

    function testBalancesAfterConfidenceSlippage() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 2000; // 0.2% per second
        uint256 cap = 100_000; // max 10%

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(11, getFutureTimestamp(1 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp 50 seconds past: cutdown = 50 * 2000 = 100_000 (10%)
        vm.warp(confidenceT + 50);

        uint256 makerBalBefore = makerToken.balanceOf(maker);
        uint256 takerMakerBalBefore = makerToken.balanceOf(taker);
        uint256 takerBalBefore = takerToken.balanceOf(taker);
        uint256 makerTakerBalBefore = takerToken.balanceOf(maker);

        uint256 expectedMakerFilled = MAKER_AMOUNT - MAKER_AMOUNT * 100_000 / 1e6; // 90e18

        vm.prank(taker);
        pmmProtocol.fillOrderRFQ(order, signature, 0);

        // Maker sent expectedMakerFilled of makerToken
        assertEq(makerToken.balanceOf(maker), makerBalBefore - expectedMakerFilled, "maker makerToken balance");
        // Taker received expectedMakerFilled of makerToken
        assertEq(makerToken.balanceOf(taker), takerMakerBalBefore + expectedMakerFilled, "taker makerToken balance");
        // Taker paid full TAKER_AMOUNT
        assertEq(takerToken.balanceOf(taker), takerBalBefore - TAKER_AMOUNT, "taker takerToken balance");
        // Maker received full TAKER_AMOUNT
        assertEq(takerToken.balanceOf(maker), makerTakerBalBefore + TAKER_AMOUNT, "maker takerToken balance");
    }

    // ═════════════════════════════════════════════════════════════════
    //  WITHIN MAX SLIPPAGE (CAP)
    // ═════════════════════════════════════════════════════════════════

    // ─────────────────────────────────────────────────────────────────
    //  11. Slippage is capped at confidenceCap
    // ─────────────────────────────────────────────────────────────────

    function testSlippageCappedAtConfidenceCap() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 10_000; // 1% per second (aggressive)
        uint256 cap = 100_000; // max 10%

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(12, getFutureTimestamp(2 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp 1000 seconds past: uncapped cutdown = 1000 * 10_000 = 10_000_000 (1000%)
        // but capped at 100_000 (10%)
        vm.warp(confidenceT + 1000);

        uint256 expectedMaker = MAKER_AMOUNT - MAKER_AMOUNT * cap / 1e6; // 90e18

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerFilled, expectedMaker, "slippage should be capped at 10%");
    }

    // ─────────────────────────────────────────────────────────────────
    //  12. Max cap (10%) limits reduction even with aggressive weight
    // ─────────────────────────────────────────────────────────────────

    function testMaxCapLimitsReduction() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 10_000;
        uint256 cap = 100_000; // 10% — max allowed reduction

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(13, getFutureTimestamp(2 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp far enough that uncapped cutdown far exceeds cap
        vm.warp(confidenceT + 200); // 200 * 10_000 = 2_000_000 > cap, capped at 100_000

        // makerAmount = 100e18 - 100e18 * 100_000 / 1e6 = 90e18
        uint256 expectedMaker = MAKER_AMOUNT - MAKER_AMOUNT * cap / 1e6;

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerFilled, expectedMaker, "10% confidence cap should limit reduction to 10%");
    }

    // ─────────────────────────────────────────────────────────────────
    //  13. Settlement limit check passes before confidence reduces amount
    // ─────────────────────────────────────────────────────────────────

    function testSettleLimitPassesBeforeConfidenceReducesAmount() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 10_000; // 1% per second
        uint256 cap = 100_000; // max 10%

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(14, getFutureTimestamp(2 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp far past confidenceT so cap (10%) is reached
        vm.warp(confidenceT + 1000);

        // Full fill: makerAmount = 100e18 passes settle limit (100e18 >= 60e18)
        // After confidence 10%: actual makerFilled = 90e18
        // This succeeds because settle limit is checked BEFORE confidence
        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        uint256 expectedMaker = MAKER_AMOUNT - MAKER_AMOUNT * cap / 1e6; // 90e18
        assertEq(makerFilled, expectedMaker, "settle limit does not block post-confidence amount");
    }

    // ─────────────────────────────────────────────────────────────────
    //  14. Slippage with Permit2 signature + witness transfer
    // ─────────────────────────────────────────────────────────────────

    function testSlippageWithPermit2WitnessTransfer() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 1000; // 0.1% per second
        uint256 cap = 100_000; // max 10%

        // Maker approves makerToken to Permit2 (instead of directly to pmmProtocol)
        vm.prank(maker);
        makerToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        // Build Consideration witness
        bytes32 CONSIDERATION_TYPEHASH =
            keccak256("Consideration(address token,uint256 amount,address counterparty)");
        string memory WITNESS_TYPE_STRING =
            "Consideration witness)Consideration(address token,uint256 amount,address counterparty)TokenPermissions(address token,uint256 amount)";

        // Create order with usePermit2 = true and confidence params
        OrderRFQLib.OrderRFQ memory order = OrderRFQLib.OrderRFQ({
            rfqId: 15,
            expiry: getFutureTimestamp(2 hours),
            makerAsset: address(makerToken),
            takerAsset: address(takerToken),
            makerAddress: maker,
            makerAmount: MAKER_AMOUNT,
            takerAmount: TAKER_AMOUNT,
            usePermit2: true,
            confidenceT: confidenceT,
            confidenceWeight: weight,
            confidenceCap: cap,
            permit2Signature: "",
            permit2Witness: bytes32(0),
            permit2WitnessType: ""
        });

        // Construct witness data (binds Permit2 to token, amount, counterparty)
        bytes32 witness = keccak256(
            abi.encode(
                CONSIDERATION_TYPEHASH,
                address(makerToken),
                order.makerAmount,
                maker
            )
        );
        order.permit2Witness = witness;
        order.permit2WitnessType = WITNESS_TYPE_STRING;

        // MockPermit2 skips signature verification, but we still need non-empty bytes
        // so PmmProtocol takes the permit2Signature code path
        order.permit2Signature = hex"DEAD";

        // Sign order
        bytes memory orderSignature = _sign(order);

        // Warp 100 seconds past confidenceT: cutdown = 100 * 1000 = 100_000 (10%)
        vm.warp(confidenceT + 100);

        uint256 expectedMaker = MAKER_AMOUNT - MAKER_AMOUNT * 100_000 / 1e6; // 90e18

        uint256 makerBalBefore = makerToken.balanceOf(maker);
        uint256 takerMakerBalBefore = makerToken.balanceOf(taker);
        uint256 takerBalBefore = takerToken.balanceOf(taker);

        // Execute fill
        vm.prank(taker);
        (uint256 makerFilled, uint256 takerFilled,) = pmmProtocol.fillOrderRFQ(order, orderSignature, 0);

        // Verify slippage applied correctly through Permit2 witness path
        assertEq(makerFilled, expectedMaker, "makerFilled should reflect 10% slippage via permit2 witness");
        assertEq(takerFilled, TAKER_AMOUNT, "takerFilled should be full amount");

        // Verify actual token balances
        assertEq(makerToken.balanceOf(maker), makerBalBefore - expectedMaker, "maker makerToken balance");
        assertEq(makerToken.balanceOf(taker), takerMakerBalBefore + expectedMaker, "taker makerToken balance");
        assertEq(takerToken.balanceOf(taker), takerBalBefore - TAKER_AMOUNT, "taker takerToken balance");
    }

    // ═════════════════════════════════════════════════════════════════
    //  CONFIDENCE CAP LIMIT (10%)
    // ═════════════════════════════════════════════════════════════════

    // ─────────────────────────────────────────────────────────────────
    //  15. Revert if cap > 10% with confidenceT > 0 and weight > 0
    // ─────────────────────────────────────────────────────────────────

    function testRevertWhenCapExceeds10Percent() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 1000;
        uint256 cap = 200_000; // 20% — exceeds 10% limit

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(16, getFutureTimestamp(2 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp past confidenceT to activate slippage
        vm.warp(confidenceT + 100);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_ConfidenceCapExceeded.selector, 16));
        pmmProtocol.fillOrderRFQ(order, signature, 0);
    }

    // ─────────────────────────────────────────────────────────────────
    //  16. No revert if cap > 10% but confidenceT == 0 (slippage disabled)
    // ─────────────────────────────────────────────────────────────────

    function testNoRevertWhenCapExceeds10PercentButConfidenceTIsZero() public {
        uint256 weight = 1000;
        uint256 cap = 200_000; // 20% — exceeds limit but confidenceT == 0

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(17, getFutureTimestamp(2 hours), 0, weight, cap);
        bytes memory signature = _sign(order);

        vm.warp(block.timestamp + 30 minutes);

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        // slippage never activates, so full makerAmount is transferred
        assertEq(makerFilled, MAKER_AMOUNT, "no revert and full amount when confidenceT is 0");
    }

    // ─────────────────────────────────────────────────────────────────
    //  17. No revert if cap > 10% but confidenceWeight == 0 (slippage disabled)
    // ─────────────────────────────────────────────────────────────────

    function testNoRevertWhenCapExceeds10PercentButWeightIsZero() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 cap = 200_000; // 20% — exceeds limit but weight == 0

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(18, getFutureTimestamp(2 hours), confidenceT, 0, cap);
        bytes memory signature = _sign(order);

        // warp past confidenceT
        vm.warp(confidenceT + 100);

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        // slippage never activates (weight == 0), so full makerAmount is transferred
        assertEq(makerFilled, MAKER_AMOUNT, "no revert and full amount when weight is 0");
    }
}
