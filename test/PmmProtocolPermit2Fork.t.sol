pragma solidity ^0.8.0;

import "../src/PmmProtocol.sol";
import "forge-std/Test.sol";
import "../src/interfaces/IWETH.sol";
import "../src/interfaces/IPermit2.sol";
import "./helpers/TestHelper.sol";

interface IPMMProtocol {
    struct OrderRFQ {
        uint256 rfqId; // 0x00
        uint256 expiry; // 0x20
        address makerAsset; // 0x40
        address takerAsset; // 0x60
        address makerAddress; // 0x80
        uint256 makerAmount; // 0xa0
        uint256 takerAmount; // 0xc0
        bool usePermit2; // 0xe0
    }

    function fillOrderRFQTo(
        OrderRFQLib.OrderRFQ memory order,
        bytes calldata signature,
        uint256 flagsAndAmount,
        address target
    ) external returns (uint256, uint256, bytes32);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

address constant weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
address constant usdt = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
address constant usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
address constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

contract PmmProtocolPermit2Fork is TestHelper {
    PMMProtocol pool;
    address adapter;
    address marketMaker;

    address constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    function setUp() public {
        vm.createSelectFork("arbitrum");
        pool = new PMMProtocol(IWETH(ARBITRUM_WETH));

        vm.prank(0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7); // usdc whale
        SafeERC20.safeTransfer(IERC20(usdc), MAKER_ADDRESS, 100_000_000);

        vm.prank(0xF977814e90dA44bFA03b6295A0616a897441aceC); // usdt whale
        SafeERC20.safeTransfer(IERC20(usdt), TAKER_ADDRESS, 100_000_000);

        vm.prank(MAKER_ADDRESS);
        SafeERC20.forceApprove(IERC20(usdc), permit2, type(uint256).max);
        vm.prank(TAKER_ADDRESS);
        SafeERC20.forceApprove(IERC20(usdt), address(pool), type(uint256).max);
    }

    function testARBPermit2() public {
        OrderRFQLib.OrderRFQ memory order =
            createOrder(13578, 2068195245, usdc, usdt, MAKER_ADDRESS, 100000, 90000, true);

        bytes memory orderSignature = signOrder(order, pool.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        vm.startPrank(MAKER_ADDRESS);
        IPermit2(permit2).approve(usdc, address(pool), uint160(order.makerAmount), uint48(block.timestamp + 1000));
        vm.stopPrank();

        vm.prank(TAKER_ADDRESS);
        pool.fillOrderRFQTo(order, orderSignature, order.takerAmount, TAKER_ADDRESS);

        assertEq(IERC20(usdt).balanceOf(MAKER_ADDRESS), 90000);
        assertEq(IERC20(usdc).balanceOf(TAKER_ADDRESS), 100000);
    }
}

contract PmmProtocolPermit2WithPermit2SignatureFork is TestHelper {
    IPMMProtocol public pool;

    function setUp() public {
        vm.createSelectFork("arbitrum");
        pool = IPMMProtocol(address(new PMMProtocol(IWETH(weth))));

        vm.prank(0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7); // usdc whale
        SafeERC20.safeTransfer(IERC20(usdc), MAKER_ADDRESS, 100_000_000);

        vm.prank(0xF977814e90dA44bFA03b6295A0616a897441aceC); // usdt whale
        SafeERC20.safeTransfer(IERC20(usdt), TAKER_ADDRESS, 100_000_000);

        vm.prank(MAKER_ADDRESS);
        SafeERC20.forceApprove(IERC20(usdc), permit2, type(uint256).max);
        vm.prank(TAKER_ADDRESS);
        SafeERC20.forceApprove(IERC20(usdt), address(pool), type(uint256).max);
    }

    function testARBPermit2WithPermit2Signature() public {
        OrderRFQLib.OrderRFQ memory order =
            createOrder(13578, 2068195245, usdc, usdt, MAKER_ADDRESS, 100000, 90000, true);
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: usdc, amount: order.makerAmount}),
            nonce: order.rfqId,
            deadline: order.expiry
        });
        bytes memory permit2Signature =
            getPermit2Signature(permit, address(pool), MAKER_PRIVATE_KEY, IPermit2(permit2).DOMAIN_SEPARATOR());
        order.permit2Signature = permit2Signature;

        bytes memory orderSignature = signOrder(order, pool.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        vm.prank(TAKER_ADDRESS);
        pool.fillOrderRFQTo(order, orderSignature, order.takerAmount, TAKER_ADDRESS);

        assertEq(IERC20(usdt).balanceOf(MAKER_ADDRESS), 90000);
        assertEq(IERC20(usdc).balanceOf(TAKER_ADDRESS), 100000);
    }
}
