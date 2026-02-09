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
            _orderWithConfidence(1, getFutureTimestamp(1 hours), confidenceT, 1000, 500_000);
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
            _orderWithConfidence(2, getFutureTimestamp(1 hours), confidenceT, 1000, 500_000);
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
            _orderWithConfidence(3, getFutureTimestamp(1 hours), 0, 1000, 500_000);
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
            _orderWithConfidence(4, getFutureTimestamp(1 hours), confidenceT, 0, 500_000);
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
        uint256 cap = 500_000; // max 50% reduction

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
        uint256 cap = 900_000; // max 90%

        // Test at 200 seconds past: cutdown = 200 * 500 = 100_000 (10%)
        OrderRFQLib.OrderRFQ memory order1 =
            _orderWithConfidence(7, getFutureTimestamp(2 hours), confidenceT, weight, cap);
        bytes memory sig1 = _sign(order1);

        vm.warp(confidenceT + 200);
        vm.prank(taker);
        (uint256 makerFilled1,,) = pmmProtocol.fillOrderRFQ(order1, sig1, 0);

        uint256 expected1 = MAKER_AMOUNT - MAKER_AMOUNT * 100_000 / 1e6; // 90e18
        assertEq(makerFilled1, expected1, "10% slippage at t+200s");

        // Test at 400 seconds past: cutdown = 400 * 500 = 200_000 (20%)
        OrderRFQLib.OrderRFQ memory order2 =
            _orderWithConfidence(8, getFutureTimestamp(2 hours), confidenceT, weight, cap);
        bytes memory sig2 = _sign(order2);

        vm.warp(confidenceT + 400);
        vm.prank(taker);
        (uint256 makerFilled2,,) = pmmProtocol.fillOrderRFQ(order2, sig2, 0);

        uint256 expected2 = MAKER_AMOUNT - MAKER_AMOUNT * 200_000 / 1e6; // 80e18
        assertEq(makerFilled2, expected2, "20% slippage at t+400s");

        // Verify linear relationship: reduction at 400s is exactly 2x reduction at 200s
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
        uint256 cap = 500_000; // 50%

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(9, getFutureTimestamp(1 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp 200 seconds past confidenceT: cutdown = 200 * 1000 = 200_000 (20%)
        vm.warp(confidenceT + 200);

        // partial fill: 80% of makerAmount
        uint256 partialMaker = MAKER_AMOUNT * 8 / 10; // 80e18
        uint256 flagsAndAmount = MAKER_AMOUNT_FLAG | partialMaker;

        // confidence applied to the partial amount: 80e18 - 80e18 * 200_000 / 1e6 = 64e18
        uint256 expectedMaker = partialMaker - partialMaker * 200_000 / 1e6;

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
        uint256 cap = 500_000;

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
        uint256 cap = 400_000; // max 40%

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(11, getFutureTimestamp(1 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp 100 seconds past: cutdown = 100 * 2000 = 200_000 (20%)
        vm.warp(confidenceT + 100);

        uint256 makerBalBefore = makerToken.balanceOf(maker);
        uint256 takerMakerBalBefore = makerToken.balanceOf(taker);
        uint256 takerBalBefore = takerToken.balanceOf(taker);
        uint256 makerTakerBalBefore = takerToken.balanceOf(maker);

        uint256 expectedMakerFilled = MAKER_AMOUNT - MAKER_AMOUNT * 200_000 / 1e6; // 80e18

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
        uint256 cap = 300_000; // max 30%

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(12, getFutureTimestamp(2 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp 1000 seconds past: uncapped cutdown = 1000 * 10_000 = 10_000_000 (1000%)
        // but capped at 300_000 (30%)
        vm.warp(confidenceT + 1000);

        uint256 expectedMaker = MAKER_AMOUNT - MAKER_AMOUNT * cap / 1e6; // 70e18

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerFilled, expectedMaker, "slippage should be capped at 30%");
    }

    // ─────────────────────────────────────────────────────────────────
    //  12. Confidence with max cap (100%) reduces makerAmount to zero
    // ─────────────────────────────────────────────────────────────────

    function testMaxCapReducesMakerAmountToZero() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 10_000;
        uint256 cap = 1_000_000; // 100% — full reduction

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(13, getFutureTimestamp(2 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp far enough that cutdown reaches cap (100%)
        vm.warp(confidenceT + 200); // 200 * 10_000 = 2_000_000 > cap, capped at 1_000_000

        // makerAmount = 100e18 - 100e18 * 1_000_000 / 1e6 = 0
        // The contract does NOT re-check zero after confidence — this transfer may succeed with 0
        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerFilled, 0, "100% confidence cap should reduce makerAmount to zero");
    }

    // ─────────────────────────────────────────────────────────────────
    //  13. Settlement limit check passes before confidence reduces amount
    // ─────────────────────────────────────────────────────────────────

    function testSettleLimitPassesBeforeConfidenceReducesBelow60Percent() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 10_000; // 1% per second
        uint256 cap = 500_000; // max 50%

        OrderRFQLib.OrderRFQ memory order =
            _orderWithConfidence(14, getFutureTimestamp(2 hours), confidenceT, weight, cap);
        bytes memory signature = _sign(order);

        // warp far past confidenceT so cap (50%) is reached
        vm.warp(confidenceT + 1000);

        // Full fill: makerAmount = 100e18 passes settle limit (100e18 >= 60e18)
        // After confidence 50%: actual makerFilled = 50e18 (below 60% of order.makerAmount)
        // This succeeds because settle limit is checked BEFORE confidence
        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        uint256 expectedMaker = MAKER_AMOUNT - MAKER_AMOUNT * cap / 1e6; // 50e18
        assertEq(makerFilled, expectedMaker, "settle limit does not block post-confidence amount");

        // Verify: final makerFilled (50e18) < 60% of order.makerAmount (60e18)
        assertTrue(
            makerFilled < (MAKER_AMOUNT * 6000) / 10000,
            "makerFilled is below 60% settle limit after confidence"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    //  14. Slippage with Permit2 signature + witness transfer
    // ─────────────────────────────────────────────────────────────────

    function testSlippageWithPermit2WitnessTransfer() public {
        uint256 confidenceT = block.timestamp + 10 minutes;
        uint256 weight = 1000; // 0.1% per second
        uint256 cap = 500_000; // max 50%

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
}
