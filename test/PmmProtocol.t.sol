// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/PmmProtocol.sol";
import "../src/OrderRFQLib.sol";
import "../src/interfaces/IWETH.sol";
import "../src/libraries/Errors.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockWETH.sol";
// import "./mocks/MockPMMSettler.sol"; // Not needed as settler functionality is not implemented
import "./helpers/TestHelper.sol";

contract PmmProtocolTest is TestHelper {
    PMMProtocol public pmmProtocol;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockWETH public weth;
    // MockPMMSettler public settler; // Not needed as settler functionality is not implemented

    address public maker;
    address public taker;
    address public treasury;

    uint256 public constant INITIAL_BALANCE = 1000 * 1e18;
    uint256 public constant ORDER_ID = 1;
    uint256 public constant MAKING_AMOUNT = 100 * 1e18;
    uint256 public constant TAKING_AMOUNT = 200 * 1e18;

    function setUp() public {
        // 部署mock合约
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        weth = new MockWETH();
        // settler = new MockPMMSettler(address(weth)); // Not needed as settler functionality is not implemented

        // 部署主合约
        pmmProtocol = new PMMProtocol(IWETH(address(weth)));

        // 设置地址
        maker = MAKER_ADDRESS;
        taker = TAKER_ADDRESS;
        treasury = makeAddr("treasury");

        // 设置settler
        // settler.setTreasury(treasury); // Not needed as settler functionality is not implemented

        // 初始化余额
        tokenA.mint(maker, INITIAL_BALANCE);
        tokenB.mint(taker, INITIAL_BALANCE);
        weth.mint(maker, INITIAL_BALANCE);
        weth.mint(treasury, INITIAL_BALANCE);

        // 设置授权
        vm.prank(maker);
        tokenA.approve(address(pmmProtocol), type(uint256).max);

        vm.prank(maker);
        weth.approve(address(pmmProtocol), type(uint256).max);

        vm.prank(taker);
        tokenB.approve(address(pmmProtocol), type(uint256).max);

        // vm.prank(treasury);
        // tokenA.approve(address(settler), type(uint256).max);

        // vm.prank(treasury);
        // weth.approve(address(settler), type(uint256).max);
        // Settler approvals not needed as settler functionality is not implemented
    }

    function testFillOrderRFQ_BasicOrder() public {
        // 创建订单
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(tokenA),
            address(tokenB),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            false
        );

        // 签名
        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // 记录初始余额
        uint256 makerTokenABefore = tokenA.balanceOf(maker);
        uint256 makerTokenBBefore = tokenB.balanceOf(maker);
        uint256 takerTokenABefore = tokenA.balanceOf(taker);
        uint256 takerTokenBBefore = tokenB.balanceOf(taker);

        // 执行交易
        vm.prank(taker);
        (uint256 filledMakingAmount, uint256 filledTakingAmount, bytes32 orderHash) =
            pmmProtocol.fillOrderRFQ(order, signature, 0);

        // 验证结果
        assertEq(filledMakingAmount, MAKING_AMOUNT);
        assertEq(filledTakingAmount, TAKING_AMOUNT);
        assertNotEq(orderHash, bytes32(0));

        // 验证余额变化
        assertEq(tokenA.balanceOf(maker), makerTokenABefore - MAKING_AMOUNT);
        assertEq(tokenB.balanceOf(maker), makerTokenBBefore + TAKING_AMOUNT);
        assertEq(tokenA.balanceOf(taker), takerTokenABefore + MAKING_AMOUNT);
        assertEq(tokenB.balanceOf(taker), takerTokenBBefore - TAKING_AMOUNT);
    }

    function testFillOrderRFQ_BasicOrderWithNonZeroAmount() public {
        // 创建订单
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(tokenA),
            address(tokenB),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            false
        );

        // 签名
        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        console2.logBytes(signature);

        // 记录初始余额
        uint256 makerTokenABefore = tokenA.balanceOf(maker);
        uint256 makerTokenBBefore = tokenB.balanceOf(maker);
        uint256 takerTokenABefore = tokenA.balanceOf(taker);
        uint256 takerTokenBBefore = tokenB.balanceOf(taker);

        // 执行交易
        vm.prank(taker);
        (uint256 filledMakingAmount, uint256 filledTakingAmount, bytes32 orderHash) =
            pmmProtocol.fillOrderRFQ(order, signature, TAKING_AMOUNT);

        // 验证结果
        assertEq(filledMakingAmount, MAKING_AMOUNT);
        assertEq(filledTakingAmount, TAKING_AMOUNT);
        assertNotEq(orderHash, bytes32(0));

        // 验证余额变化
        assertEq(tokenA.balanceOf(maker), makerTokenABefore - MAKING_AMOUNT);
        assertEq(tokenB.balanceOf(maker), makerTokenBBefore + TAKING_AMOUNT);
        assertEq(tokenA.balanceOf(taker), takerTokenABefore + MAKING_AMOUNT);
        assertEq(tokenB.balanceOf(taker), takerTokenBBefore - TAKING_AMOUNT);
    }

    function testFillOrderRFQ_PartialFill() public {
        uint256 partialAmount = MAKING_AMOUNT * 8 / 10;
        uint256 expectedTakingAmount = TAKING_AMOUNT * 8 / 10;

        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(tokenA),
            address(tokenB),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            false
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // 使用_MAKER_AMOUNT_FLAG进行部分填充
        uint256 flagsAndAmount = (1 << 255) | partialAmount; // _MAKER_AMOUNT_FLAG + amount

        vm.prank(taker);
        (uint256 filledMakingAmount, uint256 filledTakingAmount,) =
            pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);

        assertEq(filledMakingAmount, partialAmount);
        assertEq(filledTakingAmount, expectedTakingAmount);
    }

    function testFillOrderRFQ_WithWETHUnwrap() public {
        // 给taker一些ETH
        vm.deal(taker, 10 ether);

        // 给WETH合约一些ETH来支持withdraw操作
        vm.deal(address(weth), 10 ether);

        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID, getFutureTimestamp(1 hours), address(weth), address(tokenB), maker, 1 ether, TAKING_AMOUNT, false
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // 使用_UNWRAP_WETH_FLAG
        uint256 flagsAndAmount = 1 << 252; // _UNWRAP_WETH_FLAG

        uint256 takerEthBefore = taker.balance;

        vm.prank(taker);
        pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);

        // 验证taker收到了ETH而不是WETH
        assertEq(taker.balance, takerEthBefore + 1 ether);
    }

    // Settler functionality is not implemented in current PmmProtocol.sol
    // function testFillOrderRFQ_WithSettler() public {
    //     // This test is commented out because settler functionality
    //     // is not implemented in the current PmmProtocol.sol
    // }

    function testFillOrderRFQ_RevertExpiredOrder() public {
        // Warp to a realistic timestamp first
        vm.warp(1700000000); // Nov 2023

        // Create an order that expires 1 second ago
        uint256 expiredTimestamp = block.timestamp - 1;
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            expiredTimestamp, // 已过期
            address(tokenA),
            address(tokenB),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            false
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_OrderExpired.selector, order.rfqId));
        pmmProtocol.fillOrderRFQ(order, signature, 0);
    }

    // Private order functionality is not implemented in current PmmProtocol.sol
    // function testFillOrderRFQ_RevertPrivateOrder() public {
    //     // This test is commented out because private order functionality
    //     // is not implemented in the current PmmProtocol.sol
    // }

    function testFillOrderRFQ_RevertBadSignature() public {
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(tokenA),
            address(tokenB),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            false
        );

        // 使用错误的私钥签名
        bytes memory badSignature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), TAKER_PRIVATE_KEY);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_BadSignature.selector, order.rfqId));
        pmmProtocol.fillOrderRFQ(order, badSignature, 0);
    }

    function testFillOrderRFQ_RevertZeroAmount() public {
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(tokenA),
            address(tokenB),
            maker,
            0, // 零making amount
            TAKING_AMOUNT,
            false
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_SwapWithZeroAmount.selector, order.rfqId));
        pmmProtocol.fillOrderRFQ(order, signature, 0);
    }

    function testFillOrderRFQ_RevertMakingAmountExceeded() public {
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(tokenA),
            address(tokenB),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            false
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // 尝试填充超过making amount的数量
        uint256 flagsAndAmount = (1 << 255) | (MAKING_AMOUNT + 1); // _MAKER_AMOUNT_FLAG + excessive amount

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_MakerAmountExceeded.selector, order.rfqId));
        pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);
    }

    // Settler functionality is not implemented in current PmmProtocol.sol
    // function testFillOrderRFQ_RevertSettleFailed() public {
    //     // This test is commented out because settler functionality
    //     // is not implemented in the current PmmProtocol.sol
    // }

    // function testCancelOrderRFQ() public {
    //     uint256 orderInfo = ORDER_ID;

    //     vm.prank(maker);
    //     pmmProtocol.cancelOrderRFQ(orderInfo);

    //     // 尝试填充已取消的订单
    //     OrderRFQLib.OrderRFQ memory order = createOrder(
    //         ORDER_ID,
    //         getFutureTimestamp(1 hours),
    //         address(tokenA),
    //         address(tokenB),
    //         maker,
    //         MAKING_AMOUNT,
    //         TAKING_AMOUNT,
    //         false
    //     );

    //     bytes memory signature = signOrder(
    //         order,
    //         pmmProtocol.DOMAIN_SEPARATOR(),
    //         MAKER_PRIVATE_KEY
    //     );

    //     vm.prank(taker);
    //     vm.expectRevert(abi.encodeWithSelector(Errors.RFQ_InvalidatedOrder.selector, order.rfqId));
    //     pmmProtocol.fillOrderRFQ(order, signature, 0);
    // }

    // function testInvalidatorForOrderRFQ() public {
    //     uint256 orderInfo = ORDER_ID;
    //     uint256 slot = uint64(orderInfo) >> 8;

    //     // 初始状态应该为0
    //     assertEq(pmmProtocol.invalidatorForOrderRFQ(maker, slot), 0);

    //     // 取消订单
    //     vm.prank(maker);
    //     pmmProtocol.cancelOrderRFQ(orderInfo);

    //     // 验证invalidator已更新
    //     uint256 expectedBit = 1 << uint8(orderInfo);
    //     assertEq(pmmProtocol.invalidatorForOrderRFQ(maker, slot), expectedBit);
    // }
}
