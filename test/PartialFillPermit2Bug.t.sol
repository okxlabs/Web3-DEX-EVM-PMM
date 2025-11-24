// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../src/PmmProtocol.sol";
import "forge-std/Test.sol";
import "../src/interfaces/IWETH.sol";
import "../src/interfaces/IPermit2.sol";
import "./helpers/TestHelper.sol";

contract PartialFillPermit2Bug is TestHelper {
    PMMProtocol pool;
    address constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant usdt = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {
        // Fork Arbitrum Mainnet
        vm.createSelectFork("arbitrum");
        pool = new PMMProtocol(IWETH(ARBITRUM_WETH));

        // Setup initial balances
        // USDC has 6 decimals, USDT has 6 decimals
        vm.prank(0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7); // usdc whale
        SafeERC20.safeTransfer(IERC20(usdc), MAKER_ADDRESS, 100_000 * 1e6);

        vm.prank(0xF977814e90dA44bFA03b6295A0616a897441aceC); // usdt whale
        SafeERC20.safeTransfer(IERC20(usdt), TAKER_ADDRESS, 100_000 * 1e6);

        // Maker approves Permit2 to spend USDC
        vm.prank(MAKER_ADDRESS);
        SafeERC20.forceApprove(IERC20(usdc), permit2, type(uint256).max);
        
        // Taker approves Pool to spend USDT
        vm.prank(TAKER_ADDRESS);
        SafeERC20.forceApprove(IERC20(usdt), address(pool), type(uint256).max);
    }

    function testBugPartialFillWithPermit2Signature() public {
        // 1. Create Order
        // Maker wants to sell 100,000 USDC for 100,000 USDT
        uint256 fullMakerAmount = 100_000 * 1e6;
        uint256 fullTakerAmount = 100_000 * 1e6;
        
        OrderRFQLib.OrderRFQ memory order = createOrder(
            12345, 
            block.timestamp + 1 hours, 
            usdc, 
            usdt, 
            MAKER_ADDRESS, 
            fullMakerAmount, 
            fullTakerAmount, 
            true // usePermit2
        );

        // 2. Create Permit2 Signature (Signing the FULL amount)
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: usdc, amount: order.makerAmount}),
            nonce: order.rfqId,
            deadline: order.expiry
        });
        
        bytes memory permit2Signature = getPermit2Signature(
            permit, 
            address(pool), 
            MAKER_PRIVATE_KEY, 
            IPermit2(permit2).DOMAIN_SEPARATOR()
        );
        order.permit2Signature = permit2Signature;

        // 3. Sign the Order
        bytes memory orderSignature = signOrder(order, pool.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // 4. Taker attempts to fill 70% of the order (must be >= 60% due to _SETTLE_LIMIT)
        uint256 partialTakerAmount = fullTakerAmount * 7 / 10; // 70,000 USDT
        
        vm.prank(TAKER_ADDRESS);
        pool.fillOrderRFQTo(order, orderSignature, partialTakerAmount, TAKER_ADDRESS);

        // 5. Assertions
        // Check Taker received 70% of Maker amount (70,000 USDC)
        assertEq(IERC20(usdc).balanceOf(TAKER_ADDRESS), 70_000 * 1e6);
        
        // Check Maker received 70% of Taker amount (70,000 USDT)
        // Note: Maker started with 100_000 USDC, 0 USDT
        assertEq(IERC20(usdt).balanceOf(MAKER_ADDRESS), 70_000 * 1e6);
    }
}

