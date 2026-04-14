# Changelog

All notable changes to `@mostajs/orm-cli` will be documented in this file.

## [0.4.1] — 2026-04-14

### Fixed — `mostajs bootstrap` reliability

- **Hard stop-on-error** : each step now verifies its outcome and aborts
  with an actionable message instead of silently continuing. Previous
  behaviour printed a success banner even when convert/DDL had failed.
- **Install `@mostajs/orm-adapter`** alongside `@mostajs/orm` / `-bridge` /
  `server-only` in step 2. Without the adapter, step 3 (schema conversion)
  was failing silently on a fresh project. Root cause : 0.4.0 only
  installed the runtime packages, not the build-time adapter.
- **Visible npm output** : step 2 no longer pipes through `tail -3`. Users
  can see the installer progress, which matters on slow networks.
- **Reload config.env** : after writing the default config, reload env
  vars so `action_init_dialects` sees `DB_DIALECT=sqlite` + `SGBD_URI`.

## [0.4.0] — 2026-04-14

### Added — the automated migration release

- **`mostajs install-bridge`** : codemod that scans a Prisma project, finds
  every `new PrismaClient(...)` instantiation site, and rewrites each file
  to use `createPrismaLikeDb()` from `@mostajs/orm-bridge`. Preserves the
  original export name (`prisma`, `db`, `client`, `default`), so none of
  the call-sites elsewhere in the codebase have to change.

  Dry-run by default. Flags :
  - `--apply`             actually write files
  - `--file <path>`       restrict to a single file
  - `--project <root>`    override working directory
  - `--restore --apply`   revert .prisma.bak backups

  Example :
  ```
  $ mostajs install-bridge
  ▶ mostajs install-bridge — scanning /home/me/my-app
  Found 3 PrismaClient instantiation site(s):
    → src/lib/db.ts         (const db)
    → src/server/prisma.ts  (const prisma)
    → scripts/seed.ts       (const prisma)
  Dry-run — no files written. Re-run with --apply to execute.

  $ mostajs install-bridge --apply
  ✓ rewrote src/lib/db.ts  (backup: src/lib/db.ts.prisma.bak)
  ✓ rewrote src/server/prisma.ts  (backup: …)
  ✓ rewrote scripts/seed.ts  (backup: …)
  ```

- **`mostajs bootstrap`** : one-shot full migration for a Prisma project.
  Runs the codemod, installs runtime deps, converts `schema.prisma` to
  `entities.json`, writes `.mostajs/config.env`, and applies DDL. Zero
  manual file edits required after this point.

  ```
  $ cd my-prisma-app
  $ npx @mostajs/orm-cli bootstrap
  ▶ Step 1/4 : rewrite PrismaClient sites
    ✓ rewrote src/lib/db.ts (backup: src/lib/db.ts.prisma.bak)
  ▶ Step 2/4 : install runtime deps
    added 42 packages in 3s
  ▶ Step 3/4 : convert schema + init DDL
    ✓ 18 entities extracted
    ✓ 18 tables created in ./data.sqlite
  ▶ Step 4/4 : done
  ```

- **Interactive menu entries** : `b` (Bootstrap) and `i` (Install bridge)
  for users who prefer the menu flow.

### Why this matters

Before 0.4.0, migrating a Prisma project required hand-editing every
`db.ts`-style file. For a project like FitZoneGym (15 instantiation
sites across `src/` and `scripts/`), that was 15 error-prone edits.
With `install-bridge`, the same migration takes one command and is
reversible with `--restore --apply`.

## [0.3.2] and earlier

See git history. Covers the interactive menu, Prisma/OpenAPI/JSON Schema
conversion, seeding pipeline (hash + validate + apply), health checks,
subcommands `convert`, `hash`, `verify`, `diagnose`, `health`, `detect`.
