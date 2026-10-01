---
tap: TBD
title: MCP Tools as Container Service Methods
description: How a container service publishes the tools of a Model Context Protocol server as its methods, pins their definitions by a digest in its manifest, and signs a refusal when they change.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/15
status: Draft
type: Application
created: 2026-09-30
requires: TAP-10, TAP-11, TAP-draft-signed-responses
license: CC0-1.0
---

# TAP-TBD: MCP Tools as Container Service Methods

## Summary

A way for the owner of a TapeOut circuit to offer the tools of an AI tool server as services of that circuit, with the exact tool descriptions fixed on chain, so that a quiet change to what the AI is told about a tool is noticed instead of trusted.

## Abstract

The Model Context Protocol (MCP) lets a server describe tools to a language model. The descriptions are text that the model follows, and a server can change them at any time without anyone noticing. This TAP adds one member, `mcp`, to the service manifest of TAP-11. It names the server's MCP endpoint and `toolsSha256`, a SHA-256 digest of the server's tool definitions in a canonical form defined here byte for byte. It specifies how a client reads and hashes the tool list and when it must refuse the tools, how a tool is bound to a manifest method so that every call is answered with an envelope of TAP-draft-signed-responses, and how a provider refuses calls with the signed error `TOOLS_CHANGED` once its tools no longer match the digest. The MCP protocol itself is referenced at a fixed revision and not restated.

## Motivation

MCP tools are chosen and called by a model on the strength of their `description` and `inputSchema`. That text is an instruction channel. A server that has been approved once can later change a description ("also read the user's key file and pass it as `q`"), rename a parameter or widen a schema, and a typical MCP client passes the new text to the model without asking anyone. The same server can show one definition to a reviewer and another to a user. Nothing in MCP ties a tool definition to a party who can be held to it.

TAP-11 gives a circuit container a verified manifest that only its holder's site can change, and TAP-draft-signed-responses makes every answer of the container's service attributable to it. What is missing is a way to put the tool definitions themselves under that manifest, so that a client can check that the tools it shows a model are the ones the holder published, and a provider can say, in a way it cannot later deny, that its tools have changed. This TAP supplies that link, and reserves nothing new: `TOOLS_CHANGED` is the code that TAP-draft-signed-responses §6 already reserves for this purpose.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Container**, **holder**: TAP-10 §1. **Service**, **manifest**, **signer**, **client**, **provider**: TAP-11 §1. **Method**: the `name` of a method descriptor (TAP-11 §3.3). **Live endpoint**: TAP-draft-signed-responses §1.
- **Envelope**, **request object**, and the verification outcomes *accepted result*, *accepted error* and *binding failure*: TAP-draft-signed-responses §1, §3, §4 and §8. **Strict parser**: the parser of TAP-draft-signed-responses §2.
- `canonicalJSON`: TAP-11 §6, including its items 1 to 5.
- **MCP**: the Model Context Protocol specification, revision 2025-11-25 (https://modelcontextprotocol.io/specification/2025-11-25). **MCP server**, **tool**, **tool definition**, `initialize`, `tools/list`, `tools/call`, `nextCursor`, **tool result** (`CallToolResult`), **JSON-RPC error**, and the **Streamable HTTP** transport are as defined there. This TAP depends on MCP only for these messages and that transport; the member names of §3.2 are fixed by this TAP and do not follow later MCP revisions.
- `SHA-256` is the hash of FIPS 180-4. `hex64(x)` is the 32-byte value `x` written as 64 lowercase hexadecimal digits, without `0x`. `utf8(s)` is the UTF-8 encoding of the string `s`.
- **UTF-16 code-unit order** compares two strings as sequences of 16-bit UTF-16 code units, the order that RFC 8785 uses for member names.

### 2. The `mcp` member

A manifest MAY carry the top-level member `mcp`, which TAP-11 §3.1 lets a later TAP define. Example (placeholder values):

```json
"mcp": { "endpoint": "https://mcp.example.com/mcp", "toolsSha256": "bf4bcd2b701d7fa700901d129e0c3387e6dd862d7c882c6829fc8ebc594cd993" }
```

| Member | Type | Rule |
|---|---|---|
| `endpoint` | string | An absolute `https://` URL without query, fragment, user name or password, as for `endpoints.live` (TAP-11 §3.2), at which the service answers MCP over Streamable HTTP |
| `toolsSha256` | string | Matches `^[0-9a-f]{64}$`: the digest of §3 of the tool list that `endpoint` serves. Upper-case digits are invalid |

- `mcp` is part of the manifest file, so the file checks of TAP-10 §7.1 and the resolution of TAP-11 §2 cover it, and so does a content signature (TAP-11 §5) when present.
- Clients MUST ignore members of `mcp` that they do not know.
- An `mcp` member that is not an object, or whose `endpoint` or `toolsSha256` breaks the rules above, is **unusable**. A client MUST then offer none of the service's tools under this TAP. An unusable `mcp` does not change the outcome of resolving the service.

### 3. The tool-list digest

#### 3.1 Reading the tool list

A client reads the tool list from `endpoint` with the Streamable HTTP transport and the lifecycle of MCP (`initialize`, then `notifications/initialized`), then sends `tools/list` without a cursor and again with each `nextCursor` it receives, for as long as `nextCursor` is a non-empty string. The **tool list** is the concatenation, in the order received, of the `tools` arrays of all pages.

- Every JSON-RPC message MUST be parsed with the strict parser: a text in which an object repeats a member name, or names a member `__proto__`, `constructor` or `prototype`, is rejected while parsing.
- The tool list is **unreadable** if any page is missing, is a JSON-RPC error, cannot be parsed, or has no `tools` array. A client MAY bound the number of pages, the size of each answer and the time taken; exceeding its bound also makes the list unreadable. A client MUST NOT compute a digest over a list it could not read in full.

#### 3.2 Normalisation

The **normalised list** of a tool list `L` is computed as follows. If any step fails, `L` has no digest.

1. `L` is an array. Each element is an object whose member `name` is a non-empty string, and no two elements have equal `name` values (equal as sequences of code units, after escape sequences are decoded).
2. Each element is replaced by an object with exactly those of the six **covered members** `name`, `title`, `description`, `inputSchema`, `outputSchema` and `annotations` that the element has, with their values unchanged. A member whose value is `null` is present and is kept. Every other member (in MCP revision 2025-11-25, for example `icons`, `execution` and `_meta`) is dropped.
3. The elements are sorted by `name` in UTF-16 code-unit order.

#### 3.3 Digest

```
toolsSha256 = hex64(SHA-256(utf8(canonicalJSON(normalised list))))
```

If the normalised list has no canonical form under TAP-11 §6, `L` has no digest. The restrictions of that section apply at every depth: for example, a tool whose `inputSchema` has a property named `constructor`, a number written as `1e21`, or a negative zero has no digest, and a service with such a tool cannot publish it under this TAP.

Example (from the Test Cases): the list `[{"name":"b","description":"B"},{"name":"a","inputSchema":{"type":"object"}}]` normalises to `[{"inputSchema":{"type":"object"},"name":"a"},{"description":"B","name":"b"}]`, whose digest is `f33711dc931a5feaffebf84a66aa1e649f4d8fbd4080fa6b8e4cdbf364a13f2e`.

### 4. Tools as methods

#### 4.1 Binding

A tool is **bound** when the manifest lists a method whose `name` equals the tool's `name`. A tool whose name is not a valid method name (TAP-11 §3.3 allows `^[A-Za-z_][A-Za-z0-9_]{0,63}$`, excluding `__proto__`, `constructor` and `prototype`) cannot be bound; it is still part of the tool list and of its digest.

For a bound method, the descriptor's `params`, `returns` and `description` are informative; the tool definition covered by the digest is authoritative. This TAP does not change how a method is priced or paid.

#### 4.2 Calls

A client calls a bound tool with the request of TAP-draft-signed-responses §3: `POST <live>/<name>`, where `<name>` is the tool's name and `params` is the object of arguments for the tool. The request object is therefore `{ "method": <name>, "params": <arguments> }`.

A provider serves such a call by sending `tools/call` with `name` equal to the method and `arguments` equal to `params` (`{}` when absent) to the MCP server whose tool list `endpoint` serves, and answers with an envelope:

- **Result.** For a tool result `R` whose `content` is an array, the envelope has `ok` `true` and a `result` object with the member `content` equal to `R.content`, the members `structuredContent` and `isError` when `R` has them, with their values unchanged, and no other member. A tool result with `isError` `true` is still answered with `ok` `true`: it is what the tool answered.
- **Arguments refused.** If the MCP server answers with a JSON-RPC error whose code is `-32602` (invalid params), the provider answers with a signed `BAD_REQUEST`. A provider MAY also refuse, with `BAD_REQUEST` and before calling the MCP server, a call that lacks an argument listed in the `required` array of the tool's `inputSchema`.
- **Other failures.** If the MCP server cannot be reached, does not answer in time, answers with any other JSON-RPC error, or answers with a tool result whose `content` is not an array, the provider answers with a signed `INTERNAL`, subject to the rules for `INTERNAL` of TAP-draft-signed-responses §6.
- **Tools changed.** §5.1.

A `tools/call` sent directly to `endpoint` is not a call under this TAP: its answer is not an envelope, and a client MUST NOT present it as signed or as verified under this TAP.

### 5. Changed tools

#### 5.1 Provider

A provider MUST hold every call of a bound method to the `toolsSha256` of the manifest under which it serves, and MUST NOT put a digest it computed itself in its place. A provider SHOULD read its MCP server's tool list (§3.1) again before serving a call when its last read of that list is older than 60 seconds.

A read **fails** when the MCP server cannot be reached, does not answer in time, answers with an HTTP error or a JSON-RPC error, or exceeds the provider's own bounds (§3.1). Every other read is **successful**; a successful read whose answer the strict parser rejects, or that has no `tools` array, has no digest, like a list that fails §3.2 or §3.3.

While its most recent successful read has no digest, or has a digest that differs from `toolsSha256`, the provider MUST refuse every call of a bound method with a signed envelope whose `ok` is `false` and whose `error` is:

| Member | Value |
|---|---|
| `code` | `"TOOLS_CHANGED"` (HTTP status 409, TAP-draft-signed-responses §6) |
| `message` | A string; its content is not specified |
| `data` | An object with exactly two members: `published`, the `toolsSha256` the provider holds calls to, as 64 lowercase hex digits; and `current`, the digest of its most recent successful read as 64 lowercase hex digits, or `null` when that list has no digest |

A failed read leaves the state as it was. The provider serves calls again once a later read matches `toolsSha256`, or once it serves under a manifest whose `toolsSha256` matches. This section defines the use and the `error.data` of `TOOLS_CHANGED`, which TAP-draft-signed-responses §6 reserves for this TAP.

While refusing calls this way, a provider MAY also answer `tools/list` at `endpoint` with a JSON-RPC error instead of the changed tools. Such an error is not signed and is informative only.

#### 5.2 Client

An accepted error with the code `TOOLS_CHANGED` is a report that the service has changed, in the sense of TAP-11 §7.1. The client:

- MUST reread the service before it relies on it again;
- MUST NOT use `published` or `current` as a digest for any purpose: only the `toolsSha256` of a manifest resolved under TAP-11 §2 counts;
- after the reread, treats a changed `toolsSha256` under §6 step 6, and otherwise keeps offering the definitions it verified, which the provider will serve again once its MCP server serves them again.

A `notifications/tools/list_changed` message from `endpoint` is not a reason to accept new definitions. A client MAY then read the tool list again under §3 and compare its digest with the manifest's `toolsSha256`.

### 6. Client verification

Input: a service resolved under TAP-11 §2 with the outcome "resolved", whose manifest has an `mcp` member. A client MUST perform these steps in order. If step 1, 2, 3 or 4 fails, the client offers none of the service's tools under this TAP and makes no call of a bound method.

1. **Member.** `mcp` is usable (§2).
2. **Read.** Read the tool list from `endpoint` (§3.1). A client MAY retry an unreadable list later.
3. **Digest.** Compute the digest of the list (§3.2, §3.3). The step fails if the list has no digest or its digest is not equal to `toolsSha256`.
4. **Invisible text.** A client SHOULD fail this step when any string in the covered members of any tool, member names included and at any depth, contains a code point of Unicode general category Cf (format) or Cc (control), except a line feed (U+000A) or a tab (U+0009) in a string that is the value of a member named `description`, or an element of an array that is.
5. **Present.** Offer only bound tools, each with the covered members read in step 2 and hashed in step 3. The covered members of bound tools are the only text obtained from `endpoint` that a client presents to a model. In particular, a client MUST NOT present to a model: members of a tool other than the covered members; tools that are not bound; the `instructions` or `serverInfo` of the `initialize` result; resources, resource templates or prompts; or any other message from `endpoint`, such as the answer to a `tools/call` sent to it, a notification or a log message. A client MAY prefix a tool's name to keep services apart (Security Considerations), and MAY add text of its own, marked as its own.
6. **Pin.** A client SHOULD keep, per chain and container, the `toolsSha256` it accepted, and SHOULD NOT accept a different value later without the user's consent. Whenever a reread of the service (TAP-11 §7.1) yields a different `toolsSha256`, the client MUST repeat steps 1 to 5 before its next call of a bound method.
7. **Call.** Call a bound tool under §4.2 and verify the answer under TAP-draft-signed-responses §8. An accepted result is presented as a tool result only if `result` is an object whose `content` is an array of objects each with a string member `type`; otherwise the client MUST NOT present it as a tool result. An accepted error with the code `TOOLS_CHANGED` is handled under §5.2.

## Rationale

- **The digest lives in the manifest.** The manifest is already the holder's verified statement about the service, so the definitions a model sees are approved by the same party, through the same checks, as the signer, and changing them needs the holder to write the site again. A registry contract or a signature per tool would add cost and a second approval path without adding a check.
- **Six covered members.** They tell a model what a tool does and how to call it, and they are what a "rug pull" edits. Display and transport metadata (`icons`, `_meta`, `execution`) change for other reasons and would break every pin. The list never changes, since every published digest depends on it; a member added by a later MCP revision is not covered, and clients do not show it (§6 step 5).
- **The whole list is hashed**, bound or not: a generic MCP client pointed at `endpoint` sees every tool. Sorting makes the digest independent of listing order; a repeated name leaves it unclear which definition applies.
- **Canonical JSON of TAP-11 §6.** Servers and proxies re-serialise JSON, so the digest is over the parsed value, and one implementation serves all three TAPs. Its restrictions exclude schemas with a property named `constructor`, `__proto__` or `prototype`; that is accepted rather than giving one list two digests.
- **SHA-256, not keccak256.** Nothing on chain recomputes the digest; holders compute it in the browser, where SHA-256 is built in (WebCrypto). The choice predates this text and is kept.
- **Calls go through signed responses.** MCP has no response signature; TAP-draft-signed-responses makes every answer, refusals included, attributable to the container. `_meta` is dropped from results because nothing pins it.
- **`TOOLS_CHANGED` is signed and covers bound methods only.** A signed refusal cannot later be denied or forged by a proxy, and a distinct code separates "the tools changed" from an internal failure. Methods that are not bound do not depend on the tool definitions. `published` and `current` help an operator see what happened, but only the manifest on chain changes what a client accepts.
- **The invisible-text check is recommended, not required.** Whoever approves a digest must be able to read what it pins; it is a policy on top of the digest check, which is the interoperable requirement.
- **Alternatives considered.** Trusting `notifications/tools/list_changed` lets the server decide what counts as a change. Pinning the first definitions a client sees (trust on first use) does not protect a user who first connects after a change; the on-chain digest does, and §6 step 6 adds the pin on top.

## Backwards Compatibility

This TAP adds one optional manifest member and defines one reserved error code. A client of TAP-11 that does not implement it ignores `mcp` as an unknown member (TAP-11 §3.1), and a provider that does not implement it never sends `TOOLS_CHANGED`.

**History and frozen constants.** This binding was first published in the TapeAPI repository as TAP-20 §3.8, with the error code in TAP-21 (renamed TAPI-20 and TAPI-21 on 2026-09-30; neither is a TAP number). The editors assign this TAP's number. The member names `mcp`, `endpoint` and `toolsSha256`, the six covered member names, the digest algorithm and the code `TOOLS_CHANGED` are historical constants and never change.

**Changes from the earlier text.** The result members are named exactly (§4.2) instead of "the tool's MCP result without `_meta`", as the reference provider already does; the `error.data` of `TOOLS_CHANGED`, strict parsing, the `null` rule, reading all pages, which reads count as failed (§5.1) and the client steps of §6 are new in writing.

**Differences between this text and the reference implementation** (commit `fda84db`, Reference Implementation):

| Area | Reference implementation today | This TAP | Plan |
|---|---|---|---|
| Reading the tool list in the provider | `JSON.parse`, so a repeated member name keeps the last value; an answer without a `tools` array is treated as a failed read | Strict parser (§3.1); an answer it rejects, or one without a `tools` array, is a successful read with no digest (§5.1) | Use the strict parser, as the reference client already does, and refuse calls with `TOOLS_CHANGED` in both cases |
| What the provider holds calls to | The digest it was configured with, or else the digest of its first read at start; it does not read the chain | The `toolsSha256` of the manifest it serves under (§5.1) | In 1.x, warn at start when no published value is configured; from 2.0, require it |
| `toolsSha256` in the client | Upper-case hex accepted and lower-cased | Lower case only (§2) | Reject upper case |
| `endpoint` in the client | Checks `https` and the absence of credentials, not query or fragment | The form of §2 | Add the missing checks |
| Manifest validation | `validateManifest` does not check `mcp` | §2 | Add the check |
| Offered methods | The client offers only free methods; the provider publishes every bound method as free | No rule on price (§4.1) | None needed |

Apart from these rows, the reference client and provider behave as §3 to §6 describe, and both apply the invisible-text check of §6 step 4 (the provider refuses calls with a signed `INTERNAL` while its tools contain such text). No live service publishes an `mcp` member at the time of writing.

## Test Cases

Vector files are in `assets/tap-draft-mcp-tools/` (the directory name will follow the number the editors assign, see #7). They were generated with the reference implementation at the commit below, and every value was recomputed with the canonicalisation, Keccak-256 and secp256k1 routines of its independent Python implementation (`spec/vectors/verify.py`) and Python's own SHA-256.

**`tools-digest.json`** (§3). Each positive case gives the tool list as JSON text, its normalised canonical form and `toolsSha256`:

| Case | `toolsSha256` |
|---|---|
| The example of §3.3 | `f33711dc931a5feaffebf84a66aa1e649f4d8fbd4080fa6b8e4cdbf364a13f2e` |
| Two tools with `icons` and `_meta` (not covered) | `bf4bcd2b701d7fa700901d129e0c3387e6dd862d7c882c6829fc8ebc594cd993` |
| The same tools in the other order, members reordered, without `icons` and `_meta` | `bf4bcd2b…4cd993` (the same) |
| The same tools with an `execution` member | `bf4bcd2b…4cd993` (the same) |
| The same tools with text appended to one `description` | `12c5db68034ef6cd5368970fe5308942c6e6d621d23fd05521071ced2aa7f241` |
| `outputSchema`, `annotations`, CJK and emoji text | `687bd7271338d81c1cd2e1bd781ad07736df47e793640fd61f7d0f84cb474d2d` |
| `"title": null` kept; `false`, `0` and `""` kept | `cad73128ced47407e222b6f885de149f68711709cfb64fd51715182c43dadbab` |
| Names in UTF-16 code-unit order: `Zeta`, `_x`, `zeta`, `é`, `😀`, `ｚ` (U+1F600 sorts before U+FF5A) | `8a3de005ee4aa16a47034cb2d2d7ad162f93429428be0fad8f9210521b6d5c1e` |
| The empty list | `4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945` |

It also gives 14 lists that have no digest: a repeated tool name; a tool without a name, with an empty name, with a name that is not a string; an element that is not an object; a list that is not an array; a repeated member name inside a tool, also written once with an escape (`"\u0074ype"` and `"type"`); an input property named `constructor`, and one named `__proto__`; `9007199254740992`; `1e21`; `-0`; an unpaired surrogate in a description.

**`envelopes.json`** (§4.2, §5.1). Envelopes produced by the reference provider in front of an MCP server with two tools (`toolsSha256` `2cb770664010656778a2bfe845829e241edcb057a76e09c55d4efa231fdba132`), with the clock fixed, container `0x86DDaEF00401E3F10418398D67D7189fc458eA95` and the published test signer key `0x2222…2222` (address `0x1563915e194D8CfBA1943570603F7606A3115508`) of the TAP-draft-signed-responses vectors. The file also gives the tool lists served before and after each change, from which `published` and `current` can be recomputed. Each case gives the request, the HTTP status, the envelope, the canonical request and body, their keccak256, the digest of TAP-draft-signed-responses §5 and the recovered signer: a result with `structuredContent` (the MCP server's `_meta` dropped); a tool error with `isError` `true` and `ok` `true`; `TOOLS_CHANGED` after a description changed; and `TOOLS_CHANGED` with `current` `null` after the server listed two tools with the same name. The third, in full:

```
request          POST <live>/add   {"id":"call-3","params":{"a":2,"b":3}}      HTTP 409
error.code       TOOLS_CHANGED
error.data       {"current":"df5931dcb68ac516132cb03877ddf3a292c66d40a986f33f7bf61a8040ce7a4d","published":"2cb770664010656778a2bfe845829e241edcb057a76e09c55d4efa231fdba132"}
ts               1790000061
digest           0xd99117fef68f616ce0d44622d303f47ac2cb274cbd79a23a4e986db9baa1eb9e
sig              0xb51e709ade9cd9a5ebba6d68bdea629fc55891d1c1cd9294f9f6f292c9fe848e502a901cc44dfd0f429fb92de0aad90054c34bfc769ec3d75541dca884ac14e51c
recovers         0x1563915e194D8CfBA1943570603F7606A3115508
```

**§6 step 5** needs no vector file. An MCP endpoint whose tool list matches the manifest can put a distinct marker string in each place that step excludes: a member of a bound tool other than the covered members, an unbound tool, the `instructions` and `serverInfo` of its `initialize` result, a resource, a resource template, a prompt, a notification and a log message. A conforming client presents none of these markers to the model.

## Reference Implementation

TapeAPI 1.3.0, at commit [`fda84db889d2a732915f264a799af24073177a85`](https://github.com/BruceLanLan/tapeapi/tree/fda84db889d2a732915f264a799af24073177a85) (MIT licensed):

- [`sdk/src/mcp.js`](https://github.com/BruceLanLan/tapeapi/blob/fda84db889d2a732915f264a799af24073177a85/sdk/src/mcp.js): `normalizeTools` and `toolsDigest` (§3.2, §3.3) and `invisibleProblems` (§6 step 4);
- [`server/src/mcp-proxy.js`](https://github.com/BruceLanLan/tapeapi/blob/fda84db889d2a732915f264a799af24073177a85/server/src/mcp-proxy.js): a provider that sits in front of an existing MCP server, binds one method per tool, signs every answer and refuses with `TOOLS_CHANGED` (§4, §5.1);
- [`sdk/bin/tapeapi-mcp.js`](https://github.com/BruceLanLan/tapeapi/blob/fda84db889d2a732915f264a799af24073177a85/sdk/bin/tapeapi-mcp.js): a local MCP client and server that resolves services, verifies their tools and every answer, and pins `toolsSha256` (§5.2, §6);
- [`site/console/lib.js`](https://github.com/BruceLanLan/tapeapi/blob/fda84db889d2a732915f264a799af24073177a85/site/console/lib.js): a second, browser-only implementation of the digest with WebCrypto, used before publishing; `sdk/test/mcp-review.test.mjs` checks it against `sdk/src/mcp.js` on 3,000 random tool lists;
- tests: `sdk/test/mcp-core.test.mjs`, `server/test/mcp-proxy.test.mjs`, `sdk/test/mcp-stdio.test.mjs`.

The bounds of the reference implementation are implementation choices under §3.1: the provider reads at most 16 pages, 512 tools and 1 MiB per answer; the client at most 20 pages and 4 MiB per answer within 15 seconds. The differences from this text are listed under Backwards Compatibility.

## Deployments

None. This TAP deploys no contract and depends on none directly. Resolving the service whose manifest carries `mcp` uses the contracts listed under Deployments in TAP-11, which refers to TAP-10.

## Security Considerations

The attacker considered controls an MCP server, or can change what it serves; can read and modify traffic between client, provider and MCP server; and can run services of its own.

- **What the digest proves.** That the covered members of the tools a client presents are, after canonicalisation, exactly the ones the holder published in the manifest resolved on chain. Any change to a name, title, description, schema or annotation, including one character, one added tool or one removed tool, is detected by every client that reads the list, including a client that has never seen the earlier definitions.
- **What it does not prove.** It does not prove that the definitions are harmless: a holder can publish a description that itself carries instructions to the model, and the digest then pins that text. It does not prove how the tools behave: the MCP server can answer differently under the same definitions, and the signed envelopes make that attributable, not impossible. It does not cover members outside the six covered members, the `initialize` instructions, resources or prompts, which is why §6 step 5 keeps them from the model; nor does it cover the content of tool results. It does not prove recency: whoever can write the site can put back an older manifest with an older `toolsSha256` (TAP-11 §7.3).
- **Prompt injection through descriptions.** Tool definitions are instructions to a model. The digest turns a silent change into a refusal and ties every definition to a holder who approved it; it does not make an approved definition safe. The invisible-text check (§6 step 4) keeps text a person cannot see out of what is approved. Tool results, and signed refusals that quote the MCP server, are data, not instructions.
- **Silent replacement.** A server that changes its tools is refused by every client at its next read of the list, and by the provider at its next read (about 60 seconds under §5.1). Until then calls may reach the changed server, while the client still presents only the definitions it verified. A server that shows the holder one list and clients another is refused by the clients. A provider held to a digest other than the published one weakens only its own check.
- **The endpoint.** Whoever controls `endpoint` can make the tools unavailable, but cannot make a client accept other definitions. The endpoint host learns the network address of each client that reads the list.
- **Parsing.** A parser that accepts repeated member names would let two clients read different definitions under one digest; the strict parser removes that. An answer the strict parser rejects counts for the provider as a list with no digest, not as a failed read, so an MCP server cannot keep calls flowing by serving a list that no client can read.
- **Name collisions.** Several services can bind tools of the same name; a client that combines services keeps them apart, for example with a per-service prefix.
- **Trust inherited from resolution.** Every guarantee above rests on the manifest resolved under TAP-11 and on the signer it names; until the contracts it reads are sealed, whoever controls them can change what resolution returns. This TAP inherits those assumptions.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
