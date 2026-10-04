# TAPs

TAPs are the public, numbered documents in which the TapeOut community proposes, reviews and records the standards of the TapeOut protocol and DeWEB. The process is defined in [TAP-01](TAPs/TAP-01.md) and follows Ethereum's EIP-1.

## Index

| TAP | Title | Type | Status |
|---|---|---|---|
| [TAP-01](TAPs/TAP-01.md) | TAP Purpose and Process | Process | Draft |
| [TAP-02](TAPs/TAP-02.md) | Circuit Netlist Format and Evaluation Semantics | Standards | Draft |
| [TAP-10](TAPs/TAP-10.md) | DeWEB Access and Messaging Layers | Standards | Draft |
| [TAP-11](TAPs/TAP-11.md) | TapeAPI Service Manifest and Holder Delegation | Application | Draft |

Drafts that are proposed but not yet merged are the open pull requests.

## Proposing a TAP

1. Open an issue with the **Idea** template and discuss the problem first.
2. Copy [`TAP-template.md`](TAP-template.md) to `TAPs/TAP-draft-<short-title>.md` and open a pull request.
3. Editors check the format, assign a number and merge it as a Draft.

Details: [CONTRIBUTING.md](CONTRIBUTING.md).

## Statuses

Idea → Draft → Review → Candidate → Final; Process TAPs such as TAP-01 become Living instead. Also Stagnant and Withdrawn. A TAP that depends on an upgradeable contract becomes Final only after that contract is sealed ([TAP-01 §5](TAPs/TAP-01.md#5-statuses)).

## License

All TAP texts are dedicated to the public domain under [CC0 1.0](LICENSE); example code under `assets/` is MIT. English is normative; translations are informative.

## 中文说明

TAP（TapeOut 协议提案）是 TapeOut 社区提出、评审和记录协议与 DeWEB 标准的公开文档，流程见 [TAP-01](TAPs/TAP-01.md)，参照以太坊的 EIP-1。

- 想提新标准：先用 Idea 模板开 issue 讨论，再复制模板写草稿提 PR，编辑审核格式、分配编号后合并为 Draft。详见 [CONTRIBUTING.md](CONTRIBUTING.md) 的中文摘要。
- 以英文文本为准，译文仅供参考；文本以 CC0 放入公有领域，`assets/` 下的示例代码用 MIT 许可。
- 已合并的 TAP 见上方索引；提交了但尚未合并的草稿见 open pull requests。
