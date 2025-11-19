pragma solidity ^0.8.0;

import "../src/PmmProtocol.sol";
import "forge-std/Test.sol";
import "../src/interfaces/IWETH.sol";
import "../src/interfaces/IPermit2.sol";

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

    function fillOrderRFQTo(OrderRFQ memory order, bytes calldata signature, uint256 flagsAndAmount, address target)
        external
        returns (uint256, uint256, bytes32);
}

contract PmmProtocolPermit2Fork is Test {
    IPMMProtocol pool;
    address adapter;
    address marketMaker;
    address constant usdt = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {
        // 2025-07-16
        vm.createSelectFork("https://eth-mainnet.nodereal.io/v1/1659dfb40aa24bbb8153a677b98064d7");
        // pool = IPMMProtocol(0x49D1552890a39F7bD8Af29142e4EB780e90a216a);
        pool = IPMMProtocol(0x8C3D3bbE4D5a41349Db248fc2436442d4968Cb7b);
        // Adapter: 0x19244841F215b6FB016736C5c735B9B065d9890B
        // Market Maker: 0x80C0664922CF70a9c38e131861403c428F36C035
        adapter = 0x19244841F215b6FB016736C5c735B9B065d9890B;
        marketMaker = 0x80C0664922CF70a9c38e131861403c428F36C035;
    }

    function testARBPermit2() public {
        vm.startPrank(marketMaker);
        SafeERC20.forceApprove(IERC20(usdc), PERMIT2, type(uint256).max);
        // 2035-07-16
        IPermit2(PERMIT2).approve(usdc, address(pool), type(uint160).max, 2068195245);
        vm.stopPrank();

        vm.prank(adapter);
        SafeERC20.forceApprove(IERC20(usdt), address(pool), type(uint256).max);

        bytes memory sig =
            hex"ff4cad1f96187ddb47102dd2b800150e8533b0d0f009e86474fcbd3576d07afa4b89d3028bc23781416b1573282552c35f8462923550599724cb2fd2e85d79751c";

        IPMMProtocol.OrderRFQ memory order = IPMMProtocol.OrderRFQ({
            rfqId: 13578,
            expiry: 2068195245,
            makerAsset: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            takerAsset: 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9,
            makerAddress: 0x80C0664922CF70a9c38e131861403c428F36C035,
            makerAmount: 101000,
            takerAmount: 100000,
            usePermit2: true
        });

        vm.prank(adapter);
        pool.fillOrderRFQTo(order, sig, 100000, adapter);
    }
}
