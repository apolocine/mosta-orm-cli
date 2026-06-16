#!/usr/bin/env node
// validate.mjs — run @mostajs/orm's ORMConceptValidator over the entities the CLI
// generated (`.mostajs/generated/entities.json`). Thin wrapper around the
// published validator API (validateSchemas + reporters), so a migrated Mongo (or
// any) project can be linted for schema anti-patterns (R001–R021).
//
// @author Dr Hamid MADANI <drmdh@msn.com>
// License: AGPL-3.0-or-later
//
// Usage (invoked by bin/mostajs.sh as `mostajs validate`) :
//
//   node validate.mjs                          # text report on entities.json
//   node validate.mjs --entities path.json      # explicit entities file
//   node validate.mjs --src ./src               # enable cross-file rules (R005…)
//   node validate.mjs --format markdown --out report.md
//   node validate.mjs --ignore R015,R017
//   node validate.mjs --ci --max-warnings 0     # exit 1 if findings ≥ threshold

import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
const argv = process.argv.slice(2);
const flag = (n) => argv.includes(`--${n}`);
const val  = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : d; };

const ROOT      = resolve(val('project', process.cwd()));
const ENTITIES  = resolve(val('entities', `${ROOT}/.mostajs/generated/entities.json`));
const SRC       = val('src') ? resolve(val('src')) : undefined;
let   FORMAT    = val('format', 'text'); if (FORMAT === 'md') FORMAT = 'markdown';
const OUT       = val('out') ? resolve(val('out')) : undefined;
const IGNORE    = (val('ignore', '') || '').split(',').map((s) => s.trim()).filter(Boolean);
const CI        = flag('ci');
const MAXW      = Number(val('max-warnings', '0')) || 0;

const c = { red: s => `\x1b[31m${s}\x1b[0m`, yellow: s => `\x1b[33m${s}\x1b[0m`, green: s => `\x1b[32m${s}\x1b[0m`, cyan: s => `\x1b[36m${s}\x1b[0m`, bold: s => `\x1b[1m${s}\x1b[0m`, dim: s => `\x1b[2m${s}\x1b[0m` };

// ── Load entities.json (array of EntitySchema, as produced by convert / introspect) ──
let schemas;
try {
  const raw = JSON.parse(readFileSync(ENTITIES, 'utf8'));
  schemas = Array.isArray(raw) ? raw : (Array.isArray(raw.entities) ? raw.entities : null);
  if (!schemas) throw new Error('not an EntitySchema[] (nor { entities: [...] })');
} catch (e) {
  console.error(c.red(`✗ Cannot read entities : ${ENTITIES}`));
  console.error(c.dim(`  ${e.message}`));
  console.error(`  Generate it first : ${c.cyan('mostajs convert')}  or  ${c.cyan('mostajs mongo-introspect')}`);
  process.exit(2);
}

// ── Resolve the validator from the project first, then the CLI's own deps ──
let validator;
const cliDir = resolve(new URL('..', import.meta.url).pathname);
for (const base of [ROOT, cliDir]) {
  try {
    const p = require.resolve('@mostajs/orm/validator', { paths: [base] });
    validator = await import(pathToFileURL(p).href);
    break;
  } catch { /* try next */ }
}
// Final fallback : bare specifier resolves against the CLI's own node_modules.
if (!validator) {
  try { validator = await import('@mostajs/orm/validator'); } catch { /* give up below */ }
}
if (!validator) {
  console.error(c.red('✗ @mostajs/orm (validator) not found in project or CLI.'));
  console.error(`  Install it : ${c.cyan('npm i @mostajs/orm')}`);
  process.exit(2);
}

const { validateSchemas, formatText, formatJson, formatMarkdown } = validator;

// ── Run ──
const report = await validateSchemas(schemas, { sourceRoot: SRC, ignore: IGNORE });

const rendered = FORMAT === 'json' ? formatJson(report, true)
  : FORMAT === 'markdown' ? formatMarkdown(report)
    : formatText(report, { verbose: flag('verbose') });

if (OUT) { writeFileSync(OUT, rendered); console.error(c.green(`✓ Report written : ${OUT}`)); }
else { console.log(rendered); }

// ── Summary line + CI gate ──
const sev = report.countBySeverity || {};
const warnOrWorse = (sev.error || 0) + (sev.warning || 0);
console.error(
  `\n${c.bold('Validate')} : ${report.schemaCount} schema(s) · ` +
  `${c.red((sev.error || 0) + ' error')} · ${c.yellow((sev.warning || 0) + ' warning')} · ` +
  `${c.dim((sev.info || 0) + ' info')}  ${c.dim(`(${report.durationMs}ms)`)}`,
);

if (CI && warnOrWorse > MAXW) {
  console.error(c.red(`✗ CI gate : ${warnOrWorse} finding(s) ≥ max-warnings (${MAXW})`));
  process.exit(1);
}
process.exit(0);
