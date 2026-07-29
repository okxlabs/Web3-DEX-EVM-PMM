# Review Report — SCDEX-1157 · EVM RFQ 防套利 / allowedSender (Stage 4.0 自审 + 终检)

- **Requirement**: SCDEX-1157 — EVM-RFQ-anti-toxic-flow-PRD-v0.2
- **Repo (canonical)**: `GitHub-Web3-DEX-EVM-PMM`
- **Reviewed inputs**: A-03 (Implementation), A-04 (Test Results)
- **PRD source of truth**: `tmp/prd.md` (v0.2)  ·  **FR→AC clist**: `docs/research-design-note.md` (A-02) §8
- **Verdict**: ✅ **PASS** — 无缺口，向后兼容/安全/约定通过，终检 build+test 全绿。不生成 rework_request.md。

---

## 结构化结论 (供下游消费)

```json
{
  "ac_coverage_gaps": [],
  "backward_compat_ok": true,
  "security_ok": true,
  "conventions_ok": true,
  "final_build_ok": true,
  "final_test_ok": true,
  "review_notes": "A-02 §8 FR→AC 1:1 复刻 PRD 5 条明文 FR-5 AC(含错误串 RFQ_BadSender、零地址 fail-closed、双路径 dexRouterCaller、绕过 revert),derived 项标注清晰无概括/合并/丢失;FR-3/§A0/FR-6-AC-1/§D 全覆盖。实现(OrderRFQLib/PmmProtocol/PmmAdaptor/CallerAuth/Constants/Errors)逐行核对与设计一致;测试 79 passed/0 failed(anti-toxic 13 + CallerAuth 16 + 基线回归 50);终检 forge build exit 0、forge test 79/0。破坏性变更(version 1.2、移除 3 个 fill 变体)均为 PRD 明确要求且已文档化,非兼容回归。"
}
```

---

## 步骤 1 — 需求覆盖

### 1a. A-02 FR→AC 是否 1:1 覆盖 PRD 每条 AC（含具体值）

PRD 本仓明文 AC = FR-5-AC-1..5 + FR-6-AC-1 + §D(3 条)。逐条核对 A-02 §8：

| PRD AC (原文关键值) | A-02 §8 对应项 | 结论 |
|---|---|---|
| FR-5-AC-1: allowedSender≠0 且 ==dexRouterCaller → 通过 | FR-5-AC-1（含「-64 按 MARKER_MASK 精确匹配」） | ✅ 逐字 |
| FR-5-AC-2: ≠0 且 !=dexRouterCaller → revert **"RFQ_BadSender"** | FR-5-AC-2（保留错误串 `"RFQ_BadSender"`） | ✅ 逐字含错误串 |
| FR-5-AC-3: ==address(0) → revert (fail-closed) | FR-5-AC-3（fail-closed） | ✅ 逐字 |
| FR-5-AC-4: 直连/DynamicRoute 两路径 dexRouterCaller 均为最外层地址 | FR-5-AC-4 | ✅ 逐字 |
| FR-5-AC-5: 绕过 PmmAdapter 直连 PMMProtocol → revert | FR-5-AC-5（→ OSA_UntrustedCaller） | ✅ 逐字 |
| FR-6-AC-1: V1/V2/V3 回归全过(基线 50) | FR-6-AC-1 | ✅ 逐字 |
| §D-1 无私钥/助记词 / §D-2 makeAddrAndKey / §D-3 覆盖清单 | AC-D-1/2/3 | ✅ 逐字 |

- A-02 额外的 `[derived]` 项（FR-5-AC-6/7/8、FR-3-AC-1..8）均明确标注 `[derived §…]`，是 PRD §目标设计/§A0/§D 的**派生可测项**，**未替代、未概括、未合并任何 PRD 明文 AC**。常量值（marker/mask、version 1.2、字段位置、错误串、allowedCallers）在 §5 逐字保留。
- **结论：无 A-02 清单缺口，不需回退 stage 1.0。**

### 1b. 每条 AC 是否有对应实现 + 测试（对代码逐行核对）

| AC | 实现证据（已读源码） | 测试证据（forge test 通过） |
|---|---|---|
| FR-5-AC-1 | `PmmAdaptor.sol:290-293` `_executeV4Order`：`dexRouterCaller=_extractDexRouterCaller()`，match 则 fill | `testFR5_AC1_AllowedSenderMatchesDexRouterCallerFills` |
| FR-5-AC-2 | 同上 `revert Errors.RFQ_BadSender(rfqId)`；`_call` 亦映射 selector→`"RFQ_BadSender"` (`PmmAdaptor.sol:442`) | `testFR5_AC2_AllowedSenderMismatchReverts` |
| FR-5-AC-3 | `allowedSender == address(0) → revert` (fail-closed) | `testFR5_AC3_ZeroAllowedSenderFailsClosed` |
| FR-5-AC-4 | `_extractDexRouterCaller` 读 calldata `-64`，路径无关 | `testFR5_AC4_SettlesViaDynamicRoute` |
| FR-5-AC-5 | `PmmProtocol.sol:126` 首行 `_verifyCallerAuth`(allowedCallers=[PmmAdapter]) | `testFR5_AC5_DirectProtocolCallByNonAdapterReverts` |
| FR-5-AC-6 | `OrderRFQLib.sol:17` 字段在 usePermit2 后/confidenceT 前；typehash+encode 三处一致；`_VERSION="1.2"` (`PmmProtocol.sol:63`) | 79 套件签名验证隐含通过 |
| FR-5-AC-7 | `CallerAuth.sol:128-136` exact `word & MARKER_MASK == DEX_ROUTER_CALLER_MARKER`，否则 addr(0) | `testFR5_ForgedMarkerFailsClosed`, `testFR5_MissingMarkerFailsClosed`, CallerAuth extract 系列 |
| FR-5-AC-8 | `PmmProtocol.sol` 全函数无 allowedSender 校验（已读全文确认） | 由 AC-5/AC-1 端到端隐含 |
| FR-3-AC-1..7 | `CallerAuth.sol:42-113` 构造零 signer revert、验签、expiry、caller 成员、nonce 位图、EIP-2098 长度 | `test/CallerAuth.t.sol` 16 tests |
| FR-3-AC-8 | `PmmProtocol.sol:126` allowedCallers=[PmmAdapter] | `testFR3_Protocol_*` |
| FR-6-AC-1 | V1/V2/V3 `_executeVxOrder` 与 `_call`/`_handleRefund(-32)` 未改；`-64` 仅 orderType=4 | 基线 50 tests 0 回归 |
| §D | 新测试用 `makeAddrAndKey`/`vm.sign`，无硬编码私钥 | grep 核对通过 |

**无实现缺口 → 不回退 stage 2.0；无测试缺口 → 不回退 stage 3.0。**

---

## 步骤 2 — 向后兼容

- V1/V2/V3 orderType 分派路径、`_executeV1/2/3Order`、`_call` selector→string 映射、`_handleRefund` 读 `-32` `ORIGIN_PAYER` 逻辑 **均未改动**（已读 `PmmAdaptor.sol` 全文）。
- `-64` `dexRouterCaller` 读取仅在 `orderType==4` 触发；`DEX_ROUTER_CALLER_MARKER@-64`(`...ddd...`) 与 `ORIGIN_PAYER@-32`(`...ccc...`) 第 3 marker 字节不同，两词不冲突。
- 既有事件 `OrderFilledRFQ`(13 参)、`OrderCancelledRFQ`、既有 14 个 `RFQ_*` 错误 **语义不变**；新增仅 `RFQ_BadSender` + `OSA_*`（追加式）。
- **破坏性变更（PRD 明确要求，非兼容回归，已文档化）**：① OrderRFQ 新增必填 `allowedSender` → typehash 变化 → domain `version` 1.1→1.2（旧签名对新合约失效，符合 EIP-712 replay 防护）；② PMMProtocol 移除 `fillOrderRFQ/fillOrderRFQCompact/fillOrderRFQToWithPermit`、`fillOrderRFQTo` 扩展 caller-auth 参数。链上已部署 V3 合约独立、不受影响。
- **结论：backward_compat_ok = true。**

---

## 步骤 3 — 安全 / 约定

- **重入**：`sellBase/sellQuote` 新增 `nonReentrant`；`PMMProtocol.fillOrderRFQTo` 保留 `nonReentrant`；CEI 保留（`_invalidateOrder` 先于 maker 转账）。CallerAuth nonce 在 `_verify*` 内消费（早于任何外部调用），防重入重放。
- **资金安全 / fail-closed**：marker 精确匹配，缺失/伪造 → `dexRouterCaller=0` → 非零 allowedSender 必不等 → `RFQ_BadSender`；零 allowedSender 直接 revert。WETH unwrap 低级 call 检查返回值（`RFQ_ETHTransferFailed`）保留。
- **签名安全**：EIP-2098 64-byte compact，upper-half `s` / recover==0 fail-closed；digest 绑定 `address(this)+chainId`（跨合约/跨链 replay 防护）；零 OKX_SIGNER 构造期 fail-closed（`OSA_ZeroSigner`）。
- **无 secret 落代码/日志**：`src` 无私钥/token；`Constants.sol` 为公开 calldata marker（非机密）；新测试用 `makeAddrAndKey` 派生、`vm.sign`，无硬编码私钥/助记词。
- **KG 约定（graph-rag 召回确认，均未被破坏）**：RFQ 失效不可回退、`block.timestamp<=expiry`、60% 结算下限（confidence 前评估）、confidence 上限 `_CONFIDENCE_CAP_LIMIT=50000`、CEI「协议交易间不持币」——已读 `PmmProtocol.sol` 全文确认全部保留。
- **结论：security_ok = true, conventions_ok = true。**

---

## 步骤 4 — 终检

| 命令 | 结果 |
|---|---|
| `forge build --offline` | ✅ exit 0（仅 pre-existing lint 警告，如 `PmmProtocol.sol:301` unsafe-typecast，属基线） |
| `forge test --offline --no-match-path "test/*Fork*"` | ✅ **79 passed / 0 failed / 0 skipped**（5 套件） |

明细：PmmAdaptor 24 · PmmProtocol 9 · PmmProtocolTimeSlippage 17 · CallerAuth 16 · PmmProtocolAntiToxic 13 = 79。
Fork 套件 `PmmProtocolPermitWitnessFork.t.sol` 依 A-01 基线约定排除（Arbitrum RPC 网络策略不可达），`forge build` 下可编译、`--fork-url` opt-in。

- **结论：final_build_ok = true, final_test_ok = true → 不阻断。**
