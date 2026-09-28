# Contributing to TAPs

This file explains how a proposal becomes a TAP. The rules themselves are in [TAP-01](TAPs/TAP-01.md); where the two differ, TAP-01 prevails. English first; 中文摘要在最后.

## 1. Before you write

1. Search the existing TAPs and open issues. Your idea may already be covered, or be close enough to extend.
2. Open an issue with the **Idea** template (it adds the label `idea`): the problem, who has it, and a rough outline of your solution. This is the **Idea** stage; there is no file and no number yet.
3. Wait for some feedback before investing in a full text. An idea that nobody else needs is better settled in a few comments.

## 2. Writing a draft

1. Copy [`TAP-template.md`](TAP-template.md) to `TAPs/TAP-draft-<short-title>.md`.
2. Fill in the preamble. Leave `tap: TBD`. Set `discussions-to` to your idea issue.
3. Write the sections in the template's order. For a Standards TAP, write the Specification so that someone who never talks to you can implement it: byte layouts, labels, function signatures, selectors and addresses written out in full.
4. Open a pull request that adds only that file (and its `assets/` files, if any).
5. Editors review the format, not the merit (TAP-01 §4). When it is ready they assign the number (TAP-01 §6.1), ask you to rename the file to `TAPs/TAP-<nn>.md` (at least two digits, e.g. `TAPs/TAP-11.md`), and merge it as **Draft**.

## 3. Bringing a draft you already published elsewhere

If your proposal already lives in your own repository, a gist or an issue thread:

1. Open an `idea` issue that links to it and says which TAPs it builds on (for most DeWEB conventions: TAP-10 and the tape:// specification).
2. Convert it to the template. A numbered TAP must be self-contained in this repository; links to your repository can stay as background, but nothing normative may depend on them.
3. Do not keep a self-assigned number. If your draft calls itself "TAP-20", call it `TAP-draft-<short-title>` until the editors assign a number; the assigned number may differ.
4. Choose the type honestly. Conventions that applications may adopt on top of a Standards TAP are **Application** TAPs; they must not weaken the Standards TAP they build on (TAP-01 §3).
5. You must have the right to dedicate the text to the public domain under CC0. If others wrote parts of it, list them as authors or get their agreement.

## 4. What editors check

Before merging a Draft:

- [ ] The preamble is complete and valid (TAP-01 §7.1); the type and status are correct;
- [ ] It covers one topic; the Summary is one sentence;
- [ ] Motivation and Specification are present and coherent;
- [ ] RFC 2119 key words appear only in capitals and only for real requirements;
- [ ] Examples are marked as examples;
- [ ] Nothing normative depends on an external link, except references at a fixed commit or version;
- [ ] The license is CC0-1.0.

Before moving a Standards TAP to Review, additionally:

- [ ] Test vectors exist and a reference implementation reproduces them;
- [ ] The reference implementation is linked at a fixed commit;
- [ ] Every deployed address in Deployments has been verified read-only on each chain, and the TAP says how;
- [ ] Security Considerations are written.

## 5. Changing an existing TAP

- Open a pull request that changes only that TAP (and its assets or translations).
- Draft and Review TAPs: the TAP's authors approve. Candidate TAPs: an editor also approves and the change goes into the TAP's change log. Final TAPs: errata only (TAP-01 §5.3).
- A Draft or Review TAP with no activity for 6 months becomes Stagnant; editors may then hand it to new authors (TAP-01 §5).

## 6. Translations

Translations go in `TAPs/TAP-<nn>.<lang>.md` and are informative. Keep them section-by-section in sync with the English text; a pull request that changes the English text should say whether the translation still matches.

## 7. License

By contributing text to this repository you dedicate it to the public domain under CC0 1.0 Universal. Code files you add under `assets/` are licensed under the MIT License unless they say otherwise (see [LICENSE](LICENSE)).

---

## 中文摘要

- 规则以 [TAP-01](TAPs/TAP-01.md) 为准，本文件只讲怎么操作。
- **先讨论**：用 Idea 模板开一个 issue（会自动加 `idea` 标签），说清问题和大致方案。这一步没有文件，也没有编号。
- **写草稿**：复制 `TAP-template.md` 为 `TAPs/TAP-draft-<短标题>.md`，`tap` 字段写 `TBD`，提一个只包含这个文件的 PR。编辑只审格式和完整性，不评判方案好坏；分配编号后（至少两位数，如 TAP-11）合并为 Draft。
- **别处已有草稿**（自己的仓库、gist、issue）：开 `idea` issue 并附上链接，改写成模板格式，所有规范性内容都要放进本仓库；不要沿用自己起的编号，正式编号由编辑分配。多数“建立在 TAP-10 之上的应用约定”属于 Application 类型，不能削弱它所依赖的 Standards TAP。
- **授权**：贡献的文字以 CC0 放入公有领域；`assets/` 下的示例代码默认用 MIT 许可。
- **英文为准**：译文放在 `TAP-<nn>.<lang>.md`，仅供参考。
