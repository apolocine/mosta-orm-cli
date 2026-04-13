#!/usr/bin/env bash
# mostajs.sh — Universal interactive CLI for @mostajs/orm integration
# Works in any project directory : auto-detects Prisma, OpenAPI, JSON Schema
# Author: Dr Hamid MADANI drmdh@msn.com
# License: AGPL-3.0-or-later
#
# Install globally :
#   curl -fsSL https://raw.githubusercontent.com/apolocine/mosta-orm-cli/main/bin/mostajs.sh -o /usr/local/bin/mostajs
#   chmod +x /usr/local/bin/mostajs
#
# Or run directly :
#   bash <(curl -fsSL https://raw.githubusercontent.com/apolocine/mosta-orm-cli/main/bin/mostajs.sh)
#
# Or via npx :
#   npx @mostajs/orm-cli

set -uo pipefail

# ============================================================
# META
# ============================================================

VERSION="0.1.0"
CLI_NAME="mostajs"

# ============================================================
# PATHS — relative to the CALLER's CWD, not the script
# ============================================================

PROJECT_ROOT="$(pwd)"
CONFIG_DIR="$PROJECT_ROOT/.mostajs"
CONFIG_FILE="$CONFIG_DIR/config.env"
LOG_DIR="$CONFIG_DIR/logs"
GENERATED_DIR="$CONFIG_DIR/generated"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$GENERATED_DIR" 2>/dev/null

# ============================================================
# COLORS
# ============================================================

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
  BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

ok()    { echo -e "  ${GREEN}✓${RESET} $*"; }
info()  { echo -e "  ${CYAN}ℹ${RESET} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET} $*"; }
err()   { echo -e "  ${RED}✗${RESET} $*"; }
dim()   { echo -e "  ${DIM}$*${RESET}"; }

# ============================================================
# ERROR HANDLING + AUTO-INSTALL
# ============================================================

# Run a node command with clean error reporting.
# Usage: run_node <script_path> [env=val ...]
run_node() {
  local script="$1"; shift
  local envvars=("$@")
  local rc=0
  if [[ ${#envvars[@]} -gt 0 ]]; then
    env "${envvars[@]}" node "$script" 2>&1
  else
    node "$script" 2>&1
  fi
  rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]]; then
    err "Script failed (exit $rc)"
    return $rc
  fi
  return 0
}

# Check if a package is installed locally; if not, offer to install it.
# Usage: ensure_pkg <package-name> [<additional-pkg> ...]
ensure_pkg() {
  local pkgs=("$@")
  local missing=()
  for pkg in "${pkgs[@]}"; do
    # Try to resolve via node's require resolution (works for any layout)
    if ! node -e "require.resolve('$pkg')" >/dev/null 2>&1; then
      # Also check if there's a node_modules with it
      if [[ ! -d "$PROJECT_ROOT/node_modules/$pkg" ]]; then
        missing+=("$pkg")
      fi
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  warn "Missing package(s): ${missing[*]}"
  if confirm "Install now with $PKG_MANAGER?"; then
    cd "$PROJECT_ROOT" || return 1
    case "$PKG_MANAGER" in
      pnpm) pnpm add "${missing[@]}" 2>&1 | tail -5 ;;
      yarn) yarn add "${missing[@]}" 2>&1 | tail -5 ;;
      bun)  bun add "${missing[@]}" 2>&1 | tail -5 ;;
      *)    npm install --save "${missing[@]}" --legacy-peer-deps 2>&1 | tail -5 ;;
    esac
    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]]; then
      err "Install failed"
      return $rc
    fi
    ok "Installed"
    return 0
  else
    err "Cannot proceed without: ${missing[*]}"
    return 1
  fi
}

# Resolve path to a specific installed package module file
# Usage: resolve_pkg <package>/dist/index.js
# Writes path to stdout; returns 0 on success, 1 on failure
resolve_pkg_path() {
  local pkg="$1"
  local result
  result=$(node -e "
    try {
      const p = require.resolve('$pkg', { paths: [process.cwd(), '$PROJECT_ROOT'] });
      console.log(p);
    } catch (e) {
      process.exit(1);
    }
  " 2>/dev/null) || return 1
  echo "$result"
}

# Check if a driver is needed for the given dialect, and install it if missing.
# Usage: ensure_dialect_driver <dialect>
ensure_dialect_driver() {
  local dialect="$1"
  local driver=""
  case "$dialect" in
    sqlite)      driver="better-sqlite3" ;;
    postgres|cockroachdb) driver="pg" ;;
    mysql)       driver="mysql2" ;;
    mariadb)     driver="mariadb" ;;
    mssql)       driver="mssql" ;;
    oracle)      driver="oracledb" ;;
    db2)         driver="ibm_db" ;;
    hana)        driver="@sap/hana-client" ;;
    spanner)     driver="@google-cloud/spanner" ;;
    sybase)      driver="sybase" ;;
    mongodb)     driver="mongoose" ;;
    *) return 0 ;;
  esac
  [[ -z "$driver" ]] && return 0
  ensure_pkg "$driver"
}

pause() {
  echo
  read -n 1 -r -s -p "$(echo -e "${DIM}Press any key...${RESET}")" || true
  echo
}

ask() {
  local prompt="$1" default="${2:-}" var
  if [[ -n "$default" ]]; then
    read -r -p "$(echo -e "${YELLOW}?${RESET} $prompt ${DIM}[$default]${RESET}: ")" var
    echo "${var:-$default}"
  else
    read -r -p "$(echo -e "${YELLOW}?${RESET} $prompt: ")" var
    echo "$var"
  fi
}

confirm() {
  local response
  read -r -p "$(echo -e "${YELLOW}?${RESET} $1 ${DIM}[y/N]${RESET}: ")" response
  [[ "$response" =~ ^[Yy]$ ]]
}

header() {
  clear
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║   @mostajs/orm-cli v$VERSION — Universal Schema Adapter Tool      ║"
  echo "║   13 databases · 4 input formats · one command                    ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

# ============================================================
# CONFIG MANAGEMENT
# ============================================================

load_env() {
  [[ -f "$CONFIG_FILE" ]] && { set -a; source "$CONFIG_FILE"; set +a; }
}

save_var() {
  local key="$1" value="$2"
  touch "$CONFIG_FILE"
  grep -v "^${key}=" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || true
  echo "${key}=${value}" >> "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# ============================================================
# PROJECT DETECTION
# ============================================================

detect_project() {
  DETECTED_TYPES=()
  PRISMA_SCHEMA=""
  OPENAPI_FILE=""
  JSON_SCHEMAS=()
  PKG_MANAGER=""

  # Prisma
  if [[ -f "$PROJECT_ROOT/prisma/schema.prisma" ]]; then
    PRISMA_SCHEMA="$PROJECT_ROOT/prisma/schema.prisma"
    DETECTED_TYPES+=("prisma")
  fi

  # OpenAPI (common names)
  for candidate in openapi.yaml openapi.yml openapi.json api.yaml api.yml api.json spec/openapi.yaml docs/openapi.yaml; do
    if [[ -f "$PROJECT_ROOT/$candidate" ]]; then
      OPENAPI_FILE="$PROJECT_ROOT/$candidate"
      DETECTED_TYPES+=("openapi")
      break
    fi
  done

  # JSON Schema files
  while IFS= read -r -d '' f; do
    JSON_SCHEMAS+=("$f")
  done < <(find "$PROJECT_ROOT/schemas" -name "*.json" -print0 2>/dev/null | head -c 10000)

  [[ ${#JSON_SCHEMAS[@]} -gt 0 ]] && DETECTED_TYPES+=("jsonschema")

  # Package manager
  if   [[ -f "$PROJECT_ROOT/pnpm-lock.yaml" ]]; then PKG_MANAGER="pnpm"
  elif [[ -f "$PROJECT_ROOT/yarn.lock"      ]]; then PKG_MANAGER="yarn"
  elif [[ -f "$PROJECT_ROOT/bun.lockb"      ]]; then PKG_MANAGER="bun"
  elif [[ -f "$PROJECT_ROOT/package.json"   ]]; then PKG_MANAGER="npm"
  else PKG_MANAGER="npm"
  fi
}

# ============================================================
# npm / npx wrapper — finds the installed adapter or uses npx
# ============================================================

run_adapter_convert() {
  local input_type="$1"  # prisma | jsonschema | openapi
  local input_file="$2"
  local output_file="$3"

  # Ensure @mostajs/orm-adapter is available — auto-install if missing
  info "Checking @mostajs/orm-adapter..."
  local adapter_base=""

  # 1. Try local project install
  if [[ -d "$PROJECT_ROOT/node_modules/@mostajs/orm-adapter/dist" ]]; then
    adapter_base="$PROJECT_ROOT/node_modules/@mostajs/orm-adapter/dist"
    ok "Using local install"
  else
    # 2. Try sibling (dev setup)
    local cli_dir
    cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [[ -d "$cli_dir/../mosta-orm-adapter/dist" ]]; then
      adapter_base="$cli_dir/../mosta-orm-adapter/dist"
      info "Using sibling dev install"
    else
      # 3. Offer auto-install
      warn "Not installed locally"
      if ensure_pkg "@mostajs/orm-adapter" "@mostajs/orm"; then
        adapter_base="$PROJECT_ROOT/node_modules/@mostajs/orm-adapter/dist"
        if [[ ! -d "$adapter_base" ]]; then
          local resolved
          resolved=$(resolve_pkg_path "@mostajs/orm-adapter") || {
            err "Install reported success but module cannot be resolved."
            return 1
          }
          adapter_base="$(dirname "$resolved")"
        fi
        ok "Installed"
      else
        err "Cannot proceed without the adapter."
        return 1
      fi
    fi
  fi

  # Use subpath-specific import to avoid loading ALL adapters (and their
  # transitive deps : ajv, ref-parser, openapi-parser...). For example,
  # importing only prisma.adapter.js avoids pulling in ajv-draft-04 issues
  # when the project only needs Prisma conversion.
  local adapter_file
  local adapter_class
  case "$input_type" in
    prisma)     adapter_file="$adapter_base/adapters/prisma.adapter.js"     ; adapter_class="PrismaAdapter" ;;
    openapi)    adapter_file="$adapter_base/adapters/openapi.adapter.js"    ; adapter_class="OpenApiAdapter" ;;
    jsonschema) adapter_file="$adapter_base/adapters/jsonschema.adapter.js" ; adapter_class="JsonSchemaAdapter" ;;
    *) err "Unknown input type: $input_type"; return 1 ;;
  esac

  if [[ ! -f "$adapter_file" ]]; then
    warn "Subpath import $adapter_file not found — falling back to root index.js"
    adapter_file="$adapter_base/index.js"
  fi

  cat > "$CONFIG_DIR/convert.mjs" << EOF
import { readFileSync, writeFileSync } from 'fs';

let adapterModule;
try {
  adapterModule = await import('$adapter_file');
} catch (e) {
  console.error('Failed to import adapter from $adapter_file');
  console.error('Reason :', e.message);
  // Common issue : ajv/ref-parser/yaml resolution problems
  if (e.message?.includes('ajv') || e.message?.includes('ref-parser') || e.message?.includes('yaml')) {
    console.error();
    console.error('Hint : this adapter requires peer deps that may be missing.');
    console.error('Try : $PKG_MANAGER install ajv@^8 @apidevtools/json-schema-ref-parser@^11');
  }
  process.exit(2);
}
const { $adapter_class } = adapterModule;
if (!$adapter_class) {
  console.error('$adapter_class not exported from the adapter module');
  process.exit(3);
}

let source;
try {
  source = readFileSync('$input_file', 'utf8');
} catch (e) {
  console.error('Cannot read input file : $input_file');
  console.error('Reason :', e.message);
  process.exit(4);
}

const adapter = new $adapter_class();
const warnings = [];
const input = '$input_type' === 'jsonschema' ? JSON.parse(source) : source;

let entities;
try {
  entities = await adapter.toEntitySchema(input, { onWarning: w => warnings.push(w) });
} catch (e) {
  console.error('Conversion failed :', e.message);
  if (e.details) console.error('Details :', JSON.stringify(e.details, null, 2).slice(0, 500));
  process.exit(5);
}

console.log('entities : ' + entities.length);
console.log('warnings : ' + warnings.length);
for (const w of warnings) console.log('  [' + w.code + '] ' + (w.entity ?? '-') + ' : ' + w.message);

const header = '// Auto-generated by @mostajs/orm-cli v$VERSION at ' + new Date().toISOString() + '\n';
const code = header +
  '// Source : $input_file\n' +
  '// Adapter : $adapter_class\n' +
  '// DO NOT EDIT BY HAND — regenerate with: mostajs convert\n\n' +
  'import type { EntitySchema } from \"@mostajs/orm\";\n\n' +
  'export const entities: EntitySchema[] = ' + JSON.stringify(entities, null, 2) + ';\n\n' +
  'export const entityByName: Record<string, EntitySchema> = Object.fromEntries(\n' +
  '  entities.map(e => [e.name, e])\n' +
  ');\n';

try {
  writeFileSync('$output_file', code);
  // Also write .json (easier to load from ESM without TS support)
  const jsonFile = '$output_file'.replace(/\.ts$/, '.json');
  writeFileSync(jsonFile, JSON.stringify(entities, null, 2));
  console.log('\u2713 Saved : $output_file');
  console.log('\u2713 Saved : ' + jsonFile);
} catch (e) {
  console.error('Cannot write output : ' + e.message);
  process.exit(6);
}
EOF

  local rc=0
  node "$CONFIG_DIR/convert.mjs" 2>&1 | tee "$LOG_DIR/convert.log"
  rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]]; then
    err "Conversion exited with code $rc"
    info "See $LOG_DIR/convert.log for details"
    return $rc
  fi
  return 0
}

# ============================================================
# MAIN MENU
# ============================================================

menu_main() {
  load_env
  detect_project
  header
  echo -e "${BOLD}Project :${RESET}  ${DIM}$PROJECT_ROOT${RESET}"
  echo -e "${BOLD}Manager :${RESET}  ${DIM}$PKG_MANAGER${RESET}"
  echo -e "${BOLD}Detected :${RESET} "
  if [[ -n "$PRISMA_SCHEMA" ]]; then
    local count
    count=$(grep -c '^model ' "$PRISMA_SCHEMA" 2>/dev/null || echo 0)
    ok "Prisma schema ($count models) at ${DIM}${PRISMA_SCHEMA#$PROJECT_ROOT/}${RESET}"
  fi
  [[ -n "$OPENAPI_FILE" ]] && ok "OpenAPI spec at ${DIM}${OPENAPI_FILE#$PROJECT_ROOT/}${RESET}"
  [[ ${#JSON_SCHEMAS[@]} -gt 0 ]] && ok "JSON Schema files: ${#JSON_SCHEMAS[@]}"
  [[ ${#DETECTED_TYPES[@]} -eq 0 ]] && warn "No schema detected. Menu 1 to create one, or cd into a project first."
  echo

  if [[ -f "$GENERATED_DIR/entities.ts" ]]; then
    local count
    count=$(grep -c '"name":' "$GENERATED_DIR/entities.ts" 2>/dev/null || echo 0)
    ok "entities.ts generated ($count entities, $(du -h "$GENERATED_DIR/entities.ts" | cut -f1))"
  else
    warn "entities.ts not generated"
  fi
  echo

  echo -e "${BOLD}${MAGENTA}━━━ MAIN MENU ━━━${RESET}"
  echo
  echo -e "  ${CYAN}1${RESET}) Convert schema → EntitySchema[]"
  echo -e "  ${CYAN}2${RESET}) Configure database URIs"
  echo -e "  ${CYAN}3${RESET}) Initialize dialects (connect + create tables)"
  echo -e "  ${CYAN}4${RESET}) Tests menu (human / mobile / AI / curl / playwright)"
  echo -e "  ${CYAN}5${RESET}) Start services"
  echo -e "  ${CYAN}6${RESET}) Metrics & status"
  echo -e "  ${CYAN}7${RESET}) View logs"
  echo -e "  ${CYAN}8${RESET}) Health checks"
  echo -e "  ${CYAN}9${RESET}) Generate boilerplate (src/db.ts with bridge)"
  echo -e "  ${CYAN}0${RESET}) About / Help"
  echo
  echo -e "  ${RED}q${RESET}) Quit"
  echo
  local choice
  choice=$(ask "Choice" "1")
  case "$choice" in
    1) action_convert ;;
    2) menu_databases ;;
    3) action_init_dialects ;;
    4) menu_tests ;;
    5) menu_services ;;
    6) action_metrics ;;
    7) action_logs ;;
    8) action_healthcheck ;;
    9) action_generate_boilerplate ;;
    0) action_about ;;
    q|Q) exit 0 ;;
    *) warn "Unknown choice"; pause ;;
  esac
}

# ============================================================
# ACTION 1 : CONVERT
# ============================================================

action_convert() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Convert schema → EntitySchema[]${RESET}"
  echo
  detect_project

  if [[ ${#DETECTED_TYPES[@]} -eq 0 ]]; then
    err "No schema file found."
    info "Expected files (any one) :"
    dim "  - prisma/schema.prisma"
    dim "  - openapi.yaml / openapi.json / api.yaml / spec/openapi.yaml"
    dim "  - schemas/*.json"
    echo
    if confirm "Pick a file manually?"; then
      local f; f=$(ask "Path to schema file (absolute or relative)")
      [[ -z "$f" ]] && { pause; return; }
      [[ ! -f "$f" ]] && { err "Not found: $f"; pause; return; }
      # Infer type by extension / content
      if [[ "$f" =~ \.prisma$ ]]; then
        PRISMA_SCHEMA="$f"; DETECTED_TYPES=("prisma")
      elif [[ "$f" =~ \.ya?ml$ ]] || grep -q "^openapi:" "$f" 2>/dev/null; then
        OPENAPI_FILE="$f"; DETECTED_TYPES=("openapi")
      else
        JSON_SCHEMAS=("$f"); DETECTED_TYPES=("jsonschema")
      fi
    else
      pause; return
    fi
  fi

  # If multiple types, ask which one
  local type input
  if [[ ${#DETECTED_TYPES[@]} -eq 1 ]]; then
    type="${DETECTED_TYPES[0]}"
  else
    echo "Multiple schema types detected. Choose:"
    local i=1
    for t in "${DETECTED_TYPES[@]}"; do echo "  $i) $t"; i=$((i+1)); done
    local choice; choice=$(ask "Number" "1")
    type="${DETECTED_TYPES[$((choice-1))]}"
  fi

  case "$type" in
    prisma)     input="$PRISMA_SCHEMA" ;;
    openapi)    input="$OPENAPI_FILE" ;;
    jsonschema) input="${JSON_SCHEMAS[0]}" ;;
  esac

  info "Input : $input"
  info "Output: $GENERATED_DIR/entities.ts"
  echo
  run_adapter_convert "$type" "$input" "$GENERATED_DIR/entities.ts"
  pause
}

# ============================================================
# MENU 2 : DATABASES
# ============================================================

menu_databases() {
  load_env
  header
  echo -e "${BOLD}${MAGENTA}▶ Database configuration${RESET}"
  echo
  echo -e "${DIM}Compatible with @mostajs/orm .env convention (see SecuAccessPro/.env.local)${RESET}"
  echo
  echo -e "${BOLD}Primary DB (single backend — 90% of apps) :${RESET}"
  echo -e "  ${CYAN}1${RESET}) DB_DIALECT          : ${DIM}${DB_DIALECT:-<not set>}${RESET}"
  echo -e "  ${CYAN}2${RESET}) SGBD_URI            : ${DIM}${SGBD_URI:-<not set>}${RESET}"
  echo -e "  ${CYAN}3${RESET}) DB_SCHEMA_STRATEGY  : ${DIM}${DB_SCHEMA_STRATEGY:-update}${RESET}"
  echo -e "  ${CYAN}4${RESET}) DB_POOL_SIZE        : ${DIM}${DB_POOL_SIZE:-20}${RESET}"
  echo -e "  ${CYAN}5${RESET}) DB_SHOW_SQL         : ${DIM}${DB_SHOW_SQL:-false}${RESET}"
  echo
  echo -e "${BOLD}Extra DBs (hybrid apps with Prisma Bridge) :${RESET}"
  echo -e "  ${CYAN}a${RESET}) Add extra binding   ${DIM}(e.g. MongoDB for audit while PG is primary)${RESET}"
  echo -e "  ${CYAN}l${RESET}) List extra bindings : ${DIM}${EXTRA_BINDINGS:-<none>}${RESET}"
  echo
  echo -e "${BOLD}mosta-net + app :${RESET}"
  echo -e "  ${CYAN}u${RESET}) MOSTA_NET_URL       : ${DIM}${MOSTA_NET_URL:-http://localhost:14488}${RESET}"
  echo -e "  ${CYAN}n${RESET}) MOSTA_NET_TRANSPORT : ${DIM}${MOSTA_NET_TRANSPORT:-rest}${RESET}"
  echo -e "  ${CYAN}p${RESET}) APP_PORT            : ${DIM}${APP_PORT:-3000}${RESET}"
  echo
  echo -e "  ${CYAN}t${RESET}) Test all connections"
  echo -e "  ${CYAN}e${RESET}) Export to .env.local in project"
  echo -e "  ${CYAN}r${RESET}) Reset config"
  echo -e "  ${CYAN}b${RESET}) Back"
  echo
  local choice; choice=$(ask "Choice" "1")
  case "$choice" in
    1) prompt_dialect ;;
    2) save_var SGBD_URI           "$(ask 'SGBD_URI (path or connection string)' "${SGBD_URI:-./data.sqlite}")";;
    3) save_var DB_SCHEMA_STRATEGY "$(ask 'DB_SCHEMA_STRATEGY (update|create|validate|none|create-drop)' "${DB_SCHEMA_STRATEGY:-update}")";;
    4) save_var DB_POOL_SIZE       "$(ask 'DB_POOL_SIZE' "${DB_POOL_SIZE:-20}")";;
    5) save_var DB_SHOW_SQL        "$(ask 'DB_SHOW_SQL (true|false)' "${DB_SHOW_SQL:-false}")";;
    a|A) add_extra_binding ;;
    l|L) list_extra_bindings; pause ;;
    u|U) save_var MOSTA_NET_URL       "$(ask 'MOSTA_NET_URL' "${MOSTA_NET_URL:-http://localhost:14488}")";;
    n|N) save_var MOSTA_NET_TRANSPORT "$(ask 'MOSTA_NET_TRANSPORT (rest|sse|graphql|mcp|websocket|jsonrpc|grpc|odata)' "${MOSTA_NET_TRANSPORT:-rest}")";;
    p|P) save_var APP_PORT            "$(ask 'APP_PORT' "${APP_PORT:-3000}")";;
    t|T) action_test_connections; return;;
    e|E) export_env_local ;;
    r|R) confirm "Really reset config?" && rm -f "$CONFIG_FILE" && ok "Reset";;
    b|B) return;;
    *) warn "Unknown";;
  esac
  pause
  menu_databases
}

# Prompt user to choose a dialect from a numbered list
prompt_dialect() {
  echo
  echo "Pick a dialect:"
  local i=1
  local -a dialects=(sqlite postgres mysql mariadb mongodb mssql oracle db2 cockroachdb hana hsqldb spanner sybase)
  for d in "${dialects[@]}"; do
    echo -e "  ${CYAN}$i${RESET}) $d"
    i=$((i+1))
  done
  local num; num=$(ask "Number" 1)
  local idx=$((num-1))
  if [[ $idx -ge 0 && $idx -lt ${#dialects[@]} ]]; then
    local d="${dialects[$idx]}"
    save_var DB_DIALECT "$d"
    # Suggest default URI for that dialect if SGBD_URI is empty
    if [[ -z "${SGBD_URI:-}" ]]; then
      local suggest
      case "$d" in
        sqlite)      suggest="./data.sqlite" ;;
        postgres)    suggest="postgres://user:pw@localhost:5432/app" ;;
        mysql|mariadb) suggest="mysql://user:pw@localhost:3306/app" ;;
        # MongoDB : include ?authSource=admin (common pitfall without it)
        mongodb)     suggest="mongodb://devuser:devpass26@localhost:27017/app?authSource=admin" ;;
        mssql)       suggest="mssql://user:pw@localhost:1433/app" ;;
        oracle)      suggest="oracle://user:pw@localhost:1521/ORCLPDB" ;;
        db2)         suggest="db2://user:pw@localhost:50000/app" ;;
        cockroachdb) suggest="postgres://user@localhost:26257/app" ;;
        hana)        suggest="hana://user:pw@localhost:39041" ;;
        *)           suggest="" ;;
      esac
      [[ -n "$suggest" ]] && save_var SGBD_URI "$(ask 'SGBD_URI' "$suggest")"
    fi
  else
    warn "Invalid number"
  fi
}

# Add an extra dialect binding for hybrid apps
add_extra_binding() {
  local name; name=$(ask "Binding name (e.g. AuditLog, Reports) — used by the Prisma Bridge")
  [[ -z "$name" ]] && return
  local dialect; dialect=$(ask "Dialect for $name (sqlite|postgres|mongodb|oracle|...)")
  [[ -z "$dialect" ]] && return
  local uri; uri=$(ask "URI for $name")
  [[ -z "$uri" ]] && return
  local current="${EXTRA_BINDINGS:-}"
  local new="${name}:${dialect}:${uri}"
  if [[ -z "$current" ]]; then
    save_var EXTRA_BINDINGS "$new"
  else
    save_var EXTRA_BINDINGS "${current};${new}"
  fi
  ok "Added: $name ($dialect @ $uri)"
}

list_extra_bindings() {
  echo
  if [[ -z "${EXTRA_BINDINGS:-}" ]]; then
    dim "  (none)"
    return
  fi
  echo -e "${BOLD}Extra bindings:${RESET}"
  local IFS=';'
  for b in $EXTRA_BINDINGS; do
    local name="${b%%:*}"
    local rest="${b#*:}"
    local dialect="${rest%%:*}"
    local uri="${rest#*:}"
    echo -e "  ${CYAN}$name${RESET} → ${MAGENTA}$dialect${RESET} @ ${DIM}$uri${RESET}"
  done
}

# Export a .env.local file compatible with @mostajs/orm convention
export_env_local() {
  local target="$PROJECT_ROOT/.env.mostajs"
  cat > "$target" <<EOF
# Generated by @mostajs/orm-cli on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Primary database
DB_DIALECT=${DB_DIALECT:-sqlite}
SGBD_URI=${SGBD_URI:-./data.sqlite}
DB_SCHEMA_STRATEGY=${DB_SCHEMA_STRATEGY:-update}
DB_POOL_SIZE=${DB_POOL_SIZE:-20}
DB_SHOW_SQL=${DB_SHOW_SQL:-false}

# mosta-net server
MOSTA_NET_URL=${MOSTA_NET_URL:-http://localhost:14488}
MOSTA_NET_TRANSPORT=${MOSTA_NET_TRANSPORT:-rest}

# App
APP_PORT=${APP_PORT:-3000}

# Extra bindings for Prisma Bridge (hybrid apps)
# Format: EXTRA_BINDINGS="ModelName:dialect:uri;OtherModel:dialect:uri"
EXTRA_BINDINGS=${EXTRA_BINDINGS:-}
EOF
  ok "Exported : $target"
  info "Review, rename to .env.local, and commit to your .env.example (without secrets)"
}

# Auto-detect mosta-orm dialect from URI scheme
detect_dialect_from_uri() {
  local uri="$1"
  case "$uri" in
    mongodb://*|mongodb+srv://*) echo "mongodb" ;;
    postgres://*|postgresql://*) echo "postgres" ;;
    mysql://*)                   echo "mysql" ;;
    mariadb://*)                 echo "mariadb" ;;
    mssql://*|sqlserver://*)     echo "mssql" ;;
    oracle://*)                  echo "oracle" ;;
    db2://*)                     echo "db2" ;;
    hana://*)                    echo "hana" ;;
    cockroachdb://*)             echo "cockroachdb" ;;
    spanner://*)                 echo "spanner" ;;
    sybase://*)                  echo "sybase" ;;
    sqlite://*|sqlite:*|*.sqlite|*.db|:memory:) echo "sqlite" ;;
    *) echo "unknown" ;;
  esac
}

# Strip scheme prefix from URI (used for SQLite path)
strip_uri_scheme() {
  local uri="$1"
  case "$uri" in
    sqlite://*) echo "${uri#sqlite://}" ;;
    sqlite:*)   echo "${uri#sqlite:}"   ;;
    *)          echo "$uri" ;;
  esac
}

action_test_connections() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Testing connections (via @mostajs/orm)${RESET}"
  echo
  load_env

  # Collect all configured URIs as (dialect, uri) pairs
  local -a pairs=()

  # Primary DB
  if [[ -n "${DB_DIALECT:-}" && -n "${SGBD_URI:-}" ]]; then
    pairs+=("${DB_DIALECT}|${SGBD_URI}")
  fi

  # Extra bindings (format: name:dialect:uri;name:dialect:uri)
  if [[ -n "${EXTRA_BINDINGS:-}" ]]; then
    local IFS=';'
    for b in $EXTRA_BINDINGS; do
      local rest="${b#*:}"       # strip name
      local dialect="${rest%%:*}"
      local uri="${rest#*:}"
      pairs+=("$dialect|$uri")
    done
    IFS=$' \t\n'
  fi

  if [[ ${#pairs[@]} -eq 0 ]]; then
    warn "No URIs configured. Go to menu 2 first."
    pause; return
  fi

  # Ensure @mostajs/orm is installed (test uses its native testConnection)
  info "Checking @mostajs/orm installation..."
  if ! ensure_pkg "@mostajs/orm"; then
    err "Cannot test connections without @mostajs/orm"
    pause; return
  fi

  # Ensure drivers for each dialect being tested
  info "Checking drivers..."
  for p in "${pairs[@]}"; do
    local d="${p%%|*}"
    ensure_dialect_driver "$d" || warn "Driver for $d may be missing"
  done

  local orm_path
  orm_path=$(resolve_pkg_path "@mostajs/orm") || {
    err "Cannot resolve @mostajs/orm"
    pause; return
  }

  # Build a small node script that tests each connection
  local -a args=()
  for p in "${pairs[@]}"; do
    args+=("$p")
  done

  cat > "$CONFIG_DIR/test-connections.mjs" <<EOF
import { getDialect } from '$orm_path';

const pairs = process.argv.slice(2).map(s => {
  const i = s.indexOf('|');
  return [s.slice(0, i), s.slice(i + 1)];
});

function stripScheme(uri) {
  if (uri.startsWith('sqlite://')) return uri.slice(9);
  if (uri.startsWith('sqlite:'))   return uri.slice(7);
  return uri;
}

// Provide dialect-specific hints for common auth / connection errors.
function hintFor(dialect, rawUri, err) {
  const msg = (err && err.message) ? err.message : '';
  const code = err && (err.code ?? err.codeName);

  // MongoDB code 18 : Authentication failed → missing ?authSource=admin
  if (dialect === 'mongodb' && (code === 18 || /AuthenticationFailed|18/.test(msg))) {
    if (!/authSource=/.test(rawUri)) {
      return 'MongoDB users are usually declared in the admin DB. Add ?authSource=admin to the URI :\n'
        + '       ' + (rawUri.includes('?') ? rawUri + '&authSource=admin' : rawUri + '?authSource=admin');
    }
    return 'Verify credentials (username / password) in the URI.';
  }

  // PostgreSQL common errors
  if (dialect === 'postgres' || dialect === 'cockroachdb') {
    if (/password authentication failed/i.test(msg)) return 'Wrong PG password. Check the URI or run: psql "' + rawUri + '" -c "SELECT 1"';
    if (/ECONNREFUSED|connect ECONNREFUSED/i.test(msg)) return 'PG server not running on that host/port. Try: pg_isready -h HOST -p PORT';
    if (/no pg_hba.conf entry/i.test(msg)) return 'Server rejects the connection (pg_hba.conf). Add your IP or use SSL.';
  }

  // MySQL common errors
  if (dialect === 'mysql' || dialect === 'mariadb') {
    if (/Access denied for user/i.test(msg)) return 'Wrong MySQL password. Try: mysql -u USER -p -h HOST';
    if (/ECONNREFUSED/i.test(msg)) return 'MySQL not running. Try: systemctl status mysql';
  }

  // SQLite common errors
  if (dialect === 'sqlite') {
    if (/SQLITE_CANTOPEN/i.test(msg)) return 'Cannot open SQLite file. Check the path exists and is writable.';
  }

  // Generic network errors
  if (/ECONNREFUSED/i.test(msg)) return 'Service is not reachable at that host/port.';
  if (/ENOTFOUND|getaddrinfo/i.test(msg)) return 'DNS resolution failed. Check the hostname.';
  if (/ETIMEDOUT/i.test(msg)) return 'Connection timed out. Check firewall / VPN / host.';

  return null;
}

let ok = 0, fail = 0;
for (const [dialect, rawUri] of pairs) {
  const uri = dialect === 'sqlite' ? stripScheme(rawUri) : rawUri;
  process.stdout.write(dialect.padEnd(12) + ' ' + rawUri + '\n');
  try {
    const d = await getDialect({ dialect, uri });
    const alive = await d.testConnection();
    if (alive) {
      console.log('  \u2713 reachable');
      ok++;
    } else {
      console.log('  \u2717 testConnection returned false');
      fail++;
    }
    await d.disconnect().catch(() => {});
  } catch (e) {
    console.error('  \u2717 ' + (e.message ?? e));
    if (e.code) console.error('    code : ' + e.code);
    if (e.codeName) console.error('    codeName : ' + e.codeName);
    const hint = hintFor(dialect, rawUri, e);
    if (hint) console.error('    \u2192 ' + hint);
    fail++;
  }
}
console.log();
console.log('Results : ' + ok + ' reachable, ' + fail + ' failed');
process.exit(fail > 0 ? 1 : 0);
EOF

  cd "$PROJECT_ROOT"
  node "$CONFIG_DIR/test-connections.mjs" "${args[@]}" 2>&1 | tee "$LOG_DIR/test-connections.log"
  local test_rc=${PIPESTATUS[0]}
  echo

  # Offer to auto-fix common MongoDB auth issue (missing ?authSource=admin)
  if [[ $test_rc -ne 0 ]] && grep -qE "authSource=admin|AuthenticationFailed|code : 18" "$LOG_DIR/test-connections.log"; then
    echo
    warn "Detected MongoDB authentication failure that is usually fixed by adding"
    warn "  ?authSource=admin  to the URI."
    if confirm "Append '?authSource=admin' to your MongoDB URI now?"; then
      # Fix the primary SGBD_URI if it's mongodb
      if [[ "${DB_DIALECT:-}" == "mongodb" ]] && [[ -n "${SGBD_URI:-}" ]] && [[ ! "$SGBD_URI" =~ authSource= ]]; then
        local new_uri
        if [[ "$SGBD_URI" =~ \? ]]; then
          new_uri="${SGBD_URI}&authSource=admin"
        else
          new_uri="${SGBD_URI}?authSource=admin"
        fi
        save_var SGBD_URI "$new_uri"
        ok "Updated SGBD_URI : $new_uri"
      fi
      # Fix any MongoDB extra binding missing authSource
      if [[ -n "${EXTRA_BINDINGS:-}" ]]; then
        local new_bindings=""
        local IFS=';'
        for b in $EXTRA_BINDINGS; do
          local name="${b%%:*}"
          local rest="${b#*:}"
          local dialect="${rest%%:*}"
          local uri="${rest#*:}"
          if [[ "$dialect" == "mongodb" ]] && [[ ! "$uri" =~ authSource= ]]; then
            if [[ "$uri" =~ \? ]]; then
              uri="${uri}&authSource=admin"
            else
              uri="${uri}?authSource=admin"
            fi
          fi
          new_bindings+="${new_bindings:+;}${name}:${dialect}:${uri}"
        done
        IFS=$' \t\n'
        save_var EXTRA_BINDINGS "$new_bindings"
        ok "Updated EXTRA_BINDINGS"
      fi
      echo
      info "Re-running the test with the fixed URI..."
      # Rebuild args with fresh env
      load_env
      args=()
      [[ -n "${DB_DIALECT:-}" && -n "${SGBD_URI:-}" ]] && args+=("${DB_DIALECT}|${SGBD_URI}")
      if [[ -n "${EXTRA_BINDINGS:-}" ]]; then
        local IFS=';'
        for b in $EXTRA_BINDINGS; do
          local rest="${b#*:}"
          args+=("${rest%%:*}|${rest#*:}")
        done
        IFS=$' \t\n'
      fi
      node "$CONFIG_DIR/test-connections.mjs" "${args[@]}" 2>&1 | tee "$LOG_DIR/test-connections.log"
    fi
  fi

  pause
}

# ============================================================
# ACTION 3 : INIT DIALECTS
# ============================================================

action_init_dialects() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Initialize dialects${RESET}"
  echo
  load_env

  if [[ ! -f "$GENERATED_DIR/entities.ts" ]]; then
    err "No entities.ts. Run menu 1 (Convert) first."
    pause; return
  fi

  # Collect configured dialects from DB_DIALECT/SGBD_URI + EXTRA_BINDINGS
  local -a configured=()
  local -a dialect_names=()

  if [[ -n "${DB_DIALECT:-}" && -n "${SGBD_URI:-}" ]]; then
    configured+=("${DB_DIALECT}:${SGBD_URI}")
    dialect_names+=("$DB_DIALECT")
  fi

  if [[ -n "${EXTRA_BINDINGS:-}" ]]; then
    local IFS=';'
    for b in $EXTRA_BINDINGS; do
      local rest="${b#*:}"
      local dialect="${rest%%:*}"
      local uri="${rest#*:}"
      configured+=("${dialect}:${uri}")
      dialect_names+=("$dialect")
    done
    IFS=$' \t\n'
  fi

  if [[ ${#configured[@]} -eq 0 ]]; then
    err "No URIs set. Menu 2 first."
    pause; return
  fi

  info "Will attempt to initialize:"
  for item in "${configured[@]}"; do
    dim "  ${item%%:*} → ${item#*:}"
  done
  echo

  confirm "Proceed?" || return

  # ---- Step 1 : ensure @mostajs/orm is installed ----
  info "Step 1/3 : checking @mostajs/orm installation..."
  if ! ensure_pkg "@mostajs/orm"; then
    err "Cannot initialize dialects without @mostajs/orm"
    pause; return
  fi
  ok "@mostajs/orm available"

  # ---- Step 2 : ensure drivers for each dialect are installed ----
  info "Step 2/3 : checking dialect drivers..."
  for dialect in "${dialect_names[@]}"; do
    ensure_dialect_driver "$dialect" || warn "Driver for $dialect may be missing"
  done
  ok "Drivers checked"

  # ---- Step 3 : resolve absolute path to @mostajs/orm (avoids import resolution issues) ----
  local orm_path
  orm_path=$(resolve_pkg_path "@mostajs/orm") || {
    err "Could not resolve @mostajs/orm path even after install"
    pause; return
  }
  dim "Using @mostajs/orm at : $orm_path"
  echo

  # Pass each dialect:uri pair as argv to the node script
  cat > "$CONFIG_DIR/init-all.mjs" <<EOF
// Auto-generated by mostajs-cli — runs from project root
import { readFileSync } from 'fs';
import { getDialect } from '$orm_path';

let entities;
try {
  entities = JSON.parse(readFileSync('$GENERATED_DIR/entities.json', 'utf8'));
} catch (e) {
  console.error('Cannot load entities.json — run menu 1 (Convert) first.');
  console.error('Reason : ' + e.message);
  process.exit(1);
}

function stripScheme(uri) {
  if (uri.startsWith('sqlite://')) return uri.slice(9);
  if (uri.startsWith('sqlite:'))   return uri.slice(7);
  return uri;
}

const pairs = process.argv.slice(2).map(s => {
  const i = s.indexOf('|');
  return [s.slice(0, i), s.slice(i + 1)];
});

let ok = 0, fail = 0;
const schemaStrategy = process.env.DB_SCHEMA_STRATEGY ?? 'update';
const poolSize = parseInt(process.env.DB_POOL_SIZE ?? '20', 10);
const showSql = process.env.DB_SHOW_SQL === 'true';

function hintFor(dialect, rawUri, err) {
  const msg = (err && err.message) ? err.message : '';
  const code = err && (err.code ?? err.codeName);
  if (dialect === 'mongodb' && (code === 18 || /AuthenticationFailed|18/.test(msg))) {
    if (!/authSource=/.test(rawUri)) {
      return 'Missing ?authSource=admin on MongoDB URI. Try :\n       '
        + (rawUri.includes('?') ? rawUri + '&authSource=admin' : rawUri + '?authSource=admin');
    }
  }
  if (/ECONNREFUSED/i.test(msg)) return 'Service not running at that host/port';
  if (/ENOTFOUND/i.test(msg))    return 'DNS resolution failed';
  if (/ETIMEDOUT/i.test(msg))    return 'Connection timed out';
  return null;
}

for (const [dialect, rawUri] of pairs) {
  const uri = dialect === 'sqlite' ? stripScheme(rawUri) : rawUri;
  process.stdout.write('→ ' + dialect.padEnd(12) + ' : ' + rawUri + '\n');
  try {
    const d = await getDialect({ dialect, uri, schemaStrategy, poolSize, showSql });
    await d.initSchema(entities);
    console.log('  ✓ ' + dialect + ' ready (' + entities.length + ' entities)');
    await d.disconnect().catch(() => {});
    ok++;
  } catch (e) {
    console.error('  ✗ ' + dialect + ' failed : ' + (e.message ?? e));
    if (e.code) console.error('    code : ' + e.code);
    const hint = hintFor(dialect, rawUri, e);
    if (hint) console.error('    → ' + hint);
    fail++;
  }
}
console.log();
console.log('Summary : ' + ok + ' succeeded, ' + fail + ' failed');
process.exit(fail > 0 ? 1 : 0);
EOF

  info "Step 3/3 : running initialization..."
  cd "$PROJECT_ROOT" || return

  # Pass each dialect:uri as an argv pair
  local -a args=()
  for item in "${configured[@]}"; do
    local d="${item%%:*}"
    local u="${item#*:}"
    args+=("$d|$u")
  done

  if node "$CONFIG_DIR/init-all.mjs" "${args[@]}" 2>&1 | tee "$LOG_DIR/init.log"; then
    echo
    ok "Initialization complete"
  else
    echo
    warn "One or more dialects failed — check the log above"
    info "Log : $LOG_DIR/init.log"
    echo
    info "Common fixes :"
    dim "  - Verify the URI in menu 2 is reachable (menu 2 → T)"
    dim "  - Install missing driver : $PKG_MANAGER install <driver>"
    dim "  - Oracle/DB2/HANA need native libs installed on your system"
  fi
  pause
}

# ============================================================
# MENU 4 : TESTS
# ============================================================

menu_tests() {
  load_env
  header
  echo -e "${BOLD}${MAGENTA}▶ Tests menu${RESET}"
  echo
  echo -e "  ${CYAN}1${RESET}) Human : open app in browser"
  echo -e "  ${CYAN}2${RESET}) Human : open mosta-net dashboard"
  echo -e "  ${CYAN}3${RESET}) Mobile : QR code for LAN access"
  echo -e "  ${CYAN}4${RESET}) AI : MCP endpoint config (Claude/GPT)"
  echo -e "  ${CYAN}5${RESET}) curl : smoke test REST endpoints"
  echo -e "  ${CYAN}6${RESET}) Playwright"
  echo -e "  ${CYAN}7${RESET}) Jest / Vitest"
  echo
  echo -e "  ${CYAN}b${RESET}) Back"
  echo
  local choice; choice=$(ask "Choice" "1")
  case "$choice" in
    1) open_url "http://localhost:${APP_PORT:-3000}";;
    2) open_url "http://localhost:${MOSTA_NET_PORT:-4447}";;
    3) action_qr_mobile;;
    4) action_mcp_info;;
    5) action_curl_test;;
    6) run_in_project "npx playwright test";;
    7) run_in_project "$PKG_MANAGER test";;
    b|B) return;;
    *) warn Unknown;;
  esac
  pause
  menu_tests
}

open_url() {
  local url="$1"
  info "Opening $url"
  if   command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then open "$url" &
  elif command -v start >/dev/null 2>&1; then start "$url"
  else warn "Cannot auto-open. Visit: $url"
  fi
}

action_qr_mobile() {
  load_env
  header
  echo -e "${BOLD}${MAGENTA}▶ Mobile QR${RESET}"
  echo
  local port="${APP_PORT:-3000}"
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || \
       ifconfig 2>/dev/null | grep -oE 'inet (addr:)?([0-9]+\.){3}[0-9]+' | grep -v '127.0' | head -1 | awk '{print $2}' | sed 's/addr://')
  [[ -z "$ip" ]] && ip="localhost"
  local url="http://${ip}:${port}"
  info "$url"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$url"
  else
    warn "qrencode missing. Install: sudo apt install qrencode"
    echo -e "${BOLD}URL for phone : ${CYAN}$url${RESET}"
  fi
}

action_mcp_info() {
  load_env
  header
  echo -e "${BOLD}${MAGENTA}▶ AI / MCP${RESET}"
  echo
  local url="http://localhost:${MOSTA_NET_PORT:-4447}/mcp"
  info "MCP endpoint : $url"
  echo
  info "Claude Desktop (~/.config/Claude/claude_desktop_config.json or %APPDATA%\\Claude):"
  cat <<EOF
${DIM}{
  "mcpServers": {
    "$(basename "$PROJECT_ROOT")": {
      "url": "$url"
    }
  }
}${RESET}
EOF
  echo
  info "For any MCP-compatible client (Cursor, Continue, GPT clients), point to $url"
  echo
  if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
    ok "Endpoint responds"
  else
    warn "Endpoint not reachable — start mosta-net first (menu 5)"
  fi
}

action_curl_test() {
  load_env
  header
  echo -e "${BOLD}${MAGENTA}▶ curl smoke test${RESET}"
  echo

  if ! command -v curl >/dev/null 2>&1; then
    err "curl is not installed"
    info "Install with : sudo apt install curl"
    return 1
  fi

  local any_reachable=0
  for url in \
    "http://localhost:${APP_PORT:-3000}/" \
    "http://localhost:${APP_PORT:-3000}/api/health" \
    "http://localhost:${MOSTA_NET_PORT:-4447}/" \
    "http://localhost:${MOSTA_NET_PORT:-4447}/mcp"; do
    info "GET $url"
    local output
    output=$(curl -s -o /dev/null -w "    status=%{http_code}  time=%{time_total}s" --max-time 5 "$url" 2>&1)
    local rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "$output"
      any_reachable=1
    else
      err "    unreachable (curl exit $rc — check service is running)"
    fi
  done
  [[ $any_reachable -eq 0 ]] && {
    echo
    warn "No endpoints reachable. Start services first (menu 5)."
  }
}

run_in_project() {
  local cmd="$1"
  cd "$PROJECT_ROOT" || { err "Cannot cd to project root"; return 1; }
  info "Running: $cmd"
  set +e
  eval "$cmd"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    err "Command exited with code $rc"
    info "Check the output above, or common issues :"
    dim "  - Tests failing → fix them, or skip with a flag"
    dim "  - 'command not found' → install missing dev tools"
    dim "  - Port conflict → stop other services first (menu 5 → 3)"
  fi
  return $rc
}

# ============================================================
# MENU 5 : SERVICES
# ============================================================

menu_services() {
  load_env
  header
  echo -e "${BOLD}${MAGENTA}▶ Services${RESET}"
  echo
  echo -e "  ${CYAN}1${RESET}) Start project dev server ($PKG_MANAGER run dev)"
  echo -e "  ${CYAN}2${RESET}) Start mosta-net server (requires separate install)"
  echo -e "  ${CYAN}3${RESET}) Stop all tracked services"
  echo -e "  ${CYAN}4${RESET}) Status"
  echo -e "  ${CYAN}5${RESET}) Show access URLs"
  echo
  echo -e "  ${CYAN}b${RESET}) Back"
  echo
  local choice; choice=$(ask "Choice" "1")
  case "$choice" in
    1) svc_start_dev;;
    2) svc_start_mostanet;;
    3) svc_stop_all;;
    4) svc_status;;
    5) show_urls;;
    b|B) return;;
    *) warn Unknown;;
  esac
  pause
  menu_services
}

svc_start_dev() {
  cd "$PROJECT_ROOT"
  if [[ ! -f package.json ]]; then err "No package.json"; return; fi
  info "Starting dev server (logs → $LOG_DIR/dev.log)"
  nohup "$PKG_MANAGER" run dev > "$LOG_DIR/dev.log" 2>&1 &
  echo "$!" > "$LOG_DIR/dev.pid"
  ok "Started PID $!"
  show_urls
}

svc_start_mostanet() {
  load_env
  cd "$PROJECT_ROOT" || return

  if [[ ! -f "$GENERATED_DIR/entities.json" ]]; then
    err "No entities.json — run menu 1 (Convert) first"
    return
  fi

  # Ensure @mostajs/net AND its peer deps are installed
  info "Checking @mostajs/net + peer dependencies..."
  if ! ensure_pkg "@mostajs/net" "@mostajs/orm" "@mostajs/mproject" "@mostajs/replicator"; then
    err "Cannot start mosta-net server without these packages."
    return
  fi

  # Make our entities available to mostajs-net via schemas.json
  # (mostajs-net's server.js looks for ./schemas.json in CWD)
  if [[ ! -L schemas.json && ! -f schemas.json ]]; then
    ln -sf "$GENERATED_DIR/entities.json" "$PROJECT_ROOT/schemas.json" 2>/dev/null \
      || cp "$GENERATED_DIR/entities.json" "$PROJECT_ROOT/schemas.json"
    ok "Linked schemas.json → $GENERATED_DIR/entities.json"
  fi

  # Derive port from MOSTA_NET_URL
  local mosta_port=14488
  if [[ "${MOSTA_NET_URL:-}" =~ :([0-9]+) ]]; then
    mosta_port="${BASH_REMATCH[1]}"
  fi

  # Prepare env for the child process
  # - DB vars : DB_DIALECT, SGBD_URI, DB_SCHEMA_STRATEGY, ...
  # - MOSTA_NET_PORT : derived from MOSTA_NET_URL
  # - MOSTA_NET_<transport>_ENABLED=true
  local transport="${MOSTA_NET_TRANSPORT:-rest}"
  local tr_upper="$(echo "$transport" | tr '[:lower:]' '[:upper:]')"

  info "Launching mostajs-net serve (port $mosta_port, transport $transport)"
  info "Logs → $LOG_DIR/mostanet.log"

  local launcher
  if [[ -x "$PROJECT_ROOT/node_modules/.bin/mostajs-net" ]]; then
    launcher="$PROJECT_ROOT/node_modules/.bin/mostajs-net"
  else
    launcher="npx mostajs-net"
  fi

  # Launch detached with all env vars
  (
    export DB_DIALECT="${DB_DIALECT:-sqlite}"
    export SGBD_URI="${SGBD_URI:-./data.sqlite}"
    export DB_SCHEMA_STRATEGY="${DB_SCHEMA_STRATEGY:-update}"
    export DB_POOL_SIZE="${DB_POOL_SIZE:-20}"
    export DB_SHOW_SQL="${DB_SHOW_SQL:-false}"
    export MOSTA_NET_PORT="$mosta_port"
    export "MOSTA_NET_${tr_upper}_ENABLED"="true"
    # Also enable MCP alongside — commonly wanted for AI integrations
    [[ "$tr_upper" != "MCP" && "${MOSTA_NET_ALSO_MCP:-true}" == "true" ]] && export MOSTA_NET_MCP_ENABLED=true
    nohup $launcher serve >> "$LOG_DIR/mostanet.log" 2>&1 &
    echo "$!" > "$LOG_DIR/mostanet.pid"
  )
  local pid
  pid=$(cat "$LOG_DIR/mostanet.pid" 2>/dev/null || echo "?")
  ok "Started (PID $pid)"
  echo
  info "Endpoints (wait 2-3 seconds then hit them) :"
  dim "  REST CRUD : http://localhost:${mosta_port}/api/v1/<collection>"
  dim "              (collection = snake_case plural, e.g. /api/v1/users)"
  dim "  MCP (AI)  : http://localhost:${mosta_port}/mcp"
  dim "  Tail log  : tail -f $LOG_DIR/mostanet.log"
  echo
  info "Try it :"
  dim "  curl http://localhost:${mosta_port}/api/v1/users"
  dim "  curl http://localhost:${mosta_port}/api/v1/members"
}

svc_stop_all() {
  for pf in "$LOG_DIR"/*.pid; do
    [[ -f "$pf" ]] || continue
    local pid; pid=$(cat "$pf")
    kill "$pid" 2>/dev/null && ok "Stopped $(basename "$pf" .pid) (PID $pid)"
    rm -f "$pf"
  done
}

svc_status() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Status${RESET}"
  echo
  for pf in "$LOG_DIR"/*.pid; do
    [[ -f "$pf" ]] || continue
    local pid; pid=$(cat "$pf")
    local name; name=$(basename "$pf" .pid)
    kill -0 "$pid" 2>/dev/null && ok "$name (PID $pid)" || warn "$name dead (stale)"
  done
  [[ -z "$(ls "$LOG_DIR"/*.pid 2>/dev/null)" ]] && dim "No services tracked"
}

show_urls() {
  load_env
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo localhost)
  echo
  echo -e "${BOLD}Access URLs${RESET}"
  echo -e "  Dev server (local)  : ${CYAN}http://localhost:${APP_PORT:-3000}${RESET}"
  echo -e "  Dev server (mobile) : ${CYAN}http://${ip}:${APP_PORT:-3000}${RESET}"
  echo -e "  mosta-net           : ${CYAN}http://localhost:${MOSTA_NET_PORT:-4447}${RESET}"
  echo -e "  MCP endpoint (AI)   : ${CYAN}http://localhost:${MOSTA_NET_PORT:-4447}/mcp${RESET}"
}

# ============================================================
# ACTION 6 : METRICS
# ============================================================

action_metrics() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Metrics${RESET}"
  echo
  detect_project

  echo -e "${BOLD}Source${RESET}"
  if [[ -n "$PRISMA_SCHEMA" ]]; then
    echo "  Prisma models  : $(grep -c '^model ' "$PRISMA_SCHEMA")"
    echo "  Prisma lines   : $(wc -l < "$PRISMA_SCHEMA")"
  fi
  [[ -n "$OPENAPI_FILE" ]] && echo "  OpenAPI file   : $OPENAPI_FILE"
  [[ ${#JSON_SCHEMAS[@]} -gt 0 ]] && echo "  JSON schemas   : ${#JSON_SCHEMAS[@]}"

  echo
  echo -e "${BOLD}Conversion${RESET}"
  if [[ -f "$GENERATED_DIR/entities.ts" ]]; then
    echo "  entities.ts    : $(grep -c '"name":' "$GENERATED_DIR/entities.ts") entities, $(du -h "$GENERATED_DIR/entities.ts" | cut -f1)"
    echo "  last generated : $(stat -c '%y' "$GENERATED_DIR/entities.ts" 2>/dev/null | cut -d. -f1 || stat -f '%Sm' "$GENERATED_DIR/entities.ts" 2>/dev/null)"
  else
    echo "  (not generated yet)"
  fi

  echo
  echo -e "${BOLD}Services${RESET}"
  local n=0
  for pf in "$LOG_DIR"/*.pid; do [[ -f "$pf" ]] && n=$((n+1)); done
  echo "  running        : $n"

  echo
  echo -e "${BOLD}Logs${RESET}"
  for f in "$LOG_DIR"/*.log; do
    [[ -f "$f" ]] || continue
    echo "  $(basename "$f") : $(wc -l < "$f") lines"
  done

  pause
}

# ============================================================
# ACTION 7 : LOGS
# ============================================================

action_logs() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Logs${RESET}"
  echo
  local logs=()
  for f in "$LOG_DIR"/*.log; do [[ -f "$f" ]] && logs+=("$f"); done
  if [[ ${#logs[@]} -eq 0 ]]; then warn "No logs yet"; pause; return; fi

  local i=1
  for f in "${logs[@]}"; do
    echo -e "  ${CYAN}$i${RESET}) $(basename "$f")  ${DIM}($(wc -l < "$f") lines)${RESET}"
    i=$((i+1))
  done
  echo
  local choice; choice=$(ask "File #" 1)
  local idx=$((choice-1))
  [[ $idx -ge 0 && $idx -lt ${#logs[@]} ]] && ${PAGER:-less} "${logs[$idx]}"
}

# ============================================================
# ACTION 8 : HEALTH
# ============================================================

action_healthcheck() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Health checks${RESET}"
  echo
  detect_project
  command -v node >/dev/null 2>&1 && ok "node $(node -v)" || err "node missing"
  command -v "$PKG_MANAGER" >/dev/null 2>&1 && ok "$PKG_MANAGER $("$PKG_MANAGER" --version 2>&1 | head -1)" || err "$PKG_MANAGER missing"
  [[ -f "$PROJECT_ROOT/package.json" ]] && ok "package.json" || warn "no package.json"
  [[ -d "$PROJECT_ROOT/node_modules" ]] && ok "node_modules present" || warn "node_modules missing"
  [[ ${#DETECTED_TYPES[@]} -gt 0 ]] && ok "schemas detected: ${DETECTED_TYPES[*]}" || warn "no schema found"
  [[ -f "$GENERATED_DIR/entities.ts" ]] && ok "entities.ts generated" || warn "not generated"
  [[ -f "$CONFIG_FILE" ]] && ok "config present" || warn "config not set"

  command -v curl >/dev/null 2>&1 && ok "curl" || warn "curl missing"
  command -v qrencode >/dev/null 2>&1 && ok "qrencode" || warn "qrencode missing (optional, for mobile QR)"
  command -v mongosh >/dev/null 2>&1 && ok "mongosh" || warn "mongosh missing (optional, for mongo tests)"
  command -v psql    >/dev/null 2>&1 && ok "psql" || warn "psql missing (optional, for PG tests)"
  command -v xdg-open >/dev/null 2>&1 || command -v open >/dev/null 2>&1 && ok "browser-opener available" || warn "cannot auto-open URLs"
  pause
}

# ============================================================
# ACTION 9 : GENERATE BOILERPLATE
# ============================================================

action_generate_boilerplate() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Generate boilerplate${RESET}"
  echo
  echo "Available templates :"
  echo "  1) src/db.ts — Prisma bridge wrapper (choose which models move)"
  echo "  2) src/mosta-orm.ts — direct mosta-orm usage (no Prisma)"
  echo "  3) .env.example with all URIs"
  echo
  local choice; choice=$(ask "Choice" 1)
  case "$choice" in
    1) gen_prisma_bridge_boilerplate;;
    2) gen_direct_boilerplate;;
    3) gen_env_example;;
    *) warn Unknown;;
  esac
  pause
}

gen_prisma_bridge_boilerplate() {
  local target="$PROJECT_ROOT/src/db.ts"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<'EOF'
// Auto-generated by @mostajs/orm-cli
// Prisma bridge : intercepts specific models and routes them to @mostajs/orm dialects

import { PrismaClient } from '@prisma/client';
import { mostaExtension } from '@mostajs/orm-bridge/prisma';
import { entityByName } from '../.mostajs/generated/entities.js';

const g = globalThis as unknown as { prisma?: ReturnType<typeof build> };

function build() {
  return new PrismaClient().$extends(mostaExtension({
    models: {
      // Example : move AuditLog to MongoDB (uncomment and adapt)
      // AuditLog: {
      //   dialect: 'mongodb',
      //   url: process.env.MONGODB_URI!,
      //   schema: entityByName.AuditLog,
      // },

      // Example : move analytics-heavy models to PostgreSQL
      // CheckIn: {
      //   dialect: 'postgres',
      //   url: process.env.ANALYTICS_PG!,
      //   schema: entityByName.CheckIn,
      // },
    },
    fallback: 'source',          // unmapped models → Prisma default engine
    onIntercept: (e) => {
      if (process.env.NODE_ENV !== 'production') {
        console.log(`[bridge] ${e.model}.${e.operation} → ${e.dialect} (${e.duration}ms)`);
      }
    },
  }));
}

export const prisma = g.prisma ?? build();
if (process.env.NODE_ENV !== 'production') g.prisma = prisma;
EOF
  ok "Written : $target"
  info "Next steps :"
  dim "  - Review + pick which models to move"
  dim "  - Replace 'new PrismaClient()' with this 'prisma' import throughout your app"
}

gen_direct_boilerplate() {
  local target="$PROJECT_ROOT/src/mosta-orm.ts"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<'EOF'
// Auto-generated by @mostajs/orm-cli
// Direct @mostajs/orm usage — no Prisma dependency

import { getDialect } from '@mostajs/orm';
import { entities, entityByName } from '../.mostajs/generated/entities.js';

export async function createOrm() {
  const dialect = await getDialect({
    dialect: (process.env.MOSTA_DIALECT ?? 'postgres') as any,
    uri: process.env.DATABASE_URL ?? '',
    schemaStrategy: 'update',
  });
  await dialect.initSchema(entities);
  return { dialect, entities, entityByName };
}
EOF
  ok "Written : $target"
}

gen_env_example() {
  local target="$PROJECT_ROOT/.env.example"
  cat > "$target" <<'EOF'
# ===== @mostajs/orm — 13 databases =====
MONGODB_URI=mongodb://localhost:27017/app
POSTGRES_URI=postgres://user:pw@localhost:5432/app
MYSQL_URI=mysql://user:pw@localhost:3306/app
SQLITE_URI=./data.sqlite
ORACLE_URI=oracle://user:pw@localhost:1521/ORCLPDB
MSSQL_URI=mssql://user:pw@localhost:1433/app
DB2_URI=db2://user:pw@localhost:50000/app
HANA_URI=hana://user:pw@localhost:39041
COCKROACH_URI=postgres://user@localhost:26257/app

APP_PORT=3000
MOSTA_NET_PORT=4447
EOF
  ok "Written : $target"
}

# ============================================================
# ACTION 0 : ABOUT
# ============================================================

action_about() {
  header
  cat <<EOF
  ${BOLD}mostajs-cli v$VERSION${RESET}

  Convert schemas from multiple formats to @mostajs/orm EntitySchema[]
  and gain access to 13 databases without rewriting your code.

  ${BOLD}Supported inputs${RESET}
    - Prisma   (.prisma files)
    - OpenAPI  (3.0, 3.1, YAML/JSON)
    - JSON Schema (Draft-07, 2019-09, 2020-12)

  ${BOLD}Supported databases${RESET}
    PostgreSQL, MySQL, MariaDB, SQLite, MS SQL Server, Oracle, DB2,
    CockroachDB, HANA, HSQLDB, Spanner, Sybase, MongoDB

  ${BOLD}Links${RESET}
    Packages  : @mostajs/orm, @mostajs/orm-adapter, @mostajs/orm-bridge
    GitHub    : https://github.com/apolocine
    Author    : Dr Hamid MADANI <drmdh@msn.com>
    License   : AGPL-3.0-or-later (+ commercial)

  ${BOLD}Workflow${RESET}
    1. cd your/project
    2. mostajs (this tool)
    3. Menu 1 → convert your schema
    4. Menu 2 → set your DB URIs
    5. Menu 3 → init tables
    6. Menu 9 → generate boilerplate
    7. Menu 5 → start services
    8. Menu 4 → test (human / mobile / AI)
EOF
  pause
}

# ============================================================
# CLI SUBCOMMANDS (non-interactive)
# ============================================================

run_subcommand() {
  case "$1" in
    convert|c)
      detect_project
      [[ ${#DETECTED_TYPES[@]} -eq 0 ]] && { err "No schema found"; exit 1; }
      local type="${DETECTED_TYPES[0]}" input
      case "$type" in
        prisma)     input="$PRISMA_SCHEMA" ;;
        openapi)    input="$OPENAPI_FILE" ;;
        jsonschema) input="${JSON_SCHEMAS[0]}" ;;
      esac
      run_adapter_convert "$type" "$input" "$GENERATED_DIR/entities.ts"
      ;;
    detect|d)
      detect_project
      echo "project: $PROJECT_ROOT"
      echo "package manager: $PKG_MANAGER"
      echo "detected: ${DETECTED_TYPES[*]:-none}"
      [[ -n "$PRISMA_SCHEMA" ]] && echo "prisma: $PRISMA_SCHEMA"
      [[ -n "$OPENAPI_FILE" ]] && echo "openapi: $OPENAPI_FILE"
      ;;
    health|h)
      action_healthcheck
      ;;
    version|-v|--version)
      echo "$CLI_NAME $VERSION"
      ;;
    help|-h|--help)
      cat <<EOF
Usage :
  $CLI_NAME                 Interactive menu
  $CLI_NAME convert         Run conversion (auto-detect schema type)
  $CLI_NAME detect          Print detected schemas
  $CLI_NAME health          Run health checks
  $CLI_NAME version         Print version
EOF
      ;;
    *)
      err "Unknown command: $1"
      echo "Run '$CLI_NAME help' for usage"
      exit 1
      ;;
  esac
}

# ============================================================
# MAIN
# ============================================================

# If this script is being *sourced*, stop here — don't start the menu.
# This lets other scripts (e.g. tests) reuse helper functions.
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0 2>/dev/null

# Non-interactive mode if args provided
if [[ $# -gt 0 ]]; then
  run_subcommand "$@"
  exit 0
fi

# Interactive menu
while true; do
  menu_main
done
