// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
// Named imports only — PmmProtocol.sol and PmmAdaptor.sol both transitively declare `IERC20`
// / `SafeERC20` (repo-local vs OpenZeppelin), which collide under a wildcard import.
import {PMMProtocol} from "../src/PmmProtocol.sol";
import {PMMAdapter, CallerAuthData} from "../src/PmmAdaptor.sol";
import {OrderRFQLib} from "../src/OrderRFQLib.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {CallerAuth} from "../src/libraries/CallerAuth.sol";
import {DEX_ROUTER_CALLER_MARKER, MARKER_MASK, ORIGIN_PAYER, _ADDRESS_MASK} from "../src/libraries/Constants.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// @notice End-to-end coverage for the anti-toxic-flow orderType=4 path:
///         allowedSender must match dexRouterCaller and caller binding is enforced on both
///         PmmAdapter (allowedCallers=[DexRouter,DynamicRoute]) and PMMProtocol
///         (allowedCallers=[PmmAdapter]). Drives the real PMMAdapter.sellBase entry with the
///         DexRouter-injected trailing calldata words (dexRouterCaller[-64], refundTo[-32]).
///
/// The V1/V2/V3 legacy `_call` maker-balance paths and the protocol fill/slippage semantics are
/// covered by PmmAdaptor.t.sol / PmmProtocol*.t.sol; this file is scoped to the new V4 surface.
contract PmmProtocolAntiToxicTest is Test {
    PMMProtocol internal protocol;
    PMMAdapter internal adapter;
    MockERC20 internal makerToken;
    MockERC20 internal takerToken;
    MockWETH internal weth;

    // Authorization signer used by caller-auth signatures.
    uint256 internal authSignerKey;
    address internal authSigner;

    // Maker signs the OrderRFQ (EOA maker).
    uint256 internal makerKey;
    address internal maker;

    // On-chain relayers permitted to drive the adapter by the signed allowedCallers set.
    address internal dexRouter = makeAddr("dexRouter");
    address internal dynamicRoute = makeAddr("dynamicRoute");

    // The outermost address directly calling DexRouter — this is what allowedSender must equal.
    address internal dexUser = makeAddr("dexUser");
    // A different outermost caller used to model the address-decoupling attack.
    address internal toxicUser = makeAddr("toxicUser");

    address internal recipient = makeAddr("recipient"); // receives the maker asset (`to`)

    uint256 internal constant RFQ_ID = 42;
    uint256 internal constant MAKER_AMOUNT = 100 ether;
    uint256 internal constant TAKER_AMOUNT = 200 ether;
    uint256 internal constant INITIAL_BALANCE = 1_000 ether;
    uint256 internal constant REFUND_AMOUNT = 1 ether;

    // Monotonic nonce source so each auth tuple gets a fresh nonce.
    uint256 internal _nonceSeq;

    function setUp() public {
        (authSigner, authSignerKey) = makeAddrAndKey("authSigner");
        (maker, makerKey) = makeAddrAndKey("maker");

        weth = new MockWETH();
        makerToken = new MockERC20("MakerToken", "MAKER", 18);
        takerToken = new MockERC20("TakerToken", "TAKER", 18);

        protocol = new PMMProtocol(IWETH(address(weth)), authSigner);
        adapter = new PMMAdapter(authSigner);

        // Maker funds + approvals (non-Permit2 path → direct safeTransferFrom by the protocol).
        makerToken.mint(maker, INITIAL_BALANCE);
        vm.prank(maker);
        makerToken.approve(address(protocol), type(uint256).max);

        vm.warp(1_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                          SIGNING / BUILDERS
    //////////////////////////////////////////////////////////////*/

    function _nextNonce() internal returns (uint256) {
        return ++_nonceSeq;
    }

    /// @dev EIP-2098 compact authorization signature over the CallerAuth `inner` preimage.
    function _signAuth(
        address verifyingContract,
        bytes32 payloadHash,
        address[] memory allowedCallers,
        uint256 nonce,
        uint256 key
    ) internal view returns (bytes memory) {
        bytes32 inner = keccak256(abi.encode(verifyingContract, payloadHash, allowedCallers, nonce, block.chainid));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ethSignedHash);
        bytes32 vs = s | bytes32(uint256(v - 27) << 255);
        return abi.encodePacked(r, vs);
    }

    /// @dev Build a valid CallerAuthData tuple signed by the authorization signer for `verifyingContract`.
    function _auth(address verifyingContract, bytes32 payloadHash, address[] memory allowedCallers)
        internal
        returns (CallerAuthData memory a)
    {
        uint256 nonce = _nextNonce();
        a = CallerAuthData({
            allowedCallers: allowedCallers,
            nonce: nonce,
            authSig: _signAuth(verifyingContract, payloadHash, allowedCallers, nonce, authSignerKey)
        });
    }

    function _single(address x) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = x;
    }

    function _routerSet() internal view returns (address[] memory) {
        address[] memory arr = new address[](2);
        arr[0] = dexRouter;
        arr[1] = dynamicRoute;
        return arr;
    }

    /// @dev Build an orderType=4 order with the given allowedSender.
    function _order(address allowedSender) internal view returns (OrderRFQLib.OrderRFQ memory) {
        return OrderRFQLib.OrderRFQ({
            rfqId: RFQ_ID,
            expiry: block.timestamp + 1 hours,
            makerAsset: address(makerToken),
            takerAsset: address(takerToken),
            makerAddress: maker,
            makerAmount: MAKER_AMOUNT,
            takerAmount: TAKER_AMOUNT,
            usePermit2: false,
            allowedSender: allowedSender,
            confidenceT: 0,
            confidenceWeight: 0,
            confidenceCap: 0,
            permit2Signature: "",
            permit2Witness: bytes32(0),
            permit2WitnessType: ""
        });
    }

    function _signOrder(OrderRFQLib.OrderRFQ memory order) internal view returns (bytes memory) {
        bytes32 orderHash = OrderRFQLib.hash(order, protocol.DOMAIN_SEPARATOR());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, orderHash);
        return abi.encodePacked(r, s, v); // 65-byte EOA signature
    }

    /// @dev Encode the orderType=4 `moreInfo` payload consumed by PMMAdapter._PMMSwap.
    function _moreInfoV4(
        OrderRFQLib.OrderRFQ memory order,
        bytes memory orderSig,
        CallerAuthData memory adaptorAuth,
        CallerAuthData memory protocolAuth
    ) internal pure returns (bytes memory) {
        bytes memory orderInfo = abi.encode(order, adaptorAuth, protocolAuth);
        return abi.encode(orderInfo, orderSig, uint256(0) /* EIP712 */, uint256(4));
    }

    function _markCaller(address caller) internal pure returns (uint256) {
        return DEX_ROUTER_CALLER_MARKER | uint256(uint160(caller));
    }

    /// @dev Invoke adapter.sellBase from `caller`, appending the DexRouter trailing words:
    /// `word64` at calldatasize-64 (dexRouterCaller) and `word32` at calldatasize-32 (refundTo).
    function _sellBase(address caller, bytes memory moreInfo, uint256 word64, uint256 word32)
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes memory data =
            abi.encodeWithSelector(PMMAdapter.sellBase.selector, recipient, address(protocol), moreInfo);
        data = abi.encodePacked(data, word64, word32);
        vm.prank(caller);
        (ok, ret) = address(adapter).call(data);
    }

    /// @dev Full happy-path builder: fund adapter with the taker leg, build both auth tuples,
    /// and return the encoded moreInfo.
    function _buildHappyCall(address allowedSender)
        internal
        returns (bytes memory moreInfo, uint256 adaptorNonce, uint256 protocolNonce)
    {
        takerToken.mint(address(adapter), TAKER_AMOUNT); // full-fill

        OrderRFQLib.OrderRFQ memory order = _order(allowedSender);
        bytes memory orderSig = _signOrder(order);

        CallerAuthData memory protocolAuth = _auth(address(protocol), keccak256(abi.encode(order)), _single(address(adapter)));
        CallerAuthData memory adaptorAuth = _auth(address(adapter), keccak256(abi.encode(order)), _routerSet());
        adaptorNonce = adaptorAuth.nonce;
        protocolNonce = protocolAuth.nonce;

        moreInfo = _moreInfoV4(order, orderSig, adaptorAuth, protocolAuth);
    }

    /*//////////////////////////////////////////////////////////////
                    HAPPY PATH (allowedSender ok)
    //////////////////////////////////////////////////////////////*/

    // allowedSender != 0 and == dexRouterCaller -> settlement succeeds, funds move, order + both
    // caller-auth nonces are consumed.
    function testAllowedSenderMatchesDexRouterCallerFills() public {
        (bytes memory moreInfo, uint256 adaptorNonce, uint256 protocolNonce) = _buildHappyCall(dexUser);

        (bool ok,) = _sellBase(dexRouter, moreInfo, _markCaller(dexUser), 0);
        assertTrue(ok, "orderType=4 happy path must not revert");

        // Maker asset delivered to `to`; taker asset delivered to maker.
        assertEq(makerToken.balanceOf(recipient), MAKER_AMOUNT, "maker asset to recipient");
        assertEq(takerToken.balanceOf(maker), TAKER_AMOUNT, "taker asset to maker");
        // Adapter fully consumed its taker balance (no dust left, no refund path).
        assertEq(takerToken.balanceOf(address(adapter)), 0, "adapter taker balance drained");

        // Order + both auth nonces consumed.
        assertTrue(protocol.isRfqIdUsed(maker, uint64(RFQ_ID)), "rfqId invalidated");
        assertTrue(adapter.isNonceUsed(adaptorNonce), "adaptor auth nonce consumed");
        assertTrue(protocol.isNonceUsed(protocolNonce), "protocol auth nonce consumed");
    }

    // The same order settles when relayed via the second allowed caller; dexRouterCaller is still
    // read from -64 the same way.
    function testSettlesViaDynamicRoute() public {
        (bytes memory moreInfo,,) = _buildHappyCall(dexUser);

        (bool ok,) = _sellBase(dynamicRoute, moreInfo, _markCaller(dexUser), 0);
        assertTrue(ok, "dynamicRoute relay must settle");
        assertEq(makerToken.balanceOf(recipient), MAKER_AMOUNT);
    }

    function testRefund_ExactOriginPayerMarkerRefundsLeftover() public {
        (bytes memory moreInfo,,) = _buildHappyCall(dexUser);
        address refundTo = makeAddr("refundTo");
        takerToken.mint(address(adapter), REFUND_AMOUNT);

        uint256 refundWord = ORIGIN_PAYER | uint256(uint160(refundTo));
        (bool ok,) = _sellBase(dexRouter, moreInfo, _markCaller(dexUser), refundWord);

        assertTrue(ok);
        assertEq(takerToken.balanceOf(refundTo), REFUND_AMOUNT);
        assertEq(takerToken.balanceOf(address(adapter)), 0);
    }

    function testRefund_CallerMarkerAliasIsRejected() public {
        (bytes memory moreInfo,,) = _buildHappyCall(dexUser);
        address forgedRefundTo = makeAddr("forgedRefundTo");
        takerToken.mint(address(adapter), REFUND_AMOUNT);

        uint256 forgedRefundWord = DEX_ROUTER_CALLER_MARKER | uint256(uint160(forgedRefundTo));
        (bool ok,) = _sellBase(dexRouter, moreInfo, _markCaller(dexUser), forgedRefundWord);

        assertTrue(ok);
        assertEq(takerToken.balanceOf(forgedRefundTo), 0);
        assertEq(takerToken.balanceOf(address(adapter)), REFUND_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
              ANTI-TOXIC-FLOW REVERTS
    //////////////////////////////////////////////////////////////*/

    // allowedSender != 0 but != dexRouterCaller -> RFQ_BadSender. This is the core
    // address-decoupling intercept: the maker quoted for `dexUser`, but the swap is relayed with
    // `toxicUser` as the outermost DexRouter caller.
    function testAllowedSenderMismatchReverts() public {
        (bytes memory moreInfo,,) = _buildHappyCall(dexUser);

        (bool ok, bytes memory ret) = _sellBase(dexRouter, moreInfo, _markCaller(toxicUser), 0);
        assertFalse(ok, "mismatched allowedSender must revert");
        assertEq(ret, abi.encodeWithSelector(Errors.RFQ_BadSender.selector, RFQ_ID));

        // No funds moved, order not consumed.
        assertEq(makerToken.balanceOf(recipient), 0);
        assertFalse(protocol.isRfqIdUsed(maker, uint64(RFQ_ID)));
    }

    // allowedSender == address(0) (unset) -> RFQ_BadSender, even when the
    // -64 dexRouterCaller word is itself zero (a would-be "both zero" bypass).
    function testZeroAllowedSenderFailsClosed() public {
        (bytes memory moreInfo,,) = _buildHappyCall(address(0));

        // dexRouterCaller word carries a marker with a zero address -> extracted == address(0).
        (bool ok, bytes memory ret) = _sellBase(dexRouter, moreInfo, DEX_ROUTER_CALLER_MARKER, 0);
        assertFalse(ok, "zero allowedSender must fail closed");
        assertEq(ret, abi.encodeWithSelector(Errors.RFQ_BadSender.selector, RFQ_ID));
    }

    // Fail-closed marker path: allowedSender is a real address, but the -64 word carries a forged
    // marker (high bits all set). `_extractDexRouterCaller` returns address(0) -> mismatch ->
    // RFQ_BadSender. A spoofed marker cannot satisfy the check.
    function testForgedMarkerFailsClosed() public {
        (bytes memory moreInfo,,) = _buildHappyCall(dexUser);

        uint256 forged = MARKER_MASK | uint256(uint160(dexUser)); // wrong marker, right address
        (bool ok, bytes memory ret) = _sellBase(dexRouter, moreInfo, forged, 0);
        assertFalse(ok, "forged marker must fail closed");
        assertEq(ret, abi.encodeWithSelector(Errors.RFQ_BadSender.selector, RFQ_ID));
    }

    // Fail-closed marker path: no marker at all (plain address word) -> extracted address(0) ->
    // RFQ_BadSender.
    function testMissingMarkerFailsClosed() public {
        (bytes memory moreInfo,,) = _buildHappyCall(dexUser);

        uint256 noMarker = uint256(uint160(dexUser)); // address without the marker bits
        (bool ok, bytes memory ret) = _sellBase(dexRouter, moreInfo, noMarker, 0);
        assertFalse(ok, "missing marker must fail closed");
        assertEq(ret, abi.encodeWithSelector(Errors.RFQ_BadSender.selector, RFQ_ID));
    }

    /*//////////////////////////////////////////////////////////////
        ADAPTER CALLER BINDING (allowedCallers=[DexRouter,DynamicRoute])
    //////////////////////////////////////////////////////////////*/

    // An untrusted relayer (not in the signed allowedCallers) is rejected by the
    // adaptor caller-auth BEFORE any settlement → AUTH_UntrustedCaller.
    function testAdapterUntrustedRelayerReverts() public {
        (bytes memory moreInfo,,) = _buildHappyCall(dexUser);

        address rogueRelayer = makeAddr("rogueRelayer");
        (bool ok, bytes memory ret) = _sellBase(rogueRelayer, moreInfo, _markCaller(dexUser), 0);
        assertFalse(ok, "untrusted relayer must revert");
        assertEq(ret, abi.encodeWithSelector(CallerAuth.AUTH_UntrustedCaller.selector));
        // Guard runs before the allowedSender check and before any transfer.
        assertEq(makerToken.balanceOf(recipient), 0);
    }

    function testAdapterOrderPayloadTamperReverts() public {
        takerToken.mint(address(adapter), TAKER_AMOUNT);
        OrderRFQLib.OrderRFQ memory signedOrder = _order(dexUser);
        CallerAuthData memory protocolAuth =
            _auth(address(protocol), keccak256(abi.encode(signedOrder)), _single(address(adapter)));
        CallerAuthData memory adaptorAuth = _auth(address(adapter), keccak256(abi.encode(signedOrder)), _routerSet());

        OrderRFQLib.OrderRFQ memory tamperedOrder = _order(dexUser);
        tamperedOrder.rfqId = RFQ_ID + 1;
        bytes memory tamperedOrderSig = _signOrder(tamperedOrder);

        bytes memory moreInfo = _moreInfoV4(tamperedOrder, tamperedOrderSig, adaptorAuth, protocolAuth);
        (bool ok, bytes memory ret) = _sellBase(dexRouter, moreInfo, _markCaller(dexUser), 0);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(CallerAuth.AUTH_BadAuthSig.selector));
        assertFalse(adapter.isNonceUsed(adaptorAuth.nonce));
    }

    /*//////////////////////////////////////////////////////////////
        PROTOCOL CALLER BINDING (allowedCallers=[PmmAdapter])
    //////////////////////////////////////////////////////////////*/

    // Bypass the adapter and call PMMProtocol.fillOrderRFQTo directly. The caller
    // (an EOA/attacker) is not in the protocol's allowedCallers set → AUTH_UntrustedCaller.
    function testDirectProtocolCallByNonAdapterReverts() public {
        OrderRFQLib.OrderRFQ memory order = _order(dexUser);
        bytes memory orderSig = _signOrder(order);

        // A valid protocol auth naming the adapter as the sole allowed caller.
        CallerAuthData memory protocolAuth = _auth(address(protocol), keccak256(abi.encode(order)), _single(address(adapter)));

        address attacker = makeAddr("directAttacker");
        vm.prank(attacker); // msg.sender = attacker, not the adapter
        vm.expectRevert(CallerAuth.AUTH_UntrustedCaller.selector);
        protocol.fillOrderRFQTo(
            order,
            orderSig,
            0,
            recipient,
            protocolAuth.allowedCallers,
            protocolAuth.nonce,
            protocolAuth.authSig
        );
    }

    function testProtocolOrderPayloadTamperReverts() public {
        OrderRFQLib.OrderRFQ memory signedOrder = _order(dexUser);
        CallerAuthData memory protocolAuth =
            _auth(address(protocol), keccak256(abi.encode(signedOrder)), _single(address(adapter)));

        OrderRFQLib.OrderRFQ memory tamperedOrder = _order(dexUser);
        tamperedOrder.rfqId = RFQ_ID + 1;
        bytes memory tamperedOrderSig = _signOrder(tamperedOrder);

        vm.prank(address(adapter));
        vm.expectRevert(CallerAuth.AUTH_BadAuthSig.selector);
        protocol.fillOrderRFQTo(
            tamperedOrder,
            tamperedOrderSig,
            0,
            recipient,
            protocolAuth.allowedCallers,
            protocolAuth.nonce,
            protocolAuth.authSig
        );
        assertFalse(protocol.isNonceUsed(protocolAuth.nonce));
    }

    // Protocol anti-replay: a protocol auth nonce cannot be reused across two
    // settlements. First fill succeeds; a second fill re-presenting the SAME protocol nonce
    // (fresh order/rfqId, valid re-signature) reverts AUTH_NonceUsed.
    function testProtocolNonceReplayReverts() public {
        // First settlement (consumes a protocol auth nonce).
        (bytes memory moreInfo1,, uint256 protocolNonce) = _buildHappyCall(dexUser);
        (bool ok1,) = _sellBase(dexRouter, moreInfo1, _markCaller(dexUser), 0);
        assertTrue(ok1);
        assertTrue(protocol.isNonceUsed(protocolNonce));

        // Second settlement: a different order (rfqId+1) but reusing the same protocol nonce.
        takerToken.mint(address(adapter), TAKER_AMOUNT);
        OrderRFQLib.OrderRFQ memory order2 = _order(dexUser);
        order2.rfqId = RFQ_ID + 1;
        bytes memory orderSig2 = _signOrder(order2);

        // Reuse protocolNonce with a valid re-signature over that same nonce.
        address[] memory pCallers = _single(address(adapter));
        CallerAuthData memory protocolAuth2 = CallerAuthData({
            allowedCallers: pCallers,
            nonce: protocolNonce,
            authSig: _signAuth(address(protocol), keccak256(abi.encode(order2)), pCallers, protocolNonce, authSignerKey)
        });
        CallerAuthData memory adaptorAuth2 = _auth(address(adapter), keccak256(abi.encode(order2)), _routerSet());

        bytes memory moreInfo2 = _moreInfoV4(order2, orderSig2, adaptorAuth2, protocolAuth2);
        (bool ok2, bytes memory ret2) = _sellBase(dexRouter, moreInfo2, _markCaller(dexUser), 0);
        assertFalse(ok2, "reused protocol nonce must revert");
        // The protocol's AUTH_NonceUsed bubbles through the adapter's `_call`, which remaps the
        // selector to the observable "AUTH_NonceUsed <rfqId>" string (rfqId == order2.rfqId).
        assertEq(
            ret2,
            abi.encodeWithSignature(
                "Error(string)", string(abi.encodePacked("AUTH_NonceUsed ", vm.toString(order2.rfqId)))
            )
        );
    }

}
