#!/usr/bin/env node
// Resolve merge conflicts whose fork-side change is nothing but a brand rename.
//
// Runs against a conflicted index. For each conflicted file it reads the three
// stages git already stores -- base (ancestor), ours (fork), theirs (upstream) --
// and never parses conflict markers.
//
// A file qualifies when the fork's change relative to the ancestor consists only
// of brand tokens. The rename map is then derived from that ancestor/fork pair
// rather than hand-written, so identifiers the fork deliberately left alone
// (PASEO_HOME, the @getpaseo scope, paseoHome locals) can never be rewritten:
// they are identical on both sides and so never enter the map.
//
// Anything that does not qualify is left conflicted and reported. The caller
// decides whether a partial resolution is worth continuing with.

import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const BRAND = /paseo|rambla/gi;
// Maximal run of identifier/path characters containing a brand token. Anchoring
// on the whole run keeps "@getpaseo/server" distinct from "github.com/getpaseo/paseo".
const ANCHOR = /[A-Za-z0-9_.@/-]*(?:paseo|rambla)[A-Za-z0-9_.@/-]*/gi;

function git(args, { allowFail = false } = {}) {
  try {
    return execFileSync("git", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  } catch (error) {
    if (allowFail) return null;
    throw error;
  }
}

function stage(n, path) {
  return git(["show", `:${n}:${path}`], { allowFail: true });
}

const strip = (text) => text.replace(BRAND, "");

// Ancestor and fork differ only at brand tokens, so their anchor runs correspond
// one to one in order. Zip them into replacement pairs.
function collectPairs(base, ours, map) {
  const from = base.match(ANCHOR) ?? [];
  const to = ours.match(ANCHOR) ?? [];
  if (from.length !== to.length) return false;
  for (let i = 0; i < from.length; i++) {
    const existing = map.get(from[i]);
    if (existing !== undefined && existing !== to[i]) return false; // ambiguous
    map.set(from[i], to[i]);
  }
  return true;
}

// Derive the map from every file the fork touched, not just the conflicted one.
// A token upstream uses that the fork renamed somewhere else still resolves.
function globalMap(mergeBase) {
  const map = new Map();
  const ambiguous = new Set();
  const changed = (git(["diff", "--name-only", mergeBase, "HEAD"]) ?? "").split("\n").filter(Boolean);
  for (const path of changed) {
    const base = git(["show", `${mergeBase}:${path}`], { allowFail: true });
    const ours = git(["show", `HEAD:${path}`], { allowFail: true });
    if (base === null || ours === null) continue;
    if (strip(base) !== strip(ours)) continue;
    const from = base.match(ANCHOR) ?? [];
    const to = ours.match(ANCHOR) ?? [];
    if (from.length !== to.length) continue;
    for (let i = 0; i < from.length; i++) {
      const existing = map.get(from[i]);
      if (existing !== undefined && existing !== to[i]) ambiguous.add(from[i]);
      else map.set(from[i], to[i]);
    }
  }
  // A token the fork renamed one way here and another way there cannot be
  // applied blind to upstream code. Drop it and let the file decide, or stop.
  for (const token of ambiguous) map.delete(token);
  return { map, ambiguous };
}

// Two classes never change, by fork policy: PASEO_* environment variables and
// the @getpaseo npm scope. Upstream can introduce new ones the fork has never
// seen, so they are recognised by shape rather than by having been observed.
const KEPT_BY_POLICY = /PASEO_[A-Z0-9_]|@getpaseo/;

// Otherwise a token the map never saw is safe to leave alone only if the fork
// itself still uses that exact token -- which is what protects the bin alias.
const keptCache = new Map();
function forkStillUses(token) {
  if (KEPT_BY_POLICY.test(token)) return true;
  if (!keptCache.has(token)) {
    keptCache.set(token, git(["grep", "-qF", "--", token, "HEAD"], { allowFail: true }) !== null);
  }
  return keptCache.get(token);
}

function apply(text, map) {
  const unmapped = new Set();
  const out = text.replace(ANCHOR, (run) => {
    const replacement = map.get(run);
    if (replacement === undefined) {
      unmapped.add(run);
      return run;
    }
    return replacement;
  });
  return { out, unmapped };
}

const conflicted = (git(["diff", "--name-only", "--diff-filter=U"]) ?? "")
  .split("\n")
  .filter(Boolean);

if (conflicted.length === 0) {
  console.log("No conflicted files.");
  process.exit(0);
}

const mergeBase = (git(["merge-base", "HEAD", "MERGE_HEAD"]) ?? "").trim();
const { map: renames, ambiguous: ambiguousTokens } = globalMap(mergeBase);

const resolved = [];
const deleted = [];
const skipped = [];
const substitutions = new Map();

for (const path of conflicted) {
  const base = stage(1, path);
  const ours = stage(2, path);
  const theirs = stage(3, path);

  if (base === null || ours === null) {
    skipped.push([path, "no common ancestor or no fork-side content"]);
    continue;
  }
  if (strip(base) !== strip(ours)) {
    skipped.push([path, "fork changed more than brand tokens"]);
    continue;
  }

  // Upstream deleted a file whose only fork-side change was a rename: nothing
  // of the fork's is lost by taking the deletion.
  if (theirs === null) {
    git(["rm", "-q", "--", path]);
    deleted.push(path);
    continue;
  }

  // What this file itself proves beats what the rest of the fork suggests.
  const perFile = new Map();
  if (!collectPairs(base, ours, perFile)) {
    skipped.push([path, "the fork renamed one token two ways in this file"]);
    continue;
  }
  const map = new Map([...renames, ...perFile]);

  // The map must reproduce the fork's own file exactly, or it is not the
  // transformation the fork actually applied.
  if (apply(base, map).out !== ours) {
    skipped.push([path, "derived map does not reproduce the fork's file"]);
    continue;
  }

  const { out, unmapped } = apply(theirs, map);
  const undecidable = [...unmapped].filter(
    (token) => ambiguousTokens.has(token) || !forkStillUses(token),
  );
  if (undecidable.length > 0) {
    skipped.push([path, `upstream brand tokens the fork cannot decide: ${undecidable.join(", ")}`]);
    continue;
  }

  writeFileSync(path, out);
  git(["add", "--", path]);
  resolved.push(path);
  for (const [from, to] of map) if (from !== to) substitutions.set(from, to);
}

for (const path of resolved) console.log(`resolved  ${path}`);
for (const path of deleted) console.log(`deleted   ${path}  (upstream removed it; fork had only renames)`);
for (const [path, reason] of skipped) console.log(`SKIPPED   ${path}  -- ${reason}`);

if (substitutions.size > 0) {
  console.log("\nRenames applied to upstream code:");
  for (const [from, to] of [...substitutions].sort()) console.log(`  ${from} -> ${to}`);
}

console.log(
  `\n${resolved.length} resolved, ${deleted.length} deleted, ${skipped.length} left conflicted.`,
);
process.exit(skipped.length === 0 ? 0 : 1);
