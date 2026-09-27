# TAPs — TapeOut Protocol Proposals

TapeOut 协议提案。协议层面的改动、新格式、新接口，都先写成一份 TAP，公开讨论后再实现。

Design documents for the TapeOut Protocol. Anything that changes the protocol — new formats, new interfaces, new on-chain conventions — starts as a TAP, gets discussed in the open, and only then gets built.

## 编号 / Numbering

`TAP-<n>`，按提交顺序分配，永不重用。一份提案一个目录：`TAP-<n>/README.md`，附件放同一目录。

`TAP-<n>`, assigned in submission order, never reused. One proposal per directory: `TAP-<n>/README.md`, with any attachments alongside it.

## 状态 / Status

| 状态 / Status | 含义 / Meaning |
| --- | --- |
| Draft | 起草中，随时会变 / Work in progress, may change at any time |
| Review | 征求意见，接口基本稳定 / Open for comment, interface mostly settled |
| Final | 已实现并上主网，接口冻结 / Implemented on mainnet, interface frozen |
| Withdrawn | 已放弃 / Abandoned |

Final 之后不再改动。要改就开一份新的 TAP，并在旧的那份里注明被谁取代。

Once Final, a TAP is not edited. Changes go into a new TAP, and the old one records which TAP supersedes it.

## 怎么提一份 TAP / How to submit

1. Fork 本仓库，新建 `TAP-<n>/README.md`。
2. 写清楚四件事：要解决什么问题、具体方案、为什么这样选、以及对现有链上数据和合约的影响。
3. 发一个 Pull Request。编号有冲突的话，合并时会重新分配。

Fork this repository, add `TAP-<n>/README.md`, and open a pull request. State the problem, the proposal, the rationale, and the impact on existing on-chain data and contracts. Numbers are reassigned at merge time if two proposals collide.

## 已有提案 / Existing proposals

TAP-10（DeWEB 跨链消息层 / cross-chain messaging）目前仍在 [TapeKit](https://github.com/TapeOutProtocol/TapeKit) 仓库中，之后会迁移到这里。

TAP-10 currently lives in the [TapeKit](https://github.com/TapeOutProtocol/TapeKit) repository and will be migrated here.

## 相关仓库 / Related

- [TapeKit](https://github.com/TapeOutProtocol/TapeKit) — 协议的开源浏览器内核与工具 / open-source browser kernel and tooling

## 许可 / License

规范文本 CC0-1.0，示例代码 MIT。

Specification text is CC0-1.0. Example code is MIT.
