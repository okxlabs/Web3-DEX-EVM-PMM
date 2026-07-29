# Research & Design Note — EVM RFQ 防套利 · allowedSender 校验 (本仓)

- **Requirement**: SCDEX-1157 — EVM-RFQ-anti-toxic-flow-PRD-v0.2
- **Repo (canonical for these changes)**: `GitHub-Web3-DEX-EVM-PMM`
- **PRD source of truth**: `tmp/prd.md` (v0.2, 2026-07-03, 张路 Amy Zhang)
- **本仓交付范围**: FR-5、FR-3（在 PmmAdapter/PMMProtocol 上验证）、FR-6-AC-1
- **本仓 Out of Scope**: FR-1 / FR-2 / FR-4；FR-5 的 DynamicRoute/NativePmmAdapter 落地；DexRouter 的 `dexRouterCaller` 注入（本仓测试用 mock 注入 `-64`）

> 权威优先级：PRD 是"被改动行为"的唯一 source of truth。context-kg / 现有 V1/V2/V3 合约仅对"不变的约定与向后兼容"权威，不作为新行为模板。本设计与 PRD §目标设计 一致，无偏离项；如后续实现需偏离 PRD 某条，必须标注「偏离 PRD §X + 理由」。

---

## 1. Scope 摘要

| 交付单元 | 负责的 FR/AC | 对本仓属 Out of Scope |
|---------|------------|---------------------|
| Web3-DEX-EVM（他仓） | FR-1、FR-2、FR-3（DynamicRoute/NativePmmAdapter）、FR-4、FR-6-AC-2 | — |
| **Web3-DEX-EVM-PMM（本仓）** | **FR-5、FR-3（PmmAdapter/PMMProtocol）、FR-6-AC-1** | FR-1/FR-2/FR-4；DexRouter 注入（用 mock） |

**背景（Motivation）**：PMM/RFQ firm-quote 模式下套利者用「地址解耦」攻击：干净地址询价、未审地址成交。经 adapter 调用 PMM 时，PMM 看到的 `msg.sender` 是 adapter 地址 → MM 的 allowedSender / 黑名单 / 费率风控全部失效。本次通过 (a) 订单内新增必填 `allowedSender`，(b) 在 PmmAdapter 处校验 `allowedSender == dexRouterCaller`（从 calldata `-64` 读取最外层直连 DexRouter 的地址），(c) 用 OKX 后端签名做调用方绑定，把成交入口收敛到唯一函数，堵住地址解耦与绕过路径。

---

## 2. 现状调研（受影响合约 / 接口 / 事件 / 存储 / 修饰符 / 测试约定）

### 2.1 `src/OrderRFQLib.sol`（MODIFY）
- `struct OrderRFQ` 现有 **14 字段**，顺序：`rfqId, expiry, makerAsset, takerAsset, makerAddress, makerAmount, takerAmount, usePermit2, confidenceT, confidenceWeight, confidenceCap, permit2Signature, permit2Witness, permit2WitnessType`。
- `_LIMIT_ORDER_RFQ_TYPEHASH` 与 `hash()` 的 `abi.encode` 顺序必须与 struct **三处一致**。
- 编码规则（CLAUDE.md）：`bytes` 字段 `keccak256(...)`；`string` 字段 `keccak256(bytes(...))`；`bytes32` 字段直接编码不 hash。

### 2.2 `src/EIP712.sol`（MODIFY）
- 抽象合约，构造 `EIP712(name, version)`；domain typehash = `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)`；domain separator 缓存 `chainId + verifyingContract`（KG 最高授权规则：任何 EIP712 改动必须保留这两者）。
- 当前 `version` 由 `PMMProtocol._VERSION = "1.1"` 传入。

### 2.3 `src/PmmProtocol.sol`（MODIFY，命名 `contract PMMProtocol`）
- 继承 `EIP712, ReentrancyGuard`；构造 `constructor(IWETH weth)`；`_NAME="OKX Labs PMM Protocol"`，`_VERSION="1.1"`。
- **现有四个成交入口**（均需按 PRD 收敛/移除）：
  - `fillOrderRFQ(order, signature, flagsAndAmount)` → 转 `fillOrderRFQTo(...,msg.sender)`
  - `fillOrderRFQCompact(order, r, vs, flagsAndAmount)` `nonReentrant`
  - `fillOrderRFQToWithPermit(order, signature, flagsAndAmount, target, permit)`
  - `fillOrderRFQTo(order, signature, flagsAndAmount, target)` `public payable nonReentrant` — 核心
- 内部 `_fillOrderRFQTo(order, flagsAndAmount, target)`：过期检查 → `_invalidateOrder`（CEI，先失效再转账）→ 部分成交计算 → 60% 结算下限（`_SETTLE_LIMIT=6000/_SETTLE_LIMIT_BASE=10000`）→ 时间滑点（`_CONFIDENCE_CAP_LIMIT=50000` = 5%，1e6 单位）→ maker→taker 转账（Permit2 / permitWitness / allowance / safeTransferFrom）→ WETH unwrap（低级 call 检查返回值，失败 `RFQ_ETHTransferFailed`）→ taker→maker。
- 事件：`OrderFilledRFQ(...)`（13 参数）、`OrderCancelledRFQ(rfqId, maker)`。
- 存储：`IWETH private immutable _WETH`；`mapping(address=>mapping(uint256=>uint256)) private _invalidator`（nonce 位图，maker 维度）。
- **无特权角色**：现仅靠 EIP-712 签名授权，无 onlyAdaptor（KG「no privileged roles」）；PRD 要求新增 CallerAuth 调用方绑定。

### 2.4 `src/PmmAdaptor.sol`（MODIFY，命名 `contract PMMAdapter`）
- 无状态、无构造参数（`constructor(){}`）；不继承 CallerAuth / ReentrancyGuard（PRD 要求补上）。
- 现有常量内联：`ORIGIN_PAYER = 0x3ca20afc2ccc...`、`ADDRESS_MASK = 0x0000...ffff...`（PRD 要求改为从新建 `Constants.sol` 引用，并清掉旧名 `REAL_PAYER_MARKER`——本仓当前未见该旧名，实现时确认）。
- 入口 `sellBase/sellQuote(to, pool, moreInfo)` → 汇编从 calldata **`-32`** 读 `payerOrigin`（refund 路由）→ `_PMMSwap`。
- `_PMMSwap` 解码 `moreInfo = abi.decode(_, (bytes orderInfo, bytes signature, uint256 signatureType, uint256 orderType))`；`orderType ∈ {1,2,3}` 分派 V1/V2/V3；`else → revert("PMMAdapter: unsupported orderType")`。
- `_executeVxOrder`：读 adapter 自身 takerAsset 余额→ approve pool → 组 `flagsAndAmount` → `_call(pool, fillOrderRFQTo.selector 编码, rfqId[, balanceCheck])` → `_handleRefund`。
- `_call` 大量 selector→string 错误映射；新增错误 `RFQ_BadSender` 及 CallerAuth 的 `OSA_*` 需在此映射（否则回退到 `RFQ_Failed`）。
- **注意**：现有 `_handleRefund` 用 `-32`（`ORIGIN_PAYER` marker）读 refundTo；PRD 布局 `… , dexRouterCaller@-64 , refundTo@-32`——`dexRouterCaller` 在 **`-64`**，refundTo 仍在 `-32`，两者并存不冲突。

### 2.5 `src/libraries/Errors.sol`（MODIFY）
- 现 14 个 `RFQ_*` 自定义错误，每个带 `rfqId`。需新增 `RFQ_BadSender`（PRD AC 明确错误串 `"RFQ_BadSender"`）。CallerAuth 的 `OSA_*` 错误按 PRD §A0 定义（可置于 CallerAuth 内或 Errors.sol，实现时定；本仓 canonical CallerAuth 文件自带）。

### 2.6 `src/libraries/ECDSA.sol`（READ-ONLY）
- 提供 `recover`（65/64-byte EIP-2098 compact）、`isValidSignature`(ERC-1271)、`toTypedDataHash`、`toEthSignedMessageHash`（EIP-191 `\x19Ethereum Signed Message:\n32`）。CallerAuth 的 EIP-2098 64-byte 校验与 EIP-191 消息哈希可复用此库，无需改动。

### 2.7 新建文件
- `src/libraries/Constants.sol`（CREATE）— 四个常量（值见 §5）。
- `src/libraries/CallerAuth.sol`（CREATE）— 抽象合约，**两仓字节级同一文件（canonical）**。

### 2.8 测试约定（`context-kg/technical/conventions/testing-patterns.md` + A-01）
- Foundry `forge test`；测试在 `test/`，helpers/mocks 在 `test/helpers` `test/mocks`。
- 签名用 `vm.sign(pk, digest)`；测试地址用 `makeAddrAndKey("label")`；**禁止硬编码私钥/明文助记词**。
- 现有回归套件：`PmmProtocol.t.sol`(9)、`PmmProtocolTimeSlippage.t.sol`(17)、`PmmAdaptor.t.sol`(24) = **50 通过**（Fork 套件因 RPC 排除）。基线干净。
- 已知：`MockMarketMaker` 仍是 V3 struct（testing-patterns 标注 "Out-of-Sync"）——新增 allowedSender 字段后，mock/helper 的订单构造需同步更新。

---

## 3. 实现方案（Approach）

按 PRD §目标设计「五处改动」+ §A0 CallerAuth：

1. **`Constants.sol`（新建）** — 定义四常量（§5），供 PmmAdapter / CallerAuth 引用；PmmAdapter 内联常量改为引用，清理旧名。
2. **`OrderRFQLib`（加 `allowedSender`）** — 在 `usePermit2` 之后、`confidenceT` 之前插入 `address allowedSender`；struct 顺序 == type string 顺序 == `hash()` 的 `abi.encode` 顺序（三处一致）；typehash 破坏性变更 → domain `version` 升 **`1.2`**。语义：必填非零（校验在 PmmAdapter，PMMProtocol 内严禁做 allowedSender 校验）。
3. **`EIP712.sol` / `PMMProtocol._VERSION`** — `version` → **`1.2`**。
4. **`PMMProtocol`（唯一入口 + CallerAuth 绑定）**：
   - 继承 `CallerAuth`；构造 `constructor(IWETH weth, address okxSigner)`（透传 okxSigner 给 CallerAuth）。
   - 成交入口收敛为唯一：`fillOrderRFQTo(order, signature, flagsAndAmount, target, address[] allowedCallers, uint256 nonce, uint256 expiry, bytes okxSig)`；首行 `_verifyCallerAuth(allowedCallers, nonce, expiry, okxSig)`（业务上 allowedCallers=[PmmAdapter]）。
   - 移除 `fillOrderRFQ` / `fillOrderRFQCompact` / `fillOrderRFQToWithPermit`（破坏性收敛，PRD 明确要求）。
   - 保留 `nonReentrant`、CEI、`_invalidateOrder` 先于转账、WETH call 返回值检查等 KG 硬规则。
5. **`PmmAdapter`（orderType=4 新路径）**：
   - 继承 `CallerAuth` 与 `ReentrancyGuard`；构造 `constructor(address okxSigner)`；`sellBase/sellQuote` 加 `nonReentrant`。
   - orderType=4：`orderInfo = abi.encode(OrderRFQ order, OkxAuth adaptorAuth, OkxAuth protocolAuth)`。
   - 先 `_verifyCallerAuth(adaptorAuth…)`（allowedCallers=[DexRouter, DynamicRoute]）。
   - 核心防套利校验：`if (order.allowedSender == address(0) || order.allowedSender != dexRouterCaller) revert RFQ_BadSender;`
   - `dexRouterCaller = _extractDexRouterCaller()`：读 calldata `-64`，`word & MARKER_MASK == DEX_ROUTER_CALLER_MARKER`（**精确匹配，非子集**）→ 低 20 字节为地址；marker 缺失/伪造 → 返回 `address(0)`（fail-closed）。
   - 调用 PMMProtocol 唯一成交入口，`protocolAuth` 原样转发。
   - **V1/V2/V3 旧 orderType 路径保持不变**（向后兼容，FR-6-AC-1）；`-64` 读取仅在 orderType=4 生效。
6. **CallerAuth（§A0，canonical 双仓同文件）**：
   - `address public immutable OKX_SIGNER`。
   - `_verifyCallerAuth(address[] allowedCallers, uint256 nonce, uint256 expiry, bytes okxSig)`：验签（OKX 后端 EIP-191 签名式）、`expiry` 检查、`msg.sender ∈ allowedCallers`、nonce 位图防重放。
   - `_verifyNativeAuth(...)`（仅 NativePmmAdapter 用，本仓不涉及）。
   - `_extractDexRouterCaller()`（读 -64，按 MARKER_MASK 精确校验）。
   - EIP-2098 compact 64-byte 签名；nonce 位图（Permit2 风格）；`view isNonceUsed(uint256 nonce)`。
   - Errors：`OSA_ZeroSigner / OSA_Expired / OSA_UntrustedCaller / OSA_BadOkxSig / OSA_BadSigLen / OSA_NonceUsed`。

---

## 4. 边界 / 向后兼容 / 风险

**向后兼容策略**
- V1/V2/V3 orderType 路径与 `_call` 语义、既有事件/成功路径不变（FR-6-AC-1 回归全绿）。
- `-64` 读取只在 orderType=4 触发；refund 仍读 `-32`，两 marker（`DEX_ROUTER_CALLER_MARKER` @-64 / `ORIGIN_PAYER` @-32）互不干扰。
- **破坏性变更（PRD 明确要求，非兼容项）**：① OrderRFQ 新增字段 → typehash 变化 → domain version 升 `1.2`（旧签名对新合约失效，符合 EIP-712 replay 防护）；② PMMProtocol 移除 3 个 fill 变体、`fillOrderRFQTo` 签名扩展。链上已部署 V3 合约不受影响（新合约独立部署）。

**边界**
- `allowedSender` 必填非零，零地址 fail-closed（AC-3）。
- marker 精确匹配（`== DEX_ROUTER_CALLER_MARKER`），伪 marker / 缺失 → `dexRouterCaller=0` → 触发 BadSender fail-closed。
- 直连 DexRouter 与经 DynamicRoute 两条路径，`dexRouterCaller` 均为「直连 DexRouter 的最外层地址」（AC-4）。

**风险点**
- R1: OrderRFQLib 三处（struct / type string / abi.encode）不一致 → 签名恒失败。**Mitigation**: Stage 3 加 typehash/digest 断言测试。
- R2: PMMProtocol 移除 fill 变体属破坏性，外部集成方/脚本/`script/*.js`、`.claude/skills/pmm-settle` 需同步（Stage 5 KG 回写 + 文档）。
- R3: `_call` 未映射 `RFQ_BadSender` / `OSA_*` 新 selector → 错误退化为 `RFQ_Failed`，影响可观测性。**Mitigation**: 在 `_call` 补 selector 映射。
- R4: nonce 位图与 OKX 后端 nonce 分配须对齐（防重放且不误伤并发）——后端硬不变量，属跨仓约定（见 §6）。
- R5: `MockMarketMaker`/helper 仍 V3 struct，新增字段后测试构造需全量更新，否则回归假失败。
- R6: EIP-191 `okxSig` preimage 布局须与 OKX 后端一致——由 canonical CallerAuth.sol 固定（见 §6 external_deps）。

---

## 5. 常量（PRD §目标设计 / cross-repo-sync，原文保留）

| 常量 | 值 |
|------|----|
| `DEX_ROUTER_CALLER_MARKER` | `0x3ca20afc2ddd0000000000000000000000000000000000000000000000000000` |
| `MARKER_MASK` | `0xffffffffffff0000000000000000000000000000000000000000000000000000` |
| `ORIGIN_PAYER` | `0x3ca20afc2ccc0000000000000000000000000000000000000000000000000000` |
| `_ADDRESS_MASK` | `0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff` |
| Domain `version` | `1.2` |
| Domain `name` | `OKX Labs PMM Protocol`（不变） |
| calldata 布局 | `… , dexRouterCaller@-64 , refundTo@-32` |
| PmmAdapter allowedCallers | `[DexRouter, DynamicRoute]` |
| PMMProtocol allowedCallers | `[PmmAdapter]` |
| BadSender 错误串 | `RFQ_BadSender` |
| CallerAuth errors | `OSA_ZeroSigner / OSA_Expired / OSA_UntrustedCaller / OSA_BadOkxSig / OSA_BadSigLen / OSA_NonceUsed` |
| allowedSender 字段位置 | 插在 `usePermit2` 之后、`confidenceT` 之前 |

---

## 6. 外部 / 跨 repo 依赖（external_deps）

已锁定（PRD / cross-repo-sync.md 提供，非阻塞）：
- **calldata 布局**：`dexRouterCaller@-64, refundTo@-32`；marker/mask 值见 §5。DexRouter 侧注入已在他仓实现，本仓只读；本仓测试用 mock 注入 `-64`。
- **allowedCallers 取值**：PmmAdapter=[DexRouter, DynamicRoute]，PMMProtocol=[PmmAdapter]（部署期真实地址由构造/配置注入；测试用 `makeAddrAndKey` 派生 → **非代码级阻塞**）。
- **CallerAuth 接口已定稿**（cross-repo-sync.md）：`_verifyCallerAuth / isNonceUsed / _extractDexRouterCaller` + `OSA_*` errors + EIP-2098 + nonce 位图。
- **CallerAuth.sol 全量源码**：canonical、双仓同一文件，Stage 0 记录「full implementation provided」。**本仓为 canonical 源头之一**，Stage 2 需取得该定稿源码逐字落地（EIP-191 `okxSig` preimage 由该文件固定）。这是实现期需获取的既有产物，**不构成设计级阻塞**（PRD §A0 已给出完整行为规格）。
- **后端硬不变量**（PRD §目标设计 5，文档化）：OKX 后端签名 nonce 分配、allowedCallers 段构造——属后端契约，本仓按 CallerAuth 校验即可。

**部署期取值**（构造参数，不阻塞代码）：`okxSigner` 真实地址、各链 DexRouter/DynamicRoute/PmmAdapter/PMMProtocol 地址。

---

## 7. 开放问题（open_questions）

经在 `tmp/prd.md` 与 `tmp/resources/` 全文检索：PRD §目标设计 已给出结构体字段、typehash/version、机制步骤、常量值、错误串、calldata 偏移的完整规格——**无代码级阻塞开放问题**。

非阻塞待办（交由后续 stage，不 stop）：
- OQ-1（实现期）：取得 canonical `CallerAuth.sol` 定稿全量源码（含 EIP-191 `okxSig` preimage 精确布局与 `OkxAuth` struct 定义）。cross-repo-sync.md 仅注「See document for full Solidity source」，物化副本未含源码正文；本仓为 canonical 源头，Stage 2 落地即完成本仓义务。
- OQ-2（实现期）：`OkxAuth` struct 的具体字段（adaptorAuth / protocolAuth 的 ABI 形状）——PRD 以 `OkxAuth adaptorAuth, OkxAuth protocolAuth` 表述，随 CallerAuth 定稿确定。
- OQ-3（文档/回归）：`MockMarketMaker` 及 helper 的 OrderRFQ 构造需同步新增 `allowedSender` 字段（Stage 3）。

> 以上均为实现/测试期依赖既有跨仓定稿或本仓落地即可解决，不满足 flow「关键依赖在 PRD/A-00 中缺失或未锁定」的 stop 条件，故不 stop。

---

## 8. FR → AC 逐条清单（1:1 复刻 PRD，Given-When-Then，具体值原文保留）

> 供 Stage 3（测试）与 Stage 4（核查）逐条对照。**AC-1..AC-5 为 PRD 明文 AC，逐字复刻**；标 `[derived §…]` 者为 PRD 无明文 AC 但由 §目标设计 / §A0 / §D 派生的可测项（不替代明文 AC，不概括合并）。

### FR-5：PMMProtocol 通用 allowedSender 校验（allowedSender 必填非零）
> 校验「allowedSender 非零且 == dexRouterCaller」在 **PmmAdapter** 执行；PMMProtocol 把成交入口收敛为唯一函数并施加调用方绑定；协议内严禁做 allowedSender 校验。

- **FR-5-AC-1**（PRD 明文）
  - **Given** 一笔经 PmmAdapter orderType=4 的成交，`order.allowedSender` 非 0
  - **When** `order.allowedSender == dexRouterCaller`（`dexRouterCaller` 从 calldata `-64` 按 `MARKER_MASK` 精确匹配读出）
  - **Then** 校验通过，成交正常执行
- **FR-5-AC-2**（PRD 明文）
  - **Given** `order.allowedSender` 非 0
  - **When** `order.allowedSender != dexRouterCaller`
  - **Then** revert，错误串 **`"RFQ_BadSender"`**
- **FR-5-AC-3**（PRD 明文，fail-closed）
  - **Given** 一笔 orderType=4 成交
  - **When** `order.allowedSender == address(0)`（零地址=未填）
  - **Then** **revert**（fail-closed）
- **FR-5-AC-4**（PRD 明文）
  - **Given** PmmAdapter 经「直连 DexRouter」或「经 DynamicRoute」两条路径被调用
  - **When** 读取 `dexRouterCaller`
  - **Then** 两条路径下 `dexRouterCaller` 均为「直连 DexRouter 的最外层地址」
- **FR-5-AC-5**（PRD 明文，调用方绑定）
  - **Given** 绕过 PmmAdapter
  - **When** 直接调用 PMMProtocol 成交入口 `fillOrderRFQTo`
  - **Then** revert（`_verifyCallerAuth`：`msg.sender ∉ [PmmAdapter]` → `OSA_UntrustedCaller`）
- **FR-5-AC-6** `[derived §目标设计 C.2]`
  - **Given** OrderRFQ 新增 `allowedSender`（位于 `usePermit2` 之后、`confidenceT` 之前）
  - **When** 计算 EIP-712 digest
  - **Then** struct 顺序 == type string 顺序 == `hash()` abi.encode 顺序（三处一致）；domain `version` == **`1.2`**；旧 `1.1` 签名对新合约失效
- **FR-5-AC-7** `[derived §目标设计 C.4]` marker 精确校验
  - **Given** calldata `-64` 处 word
  - **When** `word & MARKER_MASK != DEX_ROUTER_CALLER_MARKER`（marker 缺失或伪造）
  - **Then** `_extractDexRouterCaller()` 返回 `address(0)` → 命中 AC-3 fail-closed（`RFQ_BadSender`）
- **FR-5-AC-8** `[derived §目标设计 C.3]` 协议内不做 allowedSender 校验
  - **Given** PMMProtocol
  - **When** 审阅其成交路径
  - **Then** 协议内**无** allowedSender 校验（校验只在 PmmAdapter）

### FR-3：调用方绑定（在 PmmAdapter/PMMProtocol 上，OKX 后端 EIP-191 签名式）
> PmmAdapter allowedCallers=[DexRouter, DynamicRoute]；PMMProtocol allowedCallers=[PmmAdapter]。PRD 本仓段未列明文 AC-N，下列由 §目标设计 + §A0 + §D 派生。

- **FR-3-AC-1** `[derived §A0]` 合法调用方通过
  - **Given** PmmAdapter 继承 CallerAuth，`OKX_SIGNER` 已配置
  - **When** `msg.sender ∈ [DexRouter, DynamicRoute]` 且 `okxSig` 由 OKX_SIGNER 对 (allowedCallers, nonce, expiry) 正确签名、未过期、nonce 未用
  - **Then** `_verifyCallerAuth` 通过
- **FR-3-AC-2** `[derived §A0]` 非信任调用方
  - **When** `msg.sender ∉ allowedCallers`
  - **Then** revert `OSA_UntrustedCaller`
- **FR-3-AC-3** `[derived §A0]` 过期
  - **When** `block.timestamp > expiry`
  - **Then** revert `OSA_Expired`
- **FR-3-AC-4** `[derived §A0]` 错误 OKX 签名
  - **When** `okxSig` recover != `OKX_SIGNER`
  - **Then** revert `OSA_BadOkxSig`
- **FR-3-AC-5** `[derived §A0]` 签名长度非法
  - **When** `okxSig` 长度非 64（EIP-2098 compact）预期
  - **Then** revert `OSA_BadSigLen`
- **FR-3-AC-6** `[derived §A0 / §D 防重放]` nonce 重放
  - **Given** 某 nonce 已消费（`isNonceUsed(nonce)==true`）
  - **When** 用同一 nonce 再次调用
  - **Then** revert `OSA_NonceUsed`
- **FR-3-AC-7** `[derived §A0]` 零 signer
  - **Given** `OKX_SIGNER == address(0)`（异常部署）
  - **When** 验签
  - **Then** revert `OSA_ZeroSigner`
- **FR-3-AC-8** `[derived §目标设计 C.4]` PMMProtocol 段绑定
  - **Given** PmmAdapter 调用 PMMProtocol 唯一入口，转发 `protocolAuth`
  - **When** PMMProtocol 首行 `_verifyCallerAuth`（allowedCallers=[PmmAdapter]）
  - **Then** 仅 PmmAdapter 可调用；其它调用方 → `OSA_UntrustedCaller`（与 FR-5-AC-5 同源）

### FR-6-AC-1：既有 adapter / PMM（含 V1/V2/V3）回归全部通过
- **FR-6-AC-1**（PRD 明文）
  - **Given** 现有 V1/V2/V3 orderType 路径与既有测试套件（基线 50 passing）
  - **When** 在本次改动之上运行 `forge test`（Fork 套件除外）
  - **Then** 全部通过，行为不变（成功路径、既有错误码、事件语义、refund `-32` 逻辑均不变）

### §D 测试要求（PRD 明文，Stage 3 必须覆盖）
- **AC-D-1**：不得出现任何私钥/明文助记词
- **AC-D-2**：用 `makeAddrAndKey("okxSigner")` 派生测试地址
- **AC-D-3**：覆盖 happy path、地址解耦拦截、marker 精确校验、调用方校验、授权防重放、fail-closed、资金安全、回归

---

## 9. kg_impact — Stage 5 需回写 context-kg 的内容

| 文档 | 类型 | 原因 |
|------|------|------|
| `technical/contracts/contract-PMMProtocol.md` | UPDATE | CallerAuth 继承、唯一入口 `fillOrderRFQTo` 新签名、allowedCallers、移除 3 个 fill 变体、version 1.2 |
| `technical/contracts/contract-PMMAdapter.md` | UPDATE | orderType=4 路径、allowedSender 校验、CallerAuth、`-64` dexRouterCaller、nonReentrant |
| `technical/arch/architecture-overview.md` | UPDATE | 合约清单新增 CallerAuth / Constants；角色模型从「no privileged roles」→ OKX 签名调用方绑定 |
| `technical/arch/eip712-signature-design.md` | UPDATE | OrderRFQ 15 字段、新 typehash、domain version 1.2 |
| `business/pmm_settlement.md` | UPDATE | allowedSender 必填、version 1.2、`RFQ_BadSender` |
| `technical/knowledge-base.md` | UPDATE | 新硬规则：唯一成交入口 + CallerAuth 首行绑定 + nonce CEI；四个旧 fill 入口规则作废 |
| `technical/conventions/testing-patterns.md` | UPDATE | MockMarketMaker 加 allowedSender；防套利测试模式 |
| (NEW) `technical/contracts/contract-CallerAuth.md` | CREATE | CallerAuth 参考文档 |
| (NEW) `business/pmm_anti_toxic_flow.md` | CREATE | 防套利业务域文档 |

---

## 10. Knowledge Graph References

- **gitlab_name**: `GitHub-Web3-DEX-EVM-PMM`
- **queries**: `["allowedSender CallerAuth caller binding OKX signer nonce anti-toxic orderType dexRouterCaller"]`
- 结论：KG 现有 19 篇 design 文档均描述 **V1/V2/V3 现状**（allowedSender / CallerAuth / orderType=4 为本次**净新增**，KG 尚无对应内容）。故 KG 作为「不变约定 + 向后兼容」参考，不作为新行为模板；新增内容见 §9。

### Retrieved Documents
| Title | Git Link | doc_type | Chunks | Chunk Excerpts |
|---|---|---|---|---|
| Knowledge Base | [link](https://gitlab.okg.com/okone/oli-platform/knowledge-base/-/blob/master/web3-dex/GitHub-Web3-DEX-EVM-PMM/context-kg/technical/knowledge-base.md) | design | 4 | ① 四个 fill 入口须走 nonReentrant…<br>② `_invalidateOrder` 须先于 maker 转账（CEI）…<br>③ EIP-712 domain 须含 chainId+verifyingContract…<br>④ `order.expiry` 须检查 → RFQ_OrderExpired… |
| Architecture Overview | [link](https://gitlab.okg.com/okone/oli-platform/knowledge-base/-/blob/master/web3-dex/GitHub-Web3-DEX-EVM-PMM/context-kg/technical/arch/architecture-overview.md) | design | 4 | ① PMMProtocol=链上结算，无特权角色，仅 EIP-712 授权…<br>② PMMAdapter 无状态分派 V1/V2/V3…<br>③ ORIGIN_PAYER calldataload(-32) refund…<br>④ 组件关系图… |
| EIP-712 Signature Design | [link](https://gitlab.okg.com/okone/oli-platform/knowledge-base/-/blob/master/web3-dex/GitHub-Web3-DEX-EVM-PMM/context-kg/technical/arch/eip712-signature-design.md) | design | 4 | ① domain separator 缓存 chainId+verifyingContract…<br>② OrderRFQ typehash 覆盖全部字段（现 14）…<br>③ 改 typehash = 破坏性变更须升 version…<br>④ 后端生成 + 链上验证… |

### Graph RAG Query Stats
| Metric | Value |
|---|---|
| list-docs calls | 2 |
| graph nodes touched | 1 |
| graph edges found | 19 |
| documents found | 19 |
| fetch-content calls | 3 (本轮) |
| chunks retrieved | 15 (本轮) |

#### Retrieved KG
retrieved_kg: [context-kg/technical/knowledge-base.md, context-kg/technical/arch/architecture-overview.md, context-kg/technical/arch/eip712-signature-design.md]

---

## 11. 结构化产出（供下游 stage 消费）

```json
{
  "fr_list": ["FR-5", "FR-3", "FR-6-AC-1"],
  "impacted_contracts": {
    "create": ["src/libraries/Constants.sol", "src/libraries/CallerAuth.sol", "test/PmmProtocolAntiToxic.t.sol"],
    "modify": ["src/OrderRFQLib.sol", "src/PmmProtocol.sol", "src/PmmAdaptor.sol", "src/EIP712.sol (via _VERSION)", "src/libraries/Errors.sol"],
    "readonly": ["src/libraries/ECDSA.sol"]
  },
  "ac_checklist": [
    "FR-5-AC-1: allowedSender!=0 && ==dexRouterCaller -> pass",
    "FR-5-AC-2: allowedSender!=0 && !=dexRouterCaller -> revert RFQ_BadSender",
    "FR-5-AC-3: allowedSender==address(0) -> revert (fail-closed)",
    "FR-5-AC-4: direct or via-DynamicRoute -> dexRouterCaller == outermost address directly calling DexRouter",
    "FR-5-AC-5: bypass PmmAdapter, call PMMProtocol entry directly -> revert (caller binding, OSA_UntrustedCaller)",
    "FR-5-AC-6[derived]: allowedSender field after usePermit2 before confidenceT; 3-way consistent; domain version 1.2; old 1.1 sig invalid",
    "FR-5-AC-7[derived]: word & MARKER_MASK != DEX_ROUTER_CALLER_MARKER -> dexRouterCaller=0 -> fail-closed RFQ_BadSender",
    "FR-5-AC-8[derived]: PMMProtocol performs NO allowedSender check",
    "FR-3-AC-1[derived]: valid caller in [DexRouter,DynamicRoute] + valid okxSig + not expired + nonce unused -> pass",
    "FR-3-AC-2[derived]: msg.sender not in allowedCallers -> OSA_UntrustedCaller",
    "FR-3-AC-3[derived]: block.timestamp > expiry -> OSA_Expired",
    "FR-3-AC-4[derived]: okxSig recover != OKX_SIGNER -> OSA_BadOkxSig",
    "FR-3-AC-5[derived]: bad okxSig length -> OSA_BadSigLen",
    "FR-3-AC-6[derived]: reused nonce -> OSA_NonceUsed",
    "FR-3-AC-7[derived]: OKX_SIGNER==address(0) -> OSA_ZeroSigner",
    "FR-3-AC-8[derived]: PMMProtocol _verifyCallerAuth allowedCallers=[PmmAdapter]",
    "FR-6-AC-1: V1/V2/V3 regression all pass, behavior unchanged (baseline 50 passing)",
    "AC-D-1: no private keys / plaintext mnemonics in tests",
    "AC-D-2: makeAddrAndKey(\"okxSigner\") for test signer",
    "AC-D-3: cover happy path, address-decoupling intercept, marker exact-match, caller check, replay protection, fail-closed, fund safety, regression"
  ],
  "constants": {
    "DEX_ROUTER_CALLER_MARKER": "0x3ca20afc2ddd0000000000000000000000000000000000000000000000000000",
    "MARKER_MASK": "0xffffffffffff0000000000000000000000000000000000000000000000000000",
    "ORIGIN_PAYER": "0x3ca20afc2ccc0000000000000000000000000000000000000000000000000000",
    "_ADDRESS_MASK": "0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff",
    "domain_version": "1.2",
    "calldata_layout": "dexRouterCaller@-64, refundTo@-32",
    "pmmadapter_allowed_callers": ["DexRouter", "DynamicRoute"],
    "pmmprotocol_allowed_callers": ["PmmAdapter"],
    "bad_sender_error": "RFQ_BadSender",
    "callerauth_errors": ["OSA_ZeroSigner", "OSA_Expired", "OSA_UntrustedCaller", "OSA_BadOkxSig", "OSA_BadSigLen", "OSA_NonceUsed"]
  },
  "approach": "PRD §目标设计 five-part change + §A0 CallerAuth: Constants.sol (new); OrderRFQLib add required allowedSender (between usePermit2 and confidenceT), typehash breaking change -> domain version 1.2; PMMProtocol inherit CallerAuth, constructor(weth,okxSigner), converge to unique fillOrderRFQTo with _verifyCallerAuth first line, remove other 3 fill variants, NO allowedSender check inside protocol; PmmAdapter inherit CallerAuth+ReentrancyGuard, constructor(okxSigner), add orderType=4 path (orderInfo=abi.encode(order,adaptorAuth,protocolAuth)), _verifyCallerAuth([DexRouter,DynamicRoute]), check allowedSender==dexRouterCaller read from calldata -64 via MARKER_MASK exact match else revert RFQ_BadSender, forward protocolAuth to PMMProtocol; V1/V2/V3 unchanged; CallerAuth canonical two-repo same file.",
  "out_of_scope": ["FR-1", "FR-2", "FR-4", "FR-5 on DynamicRoute/NativePmmAdapter", "DexRouter dexRouterCaller injection (本仓用 mock 注入 -64)", "actual on-chain deploy/broadcast"],
  "external_deps": [
    "calldata layout dexRouterCaller@-64 refundTo@-32 (DexRouter injection done in other repo; 本仓 read-only, mock in tests)",
    "allowedCallers values PmmAdapter=[DexRouter,DynamicRoute] PMMProtocol=[PmmAdapter] (deploy-time addrs via constructor/config; tests derive via makeAddrAndKey -> not code blocker)",
    "CallerAuth interface finalized (cross-repo-sync.md): _verifyCallerAuth/isNonceUsed/_extractDexRouterCaller + OSA_* + EIP-2098 + nonce bitmap",
    "canonical CallerAuth.sol full source (two-repo same file; Stage 2 to obtain/finalize; 本仓 canonical source-of-truth)",
    "backend hard invariants (OKX signer nonce allocation, allowedCallers segment) — backend contract, documented"
  ],
  "open_questions": [
    "OQ-1 (impl-time, non-blocking): obtain canonical CallerAuth.sol full source incl. EIP-191 okxSig preimage layout & OkxAuth struct; materialized copy only referenced it. 本仓 canonical -> Stage 2 landing fulfills 本仓 duty.",
    "OQ-2 (impl-time, non-blocking): exact OkxAuth struct fields (adaptorAuth/protocolAuth ABI shape) — finalized with CallerAuth.",
    "OQ-3 (test, non-blocking): MockMarketMaker/helpers OrderRFQ construction must add allowedSender field (Stage 3)."
  ],
  "kg_impact": {
    "update": ["technical/contracts/contract-PMMProtocol.md", "technical/contracts/contract-PMMAdapter.md", "technical/arch/architecture-overview.md", "technical/arch/eip712-signature-design.md", "business/pmm_settlement.md", "technical/knowledge-base.md", "technical/conventions/testing-patterns.md"],
    "create": ["technical/contracts/contract-CallerAuth.md", "business/pmm_anti_toxic_flow.md"]
  },
  "design_note_path": "GitHub-Web3-DEX-EVM-PMM/docs/research-design-note.md",
  "deviation_from_prd": "none"
}
```
