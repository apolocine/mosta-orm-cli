#!/usr/bin/env node
// fix-mongo-id.mjs — codemod : repair Mongo-era residue left in app code after a
// project migrates from Mongoose to @mostajs/orm (data-plug). The ORM normalizer
// maps `_id`→`id` and ids are plain STRINGS for every dialect (mongo included),
// so two classes of stale code must be repaired :
//
//   1. Identifier reads   `obj._id`              → `obj.id`
//   2. ObjectId wrapping   `new ObjectId(x)`      → `x`
//                          `mongoose.Types.ObjectId(x)` → `x`
//
// @author Dr Hamid MADANI <drmdh@msn.com>
// License: AGPL-3.0-or-later
//
// Usage (invoked by bin/mostajs.sh as `mostajs fix-ids`) :
//
//   node fix-mongo-id.mjs                 # dry-run (default, safe — lists sites)
//   node fix-mongo-id.mjs --apply         # rewrite files (+ .mongoid.bak backups)
//   node fix-mongo-id.mjs --file X         # restrict to a single file
//   node fix-mongo-id.mjs --project P      # root to scan (default: cwd)
//   node fix-mongo-id.mjs --map old:new    # extra member rename (repeatable)
//   node fix-mongo-id.mjs --no-objectid    # skip ObjectId() unwrapping
//   node fix-mongo-id.mjs --include-mongoose  # also touch files importing mongoose
//   node fix-mongo-id.mjs --restore        # restore from .mongoid.bak backups
//
// Conservative by design :
//   - Member rename touches ACCESS only : `.​_id`, `?._id`, `['_id']`, `["_id"]`.
//     A bare `_id:` object *key* (a Mongoose schema declaration) is left intact.
//   - ObjectId unwrap removes the constructor wrapper but KEEPS the inner
//     expression : `new ObjectId(req.params.id)` → `req.params.id`.
//     `ObjectId.isValid(...)` and `import { ObjectId }` lines are NOT rewritten
//     (semantics differ) — they are reported for manual review.
//   - Files importing `mongoose` (likely real Mongo models) are skipped + reported.
//   - Original file is saved as <path>.mongoid.bak. Re-runs are idempotent.

import { readFileSync, writeFileSync, readdirSync, statSync, existsSync, renameSync, copyFileSync } from 'node:fs';
import { join, resolve, relative, extname } from 'node:path';

// ---------- CLI ----------
const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const val  = (name) => { const i = argv.indexOf(`--${name}`); return i >= 0 ? argv[i + 1] : null; };
const vals = (name) => argv.reduce((acc, a, i) => (a === `--${name}` && argv[i + 1] ? [...acc, argv[i + 1]] : acc), []);

const APPLY            = flag('apply');
const RESTORE          = flag('restore');
const ONE_FILE         = val('file');
const ROOT             = resolve(val('project') ?? process.cwd());
const QUIET            = flag('quiet');
const INCLUDE_MONGOOSE = flag('include-mongoose');
const NO_OBJECTID      = flag('no-objectid');

const log = (...a) => { if (!QUIET) console.log(...a); };
const c   = { cyan: s => `\x1b[36m${s}\x1b[0m`, yellow: s => `\x1b[33m${s}\x1b[0m`, green: s => `\x1b[32m${s}\x1b[0m`, red: s => `\x1b[31m${s}\x1b[0m`, bold: s => `\x1b[1m${s}\x1b[0m`, dim: s => `\x1b[2m${s}\x1b[0m` };

// ---------- Rename map (member access) ----------
const renameMap = new Map([['_id', 'id']]);
for (const m of vals('map')) {
  const [from, to] = m.split(':');
  if (!from || !to) { console.error(c.red(`Bad --map "${m}" — expected old:new`)); process.exit(1); }
  renameMap.set(from, to);
}
const RISKY = [...renameMap.keys()].filter((k) => /^[a-z][a-zA-Z]*$/.test(k) && k.length <= 6 && k !== 'id');

// ---------- Walk ----------
const SKIP_DIRS = new Set(['node_modules', '.next', '.svelte-kit', 'dist', 'build', '.turbo', '.vercel', '.cache', 'coverage', '.git', '.vscode', '.idea']);
const EXTENSIONS = new Set(['.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs', '.vue', '.svelte']);
const BAK = '.mongoid.bak';

function* walk(dir) {
  let entries;
  try { entries = readdirSync(dir); } catch { return; }
  for (const name of entries) {
    if (SKIP_DIRS.has(name)) continue;
    const p = join(dir, name);
    let st;
    try { st = statSync(p); } catch { continue; }
    if (st.isDirectory()) yield* walk(p);
    else if (EXTENSIONS.has(extname(name)) || name.endsWith(BAK)) yield p;
  }
}

// ---------- Member access rename ( ._id → .id ) ----------
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function memberPatterns(from, to) {
  const f = escape(from);
  return [
    { re: new RegExp(`(\\??\\.)${f}\\b`, 'g'), build: (g1) => `${g1}${to}` },           // .foo / ?.foo
    { re: new RegExp(`\\[(['"])${f}\\1\\]`, 'g'), build: (q) => `[${q}${to}${q}]` },     // ['foo'] / ["foo"]
  ];
}

function renameMembers(src) {
  let out = src, count = 0;
  for (const [from, to] of renameMap) {
    for (const { re, build } of memberPatterns(from, to)) {
      out = out.replace(re, (_m, g1) => { count++; return build(g1); });
    }
  }
  return { out, count };
}

// ---------- ObjectId unwrap ( new ObjectId(x) → x ) ----------
// Matches the constructor head, with or without `new`, and the mongoose paths
// `mongoose.Types.ObjectId(` / `Types.ObjectId(`. NOT `ObjectId.isValid(` (the
// `.isValid` sits between `ObjectId` and `(`, so the head regex can't match it).
const RX_OBJID_CTOR_HEAD = /(?:new\s+)?(?:mongoose\.)?(?:Types\.)?ObjectId\s*\(/g;

function unwrapObjectId(src) {
  if (NO_OBJECTID) return { out: src, count: 0 };
  let out = '', last = 0, count = 0;
  const re = new RegExp(RX_OBJID_CTOR_HEAD.source, 'g');
  let m;
  while ((m = re.exec(src)) !== null) {
    const open = m.index + m[0].length - 1;   // index of the '('
    let depth = 1, j = open + 1;
    for (; j < src.length && depth > 0; j++) {
      const ch = src[j];
      if (ch === '(') depth++;
      else if (ch === ')') depth--;
    }
    if (depth !== 0) continue;                 // unbalanced — leave as-is
    const close = j - 1;
    const inner = src.slice(open + 1, close).trim();
    out += src.slice(last, m.index) + inner;
    last = close + 1;
    count++;
    re.lastIndex = last;
  }
  out += src.slice(last);
  return { out, count };
}

// ---------- Per-file analysis ----------
const RX_MONGOOSE      = /\b(?:from\s+['"]mongoose['"]|require\(\s*['"]mongoose['"]\s*\)|new\s+(?:mongoose\.)?Schema\s*\()/;
const RX_OBJID_ISVALID = /\bObjectId\.isValid\s*\(/;
const RX_OBJID_IMPORT  = /\bimport\b[^;\n]*\bObjectId\b[^;\n]*\bfrom\b[^;\n]*['"](?:mongodb|bson|mongoose)['"]/;

function analyze(src, rel) {
  const r1 = renameMembers(src);
  const r2 = unwrapObjectId(r1.out);
  const idCount = r1.count, objCount = r2.count;
  // Manual-review notes (reported, never auto-edited).
  const manual = [];
  src.split('\n').forEach((line, i) => {
    if (RX_OBJID_ISVALID.test(line)) manual.push({ ln: i + 1, text: line.trim().slice(0, 100), why: 'ObjectId.isValid — replace with a string check' });
    if (RX_OBJID_IMPORT.test(line))  manual.push({ ln: i + 1, text: line.trim().slice(0, 100), why: 'ObjectId import — likely unused after unwrap, remove' });
  });
  // Sample hit lines (from the ORIGINAL source) for the report.
  const hitLines = [];
  src.split('\n').forEach((line, i) => {
    let hit = false;
    for (const [from, to] of renameMap) for (const { re } of memberPatterns(from, to)) { re.lastIndex = 0; if (re.test(line)) hit = true; }
    if (!NO_OBJECTID && RX_OBJID_CTOR_HEAD.test(line) && !RX_OBJID_ISVALID.test(line)) hit = true;
    if (hit) hitLines.push({ ln: i + 1, text: line.trim().slice(0, 100) });
  });
  return { rel, rewritten: r2.out, idCount, objCount, manual, hitLines };
}

// ---------- Restore ----------
function restoreBackups() {
  const restored = [];
  for (const p of walk(ROOT)) {
    if (!p.endsWith(BAK)) continue;
    const original = p.slice(0, -BAK.length);
    const rel = relative(ROOT, original);
    if (APPLY) { renameSync(p, original); log(`  ${c.green('✓')} restored ${c.dim(rel)}`); }
    else        { log(`  ${c.yellow('•')} would restore ${c.dim(rel)}`); }
    restored.push(original);
  }
  return restored;
}

// ---------- Main ----------
if (RESTORE) {
  log(c.bold('▶ Restoring .mongoid.bak files' + (APPLY ? '' : c.yellow(' (dry-run, use --apply)'))));
  const r = restoreBackups();
  log(`\n${r.length} file(s) ${APPLY ? 'restored' : 'would be restored'}`);
  process.exit(0);
}

log(c.bold(`▶ mostajs fix-ids — scanning ${c.cyan(ROOT)}`));
log(c.dim(`  member renames : ${[...renameMap].map(([f, t]) => `${f}→${t}`).join('  ')}`));
log(c.dim(`  ObjectId unwrap : ${NO_OBJECTID ? 'disabled (--no-objectid)' : 'new ObjectId(x) → x'}`));
if (RISKY.length) log(c.yellow(`  ⚠ blunt member rename(s): ${RISKY.join(', ')} — renames EVERY occurrence; review the dry-run.`));
log('');

const candidates = [];
const manualOnly = [];
const skippedMongoose = [];
const iter = ONE_FILE ? [resolve(ROOT, ONE_FILE)] : walk(ROOT);
for (const p of iter) {
  if (p.endsWith(BAK)) continue;
  let src;
  try { src = readFileSync(p, 'utf8'); } catch { continue; }
  const rel = relative(ROOT, p);
  const a = analyze(src, rel);
  if (a.idCount === 0 && a.objCount === 0 && a.manual.length === 0) continue;
  if (RX_MONGOOSE.test(src) && !INCLUDE_MONGOOSE) { skippedMongoose.push(rel); continue; }
  if (a.idCount === 0 && a.objCount === 0) { manualOnly.push({ path: p, ...a }); continue; }
  candidates.push({ path: p, src, ...a });
}

const totalId  = candidates.reduce((n, ca) => n + ca.idCount, 0);
const totalObj = candidates.reduce((n, ca) => n + ca.objCount, 0);

if (candidates.length === 0 && manualOnly.length === 0) {
  log(c.green('  Nothing to fix.'));
  if (skippedMongoose.length) { log(''); log(c.yellow(`  ${skippedMongoose.length} mongoose file(s) skipped (use --include-mongoose):`)); for (const r of skippedMongoose) log(c.dim(`    • ${r}`)); }
  process.exit(0);
}

if (candidates.length) {
  log(c.bold(`Found ${totalId} stale id read(s) + ${totalObj} ObjectId wrap(s) in ${candidates.length} file(s):`));
  for (const ca of candidates) {
    log(`  ${c.green('→')} ${ca.rel}  ${c.dim(`(_id:${ca.idCount}  ObjectId:${ca.objCount})`)}`);
    for (const h of ca.hitLines.slice(0, 6)) log(c.dim(`      ${h.ln}: ${h.text}`));
    if (ca.hitLines.length > 6) log(c.dim(`      … +${ca.hitLines.length - 6} more`));
  }
  log('');
}

// Manual-review notes (across all files that have them).
const allManual = [...candidates, ...manualOnly].filter((f) => f.manual.length);
if (allManual.length) {
  log(c.yellow('Manual review (NOT auto-rewritten):'));
  for (const f of allManual) for (const mn of f.manual) log(c.dim(`    ${f.rel}:${mn.ln}  ${c.yellow(mn.why)}\n      ${mn.text}`));
  log('');
}

if (skippedMongoose.length) {
  log(c.yellow(`${skippedMongoose.length} mongoose file(s) skipped (real Mongo models keep _id):`));
  for (const r of skippedMongoose) log(c.dim(`    • ${r}`));
  log(c.dim('  Force with --include-mongoose if these are actually data-plug call-sites.'));
  log('');
}

if (!APPLY) {
  log(c.yellow('Dry-run — no files written. Re-run with --apply to execute.'));
  process.exit(0);
}

if (candidates.length === 0) { log(c.green('Nothing to auto-rewrite (manual items only).')); process.exit(0); }

// ---------- Apply ----------
log(c.bold('Applying rewrites :'));
for (const ca of candidates) {
  const bak = ca.path + BAK;
  if (!existsSync(bak)) copyFileSync(ca.path, bak);
  writeFileSync(ca.path, ca.rewritten);
  log(`  ${c.green('✓')} fixed ${ca.rel}  ${c.dim(`(backup: ${relative(ROOT, bak)})`)}`);
}

log('');
log(c.bold(c.green(`✓ Repaired ${totalId} id read(s) + ${totalObj} ObjectId wrap(s) in ${candidates.length} file(s).`)));
if (allManual.length) log(c.yellow(`  ${allManual.reduce((n, f) => n + f.manual.length, 0)} manual item(s) still need review (see above).`));
log('');
log(`Review the diff, then rebuild your front/app.`);
log(`To undo all : ${c.cyan('mostajs fix-ids --restore --apply')}`);
