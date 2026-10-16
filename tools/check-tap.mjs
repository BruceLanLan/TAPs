#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Mechanical checks for TAP files, from TAP-01 §6 and §7 and CONTRIBUTING.md §4.
// It only covers what a script can decide (preamble fields, section order, file
// names, key-word spelling, invisible characters, unpinned links). Coherence, one
// topic per TAP and whether a key word is a real requirement stay with the editors.
//
// Usage:  node tools/check-tap.mjs [--json] [file ...]
//         With no file, checks every TAPs/*.md that is not a translation.
// Exit:   1 if any file has an error, otherwise 0. Warnings never fail.
// Output: key words are counted separately, so "MUST 18, MUST NOT 15" means 18
//         MUSTs not followed by NOT; some drafts report MUST as 33 (both together).
// Needs:  Node 18 or later, no dependencies.

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';

const STATUSES = ['Idea', 'Draft', 'Review', 'Candidate', 'Final', 'Living', 'Stagnant', 'Withdrawn'];
const TYPES = ['Standards', 'Application', 'Information', 'Process'];
const REQUIRED = ['tap', 'title', 'description', 'author', 'discussions-to', 'status', 'type', 'created', 'license'];
const KNOWN = [...REQUIRED, 'updated', 'version', 'requires', 'supersedes', 'superseded-by'];
// TAP-01 §7.2, in order. `need(type)` says whether the section must be present.
const SECTIONS = [
  ['Summary', () => true],
  ['Abstract', () => true],
  ['Motivation', () => true],
  ['Specification', () => true],
  ['Rationale', () => true],
  ['Backwards Compatibility', () => false],
  ['Test Cases', (t) => t === 'Standards'],
  ['Reference Implementation', () => false],
  ['Deployments', () => false],
  ['Security Considerations', (t) => t !== 'Information'],
  ['Copyright', () => true],
];
const KEY_WORDS = ['MUST NOT', 'MUST', 'SHOULD NOT', 'SHOULD', 'MAY'];
// Format characters and other default-ignorable code points a reader cannot see.
const INVISIBLE = /[­͏؜ᅟᅠ឴឵᠋-᠏​-‏‪-‮⁠-⁯ㅤ︀-️﻿ﾠ￰-￸]|\uDB40[\uDC00-\uDDEF]/g;
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function checkFile(path, root) {
  const errors = [];
  const warnings = [];
  const raw = readFileSync(path);
  const name = basename(path);

  if (raw[0] === 0xef && raw[1] === 0xbb && raw[2] === 0xbf) errors.push('file begins with a byte order mark');
  const text = raw.toString('utf8');
  if (Buffer.from(text, 'utf8').compare(raw) !== 0) errors.push('file is not valid UTF-8');
  const lines = text.split(/\r?\n/);

  // §7.1 preamble
  const fm = {};
  if (lines[0] !== '---') {
    errors.push('missing YAML front matter (first line must be ---)');
  } else {
    const end = lines.indexOf('---', 1);
    if (end < 0) errors.push('front matter is not closed with ---');
    for (const line of lines.slice(1, end < 0 ? 1 : end)) {
      const m = /^([a-z-]+):\s*(.*)$/.exec(line);
      if (!m) { if (line.trim()) warnings.push(`front matter line not understood: ${line}`); continue; }
      if (m[1] in fm) errors.push(`front matter field repeated: ${m[1]}`);
      fm[m[1]] = m[2].trim();
    }
  }
  for (const f of REQUIRED) if (!fm[f]) errors.push(`front matter field missing or empty: ${f}`);
  for (const f of Object.keys(fm)) if (!KNOWN.includes(f)) warnings.push(`front matter field not in TAP-01 §7.1: ${f}`);
  if (fm.status && !STATUSES.includes(fm.status)) errors.push(`status "${fm.status}" is not one of TAP-01 §5`);
  if (fm.type && !TYPES.includes(fm.type)) errors.push(`type "${fm.type}" is not one of TAP-01 §3`);
  if (fm.license && fm.license !== 'CC0-1.0') errors.push(`license must be CC0-1.0, found "${fm.license}"`);
  for (const f of ['created', 'updated']) {
    if (fm[f] && !ISO_DATE.test(fm[f])) errors.push(`${f} is not a YYYY-MM-DD date: ${fm[f]}`);
  }
  if (ISO_DATE.test(fm.created ?? '') && ISO_DATE.test(fm.updated ?? '') && fm.updated < fm.created) {
    errors.push(`updated (${fm.updated}) is earlier than created (${fm.created})`);
  }
  if (fm.author && !/\(@[A-Za-z0-9-]+\)/.test(fm.author)) warnings.push('author has no GitHub handle in the form Name (@handle)');
  if (fm.title && /\bTAP-\d/.test(fm.title)) errors.push('title must not contain a TAP number');
  if (fm.description && sentences(fm.description) > 1) warnings.push('description looks like more than one sentence');
  if (fm['discussions-to'] && !/^https:\/\//.test(fm['discussions-to'])) errors.push('discussions-to is not an https URL');

  // §6.1, §6.2 file name and number
  const draft = /^TAP-draft-([a-z0-9-]+)\.md$/.exec(name);
  const numbered = /^TAP-(\d{2,})\.md$/.exec(name);
  let heading = 'TAP-TBD';
  if (draft) {
    if (fm.tap && fm.tap !== 'TBD') errors.push(`a draft file must have tap: TBD, found ${fm.tap}`);
    const own = `assets/tap-draft-${draft[1]}/`;
    if (text.includes(own) && !existsSync(join(root, own))) warnings.push(`refers to ${own} but it does not exist`);
  } else if (numbered) {
    if (fm.tap && String(Number(fm.tap)) !== String(Number(numbered[1]))) errors.push(`tap: ${fm.tap} does not match the file name ${name}`);
    if (fm.tap && /^\d+$/.test(fm.tap)) heading = `TAP-${fm.tap.padStart(2, '0')}`;
  } else {
    errors.push('file name is neither TAP-<nn>.md nor TAP-draft-<short-title>.md (TAP-01 §6.2)');
  }

  // §7.2 title heading and sections
  const h1 = lines.find((l) => l.startsWith('# '));
  if (!h1) errors.push('no level-1 heading');
  else if (!h1.startsWith(`# ${heading}: `)) warnings.push(`level-1 heading should start with "# ${heading}: "`);
  // Process TAPs (like TAP-01) do not follow the section list (TAP-01 §7.2).
  const h2 = lines.filter((l) => /^## /.test(l)).map((l) => l.slice(3).trim());
  if (fm.type !== 'Process') {
    const present = [];
    for (const [sec, need] of SECTIONS) {
      const at = h2.indexOf(sec);
      if (at < 0) { if (need(fm.type)) errors.push(`required section missing: ## ${sec}`); continue; }
      present.push([sec, at]);
    }
    for (let i = 1; i < present.length; i++) {
      if (present[i][1] < present[i - 1][1]) errors.push(`section out of order: ## ${present[i - 1][0]} comes after ## ${present[i][0]}`);
    }
    if (fm.type === 'Information' && /\*\*(MUST|SHOULD|MAY)\b/.test(text)) {
      warnings.push('an Information TAP has no requirements, but key words appear in bold');
    }
  }
  const summary = sectionText(lines, 'Summary');
  if (summary !== null && sentences(summary) > 1) warnings.push('Summary looks like more than one sentence');
  const copyright = sectionText(lines, 'Copyright');
  if (copyright !== null && !/waived via \[?CC0\b/.test(copyright)) errors.push('Copyright section does not say "Copyright and related rights waived via CC0."');

  // §7.2 key words: capitals only
  const body = stripCode(text);
  const counts = {};
  let rest = body;
  for (const kw of KEY_WORDS) {
    const re = new RegExp(`\\b${kw.replace(' ', '\\s+')}\\b`, 'g');
    counts[kw] = (rest.match(re) ?? []).length;
    rest = rest.replace(re, '');
  }
  for (const m of body.matchAll(/\*\*(must not|must|should not|should|may|Must Not|Must|Should|May|required|REQUIRED|SHALL|SHALL NOT|RECOMMENDED|OPTIONAL)\*\*/g)) {
    warnings.push(`bold "${m[1]}": TAP-01 §7.2 uses only MUST, MUST NOT, SHOULD, SHOULD NOT and MAY, in capitals`);
  }

  // Invisible characters outside code spans (they change what a reader sees, not
  // what a parser reads). Code spans are skipped so a TAP can show them as examples.
  lines.forEach((l, i) => {
    const hits = l.replace(/`[^`]*`/g, '').match(INVISIBLE);
    if (hits) warnings.push(`line ${i + 1}: invisible character${hits.length > 1 ? 's' : ''} ${[...new Set(hits)].map(hex).join(' ')}`);
  });

  // CONTRIBUTING §4: nothing normative on an external link, except at a fixed commit or version
  for (const m of body.matchAll(/https:\/\/github\.com\/([^\s)>\]]+)/g)) {
    const url = m[1];
    if (/^[^/]+\/[^/]+\/(issues|pull|discussions|releases\/tag)\//.test(url)) continue;
    if (/^[^/]+\/[^/]+\/?$/.test(url)) continue;
    if (/\/(tree|blob|commit)\/[0-9a-f]{7,40}\b/.test(url) || /\/(tree|blob)\/v?\d+\.\d+/.test(url)) continue;
    warnings.push(`GitHub link not pinned to a commit or version: https://github.com/${url}`);
  }

  return { file: path.slice(root.length + 1), errors, warnings, keyWords: counts };
}

function sectionText(lines, title) {
  const start = lines.indexOf(`## ${title}`);
  if (start < 0) return null;
  const end = lines.findIndex((l, i) => i > start && /^## /.test(l));
  return lines.slice(start + 1, end < 0 ? undefined : end).join('\n').trim();
}

function sentences(s) {
  const plain = s.replace(/`[^`]*`/g, 'x').replace(/\b(e\.g|i\.e|etc|vs|cf)\./g, 'x').replace(/\d\.\d/g, 'x');
  return (plain.match(/[.!?](\s|$)/g) ?? []).length;
}

function stripCode(text) {
  return text.replace(/^```[\s\S]*?^```/gm, '').replace(/`[^`\n]*`/g, '');
}

function hex(ch) {
  return `U+${ch.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`;
}

const args = process.argv.slice(2);
const json = args.includes('--json');
const root = resolve(dirname(new URL(import.meta.url).pathname), '..');
let files = args.filter((a) => a !== '--json').map((f) => resolve(f));
if (files.length === 0) {
  files = readdirSync(join(root, 'TAPs'))
    .filter((f) => /^TAP-[^.]+\.md$/.test(f))
    .map((f) => join(root, 'TAPs', f));
}

const results = files.map((f) => checkFile(f, root));
if (json) {
  console.log(JSON.stringify(results, null, 2));
} else {
  for (const r of results) {
    const kw = KEY_WORDS.map((k) => `${k} ${r.keyWords[k]}`).join(', ');
    console.log(`${r.errors.length ? 'FAIL' : 'ok  '} ${r.file}  (${kw})`);
    for (const e of r.errors) console.log(`     error:   ${e}`);
    for (const w of r.warnings) console.log(`     warning: ${w}`);
  }
}
process.exit(results.some((r) => r.errors.length) ? 1 : 0);
