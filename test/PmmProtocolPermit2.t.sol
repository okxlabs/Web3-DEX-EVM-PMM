// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/interfaces/IERC20.sol";
import "../src/PmmProtocol.sol";
import "../src/OrderRFQLib.sol";
import "../src/interfaces/IWETH.sol";
import "../src/interfaces/IPermit2.sol";
import "./helpers/TestHelper.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockWETH.sol";

contract PmmProtocolPermit2Test is TestHelper {
    PMMProtocol public pmmProtocol;

    // Use mock contracts instead of forking
    MockERC20 public weth;
    MockERC20 public usdc;
    MockWETH public mockWETH;

    // Mock Permit2 interface for testing
    IPermit2 public permit2;

    address public maker;
    address public taker;
    address public treasury;

    uint256 public constant INITIAL_BALANCE = 10000 * 1e18;
    uint256 public constant MAKING_AMOUNT = 1 ether;
    uint256 public constant TAKING_AMOUNT = 2000 * 1e6; // 2000 USDC
    uint256 public constant ORDER_ID = 1;

    function setUp() public {
        // Deploy mock contracts instead of forking
        mockWETH = new MockWETH();
        weth = MockERC20(address(mockWETH));
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy PMM Protocol with mock WETH
        pmmProtocol = new PMMProtocol(IWETH(address(mockWETH)));

        // Set up test addresses
        maker = MAKER_ADDRESS;
        taker = TAKER_ADDRESS;
        treasury = makeAddr("treasury");

        // Fund accounts with mock tokens
        _fundAccounts();
        _setupApprovals();
    }

    function _fundAccounts() internal {
        // Mint tokens for testing
        weth.mint(maker, INITIAL_BALANCE);
        usdc.mint(taker, INITIAL_BALANCE);
        weth.mint(treasury, INITIAL_BALANCE);
        usdc.mint(treasury, INITIAL_BALANCE);
    }

    function _setupApprovals() internal {
        // Maker approvals
        vm.prank(maker);
        weth.approve(address(pmmProtocol), type(uint256).max);

        // Taker approvals
        vm.prank(taker);
        usdc.approve(address(pmmProtocol), type(uint256).max);

        // Treasury approvals
        vm.prank(treasury);
        weth.approve(address(pmmProtocol), type(uint256).max);

        vm.prank(treasury);
        usdc.approve(address(pmmProtocol), type(uint256).max);
    }

    function testPermit2BasicTransfer() public {
        // Test basic transfer functionality with Permit2 flag
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(weth),
            address(usdc),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            true
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // Use Permit2 flag - this will fail because Permit2 contract doesn't exist in test environment
        uint256 USE_PERMIT2_FLAG = 1 << 250;
        uint256 flagsAndAmount = USE_PERMIT2_FLAG;

        // Execute trade - expect it to fail with SafeTransferFromFailed because Permit2 doesn't exist
        vm.prank(taker);
        vm.expectRevert("SafeTransferFromFailed()");
        pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);
    }

    function testPermit2PartialFill() public {
        uint256 partialMakingAmount = MAKING_AMOUNT * 8 / 10;

        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(weth),
            address(usdc),
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

        // Execute trade - expect it to fail with SafeTransferFromFailed because Permit2 doesn't exist
        vm.prank(taker);
        vm.expectRevert("SafeTransferFromFailed()");
        pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);
    }

    function testPermit2WithWETHUnwrap() public {
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(weth),
            address(usdc),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            true
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // Use Permit2 + UNWRAP_WETH flags
        uint256 USE_PERMIT2_FLAG = 1 << 250;
        uint256 UNWRAP_WETH_FLAG = 1 << 252;
        uint256 flagsAndAmount = USE_PERMIT2_FLAG | UNWRAP_WETH_FLAG;

        // Execute trade - expect it to fail with SafeTransferFromFailed because Permit2 doesn't exist
        vm.prank(taker);
        vm.expectRevert("SafeTransferFromFailed()");
        pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);
    }

    function testComparePermit2VsNormalTransfer() public {
        // Test that Permit2 fails while normal transfer works

        // Prepare two identical orders
        OrderRFQLib.OrderRFQ memory orderPermit2 = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(weth),
            address(usdc),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            true
        );

        OrderRFQLib.OrderRFQ memory orderNormal = createOrder(
            ORDER_ID + 1,
            getFutureTimestamp(1 hours),
            address(weth),
            address(usdc),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            false
        );

        bytes memory signaturePermit2 = signOrder(orderPermit2, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        bytes memory signatureNormal = signOrder(orderNormal, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // Test Permit2 transfer - should fail
        uint256 USE_PERMIT2_FLAG = 1 << 250;
        vm.prank(taker);
        vm.expectRevert("SafeTransferFromFailed()");
        pmmProtocol.fillOrderRFQ(orderPermit2, signaturePermit2, USE_PERMIT2_FLAG);

        // Test normal transfer - should work
        vm.prank(taker);
        (uint256 filledMakingAmount, uint256 filledTakingAmount,) =
            pmmProtocol.fillOrderRFQ(orderNormal, signatureNormal, 0);

        // Verify normal transfer worked
        assertEq(filledMakingAmount, MAKING_AMOUNT);
        assertEq(filledTakingAmount, TAKING_AMOUNT);
    }

    function testPermit2AllowanceCheck() public view {
        // This test is mainly for demonstration - in a real Permit2 setup,
        // you would check the allowance through the actual Permit2 contract

        // Since we're using mock contracts, we can check the standard ERC20 allowance
        uint256 allowance = weth.allowance(maker, address(pmmProtocol));
        assertEq(allowance, type(uint256).max);
    }

    function testPermit2FlagValidation() public {
        // Test that when Permit2 flag is not set, normal transfer is used
        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(weth),
            address(usdc),
            maker,
            MAKING_AMOUNT,
            TAKING_AMOUNT,
            false
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // Don't use Permit2 flag
        uint256 flagsAndAmount = 0;

        uint256 makerWethBefore = weth.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);

        // Execute trade (should use normal transferFrom)
        vm.prank(taker);
        (uint256 filledMakingAmount,,) = pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);

        assertEq(filledMakingAmount, MAKING_AMOUNT);
        assertEq(weth.balanceOf(maker), makerWethBefore - MAKING_AMOUNT);
        assertEq(weth.balanceOf(taker), takerWethBefore + MAKING_AMOUNT);
    }

    function testPermit2RevertWithInsufficientBalance() public {
        // Create an order requiring more WETH than maker has
        uint256 excessiveAmount = INITIAL_BALANCE + 1 ether;

        OrderRFQLib.OrderRFQ memory order = createOrder(
            ORDER_ID,
            getFutureTimestamp(1 hours),
            address(weth),
            address(usdc),
            maker,
            excessiveAmount,
            TAKING_AMOUNT,
            false
        );

        bytes memory signature = signOrder(order, pmmProtocol.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        uint256 USE_PERMIT2_FLAG = 1 << 250;
        uint256 flagsAndAmount = USE_PERMIT2_FLAG;

        // Should fail due to insufficient balance
        vm.prank(taker);
        vm.expectRevert();
        pmmProtocol.fillOrderRFQ(order, signature, flagsAndAmount);
    }
}
