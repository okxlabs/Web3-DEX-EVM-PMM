// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/PmmProtocol.sol";
import "../src/OrderRFQLib.sol";
import "../src/interfaces/IWETH.sol";
import "./helpers/TestHelper.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockWETH.sol";

// 简化的Permit2接口用于本地测试
interface IPermit2Local {
    function transferFrom(address user, address spender, uint160 amount, address token) external;
}

// Mock Permit2合约用于本地测试
contract MockPermit2 {
    mapping(address => mapping(address => uint256)) public allowances;

    function setAllowance(address user, address token, uint256 amount) external {
        allowances[user][token] = amount;
    }

    function transferFrom(address user, address spender, uint160 amount, address token) external {
        require(allowances[user][token] >= amount, "Insufficient allowance");
        allowances[user][token] -= amount;
        IERC20(token).transferFrom(user, spender, amount);
    }
}

contract PmmProtocolPermit2LocalTest is TestHelper {
    PMMProtocol public pmmProtocol;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockWETH public weth;
    MockPermit2 public mockPermit2;

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
        mockPermit2 = new MockPermit2();

        // 部署PMM协议
        pmmProtocol = new PMMProtocol(IWETH(address(weth)));

        // 设置测试地址
        maker = MAKER_ADDRESS;
        taker = TAKER_ADDRESS;
        treasury = makeAddr("treasury");

        // 初始化余额
        tokenA.mint(maker, INITIAL_BALANCE);
        tokenB.mint(taker, INITIAL_BALANCE);
        weth.mint(maker, INITIAL_BALANCE);

        // 设置授权
        vm.prank(maker);
        tokenA.approve(address(mockPermit2), type(uint256).max);

        vm.prank(maker);
        weth.approve(address(mockPermit2), type(uint256).max);

        vm.prank(taker);
        tokenB.approve(address(pmmProtocol), type(uint256).max);

        // 设置Mock Permit2的allowance
        mockPermit2.setAllowance(maker, address(tokenA), INITIAL_BALANCE);
        mockPermit2.setAllowance(maker, address(weth), INITIAL_BALANCE);
    }

    function testLocalPermit2BasicTransfer() public {
        // This test verifies that Permit2 flag causes SafeTransferFromFailed
        // because the real Permit2 contract doesn't exist in test environment

        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(tokenA),
            address(tokenB),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            true
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // Use Permit2 flag - this will cause SafeTransferFromFailed
        uint256 USE_PERMIT2_FLAG = 1 << 250;
        uint256 flagsAndAmount = USE_PERMIT2_FLAG;

        // Execute trade - expect it to fail with SafeTransferFromFailed
        vm.prank(taker);
        vm.expectRevert("SafeTransferFromFailed()");
        pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);
    }

    function testLocalPermit2PartialFill() public {
        uint256 partialMakingAmount = MAKING_AMOUNT * 8 / 10;

        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(tokenA),
            address(tokenB),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            true
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // Use Permit2 + MAKER_AMOUNT_FLAG for partial fill
        uint256 USE_PERMIT2_FLAG = 1 << 250;
        uint256 MAKER_AMOUNT_FLAG = 1 << 255;
        uint256 flagsAndAmount = USE_PERMIT2_FLAG | MAKER_AMOUNT_FLAG | partialMakingAmount;

        // Execute trade - expect it to fail with SafeTransferFromFailed
        vm.prank(taker);
        vm.expectRevert("SafeTransferFromFailed()");
        pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);
    }

    function testLocalPermit2WithWETHUnwrap() public {
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID, getFutureTimestamp(1 hours), address(weth), address(tokenB), maker, 1 ether, TAKING_AMOUNT, true
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // Use Permit2 + UNWRAP_WETH flags
        uint256 USE_PERMIT2_FLAG = 1 << 250;
        uint256 UNWRAP_WETH_FLAG = 1 << 252;
        uint256 flagsAndAmount = USE_PERMIT2_FLAG | UNWRAP_WETH_FLAG;

        // Execute trade - expect it to fail with SafeTransferFromFailed
        vm.prank(taker);
        vm.expectRevert("SafeTransferFromFailed()");
        pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);
    }

    function testLocalPermit2FlagValidation() public {
        // 测试当没有设置Permit2标志位时，使用普通转账
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

        // Maker需要向PMM协议授权以便普通转账
        vm.prank(maker);
        tokenA.approve(address(pmmProtocol), type(uint256).max);

        // 不使用Permit2标志位
        uint256 flagsAndAmount = 0;

        uint256 makerTokenABefore = tokenA.balanceOf(maker);
        uint256 takerTokenABefore = tokenA.balanceOf(taker);

        // 执行交易（应该使用普通transferFrom）
        vm.prank(taker);
        (uint256 filledMakingAmount,,) = pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);

        assertEq(filledMakingAmount, MAKING_AMOUNT);
        assertEq(tokenA.balanceOf(maker), makerTokenABefore - MAKING_AMOUNT);
        assertEq(tokenA.balanceOf(taker), takerTokenABefore + MAKING_AMOUNT);
    }

    function testLocalMockPermit2Transfer() public {
        // 测试Mock Permit2合约的基本功能
        uint256 transferAmount = 1000;

        uint256 makerBefore = tokenA.balanceOf(maker);
        uint256 takerBefore = tokenA.balanceOf(taker);

        // 通过Mock Permit2转账
        vm.prank(address(pmmProtocol));
        mockPermit2.transferFrom(maker, taker, uint160(transferAmount), address(tokenA));

        // 验证转账结果
        assertEq(tokenA.balanceOf(maker), makerBefore - transferAmount);
        assertEq(tokenA.balanceOf(taker), takerBefore + transferAmount);
    }
}
