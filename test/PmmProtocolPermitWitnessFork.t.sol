// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/PmmProtocol.sol";
import "forge-std/Test.sol";
import "../src/interfaces/IWETH.sol";
import "../src/interfaces/IPermit2.sol";
import "./helpers/TestHelper.sol";

interface IPMMProtocol {
    function fillOrderRFQTo(
        OrderRFQLib.OrderRFQ memory order,
        bytes calldata signature,
        uint256 flagsAndAmount,
        address target
    ) external returns (uint256, uint256, bytes32);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract PmmProtocolPermitWitnessFork is TestHelper {
    PMMProtocol public pool;
    address constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant usdt = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // `vm.makeAddress()` is not available in older forge-std versions; use a fixed address instead.
    address constant USER = 0x1111111111111111111111111111111111111111;
    // Consideration Witness Struct (matches maker-side signing helpers)
    struct Consideration {
        address token;
        uint256 amount;
        address counterparty;
    }

    bytes32 constant CONSIDERATION_TYPEHASH = keccak256("Consideration(address token,uint256 amount,address counterparty)");
    // NOTE: Permit2 witnessTypeString is appended to the Permit2 stub:
    // "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline," + witnessTypeString
    string constant WITNESS_TYPE_STRING =
        "Consideration witness)Consideration(address token,uint256 amount,address counterparty)TokenPermissions(address token,uint256 amount)";

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

    function testARBPermitWitnessTransfer() public {
        // Create Order
        OrderRFQLib.OrderRFQ memory order =
            createOrder(13579, block.timestamp + 1000, usdc, usdt, MAKER_ADDRESS, 100000, 90000, true);

        // Create Witness Data
        // Bind the Permit2 signature to (token, amount, counterparty=spender)
        Consideration memory witnessData =
            Consideration({token: usdc, amount: order.makerAmount, counterparty: address(USER)});
        bytes32 witness = keccak256(abi.encode(CONSIDERATION_TYPEHASH, witnessData));

        // Set Witness Fields
        order.permit2Witness = witness;
        order.permit2WitnessType = WITNESS_TYPE_STRING;

        // Sign for Permit2 Witness
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: usdc, amount: order.makerAmount}),
            nonce: order.rfqId,
            deadline: order.expiry
        });

        bytes memory permit2Signature = getPermit2WitnessSignature(
            permit, address(pool), witness, WITNESS_TYPE_STRING, MAKER_PRIVATE_KEY, IPermit2(permit2).DOMAIN_SEPARATOR()
        );
        order.permit2Signature = permit2Signature;

        // Sign Order
        bytes memory orderSignature = signOrder(order, pool.DOMAIN_SEPARATOR(), MAKER_PRIVATE_KEY);

        // Execute
        vm.prank(TAKER_ADDRESS);
        pool.fillOrderRFQTo(order, orderSignature, order.takerAmount, TAKER_ADDRESS);

        // Verify Balances
        assertEq(IERC20(usdt).balanceOf(MAKER_ADDRESS), 90000);
        assertEq(IERC20(usdc).balanceOf(TAKER_ADDRESS), 100000);
    }

    // Helper to sign Permit2 Witness Typed Data
    function getPermit2WitnessSignature(
        IPermit2.PermitTransferFrom memory permit,
        address spender,
        bytes32 witness,
        string memory witnessTypeString,
        uint256 privateKey,
        bytes32 domainSeparator
    ) internal pure returns (bytes memory) {
        bytes32 TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

        // The typehash for PermitWitnessTransferFrom includes the witness type definition
        // Construct full type string: "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline," + witnessTypeString
        // Note: The witnessTypeString usually looks like "WitnessType witness)WitnessType(..."

        // We manually reconstruct the type hash logic based on EIP-712 and Permit2 specs
        // Keccak("PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline," + witnessTypeString)

        bytes32 PERMIT_WITNESS_TRANSFER_FROM_TYPEHASH = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                witnessTypeString
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_WITNESS_TRANSFER_FROM_TYPEHASH,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted)),
                spender,
                permit.nonce,
                permit.deadline,
                witness
            )
        );

        bytes32 digest = ECDSA.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}

