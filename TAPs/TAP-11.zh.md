---
tap: 11
title: TapeAPI Service Manifest and Holder Delegation
description: How the holder of a TapeOut circuit describes a callable service in the circuit container's DeWEB site and authorises an off-chain signing key for it, and how a client verifies both against the chain.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/7
status: Draft
type: Application
created: 2026-09-30
updated: 2026-10-09
requires: TAP-10
license: CC0-1.0
---

本文是 TAP-11 的中文译文，仅供参考；与英文不一致时以英文为准（TAP-01 §6.2）。

# TAP-11：TapeAPI 服务清单与持有人委托

## 概要

本 TAP 让 TapeOut 电路的持有人在自己的链上网站里公布它运营的在线服务，以及代表这个服务说话的密钥，让任何人在依赖某个服务之前都能核实背后是谁。

## 摘要

本 TAP 定义**服务清单**：容器的 DeWEB 站点中固定路径 `/.well-known/tapeapi.json` 下的一个 JSON 文件，列出服务的 HTTPS 端点与方法，并指定一个**签名者**，即服务用来签署其返回内容的普通 secp256k1 地址。电路持有人用一份 EIP-712 **委托**授权该签名者，委托在 366 天内到期。本 TAP 规定清单格式、委托的域、类型与检查（包括经 EIP-1271 的合约持有人）、持有人对整份清单的可选签名及其所需的规范 JSON，以及客户端解析服务、重读服务、发现清单被回滚的步骤。名字、选链、节点共识、钉块、实现钉住、激活与文件核验沿用 TAP-10，只引用、不重述。响应格式、支付与其它绑定留给建立在本 TAP 之上的后续 TAP。

## 动机

TAP-10 给每个电路容器一个字节可被任何人核验的网站，以及一个收件箱。它没有给容器一种方式来声明"我在这些 URL 上接受请求，我的回答由这把密钥签名"。今天的链下 API 没有链上身份：客户端信任的是 DNS 和 TLS 证书，没有任何东西把一个回答和某个 TapeOut 名字所指的那一方联系起来。互相调用的智能体、想引用某个结果的应用，都需要这种联系。

各个部件已经存在：容器是任何人都能推导的身份；它的站点是任何人都能核验的存储；它的持有人在链上可读。缺的是一个约定的文件格式、一种让冷的持有人密钥授权热的签名密钥的约定方式，以及一套约定的检查顺序，让两个互不相识的客户端对同一个服务得出相同的结论。本 TAP 正好补上这些，不需要新合约、新的名字语法，也不改动 TAP-10。

## 规范

本文中的关键词 "MUST"、"MUST NOT"、"REQUIRED"、"SHALL"、"SHALL NOT"、"SHOULD"、"SHOULD NOT"、"RECOMMENDED"、"NOT RECOMMENDED"、"MAY" 与 "OPTIONAL"，当且仅当以全大写出现时，按 RFC 2119 与 RFC 8174 的描述解释。

### 1. 术语与记号

- **电路**、**处理器合约**、**处理器编号**、**#ID**、**容器**、**持有人**、**已开通**、**普通账户**、**站点存储**（`SiteRegistry`）、**付费合约**（`DomainBinding`）、**钉块**、**默认共识**、**严格共识**、**主链**、**端点 ID**：按 TAP-10 §1 与 §12.1 的定义。
- **中枢地址**：`0xe61A9C7213a6Aa616C246a2B569e555B417b25ee`，即 TAP-10 §13.2 的 DeWEB 中枢代理，在 TAP-10 链表的每条链上都是这个地址。本 TAP 只把它当常量用（§4.1），不调用它的任何函数。
- **服务**：其容器站点中存有清单（§3）的电路。服务只存在于其电路的主链上；同一个处理器合约地址与 #ID 在两条链上是两个服务。
- **清单**：§3 所述文件。**签名者**：清单 `signer` 成员所写的地址。**委托**：持有人对签名者的授权（§4）。
- **客户端**：按 §2 解析服务的软件。**提供者**：运行服务端点的一方。
- `now` 为客户端当前的 Unix 时间（整秒）。其余记号同 TAP-10 §1。

### 2. 解析服务

#### 2.1 输入

客户端 MUST 接受链上名字（TAP-10 §3.1）、容器地址，以及处理器合约加 #ID（TAP-10 §3.4 的文本形式或两个独立的值）。客户端 MAY 接受 TAP-10 §3.4 的其它输入形式，端点 ID 除外。其它输入 MUST 作为输入错误拒绝，数值范围与规则按 TAP-10 §3.1 与 §3.4。

#### 2.2 步骤

一次解析的所有读取 MUST 在服务所在链的同一个钉块上进行，钉块的选取与新鲜度检查按 TAP-10 §5.3（`stale-block`），且 MUST 至少以默认共识采纳（TAP-10 §5.2）。客户端 SHOULD 按 TAP-10 §5.4 用 `eth_chainId` 确认节点在预期的链上。客户端 SHOULD 以严格共识采纳 `ownerOf` 以及 §4.4 的 EIP-1271 调用，因为这两者中任何一个被伪造都会授权一个签名者。客户端给出第一个适用的结果：

1. **身份。** 按 TAP-10 §4.1–§4.3 选链并解析输入。结果为链、处理器合约、处理器编号、#ID、容器、持有人以及容器是否已开通。
2. **站点状态。** 在同一钉块上检查站点存储与付费合约的实现（TAP-10 §6.1），并按 TAP-10 §6.2 的顺序给出第一个适用的站点状态：`store-changed`、电路解析成功以外的身份结果（TAP-10 §4.4）、`not-opened`、`blocked`、`unpaid`。保有屏蔽名单（TAP-10 §10）的客户端 MUST 在这里查它。`ok` 以外的任何状态都以该状态结束解析。
3. **清单文件。** 从该链站点存储列表中第一个对该容器有任何路径的站点存储（TAP-10 §6.1）读取清单，注册表键为 `.well-known/tapeapi.json`：即 URL 路径 `/.well-known/tapeapi.json` 去掉开头的 `/`，与 TAP-10 §7.2 第 3 步的做法相同。只读这个精确的键；MUST NOT 套用 TAP-10 §7.2 第 4 步的落地规则（index 文件、回退路径）。然后：
   - `fileInfo` 的 `chunkCount` 为 0 即 `no-manifest`；
   - 声明的 `size` 超过 65,536 字节即 `manifest-invalid`，且 MUST NOT 读取该文件；
   - 否则完全按 TAP-10 §7.1 第 3–5 步读取并核验文件。文件结果不是 `ok`（`incomplete`、`no-hash`）时以该结果结束解析，且 MUST NOT 使用这些字节。
4. **解析与校验**：按 §3 校验这些字节。任何失败即 `manifest-invalid`。
5. **绑定。** `circuits` MUST 等于第 1 步解析出的处理器合约，`tokenId` 等于 #ID，`container` 等于容器（地址比较不区分大小写）。否则为 `manifest-invalid`。客户端 MUST NOT 用清单自称的任何身份值代替第 1 步解析出的值。
6. **委托。** 以第 1 步读到的持有人按 §4 核验。任何失败即 `delegation-invalid`。
7. **内容签名。** 客户端实施 §5 时，失败按 §5.3 处理。
8. **已解析。** 结果为链、链上名字、容器、持有人、钉块，以及清单及其 `signer` 与 `delegation.expires`。

#### 2.3 结果

| 结果 | 含义 |
|---|---|
| 已解析 | 各步全部通过；在 `delegation.expires` 之前、且重读（§7）没有给出别的结论时，签名者代表该服务 |
| 输入错误、`stale-block`、`unavailable`、`wrong-chain`、`ambiguous` | §2.1，或 TAP-10 §4.1 与 §5 的选链与节点规则 |
| `store-changed`、TAP-10 身份结果、`not-opened`、`blocked`、`unpaid` | 第 2 步（TAP-10 §4.4、§6.4） |
| `no-manifest` | 容器站点在 `.well-known/tapeapi.json` 没有文件 |
| `incomplete`、`no-hash` | 文件未通过 TAP-10 §7.1 |
| `manifest-invalid` | 文件过大、不是有效清单（§3），或写的是另一个电路或容器（第 5 步） |
| `delegation-invalid` | 委托未通过 §4 |

只有"已解析"允许客户端把签名者当作代表该服务。结果名只增不改。

### 3. 清单

#### 3.1 文件

- 清单是以 UTF-8 编码的 JSON 文本（RFC 8259），顶层值为对象。不是合法 UTF-8 的文件，或以字节顺序标记（BOM）开头的文件，均无效。提供者 SHOULD 以内容类型 `application/json` 存储；客户端不依赖内容类型。
- 清单 MUST NOT 超过 65,536 字节。
- 任何对象重复出现同一成员名（按 §6 第 1 条，在解码转义序列之后比较），或任何位置有名为 `__proto__`、`constructor`、`prototype` 的成员，清单即无效。
- 客户端 MUST 在各层忽略不认识的成员，且 MUST NOT 因此拒绝清单。后续 TAP MAY 定义更多顶层成员。

#### 3.2 成员

| 成员 | 类型 | 必需 | 规则 |
|---|---|---|---|
| `tapeapi` | string | 是 | 匹配 `^0\.[1-9][0-9]*$`。本 TAP 定义 `"0.1"`。客户端 MUST 接受该形式的任何值，MUST 拒绝其它值；后续次版本只增加可选成员 |
| `name` | string | 否 | 至多 64 个 Unicode 码点。仅供显示，不承载身份 |
| `circuits` | string | 是 | 处理器合约：`0x` 加 40 位十六进制，全小写或有效的 EIP-55 校验和形式 |
| `tokenId` | string | 是 | 十进制 #ID，无前导零 |
| `container` | string | 是 | 容器地址，形式同 `circuits` |
| `signer` | string | 是 | 签名者地址，形式同 `circuits` |
| `delegation` | object | 是 | `{ "expires": number, "sig": string }`（§4）。即使 `signer` 等于持有人也必需 |
| `delegation.expires` | number | 是 | 正整数，Unix 秒 |
| `delegation.sig` | string | 是 | `0x` 加 65 至 1,024 字节的十六进制；ECDSA 签名恰为 65 字节 |
| `endpoints` | object | 是 | `{ "live": array, "async": boolean }` |
| `endpoints.live` | 字符串数组 | 是 | 绝对 `https://` URL，不含查询、片段、用户名或密码。可以为空。提供者 SHOULD 至多列 4 个 |
| `endpoints.async` | boolean | 是 | `true` 表示服务接受发往其端点 ID（TAP-10 §12.1）的 TAP-10 消息形式的请求。`live` 非空与 `async` 为 `true` 至少其一成立 |
| `methods` | 对象数组 | 是 | 非空；方法名唯一（§3.3） |
| `payment` | object | 见规则 | `{ "escrow": string, "unit": "BEM", "decimals": 8 }`。任何方法的 `priceBEM` 不恰为字符串 `"0"` 时为 REQUIRED，此时 `escrow` MUST 为形式同 `circuits` 的非零地址。否则可选；出现的 `escrow` MUST 为该形式的地址。`unit` 与 `decimals` MAY 省略，省略时按 `"BEM"` 与 `8` 读取；其它值无效 |
| `contentSig` | string | 否 | 持有人对清单其余部分的签名（§5） |

#### 3.3 方法描述

| 成员 | 类型 | 必需 | 规则 |
|---|---|---|---|
| `name` | string | 是 | 匹配 `^[A-Za-z_][A-Za-z0-9_]{0,63}$`，且不是 `__proto__`、`constructor`、`prototype` |
| `priceBEM` | string | 是 | 匹配 `^[0-9]+(\.[0-9]{1,8})?$`：BEM 代币数量（BNB Smart Chain `0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a`，8 位小数）。`"0"` 表示免费。价格如何支付与结算不在本 TAP 范围内 |
| `params` | object | 是 | 参数名到类型名；可以为 `{}`。类型名仅供参考 |
| `returns` | object | 是 | 字段名到类型名；可以为 `{}`。仅供参考 |
| `description` | string | 否 | 至多 256 个 Unicode 码点 |

`endpoints.live` 与 `endpoints.async` 的请求与回答格式不在本 TAP 范围内。

### 4. 委托

#### 4.1 域与类型

以下值固定，永不改变：

| 项 | 值 |
|---|---|
| 域类型 | `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` |
| `name` | `"TapeAPI"` |
| `version` | `"1"` |
| `chainId` | 服务所在链的链 ID（TAP-10 §2.1） |
| `verifyingContract` | 中枢地址（§1） |
| 主类型 | `Delegation(address container,address signer,uint64 expires)` |
| `DELEGATION_TYPEHASH` | `keccak256("Delegation(address container,address signer,uint64 expires)")` = `0xc5081f9dc7e79dfbe7f3b3220ed9e7a29d0bc53239ee74dc184e4ac1f810948c` |

```
DOMAIN_SEPARATOR = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("TapeAPI"), keccak256("1"), chainId, 0xe61A9C7213a6Aa616C246a2B569e555B417b25ee))
structHash       = keccak256(abi.encode(DELEGATION_TYPEHASH, container, signer, uint64 expires))
digest           = keccak256(0x19 ‖ 0x01 ‖ DOMAIN_SEPARATOR ‖ structHash)
```

`container`、`signer`、`expires` 即清单的 `container`、`signer` 与 `delegation.expires`。中枢地址在每条链上相同，因此只靠 `chainId` 区分各链：为一条链签的委托 MUST NOT 在另一条链上被接受。TAP-10 链表新增的链若在该地址上没有中枢，需要自己的 `verifyingContract`，由本 TAP 的修订指定。

#### 4.2 签名

持有人用 `eth_signTypedData_v4` 或等价方式对 `digest` 签名。签名直接针对 `digest`，不加 EIP-191 `personal_sign` 前缀。

#### 4.3 有效期

只有当 `now < expires ≤ now + 31,622,400`（366 天）时委托才可接受。客户端 MUST 拒绝超出此范围的委托。

#### 4.4 持有人核验

持有人是 §2.2 第 1 步读到的 `ownerOf(#ID)`，绝不取自清单。满足以下任一条即委托有效：

1. **ECDSA。** `sig` 为 65 字节 `r ‖ s ‖ v`；`v` 为 0 或 1 时按 27 或 28 读取，{27, 28} 以外的其它 `v` 拒绝；`r` 与 `s` MUST 在 [1, n − 1] 内，且 `s` MUST NOT 超过 n/2，其中 n 为 secp256k1 的群阶；并且从 `digest` 恢复出的地址等于持有人。
2. **EIP-1271。** 持有人在钉块上有代码，且在钉块上对持有人调用 `isValidSignature(bytes32 digest, bytes sig)`（选择器 `0x1626ba7e`）返回至少 32 字节，其前 32 字节恰为 `0x1626ba7e` 后接 28 个零字节。回滚或其它任何返回都表示持有人不认可该签名。

`sig` 为 65 字节时，客户端 MUST 先尝试 ECDSA，且 65 字节的 `sig` 未通过第 1 条的范围检查时 MUST 直接拒绝，不再尝试 EIP-1271。客户端 MAY 不支持 EIP-1271；此时只有第 2 条能接受的委托会被拒绝。

#### 4.5 授权从哪里来

签名者只能通过一份在按 §2 解析出的清单中、并通过本节检查的委托来代表服务。客户端 MUST NOT 从任何其它来源接受签名者：HTTP 头、响应正文、目录或标签合约、经 HTTP 取得的清单，或在另一条链上解析出的清单。

### 5. 清单内容签名（可选）

#### 5.1 目的

委托只覆盖 `container`、`signer` 与 `expires`。持有人 MAY 在成员 `contentSig` 中对清单的其余部分也签名。客户端 MAY 忽略本节。

#### 5.2 摘要

- 域：§4.1 的域，`chainId` 为服务所在链。
- 主类型：`ManifestContent(address container,bytes32 contentHash)`；`MANIFEST_CONTENT_TYPEHASH` = `keccak256("ManifestContent(address container,bytes32 contentHash)")` = `0x809c1147faa2cda8716cdc72c000b05406f238cb127fea6f0abed585c02aea1c`。
- `contentHash = keccak256(UTF-8(canonicalJSON(M)))`，其中 `M` 是从文件原样解析出的清单对象去掉顶层成员 `contentSig`，`canonicalJSON` 见 §6。没有规范形式的清单不能带内容签名。
- `structHash = keccak256(abi.encode(MANIFEST_CONTENT_TYPEHASH, container, contentHash))`；`digest` 同 §4.1。
- 签名以此摘要、完全按 §4.4 对持有人核验。

#### 5.3 使用

实施本节的客户端 MAY 在 `contentSig` 出现时核验它，并 MAY 提供一个要求有效内容签名的设置。在该设置下，没有 `contentSig` 或 `contentSig` 未通过的清单为 `manifest-invalid`。没有该设置时，未通过的 `contentSig` MUST NOT 被报告为内容已核验，客户端 MAY 将其作为警告报告并继续。

### 6. 规范 JSON

`canonicalJSON(v)` 即 JSON 规范化方案（RFC 8785）：对象成员按名称的 UTF-16 码元序列递归排序，没有多余空白，数字采用 ECMAScript `Number::toString` 的最短往返形式，字符串按 ECMAScript `JSON.stringify` 的方式转义。此外，出现以下情形时该值没有规范形式，签名方 MUST 拒绝签名，验证方 MUST 拒绝：

1. 它所解析自的 JSON 文本中有任何对象重复出现同一成员名，成员名在解码转义序列之后比较（因此 `"a"` 与 `"\u0061"` 是同一个名字）；
2. 含有非有限数（包括 JSON 文本中写出、溢出为无穷的数）或负零；
3. 含有绝对值超过 2^53 − 1 的整数；
4. 任何位置有名为 `__proto__`、`constructor`、`prototype` 的成员；
5. 任何字符串或成员名含有未配对的 UTF-16 代理项。

验证方从解析后的值重新计算规范形式，绝不对收到的原始字节求哈希。其它签署 JSON 值的 TAP 可以引用本节。

这些规则固定不变：所有已经针对规范形式做出的签名都依赖它们，改动会使这些签名失效，或让同一个值有两种规范形式。

### 7. 重读、回滚与撤销

#### 7.1 缓存与重读

客户端 MAY 保留已解析的服务以便复用。它保留的持有人与站点状态属于 TAP-10 §11 所说的解析结果：客户端 SHOULD NOT 在不重读的情况下依赖它们超过 60 秒。客户端 SHOULD 在进行花费资金的操作之前重读超过一小时的清单，且 MUST NOT 在委托的 `expires` 之后继续依赖它。**重读**即在新的钉块上重复 §2.2：重新读取持有人、站点状态与清单文件，并重复其后的每一步。只有处理器表 MAY 取自缓存（TAP-10 §4.3）。只重新检查已保留清单的委托不算重读。

客户端在下一次依赖该服务之前 MUST 重读：

- 当它对照保留的 `signer` 检查的某个签名失败时；
- 当提供者或后续 TAP 的协议报告清单已变（例如价格或端点）时。以这种方式报告的值只是触发条件：重读之后客户端使用它从链上读到的内容。

#### 7.2 撤销

委托在到期前无法在链上撤销。出现以下情形时它不再被接受：

- 电路易手：恢复出的地址或 EIP-1271 的回答不再与新持有人相符（§4.4）；
- 持有人发布了换了 `signer` 或委托的清单，或删除了文件；
- 委托到期。

对某个客户端而言，这些都在其下一次重读时生效。

#### 7.3 被回滚的清单

能写容器站点的人可以放回一份委托尚未到期的旧清单。客户端 MAY 按链、容器、持有人与签名者记住它接受过的最大 `delegation.expires`（**下限**），并把同一链、容器、持有人与签名者下 `delegation.expires` 低于下限的清单作为 `delegation-invalid` 拒绝。保存下限的客户端 MUST 把它们存放在其所解析的服务写不到的地方，并 SHOULD 允许用户清除某个下限。

## 原理

- **电路就是身份。** 电路已经有可推导的容器、可核验的站点与持有人，用户也已认得它的名字。为服务另设注册表或名字语法，会造出第二套身份体系。把清单绑定到按 TAP-10 解析出的电路（§2.2 第 5 步），意味着清单永远不能自选身份：它的 `circuits`、`tokenId`、`container` 只需与客户端推导的结果一致。
- **清单是站点文件。** 它常变、体积小；作为站点文件不增加新成本，并继承 TAP-10 的核验（推导的容器、长度与 SHA-256、节点共识、钉住的实现）。存在合约里的清单需要自己的一套核验规则。
- **用委托，而不是让持有人签署一切。** 持有人是冷钱包、多签钱包或智能账户；回应请求需要热密钥。委托让持有人密钥不必上服务器；绑定 `container` 而非 `tokenId`，使委托只对恰好一个推导出的容器有效。
- **用中枢地址作 `verifyingContract`。** 这是 TapeOut 控制、在链表每条链上都存在的地址，因此服务不需要自己的合约，也不需要本 TAP 作者的任何合约。中枢从不被调用；它的升级或封印不改变任何摘要。各链由 `chainId` 区分。
- **366 天，强制。** 委托到期前无法撤销（§7.2），所以它的有效期就是签名密钥丢失时损害的上限。一年允许按年续期；更长的一律拒绝而不是信任。
- **站点状态完整适用，包括激活。** 清单读自站点存储，所以实现不被接受时 TAP-10 §6.1 本来就会阻止读取。激活不同：TAP-10 只通过合规的外壳执行激活（TAP-10 §6.3），消息层也不执行（TAP-10 §12.2）。本 TAP 把激活也用于服务解析，使客户端对一个名字得出与官方外壳相同的结论，服务身份与站点身份遵循同一套规则，服务约定也不会成为绕开激活的途径。另一种做法是：外壳以外的客户端照常解析未激活的服务，只把状态报告为 `unpaid`；这样服务在激活前就能使用，但同一个名字可能被一个客户端信任、被另一个客户端拒绝。
- **只读精确的键。** 落地规则是为浏览设计的。没有清单的服务不能被解析成它的 `index.html` 或回退页面。
- **内容签名是可选的。** 它只对要求它的客户端有用，而且证明的是认可，不是最新（§7.3）。若强制，今天所有无法对大对象签署类型化数据的持有人都会被挡住。它的类型名与 `Delegation` 不同，两种签名不能互相冒充；TAP-10 的密钥派生文本用 `personal_sign` 签署，与两者都不会碰撞。
- **带收紧的规范 JSON。** 存在两种都说得通的规范形式的值，就是两个验证方可能产生分歧的值，而验证方之间的分歧就是一次签名绕过。§6 的每条收紧都去掉了一种实际遇到过的情形（重复成员、`-0`、不安全整数、原型键、孤立代理项）。
- **金额用十进制字符串。** 不用浮点，JSON 可读，价格的定义与后续 TAP 如何结算无关。
- **未纳入的部分。** 早先文本（见向后兼容）中有标签目录合约、向站点暴露服务的外壳 API，以及 MCP 服务器与 AI API 的绑定。识别服务不需要其中任何一项；目录从未部署，外壳 API 从未实现。它们可以作为单独的 TAP 提出。
- **致谢。** 在电路身份下调用服务的想法来自 @Theairresearch。

## 向后兼容

本 TAP 不增加合约、中枢函数、载荷格式或名字语法，也不改动 TAP-10 的任何内容。不实施本 TAP 的 TAP-10 客户端把清单看作普通站点文件。

**历史与冻结常量。** 本规范此前在 TapeAPI 仓库中以自行起的名字 "TAP-20" 发布（配套文档为 "TAP-21" 至 "TAP-27"）。那些是本地名字，不是 TAP 编号；本 TAP 的编号由编辑分配（TAP-01 §6.1）。以旧名字部署的常量是历史常量，永不改变：EIP-712 域名 `"TapeAPI"` 与版本 `"1"`、类型串 `Delegation(address container,address signer,uint64 expires)` 与 `ManifestContent(address container,bytes32 contentHash)`、路径 `/.well-known/tapeapi.json`、版本字符串 `"0.1"`，以及配套草稿中的 `TAPI-1/resp/v2` 与以 `TAP-26/` 开头的标签等。它们都不表示本 TAP 的编号。

**现有清单。** 清单格式不变。早先文本中以建议形式出现的两条规则现在是要求，而参考实现早已执行这两条：拒绝重复成员名，以及 366 天上限。`11.1013.tape` 的线上清单满足这两条（见测试用例）。

**本文与参考实现的差异。** 参考实现（见参考实现一节，提交 `4a1ac4f`，版本 1.8.1）在以选项 `conform: 'tap10'`（其 TAP-10 一致模式，该版本标为实验性）创建时按本 TAP 解析服务。它的默认解析路径是按早先文本编写的，在其 1.x 各版本内保持不变；需要本 TAP 结论的客户端使用一致模式。下表按方面列出默认路径的做法、一致模式的做法与本 TAP 的规定：

| 方面 | 默认路径（1.8.1） | `conform: 'tap10'`（1.8.1） | 本 TAP |
|---|---|---|---|
| 容器推导 | `hub.accountOf(circuits, tokenId)` | `opener.accountOf`，并与本地 ERC-6551 推导比对 | 按 TAP-10 §4.2 的 `opener.accountOf`。对已接受的中枢实现，两者返回同一个 ERC-6551 地址（已在 BNB Smart Chain 块 124890135 对 `11.1013.tape` 核对） |
| 容器地址输入 | 先从该容器读取清单，再取清单中的处理器合约与 #ID，检查它们能推导出该容器、且工厂认得该处理器合约；不调用 `token()`，也不查处理器编号 | 在读取任何文件之前按 TAP-10 §4.3：`token()`、`isCPU`、处理器编号（随 SDK 发布的处理器表，每次命中先在钉块上读一次 `cpuAt` 核实，否则分页扫描 `cpuAt`），然后 `opener.accountOf` 必须推导出给定的地址 | 在读取任何文件之前按 TAP-10 §4.3 解析；清单中的身份值只用于比较（§2.2 第 5 步） |
| 标签输入 | 调用方配置了目录合约时（没有默认值），其它字符串会在目录中按标签查找 | 输入错误；输入形式为 TAP-10 §3.4 的各种形式，以及容器与"处理器合约加 #ID"的对象形式 | 不是输入形式（§2.1） |
| 缺文件 | 以 `fileInfo.size` 为 0 判断 | `chunkCount` 为 0 即 `no-manifest` | `chunkCount` 为 0（§2.2 第 3 步、TAP-10 §7.1） |
| 解码 | 解析前把非法 UTF-8 字节替换掉，并去掉开头的字节顺序标记 | 两者都使清单无效 | 两者都使清单无效（§3.1） |
| 开通 | 不读 | 读 `isOpened`；`not-opened` 结束解析 | TAP-10 §4.2 第 5 步、§6.2 `not-opened` |
| 激活 | 不检查 | 读 `isLive` 与 `isContainerLive`；`unpaid` 结束解析 | TAP-10 §6.2 `unpaid` 结束解析。作者的两个服务 `11.1013.tape` 与 `12.1013.tape` 在记录测试用例时（2026-09-30）未激活，解析为 `unpaid`；其持有人于 2026-10-01 激活了它们，2026-10-09 从两家运营方钉在 BNB Smart Chain 块 126658102（哈希 `0x152776aae99baff145411961ab761000d7825f21046648848d053a8a02b8b8ea`）读取时两个容器的 `isContainerLive` 均为 true |
| 实现钉住 | 读中枢与站点存储的实现槽，默认只警告 | 站点存储与付费合约在钉块上读取，失败即关闭（`store-changed`）；中枢的实现槽仍按只警告的检查读取 | 站点存储与付费合约，失败即关闭（`store-changed`） |
| 钉块 | 默认在 `latest` 读取；可选的钉块用 finality 标签与时间戳年龄 | 每次解析一个区块，按 TAP-10 §5.3 选取（每家运营方取其最低头块，取第 Q 高者减 2，按哈希读取），按块差判为 `stale-block` | 每次解析一个钉块，按块差判新鲜度（TAP-10 §5.3） |
| 无链信息的输入 | 只在调用方给出的链或配置链上解析 | 仅在另加选项 `allChains: true` 时：在每条活跃链上各自钉块解析，多于一条链命中即 `ambiguous`。不加该选项时，容器地址在它是本链容器时于本链解析，否则拒绝为 `unsupported`；以一个字符串给出的"处理器合约加 #ID"在发出任何请求之前拒绝为 `unsupported`；两者都不会回答 `not-tapeout` | 在所有活跃链上解析，`ambiguous`（TAP-10 §4.1） |
| 持有人读取的共识 | 所有读取用默认共识 | `eth_chainId`、`ownerOf` 以及合约持有人的 `eth_getCode` 与 `isValidSignature` 用严格共识；其它读取用默认共识 | 建议对 `ownerOf` 与 EIP-1271 调用采用严格共识（§2.2）；每个读取至少要默认共识 |
| 什么算回答 | 部分 JSON-RPC 错误被当作回答跨节点比较 | 只有结果与回滚算回答；其它错误按节点故障处理 | 只有结果与回滚算回答（TAP-10 §1） |
| 结果保留 | `accountOf` 与 `cpuAt` 的回答以及实现槽跨解析保留至多 300 秒 | 只保留处理器表；持有人、开通、激活与实现槽在新的钉块上重读，保留的服务满 60 秒后在调用前重新解析 | 持有人与站点状态至多依赖 60 秒；只保留处理器表（§7.1、TAP-10 §11） |
| 链检查 | 解析时不检查 `eth_chainId` | 每个客户端在采用第一次读取之前检查一次，用严格共识 | 建议（TAP-10 §5.4） |
| 结果名 | `MANIFEST_INVALID`（也用于缺文件、token 不存在、`no-hash`、`incomplete`）、`DELEGATION_INVALID`、`NOT_FOUND`、`RPC_DISAGREE`、`RPC_UNAVAILABLE`、`RPC_STALE` | 每个错误在 `error.data.status` 里带 §2.3 或 TAP-10 的名字；错误码保留，并为 `not-opened` 与 `unpaid` 新增 `SITE_STATUS` | §2.3 与 TAP-10 的名字 |

TAP-10 §3.1 的名字数值范围（#ID 至多 10^18，处理器编号至多 10^9）自 1.4.0 起在两条路径上都适用；本表的早先版本曾把它列为差异。除上表各行外，默认路径与本 TAP 的客户端对同一份清单得出相同结论。早先文本还定义了标签目录、外壳能力以及 MCP 与 AI 绑定（见原理"未纳入的部分"）；本 TAP 的客户端把 `mcp` 与 `ai` 成员当作未知成员忽略。

## 测试用例

向量文件在 `assets/tap-11/`。每个文件给出输入与精确的期望输出。下方固定提交的参考实现可复现 `delegation.json`、`content-signature.json` 与 `canonical-json.json`（后者由 `sdk/src/canon.js` 产出），以及 `mainnet-11-1013.json` 中的文件核验与委托恢复部分。本 TAP 按 TAP-10 新增的读取（opener、`isOpened`、激活、付费合约的实现槽）以普通 `eth_call` 与 `eth_getStorageAt` 记录；参考实现在 `conform: 'tap10'` 下进行这些读取，默认路径不进行（见向后兼容）。

**`delegation.json`**（§4）。域分隔符、三条链上的完整算例、公开测试密钥的两个签名，以及应拒绝的情形。对 `container = 0x0000000000000000000000000000000000000002`、`signer = 0x0000000000000000000000000000000000000003`、`expires = 1790000000`：

| 值 | 结果 |
|---|---|
| `keccak256("TapeAPI")` | `0x6f09e044b872e2827cf4fdc5d623450caee9449f1fc4151b8f9e3582593a8802` |
| `keccak256("1")` | `0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6` |
| `structHash` | `0x525ae7f6670fd36175882a96c6f8491af6c83c3ebb4ab51437a9733ecc7dd6da` |
| `DOMAIN_SEPARATOR`，chainId 56 | `0xa73ee348b5672f12dbc174f66a7d162c69e0d64befdba88475d9d7e3c0fd3ac7` |
| `digest`，chainId 56 | `0xf0ef7315ef455303fb4a7d8a301ca84f25e9fbd0641e931cdb01e7f7e8bcaa9a` |
| `DOMAIN_SEPARATOR`，chainId 8453 | `0xab3b0c6f3cecceb9d441893c56616889d71cf893f74296dc2229a6f241238516` |
| `digest`，chainId 8453 | `0x741c7e6412012f5134d127404641a4eb294c77e30a7b19104aece30efe1be9b9` |
| `DOMAIN_SEPARATOR`，chainId 196 | `0xf9c5be6dcd7d4cfdf9c57717c7d6a7e04bccd499d2a7f3fcfdc603cc7f1f3ad6` |
| `digest`，chainId 196 | `0xf4f57ad38c3efd363cbd271e3fc9fa7a54a1302db7f6adcc202a53f8a7cd529a` |

测试持有人密钥 `0x` 后接 64 个数字 `1`（地址 `0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A`）在 chainId 56 上签署 `container = 0x86DDaEF00401E3F10418398D67D7189fc458eA95`、`signer = 0x1563915e194D8CfBA1943570603F7606A3115508`、`expires = 1791592000`：摘要 `0xb6c9879471c2f82db4bb634a7ede3637872c77f75cf2746e30032e00a6b1be41`。应拒绝：同一签名用在 chainId 196 上（恢复出 `0xf041d1b484C5103D32Ee6eb3Fe5FE8CF3448f5b6`）；`expires` 晚一秒（恢复出 `0x2B93279a4576d81874Ad8BFfD7F66099f21F7aDd`）；`s` 换成 `n − s`（高 `s`）。有效期用例固定 `now = 1790000000`：`expires` 为 1790000000 与 1821622401 时拒绝，为 1790000001 与 1821622400 时接受。

**`content-signature.json`**（§5）。同一测试密钥在 chainId 56 上签署的两份清单，附其规范形式、`contentHash`（第一份为 `0x37b2d1b772e3f90d4975aecbe22d00e00c185e2db6e7ccf726a2cd4d7386e2b9`）、`structHash`、摘要与签名；第二份只有端点不同。把第一份的签名放到第二份内容上，恢复出 `0x39987963c6069A93915024607D5537DD733a208a`，应拒绝。

**`canonical-json.json`**（§6）。若干 JSON 文本及其精确的规范形式与 keccak256，包括按 UTF-16 码元的成员顺序（`é` 排在 emoji 之前）、数字形式与字符串转义；以及没有规范形式的文本（重复成员，含嵌套，以及其中一个用转义写出的情形；`-0`；`9007199254740992`；`1e400`；`__proto__` 与嵌套的 `constructor`；孤立代理项）。

**`mainnet-11-1013.json`**（§2）。BNB Smart Chain 上的服务 `11.1013.tape`，在块 124886559（哈希 `0x2c4a5d41009682a9a450cb9b9df5e4b03fef6e74b85e03c19f899f1eaff9ef69`）上只读，两家运营方回答一致。多数公共节点已不再提供该块的状态；在块 124890135（哈希 `0xae8aa2fc2ab1b59eaca4912929f13d09ea9426701e706336f65b27f34af10d66`）上再由两家运营方读取，结果相同：

| 读取 | 结果 |
|---|---|
| `cpuAt(1013)`、`isCPU` | `0xe02c26c7432A7121168AA9B610DE24eCf9a1a414`，true |
| `opener.accountOf(…, 11)`、`isOpened` | `0x1b2A657BcBa9D3229f57aC2f4FcbEE2AA756aAe8`，true |
| `ownerOf(11)` | `0x086bFB1908B1DF8C0c4412f28E4DD22Bdd52d715` |
| 站点存储与付费合约的实现 | `0x1d279D138A4D803378a7d4557c056f1beD53c261`、`0xaa226181a6588d3f9AC0035e5f3dBaF311039bCE`（均被接受） |
| `isLive("11.1013.tape", container)`、`isContainerLive(container)` | false、false |
| `fileInfo(container, ".well-known/tapeapi.json")` | 3,414 字节，`application/json`，SHA-256 `0xee57f304f8316802978695e8e9f14e89ce1f9e5c79123b5a583fdcfd3b52c37a` |

该块上的期望结果：**`unpaid`**。文件还给出精确的 3,414 字节清单（其 SHA-256 等于声明的哈希），以及第 3–6 步用这些字节得出的结果：`signer` 为 `0xaB70dEe8e1CEabb1D10eDFeBcbe0c313c53cf154`，`expires` 为 1798190813，委托摘要 `0x2477541749b1b28de5dba42ee4d9f252e904dfb9042eb15068527e3213fb4a7b`，恢复出持有人。两个应拒绝的情形：从该容器提供另一个服务的有效清单，以及把本清单的 `container` 换掉，都是 `manifest-invalid`。

## 参考实现

TapeAPI SDK，[BruceLanLan/tapeapi，提交 `4a1ac4fe2a0b2e3327652a794794765dd5da98ef`](https://github.com/BruceLanLan/tapeapi/tree/4a1ac4fe2a0b2e3327652a794794765dd5da98ef)（版本 1.8.1，MIT 许可）。以 `createTapeAPI({ conform: 'tap10' })` 创建的客户端按 §2 解析；SDK 的默认路径与本文的差异列在向后兼容中。

| 位置 | 覆盖 |
|---|---|
| `sdk/src/index.js`（`resolveConform`、`identifyAt`、`conformManifest`、`finishConform`、`siteStatus`） | `conform: 'tap10'` 下的 §2；§7.1（保留的服务满 60 秒后在调用前重新解析，`CONFORM_TTL_MS`） |
| `sdk/src/index.js`（`resolve`、`verifyDelegation`、`holderApproves`、`contentSigProblem`） | 默认路径；§4.3–§4.4、§5.2–§5.3（`requireContentSig`）、§7.3（`delegationFloor`） |
| `sdk/src/manifest.js` | §3 |
| `sdk/src/sig.js` | §4.1、§5 |
| `sdk/src/canon.js` | §6 |
| `sdk/src/rpc.js`（`tap10Block`；读取选项 `answers: 'tap10'` 与 `strict`）、`sdk/src/chains.js`、`sdk/src/processors-snapshot.js` | TAP-10 §5.3 的钉块、什么算回答、默认与严格共识、链表、名字及其范围、处理器表 |
| `sdk/test/conform-tap10.test.mjs`、`sdk/test/conform-strict-holder.test.mjs`、`sdk/test/conform-allchains.test.mjs` | 一致模式在模拟链上的测试：输入形式、§2.2 与 TAP-10 §6.2 的顺序、钉块、`ownerOf` 与 EIP-1271 的严格共识、无链信息的输入 |
| `docs/guides/upgrade-1.0.md` 的 "The TAP-10 conformance mode" 一节 | 如何开启该模式、它与默认路径的不同之处及其限制 |
| `spec/vectors/verify.py` | §4–§6 的独立 Python 实现，以仓库自己的向量和 `11.1013.tape` 清单的一份较早记录（`sdk/test/fixtures/mainnet-11-1013-manifest.json`）核对；它不读取测试用例中的文件 |

与本文的差异列在向后兼容中。BNB Smart Chain 上的服务 `https://api.tapeapi.fun`（`11.1013.tape`）与 `https://relay.tapeapi.fun`（`12.1013.tape`）以本格式发布清单。

## 部署

本 TAP 不部署合约。它按 TAP-10 部署表中的地址读取下列合约，只接受 TAP-10 列出的实现。2026-09-30 在每条链上从两家运营方重新读取了下表所有实现与封印状态（BNB Smart Chain 在块 124890135 及之后，Base 与 X Layer 在最新块），全部与 TAP-10 部署表一致。任何人都可以用 `eth_call` 以及对 ERC-1967 槽 `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` 的 `eth_getStorageAt` 重复核对。

| 合约 | BNB Smart Chain (56) | Base (8453) 与 X Layer (196) | 实现（TAP-10 部署表） | 本 TAP 用到什么 | 已封印？ |
|---|---|---|---|---|---|
| 处理器工厂（UUPS 代理） | `0x68224F668083c29e9800Be2a646d42d18cedF7e2` | `0x1f09DAeFA827f02CBb40967cc91b259763760761` | BNB `0xa68cCF4931d98ad0A4BE15eE40542eDc0DEc6422`；Base、X Layer `0x74956236Ab64eD143933040B4137E8A352e4d17b`。TAP-10 §13.8 的封印常量；本 TAP 不检查 | `cpuCount`、`cpuAt`、`isCPU`（TAP-10 §4） | 否 |
| 容器开通合约 | `0x021745DE2f42A7839d96f2d3634d0294487D81F1` | `0x536adD8F30f03b69f6fbF29d425A816A0dC50106` | — | `accountOf` `0x0c1905e5`、`isOpened` `0x8b508494` | — |
| ERC-6551 注册表 | `0x000000006551c19487814612e58FE06813775758` | 相同 | 不是代理 | 不调用；容器为 `registry.account(containerImplementation, 0, chainId, processor contract, #ID)`，客户端可以重算以核对 `accountOf` | — |
| 容器实现 | `0xAf4E78a2257C9c5480c2F8310E3b00437260751d` | `0xAC4F791353eE9F06e2C50Ae4C34680D28Ea52a57` | — | 每个容器背后的代码；`token()` `0xfc0c546a` 在容器本身上调用（TAP-10 §4.3） | — |
| 站点存储 `SiteRegistry`（UUPS 代理） | `0xd006ffdd5Ae313B17729621A00999cD3C71CE5e6` | `0xd6EFb7adCc9c83dC4924Ad56f6a8E4e969b9ADB6` | 必须为 BNB `0x1d279D138A4D803378a7d4557c056f1beD53c261`；Base、X Layer `0xa85c4143d1D4A77f54b8e4ecC9E6D1418Afea45f`（TAP-10 §6.1） | 实现槽、`fileInfo` `0x6c609107`、`read` `0xccaa7afb`、`readRange` `0x15a4cae2` | 否（可升级） |
| 付费合约 `DomainBinding`（UUPS 代理） | `0x861EE183de2BBE4a6ecf9D15812C123b566a3DB7` | `0x68809Fd2fb343aA57D0aeB7f33Defe477c9666f9` | 必须为 BNB `0xaa226181a6588d3f9AC0035e5f3dBaF311039bCE`（或此前的 `0x4E8684EaEA48b524245B2191DeE451eAa1c1cA94`）；Base、X Layer `0x5eBF29b80789e548907C707530C3C7607C4347Df`（TAP-10 §6.1） | 实现槽、`isLive` `0xd6b062cd`、`isContainerLive` `0xdcca979e` | 否（可升级） |
| DeWEB 中枢（代理） | `0xe61A9C7213a6Aa616C246a2B569e555B417b25ee` | 相同 | v3：BNB `0x80aFE7B77F2dFD08e9feab7675780baC34a7EE85`；Base `0x38A2d320b8984Bbac9b0a2691B6c0FD829A23867`；X Layer `0xdCC57797089eBD9f26e686379A4323f353a3F9C6`。由 TAP-10 消息层客户端检查（TAP-10 §13.8），本 TAP 不检查 | 不调用；其地址是 EIP-712 的 `verifyingContract`（§4.1） | 否 |

处理器合约读取 `ownerOf` `0x6352211e`；合约持有人读取 `isValidSignature` `0x1626ba7e`（§4.4）。截至上述读取，任何链上的中枢与处理器工厂均未封印（`isSealed()` 为 0，中枢所有者 `0x571d447f4f24688eC35Ccf07f1D6993655F6aF15`），站点存储与付费合约可升级。因此在它们封印或不再可升级之前，本 TAP 不能成为 Final（TAP-01 §5.1）。

## 安全考量

- **保护了什么。** 按 §2 行事的客户端只在以下条件下接受签名者：名字背后电路的当前持有人为这个确切的容器与签名者、在这条链上、在最近 366 天内签署了委托，且所在文件的字节与链上一致。自报的容器、仿冒的 ERC-721、另一条链的委托、前任持有人的委托、从另一个容器提供的清单都会被拒绝。
- **站点写入者。** 能写容器站点的人（持有人、持有人用 `setOperator` 设置的操作员，或站点存储的一次升级）可以在仍然有效的委托下改端点、方法与价格，也可以在旧清单的委托到期前把它放回去。他们不能为新签名者造出委托。要求 `contentSig`（§5）的客户端能发现内容被改，但发现不了回滚到较旧的已签名内容；下限（§7.3）只对见过较新清单的客户端能发现回滚。
- **签名密钥泄露。** 被盗的签名密钥在持有人发布新清单且客户端重读之前、或在委托到期之前，都代表该服务；366 天上限给它封顶。提供者应把签名密钥放在隔离的进程中，并使用较短的委托。
- **持有人转移。** 电路的买方继承容器与站点，包括旧清单；从下一次重读起，旧委托因恢复出的地址不再是持有人而失效。缓存了已解析服务的客户端在重读之前仍信任旧签名者（§7.1）。
- **节点。** 默认共识挡得住单个撒谎的节点，挡不住所有配置的运营方一起撒谎（TAP-10 安全考量）。伪造 `ownerOf` 或 EIP-1271 的回答会授权攻击者的签名者，这就是这两项读取建议用严格共识的原因。
- **可升级合约。** 站点存储、付费合约与处理器工厂的所有者在封印之前可以改变它们的返回。实现钉住让持久的改动失败即关闭，但发现不了在一笔交易内升级又恢复为已接受实现的情形（TAP-10 §13.8）。中枢不被调用，它的升级不影响本 TAP。
- **合约持有人。** EIP-1271 持有人由自己的代码决定接受哪些签名，它的回答可以逐块变化。把每次读取钉在同一块上保证一次解析内部一致，而不是随时间稳定。
- **时钟。** 有效期与客户端时钟比较，不同于 TAP-10 按块差判新鲜度。时钟偏慢的客户端会接受已过期的委托；偏快的会拒绝有效的委托。在意的客户端可以同时与钉块的时间戳比较。
- **激活。** 按本 TAP 解析要求名字已激活（§2.2 第 2 步、TAP-10 §6.3）。如 TAP-10 §6.3 所说，没有激活时站点存储仍可被读取；以这种方式读取清单的客户端并没有按本 TAP 解析该服务。
- **传输与含义。** `https://` 保护的是到端点的连接，不是它返回内容的真实性。清单证明的是谁站在服务背后，不是它的方法按描述工作；后续 TAP 定义的签名回答让行为可归责，而不是保证正确。
- **持有人签名时看到什么。** 钱包会显示 EIP-712 类型化数据的 `verifyingContract` 字段，所以持有人签署委托或内容签名时，会看到 DeWEB 中枢被列为验证合约（§1）。这是预期的，也无害：中枢从不被调用，也不在其上授权任何事（§4.1）。持有人应核对显示的其它字段，即容器、签名者与有效期，并确认域名称为 `TapeAPI`。
- **解析。** 清单由攻击者控制。64 KiB 上限、拒绝重复成员名与原型成员名，以及规范 JSON 的收紧，限制了解析器差异与原型污染。
- **隐私。** 解析只读取公开的链上状态。调用端点会向提供者暴露调用方的网络地址与请求内容。

## 版权

版权及相关权利依 [CC0](../LICENSE) 放弃。
