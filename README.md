# Web3 Trade PMM - RFQ订单接入文档

## 1. 术语解释

| 术语 | 描述 |
|------|------|
| PMM | Private Market Maker，私有做市商，为特定交易对提供流动性的专业机构 |
| Permit2 | 由Uniswap开发的先进代币授权管理合约，提供更安全高效的代币转账机制 |
| RFQ | Request for Quotation，询价请求，用户向做市商请求特定代币交易报价的业务流程 |

## 2. 背景

当前 OKX Lab Dex 聚合器主要依赖 AMM 模式提供流动性和报价服务。但 AMM 存在交易滑点和 MEV 问题，尤其在大额交易场景下，这影响了整体报价竞争力。基于前期调研与分析，目前优先在 EVM 链实施 RFQ 模式，以迅速提升主流资产报价竞争优势，降低滑点风险，并进一步提升用户交易体验。

### 2.1 文档版本

- **RFQ初始版本**: 参考1inch OrderRFQMixin设计RFQ protocol
- **增加Permit2**: 增加对于permit2的支持

## 3. 概要说明

私有做市商(Private Market Makers) 也可通过RFQ订单的形式接入欧易 DEX 聚合器，为欧易 DEX 上的交易提供流动性。

RFQ (A request for quotation)是一种用户向做市商请求报价以购买某些代币的业务流程。RFQ订单有不同的用例，首先是专门针对做市商的。典型的场景如下：做市商创建一系列询价订单，并通过API公开。交易者或平台算法要求做市商报价。如果报价符合交易者的需求，交易者将收到做市商签署的RFQ订单。

### 3.1 交易流程

1. **API接入** - 做市商通过我们定下的API 接口规范建立 websocket / restful api，必須包括pricing 及 firm-order API
2. **数据同步** - 完成websocket及合約接入及測試流程後，服务端定時从 pricing API 获取该链的所有币对的报价列表数据
3. **价格聚合** - 将这些价格与后端智能路由算法同步，使用户可以在各种 DEX、订单簿和私人做市商中找到最优价格
4. **路径选择** - 用户到我们的平台请求报价和兑换路径，如果 PMM 能提供有竞争力的价格，PMM 订单将进入交易路径
5. **报价返回** - 用户选择币对，服务端返回报价，用户接受报价后从服务端请求交易的 calldata
6. **订单签名** - 若该笔交易涉及做市，服务端通过 firm-order 向做市商请求指定币对和需要成交 makerToken 数量的订单，并完成签名
7. **交易执行** - 用户拿到做市商的签名后用自己的钱包签署交易并广播到区块链
8. **资金流转** - 用戶資金從用戶地址→dexRouter→Adapter→做市商settlementContract，返回時如果需要拆單則是先到Adapter再到用戶地址

### 3.2 主要特点

- **防止订单窃取**：做市商可以指定 allowedSender (tx.origin)
- **单次执行**：订单只能执行一次。第一次部分或全部执行后，订单自动失效  
- **自定义订单到期时间**：做市商可以设置自己的自定义到期时间戳，超过该时间订单将失效
- **支持做市商自定义角色**：支持做市商自定义signer(签名账号)，settler(结算合约)，treasury(资管账号)
- **Permit2 集成**：支持先进的 Permit2 授权机制，提供更安全、更高效的代币转账体验
- **灵活的结算方式**：支持标准转账和自定义结算合约两种模式

### 3.3 订单结构

```solidity
struct OrderRFQ {
    uint256 info;          // 订单信息，实际使用128位，最低64位表示订单ID, 64到128位表示订单超时时间戳
    address makerAsset;    // makerToken地址
    address takerAsset;    // takerToken地址
    address maker;         // maker地址
    address allowedSender; // 指定Taker地址，零地址表示公开订单
    uint256 makingAmount;  // makerToken交易数量
    uint256 takingAmount;  // takerToken交易数量
    address settler;       // 结算合约地址，做市商可以在结算合约中自定义结算逻辑；如果不需要，可以填入零地址
    address treasury;      // 资管账号地址，用于接收takerToken，如果不需要，可以填入零地址
}
```

---

## 4. 智能合约集成

### 4.1 合约事件

```solidity
// 订单成交事件
event OrderFilledRFQ(
    bytes32 orderHash,   // 订单hash
    uint256 refId,       // 订单ID引用
    uint256 makingAmount // makerToken成交数量
);
```

### 4.2 合约方法

#### 查询订单状态

```solidity
/**
 * @notice Returns bitmask for double-spend invalidators based on lowest byte of order.info and filled quotes
 * @param maker Maker address
 * @param slot Slot number to return bitmask for
 * @return result Each bit represents whether corresponding was already invalidated
 */
function invalidatorForOrderRFQ(address maker, uint256 slot) external view returns(uint256);
```

#### 撤销订单（目前不支持）

```solidity
/**
 * 单笔撤销订单
 * @notice Cancels order's quote  
 * @param orderInfo Order info (only order id in lowest 64 bits is used)
 */
function cancelOrderRFQ(uint256 orderInfo) external;

/**
 * 批量撤销订单
 * @notice Cancels multiple order's quotes 
 */
function cancelOrderRFQ(uint256 orderInfo, uint256 additionalMask) external;
```

#### 订单撮合

```solidity
/**
 * 基础订单撮合
 * @notice Fills order's quote, fully or partially (whichever is possible)
 * @param order Order quote to fill
 * @param signature Order signature
 * @param flagsAndAmount Fill configuration flags with amount packed in one slot
 * @return filledMakingAmount Actual amount transferred from maker to taker
 * @return filledTakingAmount Actual amount transferred from taker to maker
 * @return orderHash Hash of the filled order
 */
function fillOrderRFQ(
    OrderRFQLib.OrderRFQ memory order,
    bytes calldata signature,
    uint256 flagsAndAmount
) external payable returns(uint256 filledMakingAmount, uint256 filledTakingAmount, bytes32 orderHash);

/**
 * 紧凑签名订单撮合
 * @notice Fills order's quote, fully or partially (whichever is possible)
 * @param order Order quote to fill
 * @param r R component of signature
 * @param vs VS component of signature
 * @param flagsAndAmount Fill configuration flags with amount packed in one slot
 */
function fillOrderRFQCompact(
    OrderRFQLib.OrderRFQ memory order,
    bytes32 r,
    bytes32 vs,
    uint256 flagsAndAmount
) external payable returns(uint256 filledMakingAmount, uint256 filledTakingAmount, bytes32 orderHash);

/**
 * 指定接收地址的订单撮合
 * @notice Same as `fillOrderRFQ` but allows to specify funds destination instead of `msg.sender`
 * @param order Order quote to fill
 * @param signature Order signature
 * @param flagsAndAmount Fill configuration flags with amount packed in one slot
 * @param target Address that will receive swap funds
 */
function fillOrderRFQTo(
    OrderRFQLib.OrderRFQ memory order,
    bytes calldata signature,
    uint256 flagsAndAmount,
    address target
) external payable returns(uint256 filledMakingAmount, uint256 filledTakingAmount, bytes32 orderHash);

/**
 * 支持Permit功能的订单撮合
 * @notice Same as `fillOrderRFQTo` but calls permit first.
 * It allows to approve token spending and make a swap in one transaction.
 * Also allows to specify funds destination instead of `msg.sender`
 * @param order Order quote to fill
 * @param signature Order signature
 * @param flagsAndAmount Fill configuration flags with amount packed in one slot
 * @param target Address that will receive swap funds
 * @param permit Should contain abi-encoded calldata for `IERC20Permit.permit` call
 */
function fillOrderRFQToWithPermit(
    OrderRFQLib.OrderRFQ memory order,
    bytes calldata signature,
    uint256 flagsAndAmount,
    address target,
    bytes calldata permit
) external returns(uint256 filledMakingAmount, uint256 filledTakingAmount, bytes32 orderHash);
```

#### 数量计算公式

可以通过makingAmount计算出takingAmount：

```
takingAmount = (makingAmount * orderTakingAmount + orderMakingAmount - 1 ) / orderMakingAmount
```

### 4.3 参数说明

#### 4.3.1 flagsAndAmount标志位说明

`flagsAndAmount`类型是uint256，最高250~255位用于存放状态标识，剩余位数用于存放成交金额。

| 位数 | 标识名称 | 说明 |
|-----|---------|------|
| 255位 | `_MAKER_AMOUNT_FLAG` | 存储交易金额方向标识：0-taker方向；1-maker方向 |
| 254位 | `_SIGNER_SMART_CONTRACT_HINT` | 存储是否合约签名标识：0-否；1-是 |
| 253位 | `_IS_VALID_SIGNATURE_65_BYTES` | 存储是否65字节签名标识：0-否；1-是 |
| 252位 | `_UNWRAP_WETH_FLAG` | 存储是否需要执行Unwrap WETH标识：0-否；1-是 |
| 250位 | `_USE_PERMIT2_FLAG` | 存储是否使用Permit2标识：0-否；1-是 |

#### 4.3.2 invalidatorForOrderRFQ方法说明

通过`invalidatorForOrderRFQ`方法可以查询做市商地址在指定slot存储的所有订单状态

**参数：**
- `address maker` - 做市商地址
- `uint256 slot` - 订单所属槽位

订单ID除以256（右移8位）的结果等于该笔订单所属槽位（slot），每个槽位最多存储256笔订单状态。

**示例：**
- `0000......0001` - 表示该槽位第1笔订单已经失效（被成交或者撤单）
- `0000......0101` - 表示该槽位第1笔和第3笔订单已经失效（被成交或者撤单）
- `1000......0101` - 表示该槽位第1笔，第3笔和第256笔订单已经失效（被成交或者撤单）
- `1111......1111` - 表示该槽位全部订单已经失效（被成交或者撤单）

#### 4.3.3 批量撤单参数说明

**参数：**
- `uint256 orderInfo` - orderInfo与订单结构体中info字段相同：实际使用128位，最低64位表示订单ID，64到128位表示订单超时时间戳
- `uint256 additionalMask` - additionalMask是批量撤单位掩码，最多支持256笔订单批量撤单，位掩码规则可参考invalidatorForOrderRFQ方法说明

**示例：**
- `additionalMask = 0000.....0001` - 表示撤销该槽位第1笔订单
- `additionalMask = 0000.....0101` - 表示撤销该槽位第1笔和第3笔订单
- `additionalMask = 1111.....1111` - 标识撤销该槽位全部256笔订单

### 4.4 Permit2 支持

#### 4.4.1 Permit2 概述

Permit2 是由 Uniswap 开发的一个先进的代币授权管理合约，旨在改进传统 ERC20 代币的授权机制。PMM 协议集成了 Permit2 支持，为用户提供更安全、更高效的代币转账体验。

**Permit2 的主要优势：**

- **统一授权管理**：用户只需向 Permit2 合约授权一次，无需为每个协议单独授权
- **精确控制**：支持指定具体的转账金额和有效期
- **节省 Gas**：避免重复的 approve 交易
- **增强安全性**：支持 nonce 机制防止重放攻击
- **更好的用户体验**：减少交易步骤和等待时间

**Permit2 合约地址：**
```
以太坊主网: 0x000000000022D473030F116dDEE9F6B43aC78BA3
BSC: 0x000000000022D473030F116dDEE9F6B43aC78BA3
Arbitrum: 0x000000000022D473030F116dDEE9F6B43aC78BA3
Base: 0x000000000022D473030F116dDEE9F6B43aC78BA3
```

#### 4.4.2 在 PMM 协议中使用 Permit2

在 PMM 协议中，当设置 `_USE_PERMIT2_FLAG` 标志位时，系统将使用 Permit2 进行 maker 资产的转账。

**使用方式：**

1. **做市商准备**：做市商需要先向 Permit2 合约授权其代币
2. **设置标志位**：在 `flagsAndAmount` 中设置 `_USE_PERMIT2_FLAG`（第250位）
3. **执行转账**：协议将通过 Permit2 进行安全转账

#### 4.4.3 Permit2 数据结构

```solidity
interface IPermit2 {
    struct PermitDetails {
        address token;        // ERC20 代币地址
        uint160 amount;       // 允许花费的最大金额
        uint48 expiration;    // 授权过期的时间戳
        uint48 nonce;         // 递增的nonce值，用于防止重放攻击
    }
    
    struct PermitSingle {
        PermitDetails details; // 单个代币授权的详细信息
        address spender;       // 被授权的花费者地址
        uint256 sigDeadline;   // 签名的截止时间
    }
    
    struct PackedAllowance {
        uint160 amount;        // 允许的金额
        uint48 expiration;     // 授权过期时间
        uint48 nonce;          // nonce值
    }
    
    function transferFrom(
        address user,
        address spender, 
        uint160 amount,
        address token
    ) external;
    
    function permit(
        address owner,
        PermitSingle memory permitSingle,
        bytes calldata signature
    ) external;
    
    function allowance(
        address user,
        address token,
        address spender
    ) external view returns (PackedAllowance memory);
}
```

#### 4.4.4 Permit2 使用示例

**步骤1: 做市商向 Permit2 授权代币**

```javascript
// 做市商需要先向 Permit2 合约授权代币
const permit2Address = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const tokenContract = new ethers.Contract(tokenAddress, erc20Abi, makerWallet);

// 授权最大金额给 Permit2
await tokenContract.approve(permit2Address, ethers.constants.MaxUint256);
```

**步骤2: 构建使用 Permit2 的订单**

```javascript
// 构建订单时，通过 flagsAndAmount 启用 Permit2
const USE_PERMIT2_FLAG = 1n << 250n;
const flagsAndAmount = USE_PERMIT2_FLAG | makingAmount;

const order = buildOrderRFQ(
    orderInfo,
    makerAsset,
    takerAsset, 
    maker,
    makingAmount,
    takingAmount,
    settler,
    treasury
);

// 生成订单签名
const signature = await signOrderRFQ(order, chainId, protocolAddress, makerWallet);
```

**步骤3: 执行订单填充**

```javascript
// 调用填充函数，系统将自动使用 Permit2 进行转账
const tx = await pmmProtocol.fillOrderRFQ(
    order,
    signature,
    flagsAndAmount
);
```

#### 4.4.5 Permit2 签名授权（可选）

对于需要动态授权的场景，可以使用 Permit2 的签名授权功能：

```javascript
// EIP-712 域信息
const permit2Domain = {
    name: 'Permit2',
    chainId: chainId,
    verifyingContract: permit2Address
};

// Permit2 签名类型
const permitTypes = {
    PermitSingle: [
        { name: 'details', type: 'PermitDetails' },
        { name: 'spender', type: 'address' },
        { name: 'sigDeadline', type: 'uint256' }
    ],
    PermitDetails: [
        { name: 'token', type: 'address' },
        { name: 'amount', type: 'uint160' },
        { name: 'expiration', type: 'uint48' },
        { name: 'nonce', type: 'uint48' }
    ]
};

// 构建授权消息
const permitMessage = {
    details: {
        token: tokenAddress,
        amount: amount,
        expiration: expiration,
        nonce: nonce
    },
    spender: spenderAddress,
    sigDeadline: deadline
};

// 生成签名
const permitSignature = await makerWallet._signTypedData(
    permit2Domain,
    permitTypes,
    permitMessage
);

// 调用 Permit2 授权
await permit2Contract.permit(
    makerAddress,
    permitMessage,
    permitSignature
);
```

#### 4.4.6 最佳实践

**做市商建议：**

1. **预先授权**：在开始做市之前，预先向 Permit2 授权所有需要的代币
2. **监控授权**：定期检查 Permit2 的授权额度，必要时进行补充授权
3. **Gas 优化**：使用 Permit2 可以显著降低交易的 Gas 成本

**用户建议：**

1. **理解机制**：了解 Permit2 的工作原理，确保安全使用
2. **验证合约**：确认 Permit2 合约地址的正确性
3. **管理授权**：定期审查和管理代币授权

### 4.5 结算合约（可选）

做市商可以在结算合约中自定义结算处理逻辑，结算合约必须实现以下接口：

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IPMMSettler {
    /**
     * @notice Interface for interactor which acts for `maker -> taker` transfers.
     * @param taker Taker address
     * @param token Settle token address
     * @param amount Settle token amount
     * @param isUnwrap Whether unwrap WETH
     */
    function settleToTaker(
        address taker,
        address token,
        uint256 amount,
        bool isUnwrap
    ) external;

    /**
     * @notice Returns the settlement treasury address.
     */
    function getTreasury() external view returns (address);
}
```

#### 结算合约实现示例

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IPMMSettler.sol";
import "./interfaces/IWETH.sol";
import "./libraries/SafeERC20.sol";

contract PMMSettlerDemo is IPMMSettler, Ownable {
    using SafeERC20 for IERC20;

    uint256 private constant _RAW_CALL_GAS_LIMIT = 5000;
    IWETH private immutable _WETH;
    address _TREASURY;

    constructor(IWETH weth) {
        _WETH = weth;
    }

    function setTreasury(address treasury) public onlyOwner {
        _TREASURY = treasury;
    }

    function getTreasury() external view returns (address) {
        return _TREASURY;
    }

    function settleToTaker(
        address taker,
        address token,
        uint256 amount,
        bool isUnwrap
    ) external {
        require(taker != address(0), "zero address");
        require(amount > 0, "amount must be greater than zero");
        
        if (isUnwrap) {
            _WETH.transferFrom(_TREASURY, address(this), amount);
            _WETH.withdraw(amount);
            (bool success, ) = taker.call{
                value: amount,
                gas: _RAW_CALL_GAS_LIMIT
            }("");
            require(success, "settleToTaker failed");
        } else {
            IERC20(token).safeTransferFrom(_TREASURY, taker, amount);
        }
    }

    receive() external payable {
        require(msg.sender == address(_WETH), "Eth deposit rejected");
    }
}
```

---

## 5. API 接口规范

> **注意**: 做市商需要提供以下两个API

### 接入要求
- BD对接
- 按照规范提供相应的API
- 如果需要自定义结算合约，则阅读"4.5 结算合约"章节查看具体智能合约架构及结算合约接口配置
- **Permit2 集成**（推荐）：为获得更好的用户体验和更低的 Gas 成本，建议做市商向 Permit2 合约授权代币，详见"4.4 Permit2 支持"章节

### 5.1 请求报价接口

**接口说明**：获取全量报价数据，包含币对信息、每档报价及深度

**请求方式**：`GET /levels`

**响应示例**：
```json
{
    "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2_0xdac17f958d2ee523a2206206994597c13d831ec7": [
        ["4083.38", "0.005"],
        ["4083.38", "1.2172"],
        ["4083.2", "0.005"],
        ["4083.2", "0.040"],
        ["4083.1", "0.1122534"],
        ["4082.78", "0.70018422"]
    ],
    "0xdac17f958d2ee523a2206206994597c13d831ec7_0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": [
        ["0.000244553189095862","20.44545"],
        ["0.000244553189095862", "5471.949504"],
        ["0.0002356123123", "1000.2342"]
    ]
}
```

### 5.2 请求订单和签名接口

**接口说明**：欧易会以下方地址来请求相关数据，须符合规范，允许您获得指定数量的指定币对的订单和签名

**请求方式**：`POST /order`

**请求参数**：
- `baseToken` - takerToken地址
- `quoteToken` - makerToken地址  
- `amount` - takerToken数量
- `taker` - taker地址
- `refId` - 订单ID
- `expiryDuration` - 订单有效期（秒），默认90秒

**请求示例**：
```json
{
    "baseToken": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",  // Address of takerToken
    "quoteToken": "0xdac17f958d2ee523a2206206994597c13d831ec7",  // Address of makerToken
    "amount": "6000000000000000",                                 // Quantity of takerToken
    "taker": "taker address",                                      // Address of order taker
    "refId": "123456789",                                          // Order ID
    "expiryDuration": "90"                                         // Expiry duration in seconds
}
```

**info字段拼接规则**：
```javascript
uint128 info = uint64(refId) << 64 + uint64(expiry_timestamp)
```

**响应参数说明**：

| 字段名 | 说明 | 备注 |
|-------|------|------|
| `info` | 订单信息<br/>- 前64位是订单ID<br/>- 后64位是订单超时时间戳 | 订单ID由OKX请求时传入，超时时间默认是timestamp + 90秒 |
| `makerAsset` | 做市商需要交易资产 | |
| `takerAsset` | 用户需要资产 | |
| `maker` | 做市商签名地址 | |
| `allowedSender` | 指定taker地址，如果设为0地址，则为完全公开订单 | 默认为address(0)。如果需要设定特定taker能够吃单，需要设置为请求中的taker值 |
| `makingAmount` | 需要成交做市商资产数量 | |
| `takingAmount` | 需要成交用户资产数量 | |
| `settler` | 指定做市商自定义结算合约（如果无结算合约，则需返回零地址） | 默认为address(0) |
| `treasury` | 指定做市商资管账号地址（如果不需要，则需返回零地址） | 默认为address(0) |
| `signature` | 订单签名（签名格式需要参考下方EIP712签名示例） | |

> **Permit2 支持说明**：做市商在返回订单时，系统会根据做市商的配置自动处理 Permit2 相关逻辑。如果做市商已向 Permit2 合约授权，系统可能会在 `flagsAndAmount` 中设置 `_USE_PERMIT2_FLAG` 标志位以启用 Permit2 转账机制。

**响应示例**：
```json
{
    "order": {
        "info": "30267040123324574557115271801",
        "makerAsset": "0xdac17f958d2ee523a2206206994597c13d831ec7",
        "takerAsset": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        "maker": "maker address",
        "allowedSender": "0x0000000000000000000000000000000000000000",
        "makingAmount": "22723800",
        "takingAmount": "6000000000000000",
        "settler": "0x0000000000000000000000000000000000000000",
        "treasury": "0x0000000000000000000000000000000000000000"
    },
    "signature": "0xc64bf62b7619edda019fe491da256b9fbe892fbfeac91f9d1fce168478ad53053dde038584f063fe21e267fcb4e758bcf420036cd2838fe5cbd993ec6d3dde561b"
}
```

### 5.3 EIP712订单签名示例

下单采用EIP712协议，用户签名时可以查看签名内容

```javascript
const name = 'OKX PMM Protocol';
const version = '1.0';

const OrderRFQ = [
    { name: 'info', type: 'uint256' },
    { name: 'makerAsset', type: 'address' },
    { name: 'takerAsset', type: 'address' },
    { name: 'maker', type: 'address' },
    { name: 'allowedSender', type: 'address' },
    { name: 'makingAmount', type: 'uint256' },
    { name: 'takingAmount', type: 'uint256' },
    { name: 'settler', type: 'address' },
    { name: 'treasury', type: 'address' },
];

// 构建RFQ订单对象
function buildOrderRFQ(
    info,
    makerAsset,
    takerAsset,
    maker,
    makingAmount,
    takingAmount,
    settler,
    treasury,
    allowedSender = constants.ZERO_ADDRESS,
) {
    return {
        info,
        makerAsset,
        takerAsset,
        maker,
        allowedSender,
        makingAmount,
        takingAmount,
        settler,
        treasury,
    };
}

// 构建签名data
function buildOrderRFQData(chainId, verifyingContract, order) {
    return {
        domain: { name, version, chainId, verifyingContract },
        types: { OrderRFQ },
        value: order,
    };
}

// 订单签名
async function signOrderRFQ(order, chainId, target, wallet) {
    const orderData = buildOrderRFQData(chainId, target, order);
    return await wallet._signTypedData(orderData.domain, orderData.types, orderData.value);
}   

// 使用示例
// 1.构建RFQ订单对象
const order = buildOrderRFQ(
    salt, 
    dai.address, 
    weth.address, 
    maker.address, 
    1, 
    1, 
    constants.ZERO_ADDRESS, 
    constants.ZERO_ADDRESS
);

// 2.生成订单签名
const signature = await signOrderRFQ(order, chainId, swap.address, maker);

// 3.使用 Permit2 的示例（可选）
// 如果要启用 Permit2，需要在 flagsAndAmount 中设置相应标志位
const USE_PERMIT2_FLAG = 1n << 250n;  // _USE_PERMIT2_FLAG
const makingAmount = ethers.utils.parseEther("1");
const flagsAndAmountWithPermit2 = USE_PERMIT2_FLAG | makingAmount;

// 调用填充函数
const tx = await pmmProtocol.fillOrderRFQ(
    order,
    signature, 
    flagsAndAmountWithPermit2  // 启用 Permit2
);
```

---

## 6. 英文版本

> **注意**: 本文档提供中英文双语版本，英文版本请参考[English Documentation](./README_EN.md)

---

> **文档版本**: v2.0  
> **最后更新**: 2024年