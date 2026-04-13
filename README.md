# @mostajs/orm-cli

> **Universal interactive CLI for @mostajs/orm integration.**
> Auto-detects Prisma / OpenAPI / JSON Schema in any project, converts to EntitySchema[], tests with humans / mobiles / AI agents, and launches everything.

[![npm version](https://img.shields.io/npm/v/@mostajs/orm-cli.svg)](https://www.npmjs.com/package/@mostajs/orm-cli)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL%203.0-blue.svg)](LICENSE)

## Install

### Option 1 — npx (zero install)

```bash
cd your/project
npx @mostajs/orm-cli
```

### Option 2 — global

```bash
npm install -g @mostajs/orm-cli
cd your/project
mostajs
```

### Option 3 — curl one-liner (Unix)

```bash
curl -fsSL https://raw.githubusercontent.com/apolocine/mosta-orm-cli/main/install.sh | bash
```

## Usage

### Interactive menu (recommended)

```bash
cd your/project
mostajs
```

The CLI auto-detects :
- **Prisma** : `prisma/schema.prisma`
- **OpenAPI** : `openapi.yaml`, `openapi.json`, `api.yaml`, `spec/openapi.yaml`, etc.
- **JSON Schema** : `schemas/*.json`

Menu :

```
1) Convert schema → EntitySchema[]
2) Configure database URIs     (13 databases)
3) Initialize dialects         (connect + create tables)
4) Tests menu                  (human / mobile / AI / curl / playwright)
5) Start services              (Next.js + mosta-net)
6) Metrics & status
7) View logs
8) Health checks
9) Generate boilerplate        (src/db.ts / .env.example)
0) About / Help
```

### Non-interactive subcommands

```bash
mostajs convert    # auto-detect + convert
mostajs detect     # print detected schemas
mostajs health     # check tools + project state
mostajs version
mostajs help
```

## What it does

### Tests menu — everything you need to verify

- **Human** : opens browser on `http://localhost:3000`
- **Mobile** : generates QR code for LAN URL (needs `qrencode`)
- **AI** : displays ready-to-paste Claude Desktop MCP config
- **curl** : smoke-tests all endpoints with status codes + times
- **Playwright** : runs existing test suite

### Config stored per-project

```
your-project/.mostajs/
├── config.env              # URIs + ports
├── generated/entities.ts   # EntitySchema[] (auto-generated)
└── logs/                   # dev / convert / init logs
```

### Supported databases (13)

PostgreSQL · MySQL · MariaDB · SQLite · MS SQL Server · Oracle · DB2 · HANA · HSQLDB · Spanner · Sybase · CockroachDB · MongoDB

## Example workflow (any Prisma app)

```bash
$ cd my-nextjs-app
$ mostajs

  Project : /path/to/my-nextjs-app
  Manager : pnpm
  Detected:
    ✓ Prisma schema (40 models)
    ⚠ entities.ts not generated

  Choice [1]: 1                     # Convert
  entities : 40
  warnings : 0
  ✓ Saved : .mostajs/generated/entities.ts

  Choice [1]: 9                     # Generate boilerplate
  ✓ Written : src/db.ts (Prisma bridge)

  # now replace `new PrismaClient()` with `import { prisma } from './db.js'`
  # ... your existing Prisma code runs on 13 databases
```

## Strategy

- **Schema conversion** : via [@mostajs/orm-adapter](https://www.npmjs.com/package/@mostajs/orm-adapter) — 4 adapters (Prisma, JSON Schema, OpenAPI, Native)
- **Runtime interception** : via [@mostajs/orm-bridge](https://www.npmjs.com/package/@mostajs/orm-bridge) — route Prisma calls to any of the 13 databases
- **Zero rewrite** : your existing `prisma.user.findMany()` stays unchanged

## Links

- npm : https://www.npmjs.com/package/@mostajs/orm-cli
- GitHub : https://github.com/apolocine/mosta-orm-cli
- Ecosystem : [@mostajs/orm](https://www.npmjs.com/package/@mostajs/orm), [@mostajs/orm-adapter](https://www.npmjs.com/package/@mostajs/orm-adapter), [@mostajs/orm-bridge](https://www.npmjs.com/package/@mostajs/orm-bridge)

## License

**AGPL-3.0-or-later** + commercial license available.

For commercial use in closed-source projects : drmdh@msn.com

## Author

Dr Hamid MADANI <drmdh@msn.com>
