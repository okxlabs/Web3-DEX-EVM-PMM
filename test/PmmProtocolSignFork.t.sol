pragma solidity ^0.8.0;

import "../src/PmmProtocol.sol";
import "forge-std/Test.sol";

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

contract PmmProtocolSignFork is Test {
    IPMMProtocol pool;
    address adapter;
    address marketMaker;
    address constant usdt = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function setUp() public {
        // 2025-07-18
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", 358947139);
        pool = IPMMProtocol(0x8C3D3bbE4D5a41349Db248fc2436442d4968Cb7b);
        // Adapter: 0x19244841F215b6FB016736C5c735B9B065d9890B
        // Market Maker: 0x80C0664922CF70a9c38e131861403c428F36C035
        adapter = 0x19244841F215b6FB016736C5c735B9B065d9890B;
        marketMaker = 0x80C0664922CF70a9c38e131861403c428F36C035;
    }

    function testForkARB() public {
        // Swap usdt to usdc, mark price as 1 : 0.99
        console2.log("test here");

        deal(usdt, adapter, 10000e18);
        deal(usdc, marketMaker, 10000e18);
        console2.log("ETH balance of adapter is %s", adapter.balance);
        console2.log("ETH balance of marketMaker is %s", marketMaker.balance);

        console2.log("USDT balance of adapter is %s", IERC20(usdt).balanceOf(adapter));
        console2.log("USDT balance of market maker is %s", IERC20(usdt).balanceOf(marketMaker));

        console2.log("USDC balance of adapter is %s", IERC20(usdc).balanceOf(adapter));
        console2.log("USDC balance of market maker is %s", IERC20(usdc).balanceOf(marketMaker));
        // 1. Adapter approves token to pool.
        vm.prank(adapter);
        IERC20(usdt).approve(address(pool), type(uint256).max);
        // 2. Market Maker approves to pool.
        vm.prank(marketMaker);
        IERC20(usdc).approve(address(pool), type(uint256).max);
        // 3. Market Maker Sign EIP-712.

        // // PMM settlement contract (`pool` as adapter's perspective)
        // 2025-07-15 00:00:00 -> 1752508800

        // verifyingContract: "0x49D1552890a39F7bD8Af29142e4EB780e90a216a",
        // chainId: 42161,
        // order: {
        //     rfqId: 13579,
        //     expiry: 1752508800,
        //     makerAsset: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
        //     takerAsset: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9",
        //     makerAddress: "0x80C0664922CF70a9c38e131861403c428F36C035",
        //     makerAmount: ethers.parseUnits("0.099", 6),
        //     takerAmount: ethers.parseUnits("0.1", 6),
        // },

        // Signature: 0xc09e1c273e878a69608e516ee103072dfccc3ca65845ed65da27abb87bf4057b2ad83ac7480ac9882c231b802b61715d8ba5401bc2cb05dec764565e0d8bc0931b
        bytes memory sig =
            hex"8a69101201852541a233b1319ad5dbcf77f985b978026c61e952010de28c73b616aa38eb3fee2b22dda80da2da11ceb15979f9be582a8a12c8df7f15969a78c31c";

        // 4. Adapter calls fillOrderRFQTo of Pool.
        vm.prank(adapter);
        IPMMProtocol.OrderRFQ memory order = IPMMProtocol.OrderRFQ({
            rfqId: 115603785001049152,
            expiry: 1752831163,
            makerAsset: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            takerAsset: 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9,
            makerAddress: 0xF29a02DB18196745795cc3e7B2f3AeE405389f17,
            makerAmount: 1125000,
            takerAmount: 1000000,
            usePermit2: false
        });
        pool.fillOrderRFQTo(order, sig, 1000000, adapter);

        // 5. Check balance of each role.
        console2.log("USDT balance of adapter is %s", IERC20(usdt).balanceOf(adapter));
        console2.log("USDT balance of market maker is %s", IERC20(usdt).balanceOf(marketMaker));

        console2.log("USDC balance of adapter is %s", IERC20(usdc).balanceOf(adapter));
        console2.log("USDC balance of market maker is %s", IERC20(usdc).balanceOf(marketMaker));
    }
}
