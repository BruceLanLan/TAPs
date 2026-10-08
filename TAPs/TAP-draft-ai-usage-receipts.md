---
tap: TBD
title: AI Usage Receipts for Container Services
description: How a container service that fronts an AI API publishes its endpoints and price table in its manifest, and signs for every metered answer a receipt that binds the exact request and response bytes, the reported usage and the amounts it claims.
author: Bruce (@BruceLanLan)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/25
status: Draft
type: Application
created: 2026-09-30
updated: 2026-10-08
requires: TAP-10, TAP-11, TAP-13, WHATWG URL Standard (commit snapshot fde3f74, 2026-10-07)
license: CC0-1.0
---

# TAP-TBD: AI Usage Receipts for Container Services

## Summary

A way for an AI service that belongs to a TapeOut circuit to publish its price list on chain and to give every answer a signed receipt, so that its users can check who answered, what was asked and answered, and what they were charged.

## Abstract

This TAP defines the optional manifest member `ai`, in which a service of TAP-11 lists base URLs for four existing AI API formats (OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, OpenAI Embeddings) and a price table per model. Clients keep each format's official SDK and change only its base URL. A **sidecar** in front of the upstream API passes requests and answers through and signs, for every metered request, a **usage receipt**: an envelope of TAP-13, reusing its digest under that TAP's §9, that binds the SHA-256 of the exact request bytes and of the response (for an event stream, of its event data), the reported model and usage, and the amounts the price table gives for them. The TAP fixes the price and usage formats, the integer arithmetic of amounts, how each format is read, where each format's stream ends and the receipt goes, how receipts are retrieved, and the checks a client makes.

## Motivation

Teams that serve AI models to others bill by tokens, and their users cannot check the bill: the answer, the token counts and the price all come from the provider's server, a disputed charge is one party's word against the other's, and nothing ties an answer to an identity that outlives a domain name or a platform account.

TAP-11 binds a service to a circuit container and names the key that speaks for it, and TAP-13 defines how that key signs an answer. Neither fits AI APIs as they are used: callers keep the official SDKs of a few established formats; answers are often event streams that proxies re-chunk; each format reports usage differently, sometimes only on request; and a price is checkable only if the table and the arithmetic are fixed in advance. This TAP fills that gap without changing any format: the price table lives in the on-chain manifest, a sidecar signs a receipt in a place the official SDKs ignore, and a client that kept the bytes it sent and received can recompute every hash and amount.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Container**: as defined in TAP-10 §1. **Service**, **manifest**, **signer**, **provider**, **client**: as defined in TAP-11 §1; a service is **resolved** when its resolution under that TAP's §2 has the outcome "resolved".
- **Strict parser**: the parser of TAP-13 §2. **Envelope digest**: the digest and signature of TAP-13 §5 (prefix `TAPI-1/resp/v2`, 139-byte preimage, EIP-191, low-`s`).
- **Upstream**: the AI API the provider forwards requests to. **Sidecar**: the part of the provider that receives clients' AI requests, forwards them to the upstream, and returns the upstream's answers with receipts. A sidecar is operated by the provider and uses the service's signer key.
- **Format**, **metered path**, **receipt method**: §2. **Service root**, **root path**, **API path**: §3.2.
- **Receipt**: the envelope of §7. **Whole answer**: an answer that is not a stream (§5.2).
- `sha256hex(b)` is SHA-256 (FIPS 180-4) of the bytes `b`, written as 64 lowercase hexadecimal digits. **base64url** is RFC 4648 §5 without padding. `LF` is the byte `0x0a`, `CR` the byte `0x0d`.
- A **count** is a JSON number that is an integer from 0 to 2^53 − 1. In price entries (§3.4) and in the members read from an answer (§6.3, §7.3), a member whose value is `null` is treated as **absent**; elsewhere `null` is a value like any other. Lengths of strings are in UTF-16 code units, as in TAP-13 §1.
- **Parsed as JSON**: decoded as UTF-8, with one leading U+FEFF removed and each invalid sequence replaced by U+FFFD, and then parsed as JSON text (RFC 8259); where an object repeats a member name, its last value counts. Bytes that do not parse have no value. This applies to request bodies and answers, never to receipts (§9.3).
- **2xx** means an HTTP status from 200 to 299.
- Event-stream terms (**line**, **comment**, **field line**, **event**, **dispatched**, **data**, **event name**, **ambiguous line**, **close while an event is unfinished**) are those of §5.2; the **end** of a stream and **after the end** are those of §6.1.
- **External specifications.** Besides TAP-10, TAP-11, TAP-13 and the key-word RFCs above, this TAP relies on FIPS 180-4 (August 2015) for SHA-256, RFC 4648 for base64url, RFC 8259 for JSON, RFC 9110 and RFC 9112 for HTTP status codes, header fields, content codings and transfer codings, and the WHATWG URL Standard at commit snapshot `fde3f74f063341a28d437216f75735b8b40128f5` (2026-10-07) for parsing and serialising URLs (§3.2). It relies on no other document. In particular, the AI APIs named in §2 are named for orientation only: every rule this TAP takes from them (the paths of §2, the request member of §6.3, the final lines and sentinel of §6.1, the members read in §7.3 and the headers of §8) is written in this TAP, and Appendix A describes those APIs informatively.

### 2. Formats

This TAP defines four formats. Every other request under a service root carries no receipt and no price.

| Format | API | Metered paths (method `POST`) | `baseUrl` suffix | Receipt method | Streams |
|---|---|---|---|---|---|
| `openai-chat` | OpenAI Chat Completions | `/v1/chat/completions` | `/v1` | `openai_chat` | yes |
| `openai-responses` | OpenAI Responses | `/v1/responses`, `/v1/responses/compact` | `/v1` | `openai_responses` | yes |
| `anthropic-messages` | Anthropic Messages | `/v1/messages` | empty | `anthropic_messages` | yes |
| `openai-embeddings` | OpenAI Embeddings | `/v1/embeddings` | `/v1` | `openai_embeddings` | no |

- A format is what this TAP specifies for it. The column API names the API each format is taken from, for orientation only: a server that answers by these rules is a server of that format whoever runs it, and a change to that API changes nothing in this TAP until this TAP is changed (Appendix A).
- A request is **metered** when its HTTP method is `POST` and its API path equals, byte for byte, one of the metered paths of the endpoint's format. Case, percent-encoding and slashes are not normalised.
- The **requested model** of a request is the value of the member `model` when the request body, parsed as JSON, is an object with a string member `model` of 1 to 256 UTF-16 code units; otherwise there is none.
- A later TAP MAY add formats. It names the format, its metered paths, `baseUrl` suffix, receipt method (matching `^[a-z][a-z0-9_]{0,63}$`, distinct from every other receipt method and from `receipt`) and the rows it adds to the tables of §6.1 and §7.3. Its receipt method is then reserved under §3.5 as well.

### 3. The `ai` manifest member

#### 3.1 Shape

`ai` is an optional top-level member of the manifest (TAP-11 §3.1 allows later TAPs to define top-level members). Example, with placeholders for the prices:

```json
"ai": {
  "endpoints": [
    { "format": "openai-chat", "baseUrl": "https://ai.example/v1" },
    { "format": "anthropic-messages", "baseUrl": "https://ai.example" }
  ],
  "models": [
    { "id": "model-a", "aliases": ["model-a-2026-09-01"], "formats": ["openai-chat"],
      "prices": [ { "currency": "BEM", "unit": "1M tokens", "input": "<decimal>", "output": "<decimal>", "cacheRead": "<decimal>" } ] }
  ]
}
```

#### 3.2 Endpoints

| Member | Type | Rule |
|---|---|---|
| `endpoints` | array | 1 to 16 entries, at most one per `format` |
| `endpoints[].format` | string | Matches `^[a-z][a-z0-9-]{0,63}$` |
| `endpoints[].baseUrl` | string | An absolute `https://` URL without query, fragment, user name or password. It is used as the WHATWG URL Standard (§1) parses and serialises it, with trailing `/` characters removed |

- The **service root** of an endpoint is its `baseUrl` with the format's suffix (§2) removed from the end; its **root path** is the path of the service root without trailing `/` characters (empty when the service root is an origin). A client MUST ignore an endpoint whose format it does not know, and an endpoint whose `baseUrl` does not end with its format's suffix.
- A request of a format goes to the service root followed by an API path. A request URL has an **API path** only when it has the service root's origin and its path begins with the root path followed by `/`; the API path is then that path with the root path removed from the front. The query is not part of it.

#### 3.3 Models

| Member | Type | Rule |
|---|---|---|
| `models` | array | 1 to 256 entries |
| `models[].id` | string | 1 to 256 UTF-16 code units, none of them in U+0000–U+001F or U+007F–U+009F |
| `models[].aliases` | array of strings | Optional (when present, not `null`). 1 to 16 entries, each under the rule of `id` |
| `models[].formats` | array of strings | Optional (when present, not `null`). Non-empty, no repeated entry, each the `format` of an entry of `endpoints`, including endpoints the client ignores |
| `models[].prices` | array | 1 to 7 price entries (§3.4) |

- Every `id` and every alias appears at most once in the whole table, ids and aliases counted together.
- An entry is **allowed** for a format when it has no `formats` or its `formats` lists that format.
- A model entry that has a member `price` is invalid.

#### 3.4 Price entries

| Member | Rule |
|---|---|
| `currency` | One of `BEM`, `BNB`, `USDT`, `USDC`, `ETH`, `USD1`, `USD`; unique among the price entries of one model |
| `unit` | Exactly `"1M tokens"`: every price of the entry is an amount per 1,000,000 tokens |
| `input` | Required decimal. Input tokens that are neither cache reads nor cache writes |
| `output` | Required decimal. Output tokens, and reasoning tokens when `reasoning` is absent |
| `cacheRead` | Optional decimal. Input tokens read from a prompt cache. When absent: `input` |
| `cacheWrite` | Optional decimal. Input tokens written to a prompt cache. When absent: `input` |
| `cacheWrite1h` | Optional decimal. Cache writes kept for one hour. When absent: `cacheWrite`, and when that is absent too, `input` |
| `reasoning` | Optional decimal. Output tokens spent on reasoning |

- A **decimal** is a JSON string matching `^(0|[1-9][0-9]{0,17})(\.[0-9]{1,8})?$`: at most 18 integer digits without leading zeros, at most 8 fraction digits, no sign, exponent or whitespace. Its value is read exactly; trailing zeros after the point do not change it.
- A currency code names the unit of account in which the entry's amounts are stated. This TAP moves no funds and binds no code to a token or contract; a TAP that settles amounts does that.
- The order of the price entries of a model is kept in receipts and has no other meaning.
- The `priceBEM` of manifest methods is unrelated to this table.

#### 3.5 Validation, reserved names and the lookup method

- A client that uses `ai` MUST validate the whole member against §3.2–§3.4 and MUST NOT use any part of it when any rule is violated. Members that this TAP does not define, at any level of `ai`, are ignored. The rest of the manifest, and its resolution, are unaffected. A client that does not use `ai` ignores it.
- The receipt methods of §2 are **reserved**. A manifest that carries `ai` MUST NOT list a method (TAP-11 §3.3) whose `name` is a receipt method, and a client MUST treat the `ai` member of such a manifest as invalid. The provider of a service whose manifest carries `ai` MUST answer a request of TAP-13 §3 whose path segment is a receipt method only with an error (`ok` `false`).
- A manifest that carries `ai` MUST list the method `receipt` of §7.5, with `priceBEM` `"0"` and `params` `{ "id": "string" }`.

### 4. Usage, model matching and amounts

#### 4.1 Usage

The usage of an answer is either `null` or an object with these members, in this order:

| Member | Presence | Meaning |
|---|---|---|
| `prompt_tokens` | always | All input tokens, cache reads and cache writes included |
| `completion_tokens` | always | All output tokens, reasoning included |
| `total_tokens` | always | As reported |
| `cache_read_tokens` | when reported | Input tokens read from a cache |
| `cache_write_tokens` | when reported | Input tokens written to a cache |
| `cache_write_1h_tokens` | when reported | Cache writes kept for one hour |
| `reasoning_tokens` | when reported | Output tokens spent on reasoning |
| `other` | see below | Per-use counts, `{ name: count }` |

It is computed from the counts read from an answer (§7.3):

1. When the HTTP status is not 2xx, the usage is `null`.
2. When `prompt_tokens` is not a count, the usage is `null`.
3. An absent `completion_tokens` is 0; an absent `total_tokens` is `prompt_tokens + completion_tokens`. When either is then not a count, the usage is `null`.
4. Each of `cache_read_tokens`, `cache_write_tokens`, `cache_write_1h_tokens` and `reasoning_tokens` is left out when absent; when one is present and not a count, the usage is `null`. A reported 0 is present.
5. The usage is `null` unless `cache_read_tokens + cache_write_tokens ≤ prompt_tokens`, `cache_write_1h_tokens ≤ cache_write_tokens` and `reasoning_tokens ≤ completion_tokens`, reading absent counts as 0.
6. When `other` is read and is not an object, the usage is `null`. Otherwise only its members whose name matches `^[a-z][a-z0-9_]{0,63}$` and whose value is a count above 0 are kept, sorted by name; `other` is left out when none is kept.

#### 4.2 Model matching

The **reported model** of an answer is the model read from it (§7.3) when that is a string of 1 to 256 UTF-16 code units; otherwise the answer reports none.

- When the answer reports a model, the **matched entry** is the entry allowed for the answer's format whose `id`, or one of whose `aliases`, equals the reported model, compared as strings code unit for code unit (no case folding, normalisation, prefix or pattern matching). The requested model is not tried, even when no entry matches.
- When the answer reports none, the requested model (§2) is matched the same way.
- There is at most one matched entry (§3.3).

#### 4.3 Amount

For each price entry `p` of the matched entry and a usage `u` that is not `null`, reading absent counts as 0:

```
cr = u.cache_read_tokens    cw = u.cache_write_tokens    cw1h = u.cache_write_1h_tokens
rs = u.reasoning_tokens if p.reasoning is present, else 0

S =  P(p.input)        × (u.prompt_tokens − cr − cw)
   + P(p.cacheRead)    × cr
   + P(p.cacheWrite)   × (cw − cw1h)
   + P(p.cacheWrite1h) × cw1h
   + P(p.output)       × (u.completion_tokens − rs)
   + P(p.reasoning)    × rs                       (only when p.reasoning is present)

A = ceil(S / 1 000 000)
```

- `P(x)` is the decimal `x`, with the defaults of §3.4 applied, as an integer number of 10^-8 units (`"1.25"` is 125,000,000). Every product and `S` are exact integers; `A` is `S` divided by 1,000,000 and rounded up once, on the sum. Implementations MUST use exact integer arithmetic with no upper bound on `S`, and MUST NOT use floating point.
- The **amount** is the value `A × 10^-8` written in decimal with exactly 8 fraction digits and an integer part without leading zeros (`0` when `A` is below 10^8): `A` = 357,500 is `"0.00357500"`.
- Per-use counts (`other`) add nothing to `S`.

### 5. Hashes

#### 5.1 Request hash

`requestSha256` is `sha256hex` of the request body bytes exactly as the client sent them: after any HTTP transfer coding is removed, with any content coding the client applied still in place. An empty body gives `sha256hex` of zero bytes.

#### 5.2 Response hash

An answer is a **stream** when its format streams (§2), the upstream's `Content-Type` contains `text/event-stream` (ASCII case-insensitive), and its status is not 101, 204, 205 or 304. Otherwise it is a whole answer.

For a whole answer, `responseSha256` is `sha256hex` of the response body bytes exactly as the client receives them, after any HTTP content coding is removed (zero bytes for status 101, 204, 205 and 304).

For a stream, the bytes the client receives are parsed as a server-sent event stream by these rules, which sidecars and clients MUST apply exactly. They are complete as written here. (They follow the event-stream interpretation of the WHATWG HTML Standard, restricted to what this TAP reads; that standard is not needed to apply them.)

1. Lines end at `CR LF`, `LF` or `CR`. One U+FEFF (bytes `EF BB BF`) at the very start of the stream is skipped. Any other U+FEFF is part of the line it is in: inside a line it belongs to the field name, value or comment, and at the start of a line it begins a field name (an ambiguous line, below).
2. A line that begins with `:` is a **comment** and is ignored.
3. Any other non-empty line is a **field line**. It splits at its first `:` into a field name and a value, and one U+0020 directly after that colon is removed from the value. A line without `:` is a field of that name with an empty value.
4. An **event** is the sequence of lines up to and including the next empty line. The values of all its `data` fields are joined with `LF`: that is its **data**. Its **event name** is the value of its last `event` field, or empty.
5. An event is **dispatched** at its empty line, and only if it had at least one `data` field. Lines that are not followed by an empty line when the stream ends are discarded.

Take each dispatched event's data as UTF-8 bytes, in order; leave out every event whose data is exactly the format's sentinel (§6.1) and every event removed under §6.3; `responseSha256` is `sha256hex` of the concatenation of each remaining data followed by one `LF`. Event names, other fields and comments are not hashed.

Two shapes have a meaning under these rules but are parsed differently by clients in use:

- An **ambiguous line** is a line whose first bytes are `EF BB BF`, except where rule 1 skips them at the very start of the stream (so the second of two U+FEFF at the start of the stream begins an ambiguous line, and so does a line that consists of U+FEFF alone). For this definition, the bytes after the last line end of a stream, when there are any, also form a line. Under rule 3 it is a field line whose field name begins with U+FEFF: neither a comment nor a `data` field. Parsers that remove a U+FEFF from the start of every line read it as the comment or field that follows the U+FEFF.
- The bytes of a stream **close while an event is unfinished** when they stop in the middle of a line (a comment line included), or when a field line has been read since the last empty line (or since the start of the stream, when there is none). Rule 5 discards those lines; some parsers dispatch the unfinished event when the stream closes.

The hash is computed by the rules above in both cases. §6.2 and §9.3 item 8 say how sidecars and clients treat these shapes.

### 6. Streams

#### 6.1 Sentinels, final events and the end of a stream

| Format | Sentinel | Final lines |
|---|---|---|
| `openai-chat` | `[DONE]` | `data: [DONE]` |
| `openai-responses` | `[DONE]` | `event: response.completed`, `event: response.incomplete`, `event: response.failed`, `data: [DONE]` |
| `anthropic-messages` | none | `event: message_stop` |

- Each final line also matches when written without the space after the colon (`data:[DONE]`, `event:message_stop`). A line matches when it is byte for byte one of these, without its line end.
- A **final event** is an event whose first field line matches a final line of its format. Comments before that line belong to the event.
- The **end** of a stream is the dispatch of its first event whose event name is the name in an `event:` final line, or whose data is the value in a `data:` final line or the sentinel. A stream without such an event has no end before the upstream closes it.
- The end is also a point in the bytes: just after the line end of the empty line at which that event is dispatched (after the `LF` of a `CR LF`). A client that has received a `CR` there but not yet the byte after it need not wait for that byte: it may take the end to lie just after the `CR`, and an `LF` that then arrives completes that line end. Every other byte that follows the end is **after the end**, whether or not it arrives in the same read from the network as the end.

**Which streams `[DONE]` applies to.** The sentinel `[DONE]` and the final line `data: [DONE]` apply to every stream (§5.2) of the formats `openai-chat` and `openai-responses`, whichever server sends it and whether or not its events carry `event:` lines, and to no stream of any other format:

- In a stream of those two formats, an event whose data is exactly the six bytes `[DONE]` is never hashed (§5.2), whatever its event name, and the first such event is the end unless an earlier event is. In an `openai-responses` stream with `event:` lines, the event of an `event:` final line usually comes first and is the end; a `[DONE]` event after it is after the end. A `[DONE]` event that comes before such an event is the end, and the events after it are after the end.
- Only data that is exactly `[DONE]` is the sentinel. Data such as `[DONE] ` (with a trailing space), `[done]`, or `[DONE]` joined with a second `data` field of the same event (§5.2 rule 4) is data like any other: it is hashed and is not an end.
- In an `anthropic-messages` stream, an event whose data is `[DONE]` is an ordinary event: it is hashed, it is not an end, and after `message_stop` it is an event after the end. `openai-embeddings` answers are never streams, and a whole answer is hashed as bytes whatever it contains.

`stream-shapes.json` and `receipts-done.json` (Test Cases) give vectors for each of these cases.

#### 6.2 Placing the receipt

A sidecar passes each event on as it arrives, with these exceptions:

1. It holds back the first final event of the stream, from its first line until its empty line. It then dispatches that event (it enters the hash and is read under §7.3), signs the receipt, and sends the **receipt block** `: tapeapi-receipt ` + base64url(receipt JSON text) + `LF LF`, followed by the held bytes unchanged. Comment lines at the start of an event are held until its first field line shows whether it is a final event.
2. When the sidecar injected a usage request (§6.3), it also holds back every other event whose first field line begins with `data`, until its empty line, and removes it or passes it on as §6.3 says. A final event is handled under item 1.
3. When the stream ends without a receipt sent: if a final event was begun and not ended, the sidecar sends the receipt block and then the held bytes. Otherwise it sends any held bytes; then, if at least one byte was sent and the last byte sent is neither `LF` nor `CR`, one `LF`; then `: tapeapi-receipt ` + base64url(receipt JSON text) + `LF`, with no empty line after it, so that an unfinished event stays unfinished. When the upstream's bytes closed while an event was unfinished (§5.2), the receipt is still sent. Clients then do not verify the stream (§9.3 item 8), unless the upstream stopped inside a comment line with no field line read since the last empty line: the line end that the sidecar adds finishes that comment, and the bytes the client receives do not close while an event is unfinished.
4. A sidecar sends exactly one receipt per answer, except under item 6. Receipt comments are neither events nor hashed.
5. A sidecar MAY limit how many bytes of one event it holds. An event over its limit is passed on as it arrives and is neither treated as a final event nor removed; a later final event is still handled under item 1, and without one, item 3 applies. If the event passed on is the end of the stream (§6.1), the receipt follows the end and a client rejects the stream (§9.2). A sidecar MAY end a stream from which the upstream has sent nothing for a period; item 3 then applies.
6. A sidecar MUST NOT sign a receipt for a stream in which an ambiguous line (§5.2) comes before the point where it signs (under item 1, the empty line that ends the held final event; under item 3, the last byte sent before the receipt comment). It passes such a stream on without a receipt comment, otherwise as this section says. An ambiguous line after that point does not prevent the receipt; clients treat it under §9.3 item 8.

A sidecar MUST NOT carry a receipt in an event of a custom type. A stream that passes through several sidecars carries one receipt comment from each; the outermost sidecar's comes last.

The first field line decides where the sidecar places the receipt, and the dispatched event decides where a client sees the end. The two agree when an event's `event` field is its first field line, as in the published streams of the three formats. When they do not, the receipt follows the end and a client rejects the stream (§9.2).

#### 6.3 Usage injection

A request **asks for usage** when its body, parsed as JSON, is an object with a `stream_options` member that is an object whose `include_usage` is `true`. When the request body of an `openai-chat` request, parsed as JSON, is an object in which `stream` is `true` and the request does not ask for usage, a sidecar MAY send the upstream, instead of the client's bytes, the JSON serialisation of that object in which `stream_options` is replaced by an object holding the members of the original `stream_options` (when it was an object) and `"include_usage": true`. It MUST NOT change the request it sends upstream in any other way. When it does so:

- It MUST remove from the client's copy of the stream every event held back under §6.2 item 2 whose data, parsed as JSON, is an object with a `usage` member that is an object and a `choices` member that is an array in which every element **carries nothing**. An element carries nothing when it is an object whose member names are all among `index`, `delta`, `finish_reason` and `logprobs` (whatever their values), whose `delta` is an object whose members are all `null` (an empty object qualifies), and whose `finish_reason` and `logprobs` are absent. An empty `choices` array qualifies. The whole event is removed, from its first line through its empty line.
- Removed events are not hashed (§5.2), and the sidecar reads them under §7.3.
- The receipt MUST carry `usageInjected` (§7.2).
- `requestSha256` remains the hash of the bytes the client sent (§5.1); the bytes sent upstream are covered by no hash.

No other format is changed upstream.

### 7. Receipts

#### 7.1 Envelope

A sidecar signs receipts only for a service whose manifest carries a valid `ai` member. It MUST sign a receipt for every metered request whose upstream answer it delivers to the client, whatever the status, except a stream that §6.2 item 6 does not let it sign (§8 lists the answers it makes itself). A receipt is a JSON object with exactly these members:

| Member | Content |
|---|---|
| `id` | The answer's id (§7.3) when it is a string of 1 to 128 characters, each in U+0021–U+007E. Otherwise an id the sidecar generates under the same rule, which SHOULD contain at least 96 random bits |
| `ok` | `true` |
| `container` | The service container, `0x` and 40 hexadecimal digits |
| `ts` | The sidecar's Unix time in seconds when it signs, an integer from 0 to 2^53 − 1 |
| `method` | The receipt method of the request's format (§2) |
| `params` | `{ "path": <the API path of the request>, "requestSha256": <§5.1> }`, with no other member |
| `result` | §7.2 |
| `sig` | `0x` and 130 hexadecimal digits: the envelope digest signature by the signer over the values of §10 |

A receipt has no `error` and no `block`.

#### 7.2 Result

| Member | Type | Content |
|---|---|---|
| `model` | string or `null` | The reported model (§4.2); else the requested model when it matched an entry; else `null`. When the answer reports a model that matches no entry, `model` is that reported model |
| `usage` | object or `null` | §4.1 |
| `responseSha256` | string | §5.2 |
| `stream` | boolean | Whether the answer is a stream (§5.2) |
| `complete` | boolean | §7.3. Always `false` when the status is not 2xx |
| `status` | integer | The upstream's HTTP status |
| `prices` | array or `null` | `[ { "currency": …, "amount": … } ]`: one element per price entry of the matched entry, in the table's order, each with exactly these two members and the amount of §4.3. `null` when there is no matched entry or `usage` is `null` |
| `modelMatchedBy` | string | `"response"` when the reported model matched, `"request"` when the requested model did. Present exactly when there is a matched entry, even when `prices` is `null` |
| `unpriced` | array of strings | The member names of `usage.other`. Present only when `prices` is not `null` and `usage.other` is present |
| `usageInjected` | `true` | Present only under §6.3 |

The first seven members are always present. `modelMatchedBy`, `unpriced` and `usageInjected` are left out when they do not apply, never set to `null`, `false` or an empty array. A sidecar MUST NOT add other members to `result`. In the JSON text, the members of `usage` MUST appear in the order of §4.1, and those of each element of `prices` in the order `currency`, `amount`.

#### 7.3 Reading an answer

The sidecar reads the answer's id, model, counts and completion as below; a client that holds the answer reads it the same way (§9.3). For a whole answer, "the body" is the response body parsed as JSON. For a stream, the events read are the dispatched events and the removed events (§6.3), in stream order up to and including the end (§6.1), or to the close when the stream has no end, whose data parsed as JSON has a value; the sentinel is not read, and neither is an event whose data is longer than 16,777,216 bytes (such an event is still hashed). In every format, members of a value that is not a JSON object are absent, an id or model that is not a string is absent, and `complete` is `false` whenever the status is not 2xx.

**openai-chat.** Counts from a usage object `U`: `prompt_tokens`, `completion_tokens`, `total_tokens` ← the same members of `U`; `cache_read_tokens` ← `U.prompt_tokens_details.cached_tokens` when that is a JSON number, else `U.prompt_cache_hit_tokens` when that is a JSON number; `reasoning_tokens` ← `U.completion_tokens_details.reasoning_tokens` when a JSON number.

- Whole: id, model ← the body's `id` and `model`; `U` ← the body's `usage`; `complete` is `true` for 2xx.
- Stream: id ← the first string `id` of the events' data; model ← the last string `model`; `U` ← the `usage` object of the last event that has one; `complete` is `true` when some event's `choices` array contains an object whose `finish_reason` is present, and no event has an `error` member that is present.

**openai-responses.** Counts from `U`: `prompt_tokens` ← `U.input_tokens`; `completion_tokens` ← `U.output_tokens`; `total_tokens` ← `U.total_tokens`; `cache_read_tokens` ← `U.input_tokens_details.cached_tokens` when a JSON number; `reasoning_tokens` ← `U.output_tokens_details.reasoning_tokens` when a JSON number.

- Whole: id, model, `U` ← the body's `id`, `model` and `usage`; `complete` is `true` for 2xx unless the body's `status` is a string other than `"completed"`.
- Stream: an event's type is its data's `type` when that is a string, else its event name. Among events whose data has a `response` object: id ← the first string `response.id`, model ← the last string `response.model`, `U` ← the last `response.usage` object. `complete` is `true` when some event has type `response.completed` and none has type `response.failed`, `response.incomplete` or `error`.

**anthropic-messages.** Counts from `U`, where "a count" means that member when it is a count and absent otherwise: there are no counts unless `U.input_tokens` is a count; `cache_read_tokens` ← the count `U.cache_read_input_tokens`; `cache_write_tokens` ← the count `U.cache_creation_input_tokens`; `prompt_tokens` ← `U.input_tokens` + those two (absent as 0); `completion_tokens` ← `U.output_tokens`; `total_tokens` ← `prompt_tokens + U.output_tokens` when `U.output_tokens` is a count, else absent; `cache_write_1h_tokens` ← the count `U.cache_creation.ephemeral_1h_input_tokens`; `other.web_search_requests` ← the count `U.server_tool_use.web_search_requests` when above 0.

- Whole: id, model, `U` ← the body's `id`, `model` and `usage`; `complete` is `true` for 2xx unless the body's `type` is `"error"`.
- Stream: only events whose data is an object are read; an event's type is its data's `type` when a string, else its event name. id, model ← the last string `message.id` and `message.model` of `message_start` events. In event order, a `message_start` event whose `message.usage` is an object sets `U` to a copy of it, and a `message_delta` event with a `usage` object sets, in `U` (created empty when there is none), each member it carries whose value is not `null`, replacing that member whole, nested objects included. `complete` is `true` when some event has type `message_stop` and none has type `error`.

**openai-embeddings.** Never a stream. id, model ← the body's `id` and `model`; counts ← `U.prompt_tokens` and `U.total_tokens` of the body's `usage` object `U` (`completion_tokens` is then 0 by §4.1); `complete` is `true` for 2xx.

#### 7.4 Delivery

- **Whole answer.** The receipt travels in the response header `x-tapeapi-receipt`, whose value is base64url of the receipt's JSON text in UTF-8. The sidecar MUST remove any `x-tapeapi-receipt` header of the upstream's answer, and SHOULD list the header in `Access-Control-Expose-Headers`.
- **Stream.** The receipt travels in a comment line (§6.2); the body is otherwise the upstream's, less removed events (§6.3).
- The JSON text of a receipt need not be canonical; the signature covers canonical forms (§10).

#### 7.5 Retrieval

The method `receipt` is a method of TAP-13 §3 with `params` `{ "id": string, "requestSha256"?: string }`, where `requestSha256`, when given, is 64 lowercase hexadecimal digits.

- The answer is an envelope of that TAP with `ok` `true` whose `result` is a stored receipt: the most recent receipt with that `id`, or, when `requestSha256` is given, the one whose `id` and `params.requestSha256` both equal the parameters.
- When no stored receipt matches, the provider answers a signed `BAD_REQUEST`. A provider MAY refuse, with a signed `BAD_REQUEST`, a lookup that does not give `requestSha256`.
- A provider SHOULD keep every receipt retrievable for at least one hour after the answer, and MAY limit lookups with the unsigned rate-limit answer of TAP-13 §7.

### 8. Sidecar

- A sidecar forwards a metered request to the upstream with the client's body bytes unchanged, except under §6.3. The upstream's address comes from the sidecar's configuration, never from a request.
- It MUST NOT forward a request whose path equals a metered path only after percent-encoded unreserved characters are decoded, runs of `/` are collapsed or a trailing `/` is removed; it MAY answer such a request with an error of its own.
- It MUST NOT follow an upstream redirect (a status from 300 to 399 other than 304), and signs no receipt for one.
- It forwards these caller headers when the request carries them: `Content-Type`, `Content-Encoding` and `Accept`; for `openai-chat`, `openai-responses` and `openai-embeddings`, `Authorization`, `OpenAI-Beta`, `OpenAI-Organization` and `OpenAI-Project`; for `anthropic-messages`, `X-Api-Key`, `Authorization`, `Anthropic-Version` and `Anthropic-Beta`. It may forward other headers by which a client identifies itself (Appendix A). It MUST NOT forward `Cookie`, `Cookie2`, `Forwarded`, `X-Real-IP`, a header whose name begins with `X-Forwarded-` or `CF-`, or the hop-by-hop headers `Connection`, `Keep-Alive`, `Proxy-Connection`, `Proxy-Authenticate`, `Proxy-Authorization`, `TE`, `Trailer`, `Transfer-Encoding` and `Upgrade`. Header names are compared without regard to ASCII case.
- An answer the sidecar makes itself (for example for its own rate limit, a request over its size limit or with a loosely written path, or an upstream that cannot be reached, does not answer in time, redirects or sends a whole answer over the sidecar's size limit) has no upstream answer to bind and carries no receipt and no signature. It uses the body `{ "error": { "message": …, "type": …, "param": …, "code": … } }` and MAY carry the header `x-tapeapi-sidecar-error: 1`. That header is informative: anyone on the path can add or remove it.

### 9. Client verification

#### 9.1 Input

A client verifies a receipt with: a resolved service with container `C`, signer `S` and a valid `ai` member; the request it sent (URL and body bytes); and, when it holds them, the HTTP status, headers and body bytes it received. A client verifies receipts only for metered requests addressed to an endpoint of that `ai` member (§3.2). It MUST NOT present the answer to any other request as verified, including a request to another origin or one whose path is metered only when written loosely (§8).

#### 9.2 Finding the receipt

- **Whole answer**: the value of the header `x-tapeapi-receipt`. Without it, the answer has no receipt.
- **Stream**: the **receipt comments**, lines that consist of `:`, optionally one U+0020, `tapeapi-receipt`, one U+0020 and one or more base64url characters, and nothing else. When the stream has an end (§6.1), only the receipt comments before the end count; otherwise all of them do. The client checks the last one first and accepts the stream when one of them passes §9.3. It MAY ignore receipt comments of 65,536 bytes or more and those after the sixteenth.

A client checks a stream at its end (§6.1), or at its close when it has no end, and checks the stream as it stood at that point: the hash it compares with `responseSha256` covers the events dispatched up to and including the end (§9.3 item 5), and its reading under §7.3 covers the same events. Bytes after the end are covered by no receipt. How the bytes arrive, in one read from the network or in many, MUST NOT change the outcome of any check. A client MUST NOT pass bytes after the end to the application as part of the verified answer: it either stops passing the stream on at the end and closes it there, or passes those bytes on and makes §9.3 item 8 over them too.

#### 9.3 Checks

A client that relies on a receipt MUST make these checks:

1. **Decoding.** The base64url text decodes to UTF-8 JSON text that the strict parser accepts and whose value is an object.
2. **Shape.** The receipt satisfies §7.1 and §7.2: its members and types; `ok` is `true`; `requestSha256` and `responseSha256` are 64 lowercase hexadecimal digits; `usage` is `null` or satisfies §4.1 with its members in order; `status` is an integer from 100 to 599; each element of `prices` has exactly the members `currency` and `amount`, in this order, and its amount matches `^[0-9]+\.[0-9]{8}$`; currencies are unique; and the presence rules of `prices`, `modelMatchedBy`, `unpriced` and `usageInjected`, including `usage` and `prices` `null` when `status` is not 2xx. Members of the receipt, `params` and `result` that this TAP does not define do not fail this check; the digest of item 3 covers `params` and `result` as they appear in the receipt.
3. **Signature.** `container` equals `C` (compared case-insensitively), and the envelope digest over the values of §10, with `C` as the container, recovers to `S` under the signature rules of TAP-13 §5. When it recovers to another address, this check fails; the client then rereads the service as TAP-13 §8 requires after a binding failure, and MAY accept the same receipt if the reread signer is exactly that address and the receipt passes every check against the reread service.
4. **Method and path.** `method` is the receipt method of the format of the request it sent; `params.path` is that request's API path; `result.status` is the status it received; `result.stream` is whether the answer it received is a stream (§5.2). A client that does not hold the answer's `Content-Type` cannot decide this from the headers; it then fails this check when `result.stream` is `true` and the body, parsed as JSON, is an object or an array.
5. **Bytes**, when it holds them: `requestSha256` is the hash of the bytes it sent; `responseSha256` is the hash of what it received (for a stream, of the events dispatched up to and including the end, §6.1); when the answer's id (§7.3) is a string of 1 to 128 characters in U+0021–U+007E, `id` equals it; `model` is the reported model, or, when the answer reports none, `null` unless `modelMatchedBy` is `"request"`; `usage` equals the usage it computes (§4.1, §7.3); `complete` is what its own reading gives; and when `modelMatchedBy` is `"request"`, `model` equals the requested model of its request. The usage is not compared, and that comparison is reported as not made, only when `usageInjected` is present, the answer is a stream, the format is `openai-chat`, and the request body the client sent is one that §6.3 lets a sidecar change (or the client does not hold it). A whole answer is compared whether or not `usageInjected` is present. A stream receipt that carries `usageInjected` fails this check when its format is not `openai-chat` or the request body the client sent is not one that §6.3 lets a sidecar change.
6. **Amounts.** Matching `model` against the `ai` member under §4.2 for the request's format gives an entry exactly when `modelMatchedBy` is present; `prices` equals the list §4.3 gives for that entry and `usage` (currencies, order and amounts), or is `null` when there is none; and `unpriced` equals the member names of `usage.other` when `prices` is not `null`.
7. **Freshness.** When the client checks a receipt as the answer arrives, `|now − ts|` does not exceed 300 seconds, or the bound the client is configured with.
8. **Stream shapes**, for a stream whose bytes it holds (§5.2, §6.1, §9.2). The check fails in any of these cases: (a) an ambiguous line comes before the end, or anywhere in a stream that has no end; (b) the stream has no end and its bytes close while an event is unfinished; (c) the client passes bytes after the end on to the application, and after the end an event is dispatched whose data is not the format's sentinel (§6.1), a line is ambiguous, or the bytes close while an event is unfinished. What follows the end does not fail this check for a client that passes nothing after the end on to the application.

A check that the client could not make (for example, because it no longer holds the bytes, or because of `usageInjected` under item 5) MUST be reported as not made, never as passed. A receipt checked later, for example one retrieved under §7.5, cannot be checked for freshness. A client whose check fails MUST NOT present the answer or the receipt as verified.

### 10. Reuse of the envelope digest

This section gives what TAP-13 §9 requires of a TAP that reuses its digest.

| Place in the digest | Value in a receipt | How a verifier obtains it |
|---|---|---|
| Container | The service container | The container it resolved (`C`), never the receipt's `container` |
| `id` | The receipt's `id` (§7.1) | From the receipt; compared with the answer's own id when the answer has one of the form of §7.1 (§9.3 item 5) |
| Request object | `{ "method": <receipt method>, "params": { "path": …, "requestSha256": … } }` | From the receipt, then checked against its own request: the format, the API path and the SHA-256 of the bytes it sent (§9.3 items 4, 5) |
| `ok` | `true` (byte `0x01`) | Fixed |
| Body | `result` | From the receipt, then checked against the answer and the `ai` member (§9.3 items 5, 6) |
| Time | `ts` | From the receipt (§9.3 item 7) |

Why no receipt is accepted as an answer, and no answer as a receipt:

- A request of TAP-13 §3 names a method its manifest lists, and a manifest that carries `ai` lists no receipt method (§3.5). The request object that a client builds under that TAP's §8 therefore never names a receipt method, and its digest never equals a receipt's.
- A receipt is accepted only when its `method` is the receipt method of the format of the client's own request (§9.3 item 4) and its `ok` is `true` (§9.3 item 2). An answer of the service whose request object names a receipt method is an error, with `ok` `false` (§3.5), so its digest differs from a receipt's in the `ok` byte. This includes the answers of the lookup method `receipt` (§7.5), whose request object names `receipt`, which is not a receipt method (§2).

## Rationale

- **Existing formats, receipt before the end.** Callers keep the official SDKs and change only a base URL. The receipt goes where those SDKs do not look: a response header, or a comment line, which every event-stream parser ignores (a custom event type was rejected because some official SDKs hand unknown events to the application). SDKs stop reading at a format's final event or sentinel, so the receipt goes before it, and a verifying wrapper can hold that event until the receipt verifies. Without a final event the receipt is appended without an empty line, so that a truncated event stays truncated.
- **The end is a point in the bytes.** An official SDK stops reading at the end, so what it shows is the stream up to that point, however the network divided the bytes. A client that took its hash after the whole read that carried the end counted events that no SDK shows, and a stream cut short by an inserted `[DONE]` verified whenever the rest of the stream arrived in that same read. Checking at the point, and passing nothing after it on as verified, makes the outcome independent of how the bytes arrive.
- **Failing closed where parsers disagree.** A receipt binds the stream as §5.2 reads it, and cannot say how the application's parser read it. Where a widely used parser reads a shape differently (an ambiguous line, an event left unfinished at the close), content can reach the application that no hash covers, so the stream is refused rather than verified. The cost is a few honest streams refused: one that starts with two U+FEFF, a line of U+FEFF alone, and a stream whose upstream broke off in the middle of an event. The sidecar still signs the last of these (§6.2 item 3): the receipt stays an attributable record of an answer the upstream bills, even though no client verifies the stream. It does not sign a stream with an ambiguous line, since that receipt would cover content that some clients read differently from the hash.
- **The usage exception is narrow.** A receipt is signed with the service's own key, so a flag in it cannot be allowed to switch off a check that the client can make. `usageInjected` lifts the usage comparison only where the client's copy really lacks the usage: a streamed `openai-chat` answer to a request that did not ask for it.
- **`data: [DONE]` ends Responses streams too, and only the two OpenAI formats.** Some OpenAI-compatible gateways send Responses events as `data:` lines only, ending with `data: [DONE]`; a receipt appended after the sentinel is never seen, and a strict client rejects a correctly signed stream. Streams with `event:` lines reach `response.completed` (or `incomplete`, `failed`) first, which takes the only receipt, so nothing changes for them. Leaving this to configuration would make a stream verifiable or not depending on who runs the sidecar, so the rule is stated for every stream of the format (§6.1). The end has to lie where the application's client stops reading: the official OpenAI SDK for JavaScript (7.23.0) stops at an event whose data is exactly `[DONE]`, whatever its event name, which is the rule of §6.1; the official Anthropic SDK for JavaScript (0.128.0) does not stop at such an event, so `[DONE]` is not an end of `anthropic-messages`, where treating it as one would leave events the application reads outside the receipt.
- **What is hashed.** Requests and whole answers are hashed as the exact bytes the client holds; a canonical form of an arbitrary AI answer would cost more than it proves. A stream is hashed as its event data, which survives the re-chunking and line-end changes of proxies and CDNs. Both sides read events under one size bound, so they read the same events in bounded memory.
- **Usage injection.** Without it, a streamed Chat request that did not ask for usage could not be priced. The sidecar asks upstream and removes only the event its change caused; the "carries nothing" rule accepts the empty-delta form some compatible servers send and never removes an event with content, a finish reason or an unknown member.
- **One usage shape.** Anthropic reports input tokens without cache reads and writes; the OpenAI formats include them. One shape in which subsets are subsets lets one formula price every format, each token once.
- **Exact matching, reported model first.** Any fuzzy rule lets two parties price one receipt differently. The reported model names what answered; the requested model is a fallback for formats that report none.
- **Integer arithmetic, rounding up once.** Floating point differs between platforms, and rounding per bucket would make the sum depend on how tokens are split; rounding up means a receipt never states less than the exact amount. Prices are published, not settled: settlement needs payment rules that belong in a separate TAP.
- **`ok` is always true.** A receipt states what the upstream answered, failures included: an HTTP 429 becomes attributable, with `usage` and `prices` `null`, and an answer that broke off is priced from the usage it reported, with `complete` `false`, because the upstream bills it. The sidecar's own errors have nothing to bind and are unsigned.
- **A separate TAP.** Receipts need a price table, a usage schema, stream parsing and a lookup method that no client of TAP-13 needs; that TAP's §9 is the only link.

## Backwards Compatibility

**History.** This specification was first published in the TapeAPI repository as part of TAP-20 (§3.9, the `ai` member; our own document, since renamed TAPI-20; not the official TAP-20) and TAP-21 (§3.5, usage receipts), renamed TAPI-20 and TAPI-21 on 2026-09-30; neither is a TAP number, and the editors assign this TAP's number (TAP-01 §6.1). These deployed constants never change and encode no TAP number: the envelope prefix `TAPI-1/resp/v2`, the headers `x-tapeapi-receipt` and `x-tapeapi-sidecar-error`, the comment marker `tapeapi-receipt`, the manifest member `ai`, the format names, the receipt method names and the lookup method `receipt`.

**Receipts already issued.** Nothing in this TAP changes the bytes, hashes or amounts of a receipt the reference sidecar signs; its seven published vectors are reproduced unchanged (Test Cases). The checks of §9.2 and §9.3 items 4, 5 and 8 are stricter than those of TapeAPI 1.0.0 to 1.4.0. Above all, those versions verified an OpenAI Chat or Responses stream cut short by an inserted `[DONE]` whenever the inserted end and the rest of the stream arrived in the same network read, because they took the hash after that whole read; such a stream fails the hash comparison of §9.3 item 5 now. In addition, a stream that contains an ambiguous line or closes while an event is unfinished, which those versions signed or verified, is not verified, and neither is a receipt whose `usageInjected` does not match the request. Besides the table below, this text differs from the TapeAPI text in four ways: comparing `model` and `usage` with the answer is required where that text recommended it (the reference client already fails a receipt on either); currency codes are units of account bound to no token or contract, where that text named tokens on BNB Chain; only `https://` base URLs are allowed, since TAP-11 has no development mode; and the stream shapes that parsers read differently, which TAPI-21 §8 describes in an informative note with no requirement, are requirements here (§6.2 item 6, §9.2, §9.3 item 8), which the reference implementation meets apart from the rows of the table below.

**Differences from the reference implementation** (TapeAPI 1.5.0, commit `d991f5e`) and planned changes:

| Area | Reference implementation today | This TAP | Plan |
|---|---|---|---|
| Responses final lines | The default `openai-responses` adapter lists only the three `event:` lines; `data: [DONE]` is added through `createAIProxy`'s public `formats` option, as the reference's own gateway example does | `data: [DONE]` is a final line (§6.1) | Add it to the default adapter. No receipt, hash or amount changes for a stream with `event:` lines that reaches its final event before any `[DONE]` (`receipts-extra.json`); one whose `[DONE]` comes first gets its receipt before `[DONE]` (`receipts-done.json`) |
| Reserved method names | Not checked by the client (the reference provider already answers unlisted methods with `METHOD_NOT_FOUND`) | An `ai` member next to a listed receipt method is invalid (§3.5) | Add the check. The live manifest of `11.1013.tape` (read on chain; Test Cases of TAP-11) carries no `ai` member and lists no such name, and the reference relay behind `12.1013.tape` builds its manifest without `ai` |
| Parsing and shape of a receipt | `JSON.parse`: a repeated member name keeps the last value, and forbidden member names are refused only when the canonical form is computed; `id` is checked for its length, not its characters | Strict parser and the `id` rule of §7.1 (§9.3 items 1, 2) | Parse receipts with the SDK's strict parser and check the characters of `id` |
| `http://` base URLs | Accepted in an explicit development mode | Invalid (§3.2) | Keep the development mode outside conformance |
| Non-strict verification | The verifying fetch has a reporting mode that passes every byte on: it reports the receipt as verified at the end, and then an event after the end, an ambiguous line or an event unfinished at the close as a separate failure | Such a stream fails §9.3 item 8 | Document the mode as diagnostic |
| Offline check of a whole stream | `verifyUsageReceipt` with `responseBytes` hashes every event of the stream, so an event after the end fails the hash comparison; an ambiguous line or an event unfinished at the close fails wherever it is, as for a client that passes every byte on (§9.3 item 8) | The hash covers the events up to the end (§9.2), and an event after the end fails item 8 for a client that passes it on | None decided: neither verifies content after the end |

Where the reference implementation's resolution of a service differs from TAP-10, TAP-11 lists the difference; this TAP adds none.

## Test Cases

The vector files are in `assets/tap-draft-ai-usage-receipts/`. The first five below were produced with the reference implementation at commit `fda84db` (TapeAPI 1.3.0); every hash, amount, digest and recovered signer in them was also recomputed with the independent Python routines of `spec/vectors/verify.py` at that commit. With TapeAPI 1.5.0 (the commit under Reference Implementation), every stream hash of `sse-hash.json` is reproduced, and every receipt of `receipts.json` and `receipts-extra.json` still passes `verifyUsageReceipt` against the bytes the client received, with no ambiguous line and no event unfinished at the close. The signer key is a published test key. **Every price in them is a test value; none states the price of any model or service.**

- `receipts.json` (§4–§10): the reference implementation's seven vectors, unchanged, with each envelope's digest added: each format, streams and whole answers, usage injection, an alias, both kinds of cache writes, pricing by the requested model, a stream that ends in an `error` event (receipt appended) and an HTTP 429. Each gives the `ai` member, the request bytes, the upstream request when it differs, the upstream answer, the exact bytes the client receives, and the expected hashes, result, envelope, digest and header or comment value.
- `receipts-extra.json` (§4–§10): six further cases from the reference sidecar, with `data: [DONE]` made a final line of `openai-responses` through `createAIProxy`'s public `formats` option: a Chat usage event with an empty-delta choice, removed; a Chat stream whose client asked for usage; a data-only Responses stream ending in `data: [DONE]`; a Responses stream with `response.completed` then `data: [DONE]`; an Anthropic whole answer with web-search counts in `unpriced`; a reported model outside the table. A seventh, marked as a control, sends the data-only stream through the default adapters: its receipt lands after `[DONE]`.
- `amounts.json` (§4): 13 amounts (single rounding on the sum, every default of §3.4, reasoning with and without its price, per-use counts, 18-digit prices with 2^53 − 1 tokens), 9 usage computations (every rule of §4.1) and 8 model matches.
- `sse-hash.json` (§5.2): 16 streams covering each parsing rule, with their exact bytes and hash. The case "an unfinished event at the end is discarded" keeps its hash, and is a stream that §9.3 item 8 does not verify.
- `field-validation.json` (§3): 3 valid and 22 invalid `ai` members.
- `stream-shapes.json` (§5.2, §6.1, §9.2, §9.3 item 8): 33 streams of the three streaming formats, each with its exact bytes, the byte offset of its end (or none), the hash at the end and over the whole stream, the events dispatched after the end, the ambiguous lines before and after the end, whether the bytes close while an event is unfinished, and the outcome of item 8 for a client that stops at the end and for one that passes every byte on. They cover an event after `[DONE]`, `response.completed` or `message_stop` in the same bytes (LF and `CR LF`); a comment, an event without data and a second `[DONE]` after the end, which fail nothing; a stream without an end closed by a receipt line, which passes; streams closed on an unfinished data line, `event` line or comment line, or cut in the middle of an event before a receipt line; ambiguous lines (a data line, a comment line, two U+FEFF at the start, U+FEFF alone, after a `CR` line end) before and after the end, and U+FEFF inside lines, which is not ambiguous; and an end whose empty line is a lone `CR`. Eleven of them, marked `"added": "2026-10-08"`, cover which streams `[DONE]` applies to (§6.1): in `openai-responses`, `data:[DONE]` without the space, `CR LF` line ends, `[DONE]` after `response.completed` (after the end, failing nothing) and before it (the end, with `response.completed` after it), and an event named `done` whose data is `[DONE]`; data that is not exactly `[DONE]` (`[DONE] `, `[done]`, `[DONE]` joined with a second data line), which is hashed and is no end; in `openai-chat`, `data:[DONE]` without the space and an `event: response.completed` line that is no end; and in `anthropic-messages`, a `[DONE]` event before `message_stop` (hashed, no end) and after it (an event after the end). The receipt comments in it are placeholders: these vectors test parsing, not signatures. Produced with `createSseScanner` and `scanSse` of TapeAPI 1.5.0, and every value recomputed by `stream-shapes-check.py` in the same directory, a whole-text parser written from this text alone (`python3 stream-shapes-check.py`).

- `receipts-done.json` (§6.1, §6.2, §7, §9.2): five signed receipts from the reference sidecar at the commit under Reference Implementation, made like those of `receipts-extra.json` (same key, manifest, clock, random source and `formats` option; at that commit the same harness reproduces every "as specified" case of `receipts-extra.json` byte for byte): a data-only `openai-responses` stream and an `openai-chat` stream each ended by `data:[DONE]` without the space; an `openai-responses` stream with `event:` lines whose upstream sends `data: [DONE]` before `response.completed` (the receipt goes before `[DONE]` and has `usage` and `prices` `null` and `complete` `false`, since nothing before the end reported usage); and two `anthropic-messages` streams with a `[DONE]` event before and after `message_stop`. Each case gives, besides the members of `receipts.json`, the values of `stream-shapes.json` for the bytes the client receives. Every receipt verifies with `verifyUsageReceipt` against the bytes up to the end, and every hash, amount, digest and signer was recomputed with the Python routines of `spec/vectors/verify.py` and `stream-shapes-check.py`.

Verdicts that depend on signed streams and on how their bytes arrive are tested in the reference implementation at the commit below, not as vector files:

- `sdk/test/ai-stream-chunking.test.mjs` (§6.1, §9.2, §9.3 item 8): signed streams of each format from the reference sidecar, honest and edited on the way (a `[DONE]` or final event inserted early with the receipt moved to the start, an event appended after the end, an unfinished event appended, a data or comment line led by U+FEFF), each replayed under one event per read, the whole stream in one read, the end and the rest in one read, one byte per read and seeded random divisions, with LF and `CR LF`, through a client that stops at the end and one that passes every byte on. It asserts that the outcome does not depend on the division, and that neither do the bytes a stopping client passes on, except that when the empty line that ends the stream is a `CR` at the end of a read, the stream ends at that `CR` and the `LF` that may follow it (the one byte §6.1 lets a client not wait for) is not passed on; and that the sidecar signs no stream with an ambiguous line before its signing point, while a stream cut in the middle of an event carries a receipt that is not verified.
- `sdk/test/ai-usage-injected.test.mjs` (§9.3 items 4, 5): a whole answer whose usage was raised and re-signed with `usageInjected` fails; the honest sidecar's receipt for a stream request answered as a whole answer still passes with the usage compared; an injected stream passes with the usage reported as not checked; a stream whose request already asked for usage, or of a format that never injects, fails when its receipt carries the flag; and a whole JSON answer under a receipt that calls it a stream fails when the verifier holds no `Content-Type`.

Example, the case `openai-chat-json` of `receipts.json`: usage `prompt_tokens` 1200 (of which `cache_read_tokens` 1000) and `completion_tokens` 300 (of which `reasoning_tokens` 100). With the test entry `input` `"1.25"`, `cacheRead` `"0.125"`, `output` `"10"`, `reasoning` `"12"`: `S` = 125000000 × 200 + 12500000 × 1000 + 1000000000 × 200 + 1200000000 × 100 = 357500000000, `A` = 357500, amount `"0.00357500"`.

```
requestSha256   ed27ce746e9fbaf5a7ad044821b660372e1d531029e3aa23deb0dd1d58c36306
responseSha256  a783a8f0f6acfeb41efe248f2b5c9d58818d2c8f89aff5da274ae3a2adc2f27d
id              chatcmpl-v1        method openai_chat        ts 1790000000
digest          0x9c1a12040ced607f4c123ca727cb9ff8ee268288876bad13c0e47bb717d8c958
signer          0x504e4FbaB7bC2962b361E3730B965E61F289d0cC
```

## Reference Implementation

TapeAPI 1.5.0, at commit [`d991f5e27429e13a480025bc3bdb8c2c29231574`](https://github.com/BruceLanLan/tapeapi/tree/d991f5e27429e13a480025bc3bdb8c2c29231574) (tag [`v1.5.0`](https://github.com/BruceLanLan/tapeapi/releases/tag/v1.5.0); MIT licensed):

- [`sdk/src/ai.js`](https://github.com/BruceLanLan/tapeapi/blob/d991f5e27429e13a480025bc3bdb8c2c29231574/sdk/src/ai.js): validation of `ai` (§3), usage, matching and amounts (§4), the incremental event-stream scanner (`createSseScanner`, which also keeps the hash, event count and offset at the end and counts ambiguous lines) and hashes (§5, §6.1), the receipt codec, and client verification (`verifyUsageReceipt`, `answerProblems`, and `createVerifyingFetch`, which wraps an official SDK's fetch) (§9);
- `sdk/src/ai-openai-chat.js`, `sdk/src/ai-openai-responses.js`, `sdk/src/ai-anthropic-messages.js`, `sdk/src/ai-openai-embeddings.js`: one adapter per format (§2, §6.1, §6.3, §7.3);
- [`server/src/ai-proxy.js`](https://github.com/BruceLanLan/tapeapi/blob/d991f5e27429e13a480025bc3bdb8c2c29231574/server/src/ai-proxy.js): a sidecar (§6.2, §7, §8);
- `sdk/bin/tapeapi-verify.js`: a local verifying proxy for clients that cannot wrap fetch;
- `sdk/test/ai-receipt-vectors.test.mjs`: regenerates the reference vectors with the sidecar and recomputes every stream hash with a separate whole-text parser; `sdk/test/ai-stream-chunking.test.mjs` and `sdk/test/ai-usage-injected.test.mjs`: the tests listed under Test Cases;
- [`spec/vectors/verify.py`](https://github.com/BruceLanLan/tapeapi/blob/d991f5e27429e13a480025bc3bdb8c2c29231574/spec/vectors/verify.py): an independent Python implementation of the request and stream hashes, the amounts, the model match and the envelope digest with secp256k1 recovery.

The differences from this text are listed under Backwards Compatibility. The author runs no sidecar as a public service; each provider runs its own. Nothing here has been audited.

## Deployments

None. This TAP deploys no contract and depends on none directly. Resolving a service and its signer uses the contracts listed under Deployments in TAP-11, which refers to TAP-10.

## Security Considerations

The attacker considered can read, delay, drop, replay and modify traffic between client and sidecar, including through a proxy or CDN, can run services of its own, and can be the provider itself.

- **What a receipt proves.** That the service's signer, at time `ts`, stated that a request whose body had this SHA-256 was sent to this API path, that the upstream answered it with this status and these bytes (for a stream, this event data), reporting this model and usage and completing or not, and that the published table gives these amounts. Because the signer is bound to the container on chain, the statement cannot later be disowned.
- **What it does not prove.** Which model produced the answer: `model` is what the upstream reported, and a provider can label a cheaper model's answer with a dearer model's name. Nor that the reported usage is the true token count, that anything was paid, or that the upstream is who the provider says. A receipt makes such misstatements attributable, not impossible: anyone can send test prompts on a schedule and publish the answers with their receipts.
- **What the checks protect.** A receipt cannot be moved to another request (request hash and path), answer (response hash), service (the container taken from resolution) or time (`ts` and the freshness window). An answer or usage altered on the path fails the response hash or the usage comparison; a price that differs from the published table fails the amount check.
- **What they do not cover.** Anyone on the path can remove a receipt or replace the answer with a sidecar-style error; the client then has no verified answer and cannot tell this from a provider failure (the `x-tapeapi-sidecar-error` header proves nothing). Under `usageInjected`, for a streamed `openai-chat` request that did not ask for usage, the client never saw the usage event and relies on the signed statement alone; a client that asks for usage itself avoids this. Bytes after the end of a stream are covered by no receipt (§9.2), and the query of a request URL is covered by none (§3.2).
- **Parser differences.** A receipt binds bytes as this TAP parses them, while the application sees them as its own client parses them. Where the two readings differ, the provider or a party on the path can show the application content that no receipt covers while every hash still matches. Four such gaps were found in an implementation of this specification and are closed here. A client that took its hash after the whole network read that carried the end counted events after the end, so a stream cut short by an inserted `[DONE]` verified when the rest arrived in the same read (§9.2). The official OpenAI and Anthropic SDKs for JavaScript (tested with `openai` 7.23.0 and `@anthropic-ai/sdk` 0.128.0) remove a U+FEFF from the start of every line and read the field after it, which §5.2 reads as an unknown field: content could be inserted anywhere in a signed stream without changing its hash (§6.2 item 6, §9.3 item 8). The OpenAI SDK (the same version) dispatches an event that the stream closes on before its empty line, which §5.2 discards: content appended after a stream with its sentinel removed reached the application as verified (§9.3 item 8). And a verifier that skipped the usage comparison whenever a receipt carried `usageInjected` let whoever holds the signer key (the operator of the sidecar) claim any usage, with matching prices, for an answer whose usage the verifier could read (§9.3 item 5). Other parsers can differ in ways not listed here; an implementation should test the parsers its users run against the vectors of this TAP (Test Cases).
- **Request privacy.** A receipt carries hashes, never content, so it can be shown to a third party; but a short or predictable prompt can be confirmed from its hash by guessing. A client can prevent that by appending random JSON whitespace (space, tab, `LF`, `CR`) after the JSON text of its request body: the parsed request, its tokens and any prompt cache keyed on them are unchanged, and the hash cannot be guessed. The model, usage and time stay visible.
- **Retrieval by id.** The lookup method answers whoever presents an id. Some OpenAI-compatible servers draw answer ids from a small set, and the sidecar keeps the upstream's id, so a stranger can read other callers' receipts (model, usage, time, hashes). Providers behind such upstreams can require `requestSha256` in lookups (§7.5), keep receipts for less time and rate-limit lookups.
- **Credentials and routing.** The sidecar sees each caller's API key and forwards it upstream, as the provider's own server would, so it is operated by the provider, never by a third party. The headers of §8 keep client addresses and cookies from the upstream; forwarded session headers of the official clients let the upstream link a caller's requests. Redirects are not followed and the upstream address is fixed by configuration, so a request cannot steer the sidecar to another host.
- **Signer key and parsing.** The sidecar holds the signer key online; whoever steals it can sign receipts for the service until the holder replaces the key or the delegation expires (TAP-11 §7.2). Receipts share the signature domain of TAP-13; §3.5 and §10 keep a receipt and an answer apart, and the strict parser and canonical forms of that TAP (§2, §5) remove the values on which implementations have been seen to disagree.
- **Compliance.** This TAP gives a provider an identity and a published price list; it is not designed to help anyone evade an upstream provider's terms.
- **Trust inherited from resolution.** Every guarantee above rests on the signer being the one the holder authorised and on the price table being the one in the manifest resolved under TAP-11. Until the contracts that resolution reads are sealed, whoever controls them can change what resolution returns; this TAP inherits that assumption.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).

## Appendix A. The AI APIs the formats are taken from (informative)

This appendix describes the vendor APIs from which the four formats of §2 are taken, as their providers documented them and as the reference implementation observed them up to 2026-10-08. Nothing in it is a requirement. Where it differs from the Specification, the Specification applies, and a later change to a vendor API changes nothing in this TAP.

**OpenAI Chat Completions (`openai-chat`).** Clients send `POST /v1/chat/completions` to a base URL ending in `/v1`, authenticated with `Authorization: Bearer <key>` and optionally `OpenAI-Organization`, `OpenAI-Project` and `OpenAI-Beta`. With `"stream": true` the answer is a server-sent event stream of `data:` lines without `event:` lines, one JSON chunk per event, ended by `data: [DONE]`. A stream reports usage only when the request sets `stream_options.include_usage` to `true`; the usage then comes in one more chunk before `[DONE]`, with `choices` `[]` (some compatible servers send `[{"index":0,"delta":{}}]` instead). Usage has `prompt_tokens` (cache reads included), `completion_tokens` (reasoning included), `total_tokens`, `prompt_tokens_details.cached_tokens` and `completion_tokens_details.reasoning_tokens`; some compatible servers report cache reads as `prompt_cache_hit_tokens`.

**OpenAI Responses (`openai-responses`).** `POST /v1/responses`; `POST /v1/responses/compact` compacts a conversation and is billed like a response. A stream carries typed events (`event: response.created`, `response.output_text.delta`, …) whose JSON data repeats the event name in `type`, and ends with `response.completed`, `response.incomplete` or `response.failed`, whose `response` member holds the whole response with its usage: `input_tokens` (cache reads included), `input_tokens_details.cached_tokens`, `output_tokens` (reasoning included), `output_tokens_details.reasoning_tokens` and `total_tokens`. Some OpenAI-compatible gateways send the same events as `data:` lines only and end the stream with `data: [DONE]`, or add `data: [DONE]` after the final event.

**Anthropic Messages (`anthropic-messages`).** Clients send `POST /v1/messages` to a base URL without `/v1`, authenticated with `X-Api-Key` (or `Authorization: Bearer`), with `Anthropic-Version` and optionally `Anthropic-Beta`. A stream carries `message_start` (the message with its `id`, `model` and initial usage), `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta` (the stop reason and cumulative usage), `message_stop`, `ping` and `error` events, each with an `event:` line, and has no sentinel. Usage reports `input_tokens` without cache reads and writes, which come as `cache_read_input_tokens` and `cache_creation_input_tokens`; `cache_creation.ephemeral_5m_input_tokens` and `cache_creation.ephemeral_1h_input_tokens` split cache writes by how long the cache is kept; `output_tokens` includes thinking; `server_tool_use.web_search_requests` counts server-side web searches, which are billed per use.

**OpenAI Embeddings (`openai-embeddings`).** `POST /v1/embeddings`, with the headers of the other OpenAI formats. It never streams, and its usage has `prompt_tokens` and `total_tokens`.

**Client headers.** Besides the headers of §8, the official SDKs send `User-Agent` and headers whose names begin with `X-Stainless-`, which describe the SDK, the language and the platform, and some applications built on them send session headers that tie a caller's requests together. Forwarding them affects what the upstream learns about the caller (Security Considerations), not what is hashed or read.
