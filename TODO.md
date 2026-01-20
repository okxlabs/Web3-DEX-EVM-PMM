统一“输入输出模板”

* **输入（必须提供）** ：订单字段 JSON（含链ID、verifyingContract、domain）、`permit2Witness`、`permit2WitnessType`、参考合约版本/commit,  示例私钥
* **输出（必须打印/上报）** ：
* `structData`（hex，作为 keccak 输入的原始 bytes）
* `structHash`（bytes32）
* `domainSeparator`（bytes32）
* `digest`（EIP-712 最终 hash）
* `signature`（r/s/v 或 65 bytes）
* 如启用 Permit2：`permit2Signature` 原文、是否在 struct 中被哈希（bytes32）等

验收/对账检查表（Checklist）

* **Schema 一致** ：双方引用同一份 struct 定义与 witnessType 源（绑定 commit/版本号）。
* **对账顺序固定** ：先 `structData` → 再 `structHash` → 再 `domainSeparator` → 再 `digest` → 最后 signature。
* **Permit2 关键点** ：
* `permit2Signature` 在 struct 中的类型是否为 `bytes32`（hash 后）或 `bytes`（原文）？
* `permit2Witness` 是否为 bytes32/structHash（与合约一致）？
* `permit2WitnessType` 字符串是否完全一致（含空格、括号、字段顺序）？
* **链上验证可复现** ：给定同一订单 JSON，在至少 1 个测试网/主网 fork 上能稳定通过验签。/

要求:

1. 做成gh-pages
2. 输入: **RfqPMMClient.FirmOrderRequest(chainIndex=1, takerAsset=0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2, makerAsset=0xdac17f958d2ee523a2206206994597c13d831ec7, takerAmount=1000000000000000, takerAddress=0xd68e2150cd2da77decaeb01ab630c864ad612aaa, rfqId=4262300009041366528, rfqIdStr=null, expiryDuration=50, calldata=null, beneficiaryAddress=0xf911fb05ed9db87889f413d7fefb1cd4af03beb7, toAmount=3198469)**
   **X-RequestID:3100487888779130001**
   私钥
   witness type
3. 输出:
   order结构体 schema `permit2Witness` `permit2WitnessType `permit2Signature``
