#!/usr/bin/env node
// mongo-introspect.mjs — reverse-engineer a LIVE MongoDB into EntitySchema[].
// The "migrer" half of the Mongo → @mostajs/orm story : connect to the database,
// sample documents per collection, infer field types, and emit the same
// `.mostajs/generated/entities.json` that `mostajs convert` produces — so a Mongo
// project with no Prisma/OpenAPI schema can still adopt data-plug.
//
// The ORM normalizes `_id`→`id` (string) for every dialect, so `_id`/`__v` are
// dropped here and ObjectId-typed fields are emitted as `string`.
//
// @author Dr Hamid MADANI <drmdh@msn.com>
// License: AGPL-3.0-or-later
//
// Usage (invoked by bin/mostajs.sh as `mostajs mongo-introspect`) :
//
//   node mongo-introspect.mjs --uri mongodb://user:pw@host:27017/db?authSource=admin
//   node mongo-introspect.mjs --sample 500 --out .mostajs/generated/entities.json
//   (falls back to $SGBD_URI / $DB_DIALECT from the environment / .mostajs config)

import { writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
const argv = process.argv.slice(2);
const val  = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : d; };
const flag = (n) => argv.includes(`--${n}`);

const ROOT    = resolve(val('project', process.cwd()));
const URI     = val('uri', process.env.SGBD_URI || '');
const SAMPLE  = Math.max(1, Number(val('sample', '200')) || 200);
const OUT     = resolve(val('out', `${ROOT}/.mostajs/generated/entities.json`));
const QUIET   = flag('quiet');
const VERSION = '0.7.0';

const c = { red: s => `\x1b[31m${s}\x1b[0m`, yellow: s => `\x1b[33m${s}\x1b[0m`, green: s => `\x1b[32m${s}\x1b[0m`, cyan: s => `\x1b[36m${s}\x1b[0m`, bold: s => `\x1b[1m${s}\x1b[0m`, dim: s => `\x1b[2m${s}\x1b[0m` };
const log = (...a) => { if (!QUIET) console.log(...a); };

if (!URI) {
  console.error(c.red('✗ No MongoDB URI. Pass --uri or set SGBD_URI (menu 2 → import).'));
  process.exit(2);
}

// ── Resolve mongoose from the project (the mongo driver @mostajs/orm uses) ──
let mongoose;
const cliDir = resolve(new URL('..', import.meta.url).pathname);
for (const base of [ROOT, cliDir, process.cwd()]) {
  try { mongoose = (await import(pathToFileURL(require.resolve('mongoose', { paths: [base] })).href)).default; break; }
  catch { /* next */ }
}
if (!mongoose) {
  console.error(c.red('✗ mongoose not installed in the project.'));
  console.error(`  Install it : ${c.cyan('npm i mongoose')}   (it is the driver @mostajs/orm uses for MongoDB)`);
  process.exit(2);
}

// ── Type inference ─────────────────────────────────────────────────────────
function isObjectId(v) {
  return v && typeof v === 'object' &&
    (v._bsontype === 'ObjectID' || v._bsontype === 'ObjectId' ||
     (v.constructor && v.constructor.name === 'ObjectId'));
}
function scalarType(v) {
  if (v === null || v === undefined) return null;
  if (typeof v === 'string') return 'string';
  if (typeof v === 'number') return 'number';
  if (typeof v === 'boolean') return 'boolean';
  if (v instanceof Date) return 'date';
  if (isObjectId(v)) return 'string';          // normalized to string id
  if (Array.isArray(v)) return 'array';
  if (typeof v === 'object') return 'json';
  return 'string';
}
// Reconcile a set of observed types into a single FieldType.
function reconcile(types) {
  const s = new Set([...types].filter(Boolean));
  if (s.size === 0) return 'string';
  if (s.size === 1) return [...s][0];
  if (s.has('json') || s.has('array')) return 'json';
  if (s.has('string')) return 'string';        // string + number → string
  return 'json';
}

function pascal(s) {
  return s.replace(/[_\-.\s]+/g, ' ').trim()
    .replace(/\s+(.)/g, (_, ch) => ch.toUpperCase())
    .replace(/^(.)/, (_, ch) => ch.toUpperCase());
}
function singular(n) {
  // Don't mangle words that merely END in 's' but aren't plurals
  // (Status, Address, Analysis, Series, OS…). Naive de-pluralization otherwise.
  if (/(ss|us|is|os| news|series|species)$/i.test(n)) return n;
  if (/ies$/i.test(n)) return n.slice(0, -3) + 'y';
  if (/(ches|shes|xes|zes|ses)$/i.test(n)) return n.slice(0, -2);
  if (/s$/i.test(n)) return n.slice(0, -1);
  return n;
}

// ── Main ───────────────────────────────────────────────────────────────────
log(c.bold(`▶ mostajs mongo-introspect — ${c.cyan(URI.replace(/\/\/[^@]*@/, '//***@'))}`));
log(c.dim(`  sampling up to ${SAMPLE} doc(s) per collection`));
log('');

await mongoose.connect(URI, { serverSelectionTimeoutMS: 8000 });
const db = mongoose.connection.db;
const collInfos = (await db.listCollections().toArray())
  .filter((ci) => ci.type !== 'view' && !ci.name.startsWith('system.'));

const entities = [];
for (const ci of collInfos) {
  const name = ci.name;
  const docs = await db.collection(name).find({}).limit(SAMPLE).toArray();
  if (docs.length === 0) {
    log(`  ${c.yellow('○')} ${name}  ${c.dim('(empty — skipped)')}`);
    continue;
  }
  // Aggregate field stats.
  const stat = new Map();   // field → { present, nulls, types:Set, elemTypes:Set }
  for (const doc of docs) {
    for (const [k, v] of Object.entries(doc)) {
      if (k === '_id' || k === '__v') continue;
      const st = stat.get(k) ?? { present: 0, nulls: 0, types: new Set(), elem: new Set() };
      st.present++;
      if (v === null || v === undefined) st.nulls++;
      st.types.add(scalarType(v));
      if (Array.isArray(v) && v.length) st.elem.add(scalarType(v[0]));
      stat.set(k, st);
    }
  }

  const fields = {};
  let hasCreated = false, hasUpdated = false;
  for (const [k, st] of stat) {
    const type = reconcile(st.types);
    if (k === 'createdAt' && type === 'date') { hasCreated = true; continue; }
    if (k === 'updatedAt' && type === 'date') { hasUpdated = true; continue; }
    const def = { type };
    if (st.present === docs.length && st.nulls === 0) def.required = true;
    if (type === 'array') { const e = reconcile(st.elem); if (e) def.arrayOf = e; }
    fields[k] = def;
  }

  // Real indexes → IndexDef (skip the default _id_ index).
  const indexes = [];
  try {
    for (const ix of await db.collection(name).indexes()) {
      if (ix.name === '_id_' || !ix.key) continue;
      const f = {};
      for (const [col, dir] of Object.entries(ix.key)) {
        if (col === '_id') continue;
        f[col] = dir === -1 ? 'desc' : (dir === 1 ? 'asc' : 'asc');
      }
      if (Object.keys(f).length) indexes.push({ fields: f, ...(ix.unique ? { unique: true } : {}) });
    }
  } catch { /* indexes() can fail on some deployments — non-fatal */ }

  entities.push({
    name: pascal(singular(name)),
    collection: name,
    fields,
    relations: {},
    indexes,
    timestamps: hasCreated && hasUpdated,
  });
  log(`  ${c.green('✓')} ${name} → ${c.bold(pascal(singular(name)))}  ${c.dim(`(${Object.keys(fields).length} fields, ${indexes.length} index, ${docs.length} sampled)`)}`);
}

await mongoose.disconnect();

if (entities.length === 0) {
  console.error(c.yellow('\n  No non-empty collections found — nothing written.'));
  process.exit(0);
}

// ── Write entities.json (+ .ts, same layout as `mostajs convert`) ──
mkdirSync(dirname(OUT), { recursive: true });
const jsonFile = OUT.endsWith('.json') ? OUT : OUT.replace(/\.ts$/, '.json');
const tsFile = jsonFile.replace(/\.json$/, '.ts');
writeFileSync(jsonFile, JSON.stringify(entities, null, 2));
const header = `// Auto-generated by @mostajs/orm-cli mongo-introspect v${VERSION}\n` +
  `// Source : live MongoDB (sampled ${SAMPLE} docs/collection)\n` +
  `// DO NOT EDIT BY HAND — regenerate with: mostajs mongo-introspect\n\n` +
  `import type { EntitySchema } from "@mostajs/orm";\n\n` +
  `export const entities: EntitySchema[] = ${JSON.stringify(entities, null, 2)};\n\n` +
  `export const entityByName: Record<string, EntitySchema> = Object.fromEntries(\n` +
  `  entities.map(e => [e.name, e])\n);\n`;
writeFileSync(tsFile, header);

log('');
log(c.bold(c.green(`✓ ${entities.length} entit(y/ies) → ${jsonFile}`)));
log('');
log('Next :');
log(`  1. ${c.cyan('mostajs validate')}                 # lint the inferred schema`);
log(`  2. ${c.cyan('mostajs fix-ids --apply')}           # repair app code (_id / ObjectId)`);
log(`  3. ${c.cyan('mostajs')} → menu 3                  # init dialects / DDL on the target DB`);
