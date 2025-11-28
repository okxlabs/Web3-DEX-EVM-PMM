// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/PmmProtocol.sol";
import "../src/OrderRFQLib.sol";
import "../src/interfaces/IWETH.sol";
import "../src/libraries/Errors.sol";
import "./helpers/TestHelper.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPermit2.sol";
import "./mocks/MockWETH.sol";

contract PmmProtocolTest is TestHelper {
    PMMProtocol internal pmmProtocol;
    MockERC20 internal makerToken;
    MockERC20 internal takerToken;
    MockWETH internal weth;
    MockPermit2 internal permit2;

    address internal maker;
    address internal taker;
    address internal target;

    uint256 internal constant INITIAL_BALANCE = 1_000 ether;
    uint256 internal constant MAKER_AMOUNT = 100 ether;
    uint256 internal constant TAKING_AMOUNT = 200 ether;
    uint256 internal constant ORDER_ID = 1;

    uint256 internal constant MAKER_AMOUNT_FLAG = 1 << 255;
    uint256 internal constant UNWRAP_WETH_FLAG = 1 << 252;

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
        target = makeAddr("target");

        makerToken.mint(maker, INITIAL_BALANCE);
        takerToken.mint(taker, INITIAL_BALANCE);
        weth.mint(maker, INITIAL_BALANCE);

        vm.prank(maker);
        makerToken.approve(address(pmmProtocol), type(uint256).max);

        vm.prank(maker);
        makerToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        vm.prank(maker);
        weth.approve(address(pmmProtocol), type(uint256).max);

        vm.prank(taker);
        takerToken.approve(address(pmmProtocol), type(uint256).max);
    }

    function testFillOrderFullFillTransfersFundsAndInvalidatesId() public {
        OrderRFQLib.OrderRFQ memory order = _defaultOrder(false);
        bytes memory signature = _sign(order);

        vm.prank(taker);
        (uint256 makerFilled, uint256 takerFilled,) = pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerFilled, order.makerAmount);
        assertEq(takerFilled, order.takerAmount);
        assertTrue(pmmProtocol.isRfqIdUsed(maker, uint64(order.rfqId)));

        // second attempt should revert because rfqId already consumed
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_InvalidatedOrder.selector, order.rfqId));
        pmmProtocol.fillOrderRFQ(order, signature, 0);
    }

    function testFillOrderPartialMakerAmountUsesCalculator() public {
        OrderRFQLib.OrderRFQ memory order = _defaultOrder(false);
        bytes memory signature = _sign(order);

        uint256 desiredMaker = order.makerAmount * 8 / 10;
        uint256 flagsAndAmount = MAKER_AMOUNT_FLAG | desiredMaker;

        vm.prank(taker);
        (uint256 makerFilled, uint256 takerFilled,) = pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);

        assertEq(makerFilled, desiredMaker);
        assertEq(takerFilled, TAKING_AMOUNT * 8 / 10);
    }

    function testFillOrderPartialBelowSettleLimitReverts() public {
        OrderRFQLib.OrderRFQ memory order = _defaultOrder(false);
        bytes memory signature = _sign(order);

        uint256 desiredMaker = order.makerAmount / 2; // below 60% threshold
        uint256 flagsAndAmount = MAKER_AMOUNT_FLAG | desiredMaker;

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_SettlementAmountTooSmall.selector, order.rfqId));
        pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);
    }

    function testFillOrderUnwrapsWethWhenFlagged() public {
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(weth),
            address(takerToken),
            maker,
            1 ether,
            TAKING_AMOUNT,
            false
        );
        bytes memory signature = _sign(order);

        // MockWETH.withdraw sends native ETH that must already sit on the WETH contract.
        vm.deal(address(weth), order.makerAmount);

        uint256 takerBalanceBefore = taker.balance;
        vm.prank(taker);
        pmmProtocol.fillOrderRFQ(order, signature, UNWRAP_WETH_FLAG);

        assertEq(taker.balance, takerBalanceBefore + 1 ether);
    }

    function testFillOrderRejectsExpiredOrder() public {
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            block.timestamp - 1,
            address(makerToken),
            address(takerToken),
            maker,
            MAKER_AMOUNT,
            TAKING_AMOUNT,
            false
        );
        bytes memory signature = _sign(order);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_OrderExpired.selector, order.rfqId));
        pmmProtocol.fillOrderRFQ(order, signature, 0);
    }

    function testFillOrderRejectsBadSignature() public {
        OrderRFQLib.OrderRFQ memory order = _defaultOrder(false);
        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), TAKER_PRIVATE_KEY);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_BadSignature.selector, order.rfqId));
        pmmProtocol.fillOrderRFQ(order, signature, 0);
    }

    function testFillOrderWithPermit2AllowancePath() public {
        vm.prank(maker);
        permit2.approve(address(makerToken), address(pmmProtocol), type(uint160).max, type(uint48).max);

        OrderRFQLib.OrderRFQ memory order = _defaultOrder(true);
        bytes memory signature = _sign(order);

        vm.prank(taker);
        pmmProtocol.fillOrderRFQ(order, signature, 0);

        assertEq(makerToken.balanceOf(taker), order.makerAmount);
    }

    function testFillOrderWithPermit2SignatureAndWitness() public {
        vm.prank(maker);
        permit2.approve(address(makerToken), address(pmmProtocol), type(uint160).max, type(uint48).max);

        OrderRFQLib.OrderRFQ memory order = _defaultOrder(true);
        order.permit2Signature = hex"01";
        order.permit2Witness = keccak256("witness");
        order.permit2WitnessType =
            "ExampleWitness witness)ExampleWitness(address user)TokenPermissions(address token,uint256 amount)";

        bytes memory signature = _sign(order);
        uint256 desiredMaker = order.makerAmount * 7 / 10;
        uint256 flagsAndAmount = MAKER_AMOUNT_FLAG | desiredMaker;

        vm.prank(taker);
        (uint256 makerFilled,,) = pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);

        assertEq(makerFilled, desiredMaker);
        assertEq(makerToken.balanceOf(taker), desiredMaker);
    }

    function testCancelOrderPreventsFill() public {
        OrderRFQLib.OrderRFQ memory order = _defaultOrder(false);

        vm.prank(maker);
        pmmProtocol.cancelOrderRFQ(uint64(order.rfqId));

        bytes memory signature = _sign(order);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_InvalidatedOrder.selector, order.rfqId));
        pmmProtocol.fillOrderRFQ(order, signature, 0);
    }

    function _defaultOrder(bool usePermit2) internal view returns (OrderRFQLib.OrderRFQ memory) {
        return createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(makerToken),
            address(takerToken),
            maker,
            MAKER_AMOUNT,
            TAKING_AMOUNT,
            usePermit2
        );
    }

    function _sign(OrderRFQLib.OrderRFQ memory order) internal view returns (bytes memory) {
        return signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);
    }
}
