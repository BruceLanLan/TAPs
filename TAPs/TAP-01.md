---
tap: 1
title: TAP Purpose and Process
description: What a TAP is, the four types of TAPs, how a TAP moves from idea to final, and how TAPs are written and reviewed.
author: TapeOut (@TapeOutProtocol)
discussions-to: TBD
status: Draft
type: Process
created: 2026-09-27
license: CC0-1.0
---

# TAP-01: TAP Purpose and Process

> **Status: Draft.** This TAP is adopted through its own process: it is merged as a Draft, moves to Review for a public review of at least 14 days, and then becomes **Living** (§5.2). Items marked **[Open]** are still undecided; §11 lists them.

## Summary

TAPs are the public, numbered documents in which the TapeOut community proposes, reviews and records the standards of the TapeOut protocol and DeWEB.

## 1. What a TAP is

A TAP is a design document for the TapeOut ecosystem: the circuit protocol, circuit containers, and DeWEB (websites, messaging and other services built on containers). A TAP describes one thing precisely enough that people who never talk to its authors can implement it and interoperate: an interface, a data format, a verification rule, or a process.

Every TAP has one or more authors. They write it, build agreement around it, and record the objections raised against it. TAPs are text files in the TAPs repository, so the history of every standard is its commit history.

The process follows BNB Chain's BEP-1 and Ethereum's EIP-1, scaled down for a smaller community.

## 2. Why TAPs

- One place to propose a standard and to find the current version of one;
- A stable, numbered reference that code, contracts and other TAPs can cite (TAP-10's key-derivation labels, for example, contain the string `TAP-10`);
- A record of why a design was chosen, including the alternatives that were rejected;
- A clear status for every standard, so implementers know what they can rely on.

## 3. Types

| Type | What it covers | Normative for | Example |
|---|---|---|---|
| **Standards** | Contract interfaces, data and payload formats, key derivation, and the client verification rules that independent implementations must follow to interoperate safely | Every implementation | TAP-10 (DeWEB Access and Messaging Layers) |
| **Application** | Conventions that applications may adopt on top of Standards TAPs: request/response patterns, tool discovery, SDK and API shapes, metadata formats | Applications that claim to follow it | A request/response convention for DeWEB sites |
| **Information** | Background, guidelines and best practices | Nobody (no requirements) | An implementer's guide |
| **Process** | How TAPs, or other community processes, work | The process | TAP-01 (this document) |

All types live in the same `TAPs/` directory; the `type` field tells them apart. (BEP-1 keeps application proposals in a separate `BAPs/` directory; one small repository does not need that.)

An Application TAP **MUST NOT** weaken a requirement of a Standards TAP it builds on. If it needs to, it proposes a change to that Standards TAP instead.

## 4. Roles

- **Authors** write a TAP, answer review, and move it forward. Only the authors change a TAP's content, except that editors may fix errata and may hand a Stagnant TAP to new authors (§5).
- **Editors** keep the process running: they check format, assign numbers, merge drafts, change statuses, and announce review periods. Editors judge whether a TAP is complete, coherent and on one topic, not whether they like it. Until editors are named in this TAP, the maintainers of the TapeOutProtocol organization on GitHub act as editors. **[Open]** Who the editors are, and how someone becomes one.
- **Implementers** maintain reference implementations and test vectors. A Standards TAP cannot enter Review without them.
- **Contract owners** can upgrade a deployed contract that a TAP depends on. Owners and editors are separate roles: an owner can upgrade a contract, but a compliant client accepts only the implementations that the TAP lists (the tape:// specification and TAP-10 already work this way).

## 5. Statuses

| Status | Meaning | How a TAP gets here |
|---|---|---|
| **Idea** | Discussion only; no file, no number | Anyone opens an issue in the TAPs repository with the label `idea` |
| **Draft** | Merged into the repository with a number; content may still change freely | Editors merge the pull request once the TAP follows the template (§7), covers one topic, and is coherent. Merging a Draft does not mean the proposal is accepted |
| **Review** | The authors consider it complete and ask for review | Editors announce a public review period of at least 14 days. A Standards TAP needs a reference implementation and test vectors to enter Review |
| **Candidate** | Accepted, but a contract it depends on can still be upgraded; for a Standards TAP, its reference implementation is deployed | Editors, when the review period ends with no unresolved objection |
| **Final** | No further changes except errata. Every contract it depends on is sealed or was never upgradeable | Editors, when a review period ends with no unresolved objection, or once the contracts of a Candidate are sealed |
| **Living** | Kept up to date indefinitely | Editors, at the end of a Process TAP's review period (§5.2) |
| **Stagnant** | A Draft or Review TAP with no activity for 6 months | Editors. The authors, or new authors with editor agreement, can return it to Draft |
| **Withdrawn** | Abandoned by its authors, or its premise no longer holds | Authors or editors, at any stage before Final. The number is never reused |

### 5.1 Paths

- **Standards, Application and Information TAPs:** Idea → Draft → Review → Candidate → Final. A TAP that depends on no upgradeable contract goes from Review straight to Final. A TAP that depends on an upgradeable contract passes through Candidate and becomes Final only once that contract is sealed.
- **Process TAPs** that are meant to be kept up to date, such as this one: Idea → Draft → Review → Living.

A TAP that relies on an upgradeable contract cannot become Final while the contract can still be upgraded: until the upgrade path is removed, the owner can change what the contract does, and the text could stop describing it. Candidate covers the time in between. (TAP-10 v1.0 stated the same rule for itself: it would stay a draft until its hub contract was sealed.)

### 5.2 Adopting this TAP

TAP-01 is adopted through the process it defines. Editors merge it as a Draft, move it to Review when they announce a public review period of at least 14 days in the TAPs repository and TapeOut's community channels, and move it to Living when the review period ends with every objection resolved or answered in the text.

### 5.3 Changing a TAP

- **Draft and Review:** authors change the text freely through pull requests.
- **Candidate:** changes need editor approval and are listed in the TAP's change log. A change that breaks existing implementations needs a new major version (§6.3).
- **Final:** errata only (typos, broken links, clarifications that change no requirement). Anything else needs a new TAP that supersedes it.
- **Living:** updated through pull requests approved by an editor.

## 6. Numbers, names, files and versions

### 6.1 Numbers and names

**[Open]** Numbering rule, based on BEP-1:

- A TAP's number is the number of the pull request that first proposes it;
- Numbers 1–9 are reserved for Process and Information TAPs about the TAP process itself. TAP-10 was assigned before this process existed and keeps its number;
- If the pull request number is in the reserved range or already belongs to a TAP, editors assign the lowest number above 9 that is neither a TAP nor the number of an open pull request;
- Numbers are never reused, not even those of Withdrawn TAPs.

A TAP is named `TAP-` followed by its number written with at least two digits: TAP-01 to TAP-09, then TAP-10, TAP-11, TAP-123. The preamble's `tap` field holds the plain number (`1` for TAP-01).

Authors do not pick their own numbers. A draft that gives itself a number elsewhere (for example "TAP-20" in a personal repository) is not a TAP until the editors assign it a number here, and that number may differ.

The reserved range and the reassignment rule are additions; BEP-1 has neither. The alternative is that editors assign the next free number when they merge a Draft. That gives denser numbers, but authors learn their number only at merge time instead of when they open the pull request.

### 6.2 Files

| Path | Content |
|---|---|
| `TAPs/TAP-<nn>.md` | The English text, which is normative. `<nn>` is the number with at least two digits, as in the name |
| `TAPs/TAP-<nn>.<lang>.md` | A translation (for example `TAP-10.zh.md`). Informative: where it differs from the English text, the English text prevails |
| `assets/tap-<nn>/` | Images, test vectors, example code and other supporting files. Code files are under the MIT License unless they say otherwise; everything else is CC0 (see `LICENSE`) |
| `TAPs/TAP-draft-<short-title>.md` | A proposal before editors assign its number |

Anything normative lives in this repository. A TAP may link to a reference implementation, but only at a fixed commit.

### 6.3 Versions

A TAP may carry a `version` of the form `X.Y` when implementations need to tell editions apart. `Y` increases for backwards-compatible additions; `X` increases for changes that require implementations to change in order to keep working. The `updated` date changes with every edit. A Final TAP gets no new versions; a successor TAP supersedes it. Formats defined inside a TAP (such as TAP-10's payload format `0x02`) carry their own version numbers, defined by that TAP.

## 7. Format

### 7.1 Preamble

Every TAP starts with YAML front matter:

| Field | Required | Content |
|---|---|---|
| `tap` | yes | The plain number (for example `1` for TAP-01), or `TBD` before one is assigned |
| `title` | yes | A short title, without the TAP number |
| `description` | yes | One sentence |
| `author` | yes | Comma-separated names with GitHub handles, e.g. `Alice (@alice)` |
| `discussions-to` | yes | URL of the discussion thread |
| `status` | yes | One of §5 |
| `type` | yes | One of §3 |
| `created` | yes | ISO 8601 date |
| `updated` | no | ISO 8601 date of the last change |
| `version` | no | §6.3 |
| `requires` | no | TAP names, or external specifications with their versions |
| `supersedes`, `superseded-by` | no | TAP names |
| `license` | yes | `CC0-1.0` |

### 7.2 Sections

In this order. Sections marked *optional* may be left out when there is nothing to say. TAP-01 itself is exempt from this section, as BEP-1 is from its own format; it uses key words outside a Specification section.

1. **Summary**: one sentence that a reader without technical background can understand.
2. **Abstract**: a short paragraph on what the TAP specifies.
3. **Motivation**: the problem, and why existing TAPs or current practice do not solve it.
4. **Specification**: the normative part, precise enough for an independent implementation. It uses the key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT** and **MAY** as described in RFC 2119 and RFC 8174 (they carry that meaning only in capitals).
5. **Rationale**: why this design; the alternatives considered; the objections raised and how they were resolved.
6. **Backwards Compatibility** (*optional*): what breaks, and how to migrate.
7. **Test Cases**: required for Standards TAPs. Test vectors that every implementation must reproduce exactly: inputs and expected outputs, stored under `assets/tap-<nn>/` or in a reference implementation at a fixed commit.
8. **Reference Implementation**: required for Standards TAPs before Review; linked at a fixed commit.
9. **Deployments**: required for Standards TAPs that depend on deployed contracts. For every chain: the addresses, the implementation each proxy must point to, how anyone can recompute or verify these read-only, and whether each upgrade path is sealed.
10. **Security Considerations**: required for every TAP except Information TAPs. What an attacker can do, what the design protects, and what it does not.
11. **Copyright**: "Copyright and related rights waived via CC0."

### 7.3 Style

- State each requirement once, in the section where a reader will look for it;
- Write out numbers, labels, byte layouts and addresses in full instead of describing them;
- Mark examples as examples. Anything in an example that the Specification does not also state is not a requirement;
- Keep token prices, marketing and roadmaps out of TAPs.

## 8. Discussion and decisions

- Discussion happens in the TAPs repository: ideas in issues, drafts in their pull requests. Each TAP names its thread in `discussions-to`. Editors also announce new Drafts and review periods in TapeOut's community channels;
- Editors change statuses by rough consensus: every objection raised during Review is either resolved or answered in the TAP's Rationale before the TAP moves on;
- A Standards TAP that needs a contract deployed or upgraded also needs the contract owner to do it. The TAP records deployments; it cannot order them;
- **[Open]** Whether significant Standards TAPs also get a non-binding signal vote (for example by BEM holders). BEP-1 requires a governance vote for major changes.

## 9. Language

English is the normative language of every TAP. Translations are welcome and informative (§6.2). Discussion may happen in any language; decisions are summarised in English in the TAP or its pull request.

## 10. Relationship to other specifications

- **tape:// specification** (TapeKit `SPEC.md`, v0.2): it predates TAPs. TAP-10 incorporates it as the DeWEB access layer, next to the messaging layer, and supersedes it once merged.
- **BEPs:** proposals that change BNB Chain itself belong in bnb-chain/BEPs; proposals specific to TapeOut belong here. **[Open]** How the HashPort BEP draft on verifiable on-chain front ends relates to TAPs.
- **ERCs:** where an existing ERC fits, a TAP uses it rather than defining a new interface.

## 11. Open questions

1. Who are the editors, and how does someone become one? (Until decided, the TapeOutProtocol maintainers act as editors, §4.)
2. Numbering: the pull request number (BEP-1) or editor assignment (§6.1)?
3. Is the Candidate status worth having (§5)?
4. Do editors decide by rough consensus alone, or is there a signal vote for major Standards TAPs (§8)?
5. Does "TAP" expand to an official name?
6. How does the HashPort BEP draft relate to TAPs (§10)?

## References

- BEP-1: Purpose and Guidelines. https://github.com/bnb-chain/BEPs/blob/master/BEPs/BEP1.md
- EIP-1: EIP Purpose and Guidelines. https://eips.ethereum.org/EIPS/eip-1
- RFC 2119: Key words for use in RFCs to Indicate Requirement Levels. https://www.rfc-editor.org/rfc/rfc2119
- RFC 8174: Ambiguity of Uppercase vs Lowercase in RFC 2119 Key Words. https://www.rfc-editor.org/rfc/rfc8174

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
