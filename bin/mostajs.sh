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

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
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
    local log_file="/tmp/mostajs-install-$$.log"
    case "$PKG_MANAGER" in
      pnpm) pnpm add "${missing[@]}" >"$log_file" 2>&1 & ;;
      yarn) yarn add "${missing[@]}" >"$log_file" 2>&1 & ;;
      bun)  bun add "${missing[@]}" >"$log_file" 2>&1 & ;;
      *)    npm install --save "${missing[@]}" --legacy-peer-deps >"$log_file" 2>&1 & ;;
    esac
    local install_pid=$!
    # Braille spinner — visual feedback while the install runs in background
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local tick=0
    while kill -0 "$install_pid" 2>/dev/null; do
      local f="${frames:$((tick % 10)):1}"
      local secs=$((tick / 5))
      printf "\r  ${YELLOW}%s${RESET}  installing ${CYAN}%s${RESET}  ${DIM}(%ds)${RESET}    " \
             "$f" "${missing[*]}" "$secs"
      tick=$(( tick + 1 ))
      sleep 0.2
    done
    wait "$install_pid"
    local rc=$?
    # Clear the spinner line
    printf "\r%80s\r" ""
    # Show the last lines of the install log (errors or summary)
    tail -5 "$log_file"
    rm -f "$log_file"
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
  # Source .mostajs/config.env WITHOUT overriding env vars that are already
  # set (CLI invocation with DB_DIALECT=... mostajs ... takes precedence).
  [[ -f "$CONFIG_FILE" ]] || return
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    # Trim whitespace from key and strip surrounding quotes from value
    key="${key// /}"
    value="${value%\"}"; value="${value#\"}"
    [[ -z "${!key+x}" ]] && export "$key=$value"
  done < "$CONFIG_FILE"
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
  echo -e "  ${CYAN}s${RESET}) ${BOLD}Seeding${RESET} (upload / validate / apply seed data)"
  echo -e "  ${CYAN}e${RESET}) ${BOLD}Export entities${RESET} → Prisma / JSON Schema / OpenAPI / Native"
  echo -e "  ${CYAN}r${RESET}) ${BOLD}Replicator${RESET} — CQRS master/slave, CDC rules, failover"
  echo -e "  ${GREEN}b${RESET}) ${BOLD}Bootstrap${RESET} — one-shot migration of a Prisma project"
  echo -e "  ${GREEN}i${RESET}) ${BOLD}Install bridge${RESET} — codemod PrismaClient → bridge (dry-run / apply / restore)"
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
    s|S) menu_seeding ;;
    e|E) action_export_entities ;;
    r|R) menu_replicator ;;
    b|B) menu_bootstrap ;;
    i|I) menu_install_bridge ;;
    0) action_about ;;
    q|Q) exit 0 ;;
    *) warn "Unknown choice"; pause ;;
  esac
}

# ------------------------------------------------------------
# Interactive wrapper for `install-bridge` codemod
# ------------------------------------------------------------
menu_install_bridge() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Install bridge — PrismaClient codemod${RESET}"
  echo
  echo "  ${CYAN}1${RESET}) Dry-run : list files that would be rewritten (default)"
  echo "  ${CYAN}2${RESET}) Apply   : rewrite PrismaClient sites to createPrismaLikeDb()"
  echo "  ${CYAN}3${RESET}) Restore : revert .prisma.bak files (dry-run)"
  echo "  ${CYAN}4${RESET}) Restore : revert .prisma.bak files (apply)"
  echo "  ${RED}0${RESET}) Back"
  echo
  local cli_dir
  cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local choice; choice=$(ask "Choice" "1")
  case "$choice" in
    1) node "$cli_dir/bin/install-bridge.mjs" ;;
    2) node "$cli_dir/bin/install-bridge.mjs" --apply ;;
    3) node "$cli_dir/bin/install-bridge.mjs" --restore ;;
    4) node "$cli_dir/bin/install-bridge.mjs" --restore --apply ;;
    0) return ;;
    *) warn "Unknown" ;;
  esac
  pause
}

# ------------------------------------------------------------
# Interactive wrapper for `bootstrap` — one-shot full migration
# ------------------------------------------------------------
menu_bootstrap() {
  header
  echo -e "${BOLD}${GREEN}▶ Bootstrap — full Prisma → @mostajs/orm migration${RESET}"
  echo
  echo "This will, in ${BOLD}this project${RESET} :"
  echo "  1. Rewrite every ${CYAN}new PrismaClient()${RESET} site to use ${CYAN}createPrismaLikeDb()${RESET}"
  echo "     (originals backed up as ${DIM}*.prisma.bak${RESET})"
  echo "  2. Install ${CYAN}@mostajs/orm${RESET} + ${CYAN}@mostajs/orm-bridge${RESET} + ${CYAN}server-only${RESET}"
  echo "  3. Convert ${CYAN}prisma/schema.prisma${RESET} → ${DIM}.mostajs/generated/entities.json${RESET}"
  echo "  4. Write ${DIM}.mostajs/config.env${RESET} (default : sqlite ./data.sqlite) and init DDL"
  echo
  warn "Existing code changes will be backed up but NOT committed — review the diff before pushing."
  echo
  local go; go=$(ask "Proceed? (y/N)" "N")
  [[ "$go" =~ ^[yY]$ ]] || { info "Cancelled"; return; }
  run_subcommand bootstrap
  pause
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
  echo -e "  ${CYAN}i${RESET}) ${BOLD}Import from project .env${RESET} (auto-detect app's real DB)"
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
    i|I) action_import_env ;;
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

# Import DB config from the project's own .env file.
# This is CRUCIAL when your app (Prisma, NextAuth, ...) already has a
# DATABASE_URL / MONGODB_URI / POSTGRES_URL. Seeding the wrong DB leads to
# the classic "users are in mosta-net /api/v1/users but login fails" bug.
action_import_env() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Import DB config from project .env${RESET}"
  echo

  local candidates=(".env.local" ".env" ".env.production" ".env.development")
  local -a available=()
  for f in "${candidates[@]}"; do
    [[ -f "$PROJECT_ROOT/$f" ]] && available+=("$f")
  done

  if [[ ${#available[@]} -eq 0 ]]; then
    err "No .env* file found in $PROJECT_ROOT"
    pause; return
  fi

  echo "Found env files :"
  local i=1
  for f in "${available[@]}"; do
    echo -e "  ${CYAN}$i${RESET}) $f"
    i=$((i+1))
  done
  echo
  local choice; choice=$(ask "Number" 1)
  local src_file="${available[$((choice-1))]}"
  [[ -z "$src_file" ]] && return
  local src_path="$PROJECT_ROOT/$src_file"

  # Extract common DB URI variables — priority order matters
  # MONGODB_URI > DATABASE_URL > POSTGRES_URL > MYSQL_URL > SGBD_URI
  local found_uri="" found_var="" found_dialect=""
  for var in SGBD_URI DATABASE_URL MONGODB_URI POSTGRES_URL POSTGRES_URI MYSQL_URL MYSQL_URI POSTGRESQL_URL; do
    # Read value, skip commented lines, strip quotes
    local val
    val=$(grep -E "^${var}=" "$src_path" 2>/dev/null | grep -v "^#" | head -1 | sed "s/^${var}=//" | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
    if [[ -n "$val" ]]; then
      found_uri="$val"
      found_var="$var"
      break
    fi
  done

  if [[ -z "$found_uri" ]]; then
    err "No DB URI found in $src_file"
    info "Searched : SGBD_URI, DATABASE_URL, MONGODB_URI, POSTGRES_URL/URI, MYSQL_URL/URI"
    pause; return
  fi

  # Detect dialect from URI scheme
  found_dialect=$(detect_dialect_from_uri "$found_uri")
  if [[ "$found_dialect" == "unknown" ]]; then
    warn "Could not auto-detect dialect from URI: $found_uri"
    found_dialect=$(ask "Dialect name (mongodb|postgres|mysql|...)" "")
    [[ -z "$found_dialect" ]] && { pause; return; }
  fi

  info "Detected :"
  echo -e "  Variable : ${CYAN}$found_var${RESET}"
  echo -e "  URI      : ${DIM}$found_uri${RESET}"
  echo -e "  Dialect  : ${MAGENTA}$found_dialect${RESET}"
  echo

  # Special Prisma note
  if [[ "$found_var" == "MONGODB_URI" ]] || [[ "$found_var" == "DATABASE_URL" ]]; then
    dim "  (This is likely the Prisma datasource — the same DB your app uses for login/auth.)"
    echo
  fi

  if confirm "Save as DB_DIALECT + SGBD_URI ?"; then
    save_var DB_DIALECT "$found_dialect"
    save_var SGBD_URI   "$found_uri"
    # Suggest a strategy based on environment context
    if [[ "$src_file" == ".env.production" ]]; then
      save_var DB_SCHEMA_STRATEGY "validate"
      info "Auto-set DB_SCHEMA_STRATEGY=validate (production)"
    elif [[ -z "${DB_SCHEMA_STRATEGY:-}" ]]; then
      save_var DB_SCHEMA_STRATEGY "update"
    fi
    ok "Config imported"
    echo
    info "Next step : menu 2 → t (test connection), then menu S → 4 (seed)"
  fi
  pause
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

  # Parse mosta-net URL from config (full URL, not just port)
  local mosta_url="${MOSTA_NET_URL:-http://localhost:14488}"
  local mosta_host="${mosta_url#*://}"
  mosta_host="${mosta_host%%/*}"

  # App URL : derive from APP_PORT
  local app_port="${APP_PORT:-3000}"

  echo
  echo -e "${BOLD}Access URLs${RESET}"
  echo -e "  Dev server (local)  : ${CYAN}http://localhost:${app_port}${RESET}"
  echo -e "  Dev server (mobile) : ${CYAN}http://${ip}:${app_port}${RESET}"
  echo -e "  mosta-net base      : ${CYAN}${mosta_url}${RESET}"
  echo -e "  REST CRUD           : ${CYAN}${mosta_url}/api/v1/<collection>${RESET}"
  echo -e "  MCP endpoint (AI)   : ${CYAN}${mosta_url}/mcp${RESET}"
  echo -e "  LAN (mobile)        : ${CYAN}http://${ip}${mosta_host#localhost}${RESET}"
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
# MENU S : SEEDING
# ============================================================

menu_seeding() {
  load_env
  header
  echo -e "${BOLD}${MAGENTA}▶ Seeding — populate databases with test / initial data${RESET}"
  echo
  local seed_dir="$CONFIG_DIR/seeds"
  mkdir -p "$seed_dir"
  local count
  count=$(ls -1 "$seed_dir"/*.json 2>/dev/null | wc -l)
  echo -e "  Seed directory : ${DIM}${seed_dir}${RESET}"
  echo -e "  Seed files     : ${DIM}${count} .json${RESET}"
  [[ $count -gt 0 ]] && ls "$seed_dir"/*.json 2>/dev/null | while read f; do
    local rows; rows=$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$f','utf8')).length)}catch{console.log('?')}" 2>/dev/null)
    dim "    - $(basename "$f")  (${rows} rows)"
  done
  echo
  echo -e "${BOLD}━━━ SEEDING MENU ━━━${RESET}"
  echo
  echo -e "  ${CYAN}1${RESET}) Upload / import seed file(s)"
  echo -e "  ${CYAN}2${RESET}) Generate seed templates (one empty .json per entity)"
  echo -e "  ${CYAN}3${RESET}) Validate seeds against schema (dry-run, no DB writes)"
  echo -e "  ${CYAN}4${RESET}) Apply seeds to primary DB"
  echo -e "  ${CYAN}5${RESET}) Apply seeds with upsert (insert or update by id)"
  echo -e "  ${CYAN}6${RESET}) Truncate + apply (DESTRUCTIVE — wipes tables first)"
  echo -e "  ${CYAN}7${RESET}) Dump current DB rows → .mostajs/seeds-dump/"
  echo -e "  ${CYAN}8${RESET}) Clear the seeds directory"
  echo -e "  ${CYAN}9${RESET}) Show a seed file"
  echo -e "  ${CYAN}h${RESET}) ${BOLD}Hash plain-text passwords in seed files${RESET} (bcrypt)"
  echo -e "  ${CYAN}r${RESET}) ${BOLD}Restore seed scripts${RESET} from ${DIM}*.prisma.bak${RESET} (undo install-bridge on seeds)"
  echo -e "  ${CYAN}s${RESET}) ${BOLD}Run seed scripts${RESET} (${DIM}scripts/seed-*.ts | prisma/seed.ts${RESET}) via tsx"
  echo -e "  ${RED}d${RESET}) ${BOLD}Drop table(s)${RESET} — pick one / many / all, then DROP TABLE (DESTRUCTIVE)"
  echo
  echo -e "  ${CYAN}b${RESET}) Back"
  echo
  local choice
  choice=$(ask "Choice" "1")
  case "$choice" in
    1) action_seed_upload ;;
    2) action_seed_generate_templates ;;
    3) action_seed_apply "validate" ;;
    4) action_seed_apply "apply" ;;
    5) action_seed_apply "upsert" ;;
    6) action_seed_apply "truncate-apply" ;;
    7) action_seed_dump ;;
    8) action_seed_clear ;;
    9) action_seed_show ;;
    h|H) action_seed_hash_passwords ;;
    r|R) action_seed_restore_scripts ;;
    s|S) action_seed_run_scripts ;;
    d|D) action_drop_tables ;;
    b|B) return ;;
    *) warn "Unknown"; pause ;;
  esac
  menu_seeding
}

# ------------------------------------------------------------
# Replicator menu — CQRS master/slave + cross-dialect CDC
# ------------------------------------------------------------
#
# Thin wrapper around @mostajs/replicator. Every action is routed to
# ReplicationManager methods via a Node --input-type=module shell.
# State is persisted to $PROJECT_ROOT/.mostajs/replicator-tree.json
# (same file format as saveToFile / loadFromFile of the lib).

_replicator_tree_file() {
  echo "$PROJECT_ROOT/.mostajs/replicator-tree.json"
}

_replicator_has_lib() {
  [[ -d "$PROJECT_ROOT/node_modules/@mostajs/replicator" ]]
}

_replicator_run() {
  # Execute a Node snippet with the replicator loaded. The snippet reads
  # from stdin, gets `rm` (ReplicationManager), `pm` (ProjectManager) in
  # scope and is expected to mutate them then call `await save()`.
  # $1 = inline snippet string.
  local tree_file
  tree_file=$(_replicator_tree_file)
  mkdir -p "$(dirname "$tree_file")"
  TREE_FILE="$tree_file" RUNTIME_ROOT="$PROJECT_ROOT" \
  node --input-type=module -e "
    const { existsSync } = await import('fs');
    const { ReplicationManager } = await import(process.env.RUNTIME_ROOT + '/node_modules/@mostajs/replicator/dist/index.js');
    const { ProjectManager }     = await import(process.env.RUNTIME_ROOT + '/node_modules/@mostajs/mproject/dist/index.js');
    const pm = new ProjectManager();
    const rm = new ReplicationManager(pm);
    const save = async () => { await rm.saveToFile(process.env.TREE_FILE); };
    if (existsSync(process.env.TREE_FILE)) {
      try { await rm.loadFromFile(process.env.TREE_FILE); } catch (e) { console.error('  ⚠ load failed : ' + e.message); }
    }
    try {
      $1
    } catch (e) {
      console.error('  ✗ ' + e.message);
      process.exit(1);
    } finally {
      try { await rm.disconnectAll(); } catch {}
    }
  "
}

menu_replicator() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Replicator — CQRS, CDC, failover${RESET}"
  echo
  if ! _replicator_has_lib; then
    warn "@mostajs/replicator not installed in this project."
    echo
    if confirm "Install @mostajs/replicator + @mostajs/mproject now?"; then
      ensure_pkg "@mostajs/replicator" "@mostajs/mproject" || { pause; return; }
    else
      dim "  Cannot proceed without the replicator lib."
      pause; return
    fi
  fi

  local tree_file
  tree_file=$(_replicator_tree_file)
  echo -e "  Tree file : ${DIM}${tree_file}${RESET}"
  if [[ -f "$tree_file" ]]; then
    local projects
    projects=$(node -e "try{const t=JSON.parse(require('fs').readFileSync('$tree_file','utf8'));console.log(Object.keys(t.replicas||{}).length+' projects, '+Object.keys(t.rules||{}).length+' CDC rules')}catch{console.log('?')}" 2>/dev/null)
    echo -e "  State     : ${DIM}${projects}${RESET}"
  else
    echo -e "  State     : ${DIM}(empty — will be created on first save)${RESET}"
  fi

  echo
  echo -e "${BOLD}━━━ REPLICATOR MENU ━━━${RESET}"
  echo
  echo -e "  ${CYAN}1${RESET}) Add replica (master / slave) to a project"
  echo -e "  ${CYAN}2${RESET}) List replicas + status / lag"
  echo -e "  ${CYAN}3${RESET}) Promote a slave to master (failover)"
  echo -e "  ${CYAN}4${RESET}) Remove a replica"
  echo -e "  ${CYAN}5${RESET}) Set read-routing strategy (round-robin / least-lag / random)"
  echo -e "  ${CYAN}6${RESET}) Add a CDC rule (pg → mongo, mysql → analytics, …)"
  echo -e "  ${CYAN}7${RESET}) List CDC rules"
  echo -e "  ${CYAN}8${RESET}) Run a CDC sync + show stats"
  echo -e "  ${CYAN}9${RESET}) Remove a CDC rule"
  echo -e "  ${CYAN}m${RESET}) ${BOLD}Open monitor${RESET} (live dashboard — localhost:14499)"
  echo -e "  ${CYAN}s${RESET}) ${BOLD}Scaffold services${RESET} — services/replicator.mjs + services/monitor.mjs + package.json scripts"
  echo -e "  ${CYAN}v${RESET}) View the raw tree file"
  echo -e "  ${CYAN}c${RESET}) Clear (delete the tree file — DESTRUCTIVE)"
  echo
  echo -e "  ${CYAN}b${RESET}) Back"
  echo
  local choice
  choice=$(ask "Choice" "2")
  case "$choice" in
    1) action_rep_add_replica ;;
    2) action_rep_list_replicas ;;
    3) action_rep_promote ;;
    4) action_rep_remove_replica ;;
    5) action_rep_set_routing ;;
    6) action_rep_add_rule ;;
    7) action_rep_list_rules ;;
    8) action_rep_sync ;;
    9) action_rep_remove_rule ;;
    m|M) action_rep_open_monitor ;;
    s|S) action_rep_scaffold_services ;;
    v|V) action_rep_view_tree ;;
    c|C) action_rep_clear ;;
    b|B) return ;;
    *) warn "Unknown"; pause ;;
  esac
  menu_replicator
}

# ------------------------------------------------------------
# Scaffold background services (replicator + monitor) + package.json patch
# ------------------------------------------------------------
action_rep_scaffold_services() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Scaffold background services${RESET}"
  echo
  echo -e "  This will :"
  echo -e "    1. ${CYAN}services/replicator.mjs${RESET}  (from @mostajs/replicator)"
  echo -e "    2. ${CYAN}services/monitor.mjs${RESET}     (from @mostajs/replica-monitor)"
  echo -e "    3. patch ${CYAN}package.json${RESET} : scripts.replicator / monitor / dev:all"
  echo -e "    4. install ${CYAN}concurrently${RESET} if missing"
  echo
  if ! confirm "Proceed?"; then return; fi

  # Ensure the scaffolders' packages are installed locally
  ensure_pkg "@mostajs/replicator" "@mostajs/replica-monitor" || { pause; return; }

  local force_js="false"
  if confirm "Overwrite existing services/*.mjs if present?"; then force_js="true"; fi

  # Call each scaffolder (uses the lib's own emit logic — single source of truth)
  echo
  echo -e "${CYAN}▶ scaffoldReplicatorService${RESET}"
  FORCE="$force_js" PROJECT="$PROJECT_ROOT" node --input-type=module -e "
    const { scaffoldReplicatorService } = await import(process.env.PROJECT + '/node_modules/@mostajs/replicator/dist/scaffold.js');
    const r = scaffoldReplicatorService({ projectDir: process.env.PROJECT, force: process.env.FORCE === 'true' });
    console.log('  ' + (r.wrote ? '✓' : '•') + ' ' + r.action + ' : ' + r.path);
  " 2>&1 | sed 's/^/  /'

  echo
  echo -e "${CYAN}▶ scaffoldMonitorService${RESET}"
  FORCE="$force_js" PROJECT="$PROJECT_ROOT" node --input-type=module -e "
    const { scaffoldMonitorService } = await import(process.env.PROJECT + '/node_modules/@mostajs/replica-monitor/dist/scaffold.js');
    const r = scaffoldMonitorService({ projectDir: process.env.PROJECT, force: process.env.FORCE === 'true' });
    console.log('  ' + (r.wrote ? '✓' : '•') + ' ' + r.action + ' : ' + r.path);
  " 2>&1 | sed 's/^/  /'

  # Patch package.json scripts
  echo
  echo -e "${CYAN}▶ patching package.json scripts${RESET}"
  if [[ ! -f "$PROJECT_ROOT/package.json" ]]; then
    warn "  no package.json found — skipping scripts patch"
  else
    PROJECT="$PROJECT_ROOT" node --input-type=module -e "
      const fs = await import('node:fs');
      const path = process.env.PROJECT + '/package.json';
      const pkg = JSON.parse(fs.readFileSync(path, 'utf8'));
      pkg.scripts = pkg.scripts || {};
      const add = (key, val) => {
        if (pkg.scripts[key]) {
          console.log('  • ' + key + ' already set (kept as-is)');
        } else {
          pkg.scripts[key] = val;
          console.log('  ✓ added ' + key);
        }
      };
      add('replicator', 'node services/replicator.mjs');
      add('monitor',    'node services/monitor.mjs');
      add('dev:all',    'concurrently --kill-others-on-fail --names next,rep,mon -c blue,magenta,cyan \"npm:dev\" \"npm:replicator\" \"npm:monitor\"');
      fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + '\n');
    " 2>&1 | sed 's/^/  /'
  fi

  # Ensure concurrently is installed (devDependency)
  echo
  echo -e "${CYAN}▶ checking concurrently${RESET}"
  if [[ -d "$PROJECT_ROOT/node_modules/concurrently" ]]; then
    ok "  concurrently already installed"
  else
    if confirm "Install concurrently as a devDependency?"; then
      cd "$PROJECT_ROOT" || return 1
      local log_file="/tmp/mostajs-concurrently-$$.log"
      case "$PKG_MANAGER" in
        pnpm) pnpm add -D concurrently > "$log_file" 2>&1 & ;;
        yarn) yarn add -D concurrently > "$log_file" 2>&1 & ;;
        bun)  bun add -d concurrently > "$log_file" 2>&1 & ;;
        *)    npm install --save-dev concurrently --legacy-peer-deps > "$log_file" 2>&1 & ;;
      esac
      local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' tick=0
      while kill -0 "$pid" 2>/dev/null; do
        local f="${frames:$((tick % 10)):1}"
        printf "\r  ${YELLOW}%s${RESET}  installing concurrently  ${DIM}(%ds)${RESET}    " "$f" "$((tick / 5))"
        tick=$((tick + 1)); sleep 0.2
      done
      wait "$pid"; local rc=$?
      printf "\r%60s\r" ""
      if [[ $rc -eq 0 ]]; then ok "  concurrently installed"
      else err "  install failed (see $log_file)"; tail -3 "$log_file"
      fi
      rm -f "$log_file"
    fi
  fi

  echo
  echo -e "${BOLD}${GREEN}✓ Scaffold complete.${RESET}"
  echo
  echo -e "  ${BOLD}Next steps :${RESET}"
  echo -e "    1. ${CYAN}mostajs${RESET} → menu r → add replicas + CDC rules (writes replicator-tree.json)"
  echo -e "    2. ${CYAN}npm run dev:all${RESET}   — starts Next + replicator + monitor in parallel"
  echo -e "       or individually : ${CYAN}npm run replicator${RESET} / ${CYAN}npm run monitor${RESET}"
  echo -e "    3. Open ${CYAN}http://localhost:14499${RESET} for the live dashboard"
  pause
}

action_rep_add_replica() {
  echo
  dim "  A project is a logical group of replicas (e.g. 'fitzone', 'secuaccess')."
  dim "  Use a SHORT IDENTIFIER here (NOT a database URI — the URI comes later)."
  echo
  local project name role dialect uri lag
  # Use the smart project picker (lists known projects, suggests first)
  project=$(_pick_project)
  # Basic validation : reject URIs or paths
  if [[ "$project" == *"://"* || "$project" == *"/"* ]]; then
    err "  Project name looks like a URI or path. Use a short identifier (e.g. 'fitzone')."
    pause; return
  fi

  echo
  dim "  Replica name is a label inside the project (e.g. 'master-oracle', 'slave-pg')."
  name=$(ask    "Replica name (label, e.g. 'master-oracle')" "master")
  if [[ "$name" == *"://"* ]]; then
    err "  Replica name looks like a URI. Use a short label."
    pause; return
  fi

  role=$(ask    "Role (master|slave)" "master")
  dialect=$(ask "Dialect (sqlite|postgres|mysql|mongodb|oracle|mssql|mariadb|cockroachdb|db2|hana|hsqldb|spanner|sybase)" "${DB_DIALECT:-postgres}")
  uri=$(ask     "Connection URI" "${SGBD_URI:-postgres://user:pass@localhost:5432/db}")
  if [[ "$role" == "slave" ]]; then
    lag=$(ask "Lag tolerance (ms)" "5000")
  else
    lag="0"
  fi
  # Direct tree-JSON patch — preserves URI verbatim (no masking), no DB
  # connection needed. Validation of the URI happens later when replicator
  # service or sync action actually touches the DB.
  _tree_patch "
    tree.replicas['$project'] = tree.replicas['$project'] || {};
    tree.replicas['$project']['$name'] = {
      role: '$role',
      dialect: '$dialect',
      uri: '$uri',
      pool: { min: 2, max: 20 },
      ...( '$role' === 'slave' ? { lagTolerance: $lag } : {} ),
    };
    console.log('  ✓ replica added : $name (' + '$role' + ') on project $project');
  "
  pause
}

# ----------------------------------------------------------------
# Tree-file direct manipulation helpers
# ----------------------------------------------------------------
# The replicator's saveToFile() masks credentials (oracle://u:***@host)
# which makes loadFromFile() unable to reconnect. For add/list/remove we
# bypass the lib and patch the tree JSON directly, preserving the
# original URI verbatim. The lib is still used for sync() / promote()
# where it has logic beyond state tracking.

_tree_file() { _replicator_tree_file; }

_tree_read_json() {
  # Dump the tree JSON on stdout, empty-tree fallback if file missing.
  local tree_file
  tree_file=$(_tree_file)
  node -e "
    const fs = require('fs');
    const def = { replicas: {}, rules: {}, routing: {} };
    try { console.log(JSON.stringify(Object.assign(def, JSON.parse(fs.readFileSync('$tree_file','utf8'))))); }
    catch { console.log(JSON.stringify(def)); }
  "
}

# List known projects from the replicator-tree.json — if any — and propose
# the first one as default. Echoes the chosen project name to stdout.
_pick_project() {
  local projects=()
  while IFS= read -r p; do projects+=("$p"); done < <(
    _tree_read_json | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{for(const k of Object.keys(JSON.parse(d).replicas||{}))console.log(k)})"
  )
  local default_project="fitzone"
  if [[ ${#projects[@]} -gt 0 ]]; then
    default_project="${projects[0]}"
    if [[ ${#projects[@]} -gt 1 ]]; then
      echo >&2
      dim "  Known projects : ${projects[*]}" >&2
    fi
  fi
  local picked
  picked=$(ask "Project name" "$default_project")
  echo "$picked"
}

# Patch the tree JSON : exec a Node snippet with `tree` in scope.
# After the snippet runs, the mutated tree is written back.
_tree_patch() {
  local snippet="$1"
  local tree_file
  tree_file=$(_tree_file)
  mkdir -p "$(dirname "$tree_file")"
  TREE_FILE="$tree_file" node --input-type=module -e "
    const { readFileSync, writeFileSync, existsSync } = await import('fs');
    const { mkdirSync } = await import('fs');
    const def = { replicas: {}, rules: {}, routing: {} };
    let tree = def;
    if (existsSync(process.env.TREE_FILE)) {
      try { tree = Object.assign(def, JSON.parse(readFileSync(process.env.TREE_FILE, 'utf8'))); }
      catch { /* start fresh */ }
    }
    try { $snippet }
    catch (e) { console.error('  ✗ ' + e.message); process.exit(1); }
    writeFileSync(process.env.TREE_FILE, JSON.stringify(tree, null, 2) + '\n');
  "
}

action_rep_list_replicas() {
  local project
  project=$(_pick_project)
  echo
  _tree_read_json | PROJECT="$project" node -e "
    let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
      const tree = JSON.parse(d);
      const reps = tree.replicas[process.env.PROJECT] || {};
      const entries = Object.entries(reps);
      if (entries.length === 0) {
        console.log('  (no replicas registered for project ' + process.env.PROJECT + ')');
        return;
      }
      for (const [name, cfg] of entries) {
        const star = cfg.role === 'master' ? '\x1b[36m★\x1b[0m' : '•';
        console.log('  ' + star + ' ' + name + '  [' + cfg.role + ']  ' + cfg.dialect + '  ' + (cfg.uri ?? '').replace(/:[^:@]+@/, ':***@'));
      }
    });
  "
  pause
}

action_rep_promote() {
  local project name
  project=$(_pick_project)
  name=$(ask    "Slave to promote" "slave-1")
  if ! confirm "Promote '$name' to master on project '$project'?"; then return; fi
  _replicator_run "
    await rm.promoteToMaster('$project', '$name');
    await save();
    console.log('  ✓ $name is now the master of $project');
  "
  pause
}

action_rep_remove_replica() {
  local project name
  project=$(_pick_project)
  name=$(ask    "Replica name" "slave-1")
  if ! confirm "Remove replica '$name' from project '$project'?"; then return; fi
  _tree_patch "
    if (!tree.replicas['$project'] || !tree.replicas['$project']['$name']) {
      console.log('  • not found : $project/$name');
    } else {
      delete tree.replicas['$project']['$name'];
      if (Object.keys(tree.replicas['$project']).length === 0) delete tree.replicas['$project'];
      console.log('  ✓ removed : $project/$name');
    }
  "
  pause
}

action_rep_set_routing() {
  local project strategy
  project=$(_pick_project)
  strategy=$(ask "Strategy (round-robin | least-lag | random)" "least-lag")
  _tree_patch "
    tree.routing['$project'] = '$strategy';
    console.log('  ✓ read routing on $project = $strategy');
  "
  pause
}

action_rep_add_rule() {
  local name source target mode colls conflict
  # Pick source/target from known projects
  source=$(_pick_project)
  local src_default="$source"
  name=$(ask     "Rule name (short, e.g. 'pg-to-mongo')" "cdc-${src_default}")
  target=$(ask   "Target project" "$src_default")
  mode=$(ask     "Mode (snapshot | cdc | bidirectional)" "cdc")
  colls=$(ask    "Collections (comma-separated)" "users,clients")
  conflict=$(ask "Conflict resolution (source-wins | target-wins | timestamp)" "source-wins")
  _tree_patch "
    tree.rules['$name'] = {
      source: '$source', target: '$target', mode: '$mode',
      collections: '$colls'.split(',').map(s => s.trim()).filter(Boolean),
      conflictResolution: '$conflict',
      enabled: true,
    };
    console.log('  ✓ rule added : $name ($source → $target, mode=$mode)');
  "
  pause
}

action_rep_list_rules() {
  echo
  _tree_read_json | node -e "
    let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
      const tree = JSON.parse(d);
      const rules = Object.entries(tree.rules || {});
      if (rules.length === 0) {
        console.log('  (no CDC rules registered)');
        return;
      }
      for (const [name, r] of rules) {
        const flag = r.enabled ? '\x1b[32m✓\x1b[0m' : '\x1b[31m✗\x1b[0m';
        console.log('  ' + flag + ' ' + name + '  ' + r.source + ' → ' + r.target + '  [' + r.mode + ']  ' + (r.collections||[]).join(','));
      }
    });
  "
  pause
}

action_rep_sync() {
  local rule
  rule=$(ask "Rule name" "pg-to-mongo")
  _replicator_run "
    const stats = await rm.sync('$rule');
    console.log('  ✓ sync complete');
    console.log('    inserted: ' + (stats.inserted ?? 0));
    console.log('    updated : ' + (stats.updated  ?? 0));
    console.log('    deleted : ' + (stats.deleted  ?? 0));
    console.log('    failed  : ' + (stats.failed   ?? 0));
    await save();
  "
  pause
}

action_rep_remove_rule() {
  local name
  name=$(ask "Rule name" "pg-to-mongo")
  if ! confirm "Remove CDC rule '$name'?"; then return; fi
  _tree_patch "
    if (!tree.rules['$name']) {
      console.log('  • not found : $name');
    } else {
      delete tree.rules['$name'];
      console.log('  ✓ removed : $name');
    }
  "
  pause
}

action_rep_open_monitor() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Open replica-monitor dashboard${RESET}"
  echo
  # Ensure the monitor package is installed
  if [[ ! -d "$PROJECT_ROOT/node_modules/@mostajs/replica-monitor" ]]; then
    warn "@mostajs/replica-monitor not installed in this project."
    if confirm "Install it now?"; then
      ensure_pkg "@mostajs/replica-monitor" || { pause; return; }
    else
      pause; return
    fi
  fi
  local tree_file
  tree_file=$(_replicator_tree_file)
  local port
  port=$(ask "Port" "14499")
  local token
  token=$(ask "Auth token (empty = no auth, local-only)" "")
  local url_suffix=""
  [[ -n "$token" ]] && url_suffix="?token=${token}"

  local log_file="$PROJECT_ROOT/.mostajs/monitor.log"
  local pid_file="$PROJECT_ROOT/.mostajs/monitor.pid"

  # If already running : propose to restart (pick up tree changes with
  # the new tree-only CLI). A stale instance from before 0.2.0 sees an
  # empty state even when the tree has replicas.
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
    local old_pid
    old_pid=$(cat "$pid_file")
    dim "  Monitor already running (pid=$old_pid) at http://127.0.0.1:${port}"
    if confirm "Restart it now? (picks up recent tree-file changes)"; then
      kill "$old_pid" 2>/dev/null || true
      sleep 0.5
      rm -f "$pid_file"
    else
      ok "  Kept running — re-opening the URL"
      if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "http://127.0.0.1:${port}${url_suffix}" >/dev/null 2>&1 &
      fi
      pause; return
    fi
  fi

  if [[ ! -f "$pid_file" ]]; then
    # Spawn in background
    echo -e "  ${DIM}spawning mostajs-monitor …${RESET}"
    MONITOR_TREE="$tree_file" MONITOR_PORT="$port" MONITOR_TOKEN="$token" \
    nohup node "$PROJECT_ROOT/node_modules/@mostajs/replica-monitor/dist/cli.js" \
      --tree "$tree_file" --port "$port" --runtime "$PROJECT_ROOT" \
      ${token:+--token "$token"} \
      > "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      ok "Monitor started (pid=$pid) → http://127.0.0.1:${port}${url_suffix}"
      dim "  logs : $log_file"
      dim "  stop : kill \$(cat $pid_file)  or  menu r → m again then Ctrl+C"
    else
      err "Monitor failed to start — check $log_file"
      cat "$log_file" | tail -10
      pause; return
    fi
  fi

  # Try to open in default browser
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "http://127.0.0.1:${port}${url_suffix}" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then
    open "http://127.0.0.1:${port}${url_suffix}" >/dev/null 2>&1 &
  fi
  pause
}

action_rep_view_tree() {
  local tree_file
  tree_file=$(_replicator_tree_file)
  if [[ -f "$tree_file" ]]; then
    echo -e "${DIM}${tree_file}${RESET}"
    echo
    if command -v jq >/dev/null 2>&1; then
      jq . "$tree_file"
    else
      cat "$tree_file"
    fi
  else
    warn "No tree file yet at $tree_file"
  fi
  pause
}

action_rep_clear() {
  local tree_file
  tree_file=$(_replicator_tree_file)
  if ! confirm "DELETE the replicator tree file ($tree_file)?"; then return; fi
  rm -f "$tree_file"
  ok "  tree file deleted"
  pause
}

# ------------------------------------------------------------
# Export entities → Prisma / JSON Schema / OpenAPI / Native TS
# ------------------------------------------------------------
action_export_entities() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Export entities to another schema format${RESET}"
  echo
  local ent_json="$GENERATED_DIR/entities.json"
  if [[ ! -f "$ent_json" ]]; then
    err "No entities.json found — run menu 1 (Convert) first."
    pause; return
  fi
  local count
  count=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$ent_json','utf8')).length)" 2>/dev/null || echo 0)
  echo -e "  Source : ${DIM}${ent_json}${RESET} (${CYAN}${count}${RESET} entities)"
  echo
  echo -e "  ${CYAN}1${RESET}) Prisma        → ${DIM}schema.prisma${RESET}"
  echo -e "  ${CYAN}2${RESET}) JSON Schema   → ${DIM}schema.json${RESET} (2020-12)"
  echo -e "  ${CYAN}3${RESET}) OpenAPI 3.1   → ${DIM}openapi.json${RESET}"
  echo -e "  ${CYAN}4${RESET}) Native (TS)   → ${DIM}src/schemas.ts${RESET}"
  echo
  echo -e "  ${CYAN}b${RESET}) Back"
  echo
  local choice
  choice=$(ask "Format" "1")
  local format="" default_out=""
  case "$choice" in
    1) format="prisma";     default_out="$PROJECT_ROOT/prisma/schema.prisma" ;;
    2) format="jsonschema"; default_out="$PROJECT_ROOT/schema.json" ;;
    3) format="openapi";    default_out="$PROJECT_ROOT/openapi.json" ;;
    4) format="native";     default_out="$PROJECT_ROOT/src/schemas.ts" ;;
    b|B) return ;;
    *) warn "Unknown"; pause; return ;;
  esac
  local out
  out=$(ask "Output file" "$default_out")
  mkdir -p "$(dirname "$out")"

  # Spawn Node to run the adapter's fromEntitySchema
  node --input-type=module -e "
    import('@mostajs/orm-adapter').then(async ({ PrismaAdapter, JsonSchemaAdapter, OpenApiAdapter, NativeAdapter }) => {
      const entities = JSON.parse(await (await import('fs/promises')).readFile('$ent_json', 'utf8'));
      let out;
      switch ('$format') {
        case 'prisma':     out = await new PrismaAdapter().fromEntitySchema(entities);     break;
        case 'jsonschema': out = JSON.stringify(await new JsonSchemaAdapter().fromEntitySchema(entities), null, 2); break;
        case 'openapi':    out = JSON.stringify(await new OpenApiAdapter().fromEntitySchema(entities),    null, 2); break;
        case 'native':
          out = '// Auto-generated by mostajs export → Native (EntitySchema TS)\n'
              + '// Author: @mostajs/orm-cli\n\n'
              + \"import type { EntitySchema } from '@mostajs/orm';\n\n\"
              + 'export const schemas: EntitySchema[] = '
              + JSON.stringify(entities, null, 2) + ';\n\n'
              + '// Named exports for convenience\n'
              + entities.map(e => 'export const ' + e.name + 'Schema: EntitySchema = schemas.find(s => s.name === \"' + e.name + '\")!;').join('\n')
              + '\n';
          break;
      }
      await (await import('fs/promises')).writeFile('$out', out);
      console.log('  ✓ written ' + '$out' + ' (' + (out.length/1024).toFixed(1) + ' KB)');
    }).catch(e => { console.error('  ✗', e.message); process.exit(1); });
  " 2>&1
  pause
}

# ------------------------------------------------------------
# seed : drop tables (interactive picker)
# ------------------------------------------------------------
action_drop_tables() {
  header
  echo -e "${BOLD}${RED}▶ Drop table(s) — DESTRUCTIVE${RESET}"
  echo
  load_env
  local seed_dir="$CONFIG_DIR/seeds"
  local entities_json="$GENERATED_DIR/entities.json"
  if [[ ! -f "$entities_json" ]]; then
    warn "No entities.json found at $entities_json — run menu 1 (Convert) first."
    pause; return
  fi

  # Run a Node helper that lists live tables, lets the user pick, then drops via dialect
  node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import { createInterface } from 'node:readline/promises';
    import { stdin, stdout } from 'node:process';
    import { getDialect } from '${PROJECT_ROOT}/node_modules/@mostajs/orm/dist/index.js';

    const env = readFileSync('${PROJECT_ROOT}/.mostajs/config.env', 'utf8');
    for (const line of env.split('\n')) {
      const [k, v] = line.split('=');
      if (k && v) process.env[k.trim()] = v.trim();
    }

    const entities = JSON.parse(readFileSync('${PROJECT_ROOT}/.mostajs/generated/entities.json', 'utf8'));
    const tableSet = new Set(entities.map(e => e.collection));
    // Add junction tables (many-to-many.through)
    for (const e of entities) {
      for (const r of Object.values(e.relations || {})) {
        if (r && r.type === 'many-to-many' && r.through) tableSet.add(r.through);
      }
    }

    const d = await getDialect({
      dialect: process.env.DB_DIALECT,
      uri:     process.env.SGBD_URI,
      schemaStrategy: 'none',
    });

    // Try to list live tables (dialects that expose getTableListQuery via internal call)
    let live = [];
    try {
      const sql = d.getTableListQuery && d.getTableListQuery();
      if (sql) {
        const rows = await d.executeQuery(sql, []);
        live = rows.map(r => r.name || r.TABLE_NAME || r.table_name || Object.values(r)[0]).filter(Boolean);
      }
    } catch {}
    // Intersect with schema-known tables (only show ones we own)
    const owned = (live.length ? live : Array.from(tableSet)).filter(t => tableSet.has(t)).sort();

    if (owned.length === 0) {
      console.log('  No tables found that match this project\'s entities.');
      await d.disconnect();
      process.exit(0);
    }

    console.log('  Live tables in this project :');
    owned.forEach((t, i) => console.log('    ' + (i + 1).toString().padStart(2) + ') ' + t));
    console.log('    a) ALL of the above');
    console.log('    q) Cancel');

    const rl = createInterface({ input: stdin, output: stdout });
    const pick = (await rl.question('  Pick (number, comma-separated, or a) : ')).trim();
    if (!pick || pick.toLowerCase() === 'q') { rl.close(); await d.disconnect(); console.log('  Cancelled.'); process.exit(0); }

    const targets = pick.toLowerCase() === 'a'
      ? owned
      : pick.split(',').map(s => s.trim()).map(s => owned[parseInt(s, 10) - 1]).filter(Boolean);

    if (targets.length === 0) { rl.close(); await d.disconnect(); console.log('  Nothing to drop.'); process.exit(0); }

    console.log('  About to DROP : ' + targets.join(', '));
    const confirm = (await rl.question('  Type DROP to confirm : ')).trim();
    rl.close();
    if (confirm !== 'DROP') { await d.disconnect(); console.log('  Aborted.'); process.exit(0); }

    let ok = 0, fail = 0;
    for (const t of targets) {
      try {
        await d.dropTable(t);
        console.log('  ✓ dropped ' + t);
        ok++;
      } catch (e) {
        console.error('  ✗ ' + t + ' : ' + (e.message ?? e));
        fail++;
      }
    }
    await d.disconnect();
    console.log('\nDropped : ' + ok + ' · failed : ' + fail);
  " 2>&1
  echo
  pause
}

# ------------------------------------------------------------
# seed : restore TS seed scripts from .prisma.bak (undo install-bridge)
# ------------------------------------------------------------
action_seed_restore_scripts() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Restore seed scripts from *.prisma.bak${RESET}"
  echo
  echo -e "  ${DIM}Scans for seed-like .prisma.bak files that were rewritten by install-bridge${RESET}"
  echo -e "  ${DIM}and moves each backup back to its original filename.${RESET}"
  echo
  local cli_dir
  cli_dir="$(cd "$(dirname "$0")/.." && pwd)"
  echo -e "${DIM}\$ node install-bridge.mjs --restore-seeds --project \"$PROJECT_ROOT\"${RESET}"
  node "$cli_dir/bin/install-bridge.mjs" --restore-seeds --project "$PROJECT_ROOT"
  echo
  if confirm "Apply the restoration above?"; then
    node "$cli_dir/bin/install-bridge.mjs" --restore-seeds --apply --project "$PROJECT_ROOT"
  else
    dim "  Skipped."
  fi
  pause
}

# ------------------------------------------------------------
# seed : run TS seed scripts via tsx (or node --loader ts-node)
# ------------------------------------------------------------
action_seed_run_scripts() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Run seed scripts${RESET}"
  echo
  # Candidate scripts : prisma/seed.ts, scripts/seed*.{ts,js}, scripts/seed.ts
  local -a candidates=()
  [[ -f "$PROJECT_ROOT/prisma/seed.ts" ]] && candidates+=("$PROJECT_ROOT/prisma/seed.ts")
  [[ -f "$PROJECT_ROOT/prisma/seed.js" ]] && candidates+=("$PROJECT_ROOT/prisma/seed.js")
  if [[ -d "$PROJECT_ROOT/scripts" ]]; then
    while IFS= read -r f; do candidates+=("$f"); done < <(
      find "$PROJECT_ROOT/scripts" -maxdepth 2 \( -name 'seed-*.ts' -o -name 'seed-*.js' -o -name 'seed.ts' -o -name 'seed.js' \) 2>/dev/null | sort
    )
  fi
  if [[ ${#candidates[@]} -eq 0 ]]; then
    warn "No seed scripts found under prisma/ or scripts/."
    dim "  Expected : prisma/seed.ts | scripts/seed.ts | scripts/seed-*.ts (or .js)"
    pause
    return
  fi
  echo -e "  Found ${CYAN}${#candidates[@]}${RESET} seed script(s):"
  local i=1
  for f in "${candidates[@]}"; do
    echo -e "    ${CYAN}$i${RESET}) ${f#$PROJECT_ROOT/}"
    ((i++))
  done
  echo -e "    ${CYAN}a${RESET}) Run ALL sequentially"
  echo
  local pick
  pick=$(ask "Choice" "a")
  local runner="npx --yes tsx"
  command -v tsx >/dev/null && runner="tsx"
  if [[ "$pick" == "a" || "$pick" == "A" ]]; then
    for f in "${candidates[@]}"; do
      echo -e "${CYAN}▶ ${runner} ${f#$PROJECT_ROOT/}${RESET}"
      (cd "$PROJECT_ROOT" && $runner "$f") || { warn "Script failed: $f"; pause; return; }
    done
    ok "All seed scripts ran successfully."
  elif [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#candidates[@]} )); then
    local f="${candidates[$((pick-1))]}"
    echo -e "${CYAN}▶ ${runner} ${f#$PROJECT_ROOT/}${RESET}"
    (cd "$PROJECT_ROOT" && $runner "$f") && ok "Done." || warn "Script failed."
  else
    warn "Unknown choice"
  fi
  pause
}

# ------------------------------------------------------------
# seed : hash plain-text passwords
# ------------------------------------------------------------

action_seed_hash_passwords() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Hash plain-text passwords in seed files${RESET}"
  echo

  local seed_dir="$CONFIG_DIR/seeds"
  local count
  count=$(ls -1 "$seed_dir"/*.json 2>/dev/null | wc -l)
  if [[ $count -eq 0 ]]; then
    err "No seed files in $seed_dir (menu S → 1 first)"
    pause; return
  fi

  echo "Auto-detects fields named :"
  dim "  password, passwordHash, hashedPassword, pwd, userPassword"
  echo
  echo "Skips values that are already bcrypt hashes (start with \$2a\$ / \$2b\$ / \$2y\$, 60 chars)"
  echo

  local cost
  cost=$(ask "bcrypt cost factor" "${BCRYPT_COST:-10}")
  if ! confirm "Hash all plain passwords in $seed_dir ?"; then
    return
  fi

  # Ensure bcryptjs is available
  ensure_pkg "bcryptjs" || { pause; return; }

  cat > "$CONFIG_DIR/seed-hash.mjs" <<EOF
import { readdirSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import bcrypt from 'bcryptjs';

const SEEDDIR = '$seed_dir';
const COST    = $cost;

// Field names commonly used for passwords
const PASSWORD_FIELDS = ['password', 'passwordHash', 'hashedPassword', 'pwd', 'userPassword'];

// Test if a string is already a bcrypt hash
const isBcrypt = v => typeof v === 'string' && /^\\\$2[ayb]\\\$\\d{1,2}\\\$/.test(v) && v.length === 60;

let totalHashed = 0;
let totalSkipped = 0;
const summary = [];

for (const f of readdirSync(SEEDDIR).filter(x => x.endsWith('.json'))) {
  const path = join(SEEDDIR, f);
  let data;
  try { data = JSON.parse(readFileSync(path, 'utf8')); }
  catch { continue; }

  if (!Array.isArray(data)) continue;

  let hashed = 0, skipped = 0;
  for (const row of data) {
    for (const field of PASSWORD_FIELDS) {
      const val = row[field];
      if (typeof val !== 'string' || val.length === 0) continue;
      if (isBcrypt(val)) { skipped++; continue; }
      row[field] = bcrypt.hashSync(val, COST);
      hashed++;
    }
  }

  if (hashed > 0) {
    writeFileSync(path, JSON.stringify(data, null, 2));
    summary.push({ file: f, hashed, skipped });
  }
  totalHashed  += hashed;
  totalSkipped += skipped;
}

for (const s of summary) {
  console.log('  \u2713 ' + s.file + ' : ' + s.hashed + ' hashed' + (s.skipped ? ' (+ ' + s.skipped + ' already hashed)' : ''));
}
console.log();
console.log('Total : ' + totalHashed + ' hashed, ' + totalSkipped + ' already-hashed skipped');
if (totalHashed === 0 && totalSkipped === 0) {
  console.log('No password fields found.');
}
EOF
  cd "$PROJECT_ROOT"
  node "$CONFIG_DIR/seed-hash.mjs" 2>&1 | tee "$LOG_DIR/seed-hash.log"
  echo
  pause
}

# ------------------------------------------------------------
# seed : upload / import
# ------------------------------------------------------------

action_seed_upload() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Upload seed file(s)${RESET}"
  echo
  local seed_dir="$CONFIG_DIR/seeds"
  mkdir -p "$seed_dir"

  echo "Supported forms :"
  dim "  (a) Single file with all collections :   seeds.json  → { users: [...], posts: [...] }"
  dim "  (b) One file per collection (preferred): seeds/users.json = [...rows...]"
  dim "  (c) CSV (header row = field names) :     seeds/users.csv"
  echo
  local src
  src=$(ask "Path to seed file or directory (tilde OK)")
  [[ -z "$src" ]] && return
  src="${src/#\~/$HOME}"
  [[ ! -e "$src" ]] && { err "Path does not exist : $src"; pause; return; }

  if [[ -d "$src" ]]; then
    local n=0
    for f in "$src"/*.{json,csv}; do
      [[ -f "$f" ]] || continue
      cp "$f" "$seed_dir/" && n=$((n+1))
    done
    ok "Imported $n file(s) from $src → $seed_dir"
  elif [[ "$src" =~ \.json$ ]]; then
    # Case (a) or (b) — detect
    local is_map
    is_map=$(node -e "
      const d = JSON.parse(require('fs').readFileSync('$src','utf8'));
      console.log(!Array.isArray(d) && typeof d === 'object' ? 'yes' : 'no');
    " 2>/dev/null)
    if [[ "$is_map" == "yes" ]]; then
      # Split into per-collection files
      node -e "
        const { writeFileSync } = require('fs');
        const d = JSON.parse(require('fs').readFileSync('$src','utf8'));
        let n = 0;
        for (const [coll, rows] of Object.entries(d)) {
          if (!Array.isArray(rows)) continue;
          writeFileSync('$seed_dir/' + coll + '.json', JSON.stringify(rows, null, 2));
          console.log('  wrote ' + coll + '.json (' + rows.length + ' rows)');
          n++;
        }
        console.log('split ' + n + ' collections');
      " 2>&1 | tee -a "$LOG_DIR/seed.log"
    else
      # Single-collection array
      local base; base=$(basename "$src")
      cp "$src" "$seed_dir/$base"
      ok "Copied → $seed_dir/$base"
    fi
  elif [[ "$src" =~ \.csv$ ]]; then
    local base; base=$(basename "$src" .csv)
    # Convert CSV to JSON (minimal — header row + comma-separated values)
    node -e "
      const { readFileSync, writeFileSync } = require('fs');
      const lines = readFileSync('$src','utf8').split(/\r?\n/).filter(Boolean);
      if (lines.length < 2) { console.error('CSV too small'); process.exit(1); }
      const headers = lines[0].split(',');
      const rows = lines.slice(1).map(line => {
        const vals = line.split(',');
        const o = {};
        headers.forEach((h, i) => { o[h.trim()] = vals[i]?.trim() ?? null; });
        return o;
      });
      writeFileSync('$seed_dir/${base}.json', JSON.stringify(rows, null, 2));
      console.log('Converted ' + rows.length + ' rows → $seed_dir/${base}.json');
    " 2>&1 | tee -a "$LOG_DIR/seed.log"
  else
    err "Unsupported file type — use .json or .csv"
  fi
  pause
}

# ------------------------------------------------------------
# seed : generate empty templates
# ------------------------------------------------------------

action_seed_generate_templates() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Generate empty seed templates${RESET}"
  echo

  if [[ ! -f "$GENERATED_DIR/entities.json" ]]; then
    err "No entities.json — run menu 1 (Convert) first"
    pause; return
  fi

  local seed_dir="$CONFIG_DIR/seeds"
  mkdir -p "$seed_dir"

  if ! confirm "Generate a template .json per entity (will NOT overwrite existing files)?"; then
    return
  fi

  node -e "
    const { readFileSync, writeFileSync, existsSync } = require('fs');
    const entities = JSON.parse(readFileSync('$GENERATED_DIR/entities.json','utf8'));
    let created = 0, skipped = 0;
    for (const e of entities) {
      const file = '$seed_dir/' + e.collection + '.json';
      if (existsSync(file)) { skipped++; continue; }

      // Build a sample row from field defaults
      const sample = {};
      for (const [k, def] of Object.entries(e.fields ?? {})) {
        if (def.default !== undefined && typeof def.default !== 'object') sample[k] = def.default;
        else if (def.type === 'string' && def.enum) sample[k] = def.enum[0] ?? '';
        else if (def.type === 'string')  sample[k] = 'example';
        else if (def.type === 'number')  sample[k] = 0;
        else if (def.type === 'boolean') sample[k] = false;
        else if (def.type === 'date')    sample[k] = new Date().toISOString();
        else if (def.type === 'json')    sample[k] = {};
        else if (def.type === 'array')   sample[k] = [];
      }
      writeFileSync(file, JSON.stringify([sample], null, 2));
      created++;
    }
    console.log('Created ' + created + ', skipped ' + skipped + ' (already existed)');
  " 2>&1 | tee -a "$LOG_DIR/seed.log"
  pause
}

# ------------------------------------------------------------
# seed : validate + apply
# ------------------------------------------------------------

action_seed_apply() {
  local mode="$1"   # validate | apply | upsert | truncate-apply
  header
  local title="Validate seeds (dry-run)"
  case "$mode" in
    apply)          title="Apply seeds (insert)"           ;;
    upsert)         title="Apply seeds (upsert by id)"     ;;
    truncate-apply) title="DESTRUCTIVE: truncate + apply"  ;;
  esac
  echo -e "${BOLD}${MAGENTA}▶ $title${RESET}"
  echo

  load_env

  if [[ ! -f "$GENERATED_DIR/entities.json" ]]; then
    err "No entities.json — run menu 1 (Convert) first"
    pause; return
  fi

  local seed_dir="$CONFIG_DIR/seeds"
  local file_count
  file_count=$(ls -1 "$seed_dir"/*.json 2>/dev/null | wc -l)
  if [[ $file_count -eq 0 ]]; then
    err "No seed files in $seed_dir — use menu S → 1 or 2"
    pause; return
  fi

  if [[ "$mode" == "truncate-apply" ]]; then
    warn "This will TRUNCATE all tables listed in seeds before inserting."
    confirm "Really wipe the tables ?" || return
    if ! confirm "Are you SURE ? This cannot be undone." ; then return; fi
  fi

  if [[ "$mode" != "validate" ]]; then
    if [[ -z "${DB_DIALECT:-}" || -z "${SGBD_URI:-}" ]]; then
      err "No DB configured (menu 2 first)"
      pause; return
    fi
    # Dialect specific driver
    ensure_pkg "@mostajs/orm" || return
    ensure_dialect_driver "$DB_DIALECT" || warn "Driver for $DB_DIALECT may be missing"
  fi

  local orm_path
  orm_path=$(resolve_pkg_path "@mostajs/orm" 2>/dev/null)
  if [[ "$mode" != "validate" ]] && [[ -z "$orm_path" ]]; then
    err "Cannot resolve @mostajs/orm — install it first"
    pause; return
  fi

  cat > "$CONFIG_DIR/seed-runner.mjs" <<EOF
import { readFileSync, readdirSync } from 'fs';
import { join } from 'path';

const MODE    = process.argv[2] ?? 'validate';
const SEEDDIR = process.argv[3];
const ENTPATH = process.argv[4];
const DIALECT = process.env.DB_DIALECT ?? '';
const URI     = process.env.SGBD_URI ?? '';

function stripScheme(u) {
  if (u.startsWith('sqlite://')) return u.slice(9);
  if (u.startsWith('sqlite:'))   return u.slice(7);
  return u;
}

const entities = JSON.parse(readFileSync(ENTPATH, 'utf8'));
const entityByCollection = Object.fromEntries(entities.map(e => [e.collection, e]));
const entityByName       = Object.fromEntries(entities.map(e => [e.name, e]));

// ---------- Load seed files ----------
const seeds = {};  // collection -> rows
for (const f of readdirSync(SEEDDIR).filter(x => x.endsWith('.json'))) {
  const coll = f.replace(/\\.json$/, '');
  let data;
  try {
    data = JSON.parse(readFileSync(join(SEEDDIR, f), 'utf8'));
  } catch (e) {
    console.error('  \u2717 ' + f + ' : invalid JSON (' + e.message + ')');
    continue;
  }
  if (!Array.isArray(data)) {
    console.error('  \u2717 ' + f + ' : file is not an array of rows');
    continue;
  }
  seeds[coll] = data;
}

// ---------- Validate ----------
const PASSWORD_FIELDS = ['password', 'passwordHash', 'hashedPassword', 'pwd', 'userPassword'];
const isBcrypt = v => typeof v === 'string' && /^\\\$2[ayb]\\\$\\d{1,2}\\\$/.test(v) && v.length === 60;

function validateRow(row, entity) {
  const errors = [];
  const fieldNames = new Set(Object.keys(entity.fields ?? {}));
  const relationNames = new Set(Object.keys(entity.relations ?? {}));
  // FK columns generated by relations (many-to-one / one-to-one joinColumn, plus
  // the conventional <relName>Id fallback). These appear in seed JSONs as direct
  // FK values ("userId": "user-admin") and must NOT be flagged as "unknown field".
  const relationFkColumns = new Set();
  for (const [relName, rel] of Object.entries(entity.relations ?? {})) {
    if (rel && (rel.type === 'many-to-one' || rel.type === 'one-to-one')) {
      relationFkColumns.add(rel.joinColumn || (relName + 'Id'));
    }
  }
  // Required fields
  for (const [k, def] of Object.entries(entity.fields ?? {})) {
    if (def.required && (row[k] === undefined || row[k] === null)) {
      errors.push('missing required field "' + k + '"');
    }
    // Enum
    if (def.enum && row[k] !== undefined && !def.enum.includes(row[k])) {
      errors.push('field "' + k + '" not in enum ' + JSON.stringify(def.enum) + ' (got: ' + JSON.stringify(row[k]) + ')');
    }
    // Type basic check
    if (row[k] !== undefined && row[k] !== null) {
      const val = row[k];
      const t = def.type;
      if (t === 'number'  && typeof val !== 'number') errors.push('field "' + k + '" expected number, got ' + typeof val);
      if (t === 'boolean' && typeof val !== 'boolean') errors.push('field "' + k + '" expected boolean, got ' + typeof val);
      if (t === 'string'  && typeof val !== 'string') errors.push('field "' + k + '" expected string, got ' + typeof val);
      if (t === 'date'    && typeof val !== 'string' && !(val instanceof Date)) errors.push('field "' + k + '" expected date, got ' + typeof val);
    }
  }
  // Unknown fields (warn-level)
  const warnings = [];
  for (const k of Object.keys(row)) {
    if (!fieldNames.has(k) && !relationNames.has(k) && !relationFkColumns.has(k) && k !== 'id' && k !== '_id') {
      warnings.push('unknown field "' + k + '" (not in schema)');
    }
  }
  // Password fields that look like plain-text (not bcrypt)
  for (const pf of PASSWORD_FIELDS) {
    if (row[pf] !== undefined && row[pf] !== null && row[pf] !== '' && !isBcrypt(row[pf])) {
      warnings.push('field "' + pf + '" does not look like a bcrypt hash — run menu S \u2192 h to hash');
    }
  }
  return { errors, warnings };
}

let totalRows = 0;
let totalErrors = 0;
let totalWarnings = 0;
const reports = [];

for (const [coll, rows] of Object.entries(seeds)) {
  const entity = entityByCollection[coll] ?? entityByName[coll];
  if (!entity) {
    console.error('  \u2717 ' + coll + ' : no matching entity (collection or name)');
    continue;
  }
  let collErrs = 0, collWarns = 0;
  rows.forEach((row, i) => {
    const { errors, warnings } = validateRow(row, entity);
    if (errors.length) {
      collErrs += errors.length;
      for (const e of errors) console.error('  \u2717 ' + coll + '[' + i + '] : ' + e);
    }
    collWarns += warnings.length;
    for (const w of warnings) console.warn('  \u26A0 ' + coll + '[' + i + '] : ' + w);
  });
  const mark = collErrs === 0 ? '\u2713' : '\u2717';
  console.log('  ' + mark + ' ' + coll + ' : ' + rows.length + ' rows, ' + collErrs + ' errors, ' + collWarns + ' warnings');
  reports.push({ coll, rows: rows.length, errors: collErrs, warnings: collWarns });
  totalRows    += rows.length;
  totalErrors  += collErrs;
  totalWarnings += collWarns;
}

console.log();
console.log('Validation : ' + totalRows + ' rows · ' + totalErrors + ' errors · ' + totalWarnings + ' warnings');

if (MODE === 'validate') {
  process.exit(totalErrors > 0 ? 1 : 0);
}

if (totalErrors > 0) {
  console.error('Refusing to apply : fix validation errors first (run menu S → 3).');
  process.exit(2);
}

// ---------- Apply ----------
const { getDialect } = await import('$orm_path');
const uri = DIALECT === 'sqlite' ? stripScheme(URI) : URI;
const d = await getDialect({ dialect: DIALECT, uri, schemaStrategy: 'update' });
await d.initSchema(entities);

let inserted = 0, failed = 0;

for (const [coll, rows] of Object.entries(seeds)) {
  const entity = entityByCollection[coll] ?? entityByName[coll];
  if (!entity) continue;

  if (MODE === 'truncate-apply') {
    try {
      await d.deleteMany(entity, {});
      console.log('  \u2205 truncated ' + coll);
    } catch (e) {
      console.error('  \u2717 truncate ' + coll + ' : ' + (e.message ?? e));
    }
  }

  for (const row of rows) {
    try {
      if (MODE === 'upsert' && (row.id || row._id)) {
        const id = row.id ?? row._id;
        const existing = await d.findById(entity, String(id)).catch(() => null);
        if (existing) {
          await d.update(entity, String(id), row);
        } else {
          await d.create(entity, row);
        }
      } else {
        await d.create(entity, row);
      }
      inserted++;
    } catch (e) {
      failed++;
      console.error('  \u2717 ' + coll + ' : ' + (e.message ?? e));
    }
  }
  console.log('  \u2713 ' + coll + ' done');
}

console.log();
console.log('Applied : ' + inserted + ' inserted · ' + failed + ' failed');
await d.disconnect().catch(() => {});
process.exit(failed > 0 ? 1 : 0);
EOF

  cd "$PROJECT_ROOT" || return
  export DB_DIALECT="${DB_DIALECT:-}"
  export SGBD_URI="${SGBD_URI:-}"
  node "$CONFIG_DIR/seed-runner.mjs" "$mode" "$seed_dir" "$GENERATED_DIR/entities.json" 2>&1 | tee "$LOG_DIR/seed-${mode}.log"
  echo
  pause
}

# ------------------------------------------------------------
# seed : dump current DB → seed files
# ------------------------------------------------------------

action_seed_dump() {
  header
  echo -e "${BOLD}${MAGENTA}▶ Dump current DB rows${RESET}"
  echo
  load_env
  if [[ -z "${DB_DIALECT:-}" || -z "${SGBD_URI:-}" ]]; then
    err "No DB configured (menu 2 first)"
    pause; return
  fi
  if [[ ! -f "$GENERATED_DIR/entities.json" ]]; then
    err "No entities.json — run menu 1 (Convert) first"
    pause; return
  fi
  ensure_pkg "@mostajs/orm" || return
  local orm_path
  orm_path=$(resolve_pkg_path "@mostajs/orm") || return
  local dump_dir="$CONFIG_DIR/seeds-dump"
  mkdir -p "$dump_dir"

  cat > "$CONFIG_DIR/seed-dump.mjs" <<EOF
import { readFileSync, writeFileSync } from 'fs';
import { getDialect } from '$orm_path';

const entities = JSON.parse(readFileSync('$GENERATED_DIR/entities.json','utf8'));
const DIALECT = process.env.DB_DIALECT;
let URI = process.env.SGBD_URI;
if (DIALECT === 'sqlite') {
  if (URI.startsWith('sqlite://')) URI = URI.slice(9);
  else if (URI.startsWith('sqlite:')) URI = URI.slice(7);
}
const d = await getDialect({ dialect: DIALECT, uri: URI });
await d.initSchema(entities);

for (const e of entities) {
  const rows = await d.find(e, {}, { limit: 10000 });
  writeFileSync('$dump_dir/' + e.collection + '.json', JSON.stringify(rows, null, 2));
  console.log('  \u2713 ' + e.collection + ' : ' + rows.length + ' rows');
}
await d.disconnect().catch(() => {});
EOF
  cd "$PROJECT_ROOT"
  DB_DIALECT="$DB_DIALECT" SGBD_URI="$SGBD_URI" node "$CONFIG_DIR/seed-dump.mjs" 2>&1 | tee "$LOG_DIR/seed-dump.log"
  echo
  ok "Dump written to $dump_dir"
  pause
}

action_seed_clear() {
  header
  local seed_dir="$CONFIG_DIR/seeds"
  local count; count=$(ls -1 "$seed_dir"/*.json 2>/dev/null | wc -l)
  [[ $count -eq 0 ]] && { warn "Already empty"; pause; return; }
  if confirm "Delete all $count seed files in $seed_dir ?"; then
    rm -f "$seed_dir"/*.json
    ok "Cleared"
  fi
  pause
}

action_seed_show() {
  header
  local seed_dir="$CONFIG_DIR/seeds"
  local files=()
  for f in "$seed_dir"/*.json; do [[ -f "$f" ]] && files+=("$f"); done
  [[ ${#files[@]} -eq 0 ]] && { warn "No seed files"; pause; return; }
  echo "Pick a file to display :"
  local i=1
  for f in "${files[@]}"; do
    echo -e "  ${CYAN}$i${RESET}) $(basename "$f")"
    i=$((i+1))
  done
  local num; num=$(ask "Number" 1)
  local idx=$((num-1))
  [[ $idx -ge 0 && $idx -lt ${#files[@]} ]] && ${PAGER:-less} "${files[$idx]}"
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
# `mostajs init` — scaffold a new project
# ============================================================
#
# Creates every file a fresh project needs to run on the bridge :
#   - .env with PORT / DB_DIALECT / SGBD_URI / AUTH_SECRET
#   - prisma/schema.prisma (minimal User model — starting point)
#   - src/lib/db.ts (createPrismaLikeDb)
#   - .mostajs/config.env (mirrors .env for the seed-runner)
#   - .mostajs/generated/entities.json (empty array, filled by menu 1)
#
# Dialect defaults to sqlite ./data.sqlite. Pass --dialect=postgres etc.
# Refuses to overwrite existing files unless --force.

action_cli_init() {
  local dialect="sqlite"
  local uri=""
  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dialect) dialect="$2"; shift 2 ;;
      --dialect=*) dialect="${1#*=}"; shift ;;
      --uri)     uri="$2"; shift 2 ;;
      --uri=*)   uri="${1#*=}"; shift ;;
      --force|-f) force=1; shift ;;
      *) warn "Unknown flag: $1"; shift ;;
    esac
  done

  # Default URIs per dialect
  if [[ -z "$uri" ]]; then
    case "$dialect" in
      sqlite)      uri="./data.sqlite" ;;
      postgres)    uri="postgres://user:pass@localhost:5432/mydb" ;;
      mysql)       uri="mysql://user:pass@localhost:3306/mydb" ;;
      mariadb)     uri="mariadb://user:pass@localhost:3306/mydb" ;;
      mongodb)     uri="mongodb://user:pass@localhost:27017/mydb" ;;
      oracle)      uri="oracle://user:pass@localhost:1521/XE" ;;
      mssql)       uri="mssql://user:pass@localhost:1433/mydb" ;;
      cockroachdb) uri="postgresql://user:pass@localhost:26257/mydb?sslmode=disable" ;;
      *)           uri="./data.sqlite"; dialect="sqlite" ;;
    esac
  fi

  header
  echo -e "${BOLD}${MAGENTA}▶ mostajs init — scaffold a bridge-ready project${RESET}"
  echo
  echo -e "  Dialect : ${CYAN}${dialect}${RESET}"
  echo -e "  URI     : ${DIM}${uri}${RESET}"
  echo -e "  Root    : ${DIM}${PROJECT_ROOT}${RESET}"
  echo

  local created=0 skipped=0

  write_if_missing() {
    local path="$1"; local content="$2"
    if [[ -f "$PROJECT_ROOT/$path" && $force -eq 0 ]]; then
      dim "  - skip $path (exists — use --force to overwrite)"
      ((skipped++))
      return
    fi
    mkdir -p "$(dirname "$PROJECT_ROOT/$path")"
    printf '%s' "$content" > "$PROJECT_ROOT/$path"
    ok "created $path"
    ((created++))
  }

  # --- .env ---
  local secret
  secret=$(node -e "console.log(require('crypto').randomBytes(32).toString('base64'))" 2>/dev/null || echo 'CHANGE-ME-IN-PROD')
  write_if_missing ".env" "\
# Port — used by next dev / start (reads PORT from here)
PORT=3000

# Database — consumed by @mostajs/orm-bridge (createPrismaLikeDb)
DB_DIALECT=${dialect}
SGBD_URI=${uri}
DB_SCHEMA_STRATEGY=update

# NextAuth (if you use it)
NEXTAUTH_URL=http://localhost:3000
NEXT_PUBLIC_APP_URL=http://localhost:3000
AUTH_SECRET=${secret}
"

  # --- .mostajs/config.env (mirror for the seed-runner) ---
  write_if_missing ".mostajs/config.env" "\
DB_DIALECT=${dialect}
SGBD_URI=${uri}
DB_SCHEMA_STRATEGY=update
APP_PORT=3000
"

  # --- .mostajs/generated/entities.json (empty — filled by menu 1) ---
  write_if_missing ".mostajs/generated/entities.json" "[]
"

  # --- prisma/schema.prisma (minimal starter) ---
  # Prisma's valid providers : sqlite, postgresql, mysql, mongodb, sqlserver, cockroachdb
  local provider="$dialect"
  case "$dialect" in
    postgres|postgresql) provider="postgresql" ;;
    mssql)               provider="sqlserver" ;;
    mariadb)             provider="mysql" ;;
    oracle|db2|hana|hsqldb|spanner|sybase) provider="sqlite" ;;  # Prisma has no native provider — keep sqlite placeholder
  esac
  write_if_missing "prisma/schema.prisma" "\
// Minimal starter — edit freely. Run 'mostajs' menu 1 to convert to EntitySchema.
generator client {
  provider = \"prisma-client-js\"
}

datasource db {
  provider = \"${provider}\"
  url      = env(\"DATABASE_URL\")
}

model User {
  id            String   @id @default(uuid())
  email         String   @unique
  password      String
  name          String?
  createdAt     DateTime @default(now())
  updatedAt     DateTime @updatedAt
}
"

  # --- src/lib/db.ts (createPrismaLikeDb) ---
  write_if_missing "src/lib/db.ts" "\
// Generated by 'mostajs init' — @mostajs/orm-bridge entry point.
// Every Prisma-style db.User.findUnique(...) call below is routed to
// @mostajs/orm (13 dialects). Edit DB_DIALECT / SGBD_URI in .env to switch.
import { createPrismaLikeDb } from '@mostajs/orm-bridge/prisma-client'

export const db = createPrismaLikeDb()
"

  echo
  echo -e "  ${BOLD}${created}${RESET} file(s) created, ${DIM}${skipped}${RESET} skipped"
  echo
  echo -e "  ${BOLD}Next steps${RESET} :"
  echo -e "    ${CYAN}1.${RESET} npm install @mostajs/orm @mostajs/orm-bridge @mostajs/orm-cli --legacy-peer-deps"
  echo -e "    ${CYAN}2.${RESET} Edit ${DIM}prisma/schema.prisma${RESET} — add your models"
  echo -e "    ${CYAN}3.${RESET} ${CYAN}mostajs${RESET} → menu 1 (Convert) → menu 3 (init DDL)"
  echo -e "    ${CYAN}4.${RESET} ${CYAN}mostajs${RESET} → menu S (Seeds) — populate, hash, apply"
  echo -e "    ${CYAN}5.${RESET} ${CYAN}npm run dev${RESET}"
}

# ============================================================
# `mostajs migrate` — incremental DDL diff / apply / status
# ============================================================
#
# Subcommands :
#   diff    — list ALTERs needed to make the live DB match entities.json
#   apply   — execute those ALTERs (prompts for confirmation, --yes to skip)
#   status  — show entities.json count + live tables count + missing columns

action_cli_migrate() {
  local sub="${1:-}"
  [[ -z "$sub" ]] && { action_migrate_help; return; }
  shift
  case "$sub" in
    diff|d)     action_migrate_diff "$@" ;;
    apply|a)    action_migrate_apply "$@" ;;
    status|s)   action_migrate_status "$@" ;;
    help|h|--help) action_migrate_help ;;
    *) err "Unknown migrate subcommand: $sub"; action_migrate_help; return 1 ;;
  esac
}

action_migrate_help() {
  cat <<EOF

  ${BOLD}mostajs migrate${RESET} — incremental schema migration

    ${CYAN}diff${RESET}     show ALTER statements the DB needs to match entities.json
    ${CYAN}apply${RESET}    execute those ALTERs (prompts for confirmation)
             flags : --yes (skip confirmation)
    ${CYAN}status${RESET}   show live-vs-schema summary per entity

  Every subcommand honors DB_DIALECT + SGBD_URI from ${DIM}.mostajs/config.env${RESET}.

EOF
}

# Node helper : compare live columns vs schema.fields and emit ALTER plan as JSON.
# Outputs to stdout : { changes: [{ table, column, sql }], ok: bool }
_migrate_compute_plan() {
  load_env
  local entities_json="$GENERATED_DIR/entities.json"
  if [[ ! -f "$entities_json" ]]; then
    err "No entities.json — run menu 1 (Convert) first."
    return 1
  fi
  ENT_PATH="$entities_json" DIALECT="$DB_DIALECT" URI="$SGBD_URI" \
  node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import { getDialect } from '${PROJECT_ROOT}/node_modules/@mostajs/orm/dist/index.js';
    const entities = JSON.parse(readFileSync(process.env.ENT_PATH, 'utf8'));
    const d = await getDialect({ dialect: process.env.DIALECT, uri: process.env.URI, schemaStrategy: 'none' });

    // Use the dialect's own introspection — protected method, exposed via cast
    const changes = [];
    for (const e of entities) {
      let live;
      try {
        live = await (d).getExistingColumns(e.collection);
      } catch {
        changes.push({ table: e.collection, column: '*', sql: '-- (cannot introspect — run menu 3 first)' });
        continue;
      }
      const hasCol = (name) => {
        const lc = name.toLowerCase();
        for (const c of live) if (c.toLowerCase() === lc) return true;
        return false;
      };
      // Field columns
      for (const [name, f] of Object.entries(e.fields || {})) {
        if (name === '_id') continue;
        if (hasCol(name)) continue;
        // Reconstruct the ALTER — d has fieldToSqlType + getIdColumnType + quoteIdentifier
        const q = (n) => (d).quoteIdentifier(n);
        let sql;
        if (name === 'id') {
          sql = 'ALTER TABLE ' + q(e.collection) + ' ADD ' + q('id') + ' ' + (d).getIdColumnType();
        } else {
          sql = 'ALTER TABLE ' + q(e.collection) + ' ADD ' + q(name) + ' ' + (d).fieldToSqlType(f);
        }
        changes.push({ table: e.collection, column: name, sql });
      }
      // Relation FK columns
      for (const [rname, rel] of Object.entries(e.relations || {})) {
        if (rel.type !== 'many-to-one' && rel.type !== 'one-to-one') continue;
        const colName = rel.joinColumn || (rname + 'Id');
        if (hasCol(colName)) continue;
        const q = (n) => (d).quoteIdentifier(n);
        changes.push({
          table: e.collection, column: colName,
          sql: 'ALTER TABLE ' + q(e.collection) + ' ADD ' + q(colName) + ' ' + (d).getIdColumnType(),
        });
      }
    }
    await d.disconnect();
    console.log(JSON.stringify({ ok: true, changes }));
  "
}

action_migrate_diff() {
  header
  echo -e "${BOLD}${MAGENTA}▶ mostajs migrate diff${RESET}"
  echo
  local plan_json
  plan_json=$(_migrate_compute_plan) || { pause; return 1; }
  local count
  count=$(echo "$plan_json" | node -e "process.stdin.on('data',d=>{console.log(JSON.parse(d).changes.length)})" 2>/dev/null || echo '?')
  if [[ "$count" == "0" ]]; then
    ok "Schema is up to date — nothing to ALTER."
    return 0
  fi
  echo -e "  ${BOLD}${count}${RESET} pending change(s) :"
  echo
  echo "$plan_json" | node -e "
    let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
      const p = JSON.parse(d);
      for (const ch of p.changes) console.log('  ' + ch.sql + ';');
    });
  "
  echo
  echo -e "  Run ${CYAN}mostajs migrate apply${RESET} to execute these statements."
}

action_migrate_apply() {
  local auto_yes=0
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && auto_yes=1
  header
  echo -e "${BOLD}${MAGENTA}▶ mostajs migrate apply${RESET}"
  echo
  local plan_json
  plan_json=$(_migrate_compute_plan) || return 1
  local count
  count=$(echo "$plan_json" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).changes.length))" 2>/dev/null || echo 0)
  if [[ "$count" == "0" ]]; then
    ok "Schema is up to date — nothing to ALTER."
    return 0
  fi
  echo "  Pending : ${BOLD}${count}${RESET} statement(s)"
  echo
  echo "$plan_json" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{for(const ch of JSON.parse(d).changes) console.log('  ' + ch.sql + ';')})"
  echo
  if [[ $auto_yes -eq 0 ]]; then
    if ! confirm "Execute these ALTER statements?"; then
      dim "  Aborted."
      return
    fi
  fi

  # Execute
  load_env
  PLAN="$plan_json" DIALECT="$DB_DIALECT" URI="$SGBD_URI" \
  node --input-type=module -e "
    import { getDialect } from '${PROJECT_ROOT}/node_modules/@mostajs/orm/dist/index.js';
    const plan = JSON.parse(process.env.PLAN);
    const d = await getDialect({ dialect: process.env.DIALECT, uri: process.env.URI, schemaStrategy: 'none' });
    let ok = 0, fail = 0;
    for (const ch of plan.changes) {
      try {
        await d.executeRun(ch.sql, []);
        console.log('  ✓ ' + ch.table + '.' + ch.column);
        ok++;
      } catch (e) {
        console.error('  ✗ ' + ch.table + '.' + ch.column + ' : ' + e.message);
        fail++;
      }
    }
    await d.disconnect();
    console.log('\nApplied : ' + ok + ' ok, ' + fail + ' failed');
    process.exit(fail > 0 ? 1 : 0);
  "
}

action_migrate_status() {
  header
  echo -e "${BOLD}${MAGENTA}▶ mostajs migrate status${RESET}"
  echo
  load_env
  local ent_json="$GENERATED_DIR/entities.json"
  if [[ ! -f "$ent_json" ]]; then
    err "No entities.json — run menu 1 (Convert) first."
    return 1
  fi
  ENT_PATH="$ent_json" DIALECT="$DB_DIALECT" URI="$SGBD_URI" \
  node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import { getDialect } from '${PROJECT_ROOT}/node_modules/@mostajs/orm/dist/index.js';
    const entities = JSON.parse(readFileSync(process.env.ENT_PATH, 'utf8'));
    const d = await getDialect({ dialect: process.env.DIALECT, uri: process.env.URI, schemaStrategy: 'none' });
    let existing = 0, missing = 0, lagging = 0;
    for (const e of entities) {
      let live;
      try { live = await (d).getExistingColumns(e.collection); }
      catch { live = new Set(); }
      if (!live || live.size === 0) { console.log('  ✗ ' + e.collection + ' — table not found'); missing++; continue; }
      const hasCol = (n) => { const lc = n.toLowerCase(); for (const c of live) if (c.toLowerCase() === lc) return true; return false; };
      const schemaCols = Object.keys(e.fields || {});
      const need = schemaCols.filter(c => !hasCol(c));
      if (need.length) {
        console.log('  ⚠ ' + e.collection + ' — missing ' + need.length + ' column(s) : ' + need.join(', '));
        lagging++;
      } else {
        console.log('  ✓ ' + e.collection + ' (' + live.size + ' cols live, ' + schemaCols.length + ' in schema)');
        existing++;
      }
    }
    await d.disconnect();
    console.log('\n  ' + existing + ' up-to-date · ' + lagging + ' need migrate · ' + missing + ' missing');
  "
}

# ============================================================
# CLI SUBCOMMANDS (non-interactive)
# ============================================================

run_subcommand() {
  case "$1" in
    diagnose|diag|d)
      # mostajs diagnose [email] [password]
      # Walks through: config vs project datasource mismatch, DB connection,
      # user lookup, isActive check, bcrypt verification.
      local email="${2:-}"
      local password="${3:-}"
      action_diagnose_login "$email" "$password"
      ;;
    hash|h)
      # mostajs hash <plaintext> [cost]
      local pw="${2:-}"
      local cost="${3:-10}"
      [[ -z "$pw" ]] && { echo "Usage: mostajs hash <password> [cost=10]" >&2; exit 1; }
      # Try local project, then CLI's own node_modules (bcryptjs is a dep)
      local bcrypt_dir=""
      if [[ -d "$PROJECT_ROOT/node_modules/bcryptjs" ]]; then
        bcrypt_dir="$PROJECT_ROOT/node_modules/bcryptjs"
      else
        local cli_dir
        cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        [[ -d "$cli_dir/node_modules/bcryptjs" ]] && bcrypt_dir="$cli_dir/node_modules/bcryptjs"
      fi
      if [[ -z "$bcrypt_dir" ]]; then
        ensure_pkg "bcryptjs" >/dev/null 2>&1 || {
          err "bcryptjs not available. Install it manually : npm install bcryptjs"
          exit 1
        }
        bcrypt_dir="$PROJECT_ROOT/node_modules/bcryptjs"
      fi
      BCRYPT_PASSWORD="$pw" BCRYPT_COST="$cost" BCRYPT_DIR="$bcrypt_dir" node -e "
        const bcrypt = require(process.env.BCRYPT_DIR);
        const h = bcrypt.hashSync(process.env.BCRYPT_PASSWORD, parseInt(process.env.BCRYPT_COST, 10));
        console.log(h);
      "
      ;;
    verify|v)
      # mostajs verify <plaintext> <hash>
      local pw="${2:-}"
      local hashval="${3:-}"
      [[ -z "$pw" || -z "$hashval" ]] && { echo "Usage: mostajs verify <password> <hash>" >&2; exit 1; }
      local bcrypt_dir=""
      if [[ -d "$PROJECT_ROOT/node_modules/bcryptjs" ]]; then
        bcrypt_dir="$PROJECT_ROOT/node_modules/bcryptjs"
      else
        local cli_dir
        cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        [[ -d "$cli_dir/node_modules/bcryptjs" ]] && bcrypt_dir="$cli_dir/node_modules/bcryptjs"
      fi
      if [[ -z "$bcrypt_dir" ]]; then
        ensure_pkg "bcryptjs" >/dev/null 2>&1 || exit 1
        bcrypt_dir="$PROJECT_ROOT/node_modules/bcryptjs"
      fi
      BCRYPT_PASSWORD="$pw" BCRYPT_HASH="$hashval" BCRYPT_DIR="$bcrypt_dir" node -e "
        const bcrypt = require(process.env.BCRYPT_DIR);
        console.log(bcrypt.compareSync(process.env.BCRYPT_PASSWORD, process.env.BCRYPT_HASH) ? 'match' : 'no match');
      "
      ;;
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
    init)
      # mostajs init [--dialect sqlite|postgres|mongodb|...] [--force]
      # Scaffold a fresh project with bridge-ready layout :
      #   .env (PORT, DB_DIALECT, SGBD_URI, AUTH_SECRET)
      #   prisma/schema.prisma (minimal — User model only)
      #   src/lib/db.ts (createPrismaLikeDb)
      #   .mostajs/config.env (mirrors .env for the runner)
      #   .mostajs/generated/entities.json (empty array)
      shift
      action_cli_init "$@"
      ;;
    migrate|mig|m)
      # mostajs migrate <subcommand> [options]
      # Subcommands :
      #   diff    — show ALTER statements the target DB needs to match entities.json
      #   apply   — execute those ALTERs (with confirmation)
      #   status  — show what's in entities.json vs what's live in the DB
      shift
      action_cli_migrate "$@"
      ;;
    install-bridge|ib)
      # mostajs install-bridge [--apply] [--file X] [--project P] [--restore]
      # Codemod : scans the project for `new PrismaClient(...)` sites and rewrites
      # them in place to use createPrismaLikeDb() from @mostajs/orm-bridge.
      # Dry-run by default ; pass --apply to write the changes.
      local cli_dir
      cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
      shift
      node "$cli_dir/bin/install-bridge.mjs" "$@"
      ;;
    bootstrap|b)
      # mostajs bootstrap : the full zero-touch migration for a Prisma project.
      #   1. Rewrite every `new PrismaClient(...)` site (install-bridge --apply)
      #   2. npm install @mostajs/orm @mostajs/orm-bridge @mostajs/orm-adapter server-only
      #   3. Convert prisma/schema.prisma → entities.json
      #   4. Write .mostajs/config.env + init SQLite DDL
      #
      # Hard stop-on-error : no step proceeds if the previous one failed.
      local cli_dir
      cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
      detect_project
      [[ ${#DETECTED_TYPES[@]} -eq 0 ]] && { err "No schema found. Bootstrap needs a prisma/schema.prisma (or OpenAPI/JSONSchema)."; exit 1; }

      local BS_OK_CODEMOD=0 BS_OK_DEPS=0 BS_OK_CONVERT=0 BS_OK_DDL=0

      # ─── Step 1 ───
      echo -e "\n\e[1m▶ Step 1/4 : rewrite PrismaClient sites\e[0m"
      if node "$cli_dir/bin/install-bridge.mjs" --apply; then
        BS_OK_CODEMOD=1
      else
        err "Step 1 failed — codemod returned non-zero. Aborting."; exit 1
      fi

      # ─── Step 2 ───
      echo -e "\n\e[1m▶ Step 2/4 : install runtime deps (this can take 1-2 min)\e[0m"
      info "  installing : @mostajs/orm @mostajs/orm-bridge @mostajs/orm-adapter server-only"
      if ( cd "$PROJECT_ROOT" && $PKG_MANAGER install \
             @mostajs/orm @mostajs/orm-bridge @mostajs/orm-adapter server-only \
             --legacy-peer-deps ); then
        BS_OK_DEPS=1
        ok "  deps installed"
      else
        err "Step 2 failed — \`$PKG_MANAGER install\` returned non-zero."
        err "Fix your package manager / registry access and re-run \`mostajs bootstrap\`."
        exit 1
      fi

      # ─── Step 3 ───
      echo -e "\n\e[1m▶ Step 3/4 : convert schema + init DDL\e[0m"
      local type="${DETECTED_TYPES[0]}" input
      case "$type" in
        prisma)     input="$PRISMA_SCHEMA" ;;
        openapi)    input="$OPENAPI_FILE" ;;
        jsonschema) input="${JSON_SCHEMAS[0]}" ;;
      esac

      if run_adapter_convert "$type" "$input" "$GENERATED_DIR/entities.ts" && \
         [[ -s "$GENERATED_DIR/entities.json" || -s "$GENERATED_DIR/entities.ts" ]]; then
        BS_OK_CONVERT=1
        ok "  schema converted → $GENERATED_DIR/entities.json"
      else
        err "Step 3.1 failed — schema conversion did not produce entities.json."
        err "Re-run manually : $CLI_NAME convert   (or menu 1)"
        exit 1
      fi

      mkdir -p "$CONFIG_DIR"
      # ── Database choice ──
      # Resolution order :
      #   1. existing .mostajs/config.env → honour it (user may have set it with `mostajs` menu 2)
      #   2. --dialect / --uri / --strategy CLI flags → non-interactive scripting
      #   3. $DB_DIALECT + $SGBD_URI env vars → non-interactive, no files on disk
      #   4. interactive prompt (default)
      if [[ -f "$CONFIG_DIR/config.env" ]]; then
        load_env
        info "  using existing $CONFIG_DIR/config.env  (dialect=$DB_DIALECT  uri=$SGBD_URI)"
      else
        local bs_dialect="" bs_uri="" bs_strategy="update"
        for arg in "$@"; do
          case "$arg" in
            --dialect=*)  bs_dialect="${arg#--dialect=}" ;;
            --uri=*)      bs_uri="${arg#--uri=}" ;;
            --strategy=*) bs_strategy="${arg#--strategy=}" ;;
          esac
        done
        # Fall back to env vars
        [[ -z "$bs_dialect" ]] && bs_dialect="${DB_DIALECT:-}"
        [[ -z "$bs_uri"     ]] && bs_uri="${SGBD_URI:-}"

        if [[ -z "$bs_dialect" || -z "$bs_uri" ]]; then
          echo
          echo -e "${BOLD}▶ Database choice${RESET}    ${DIM}(run \`$CLI_NAME\` then menu 2 beforehand to skip this prompt)${RESET}"
          echo
          echo "  ${CYAN}1${RESET}) SQLite         ${DIM}./data.sqlite               (zero setup, recommended for trying out)${RESET}"
          echo "  ${CYAN}2${RESET}) PostgreSQL     ${DIM}postgres://user:pass@host:5432/db${RESET}"
          echo "  ${CYAN}3${RESET}) MongoDB        ${DIM}mongodb://user:pass@host:27017/db${RESET}"
          echo "  ${CYAN}4${RESET}) MySQL          ${DIM}mysql://user:pass@host:3306/db${RESET}"
          echo "  ${CYAN}5${RESET}) MariaDB        ${DIM}mariadb://user:pass@host:3306/db${RESET}"
          echo "  ${CYAN}6${RESET}) Oracle         ${DIM}oracle://user:pass@host:1521/XE${RESET}"
          echo "  ${CYAN}7${RESET}) SQL Server     ${DIM}mssql://user:pass@host:1433/db${RESET}"
          echo "  ${CYAN}8${RESET}) CockroachDB    ${DIM}postgresql://user:pass@host:26257/db?sslmode=disable${RESET}"
          echo "  ${CYAN}9${RESET}) DB2 / HANA / HSQLDB / Spanner / Sybase / other (enter manually)"
          echo
          local c; c=$(ask "Choice" "1")
          case "$c" in
            1) bs_dialect="sqlite";      bs_uri=$(ask "SQLite path" "./data.sqlite") ;;
            2) bs_dialect="postgres";    bs_uri=$(ask "Postgres URI" "postgres://user:pass@localhost:5432/mydb") ;;
            3) bs_dialect="mongodb";    bs_uri=$(ask "MongoDB URI"  "mongodb://localhost:27017/mydb") ;;
            4) bs_dialect="mysql";      bs_uri=$(ask "MySQL URI"    "mysql://user:pass@localhost:3306/mydb") ;;
            5) bs_dialect="mariadb";    bs_uri=$(ask "MariaDB URI"  "mariadb://user:pass@localhost:3306/mydb") ;;
            6) bs_dialect="oracle";     bs_uri=$(ask "Oracle URI"   "oracle://user:pass@localhost:1521/XE") ;;
            7) bs_dialect="mssql";      bs_uri=$(ask "SQL Server URI" "mssql://user:pass@localhost:1433/mydb") ;;
            8) bs_dialect="cockroachdb"; bs_uri=$(ask "CockroachDB URI" "postgresql://root@localhost:26257/mydb?sslmode=disable") ;;
            9) bs_dialect=$(ask "Dialect (db2|hana|hsqldb|spanner|sybase|other)" "")
               bs_uri=$(ask "URI" "") ;;
            *) err "Invalid choice"; exit 1 ;;
          esac
          [[ -z "$bs_dialect" || -z "$bs_uri" ]] && { err "dialect and uri are required"; exit 1; }

          local chosen_strategy
          chosen_strategy=$(ask "Schema strategy (validate|update|create|create-drop|none)" "$bs_strategy")
          bs_strategy="$chosen_strategy"
        fi

        cat > "$CONFIG_DIR/config.env" <<CFG
DB_DIALECT=$bs_dialect
SGBD_URI=$bs_uri
DB_SCHEMA_STRATEGY=$bs_strategy
CFG
        ok "  wrote $CONFIG_DIR/config.env (dialect=$bs_dialect)"
        load_env
      fi

      if action_init_dialects; then
        BS_OK_DDL=1
        ok "  DDL applied"
      else
        err "Step 3.2 failed — DDL init returned non-zero."
        err "Re-run manually : $CLI_NAME   (menu 3)"
        exit 1
      fi

      # ─── Step 4 ───
      echo -e "\n\e[1m▶ Step 4/4 : done\e[0m"
      if (( BS_OK_CODEMOD && BS_OK_DEPS && BS_OK_CONVERT && BS_OK_DDL )); then
        cat <<DONE

  ✓ Bridge installed in-place.  Original files backed up as *.prisma.bak
  ✓ Schema converted :   $GENERATED_DIR/entities.json
  ✓ DDL applied        (DB_DIALECT=$DB_DIALECT  SGBD_URI=$SGBD_URI)

  Next :
    - Add seeds to $CONFIG_DIR/seeds/*.json   (one file per entity)
    - $CLI_NAME             # menu S → h (hash) → 4 (apply)
    - npm run dev
    - Open http://localhost:3000/login

  To undo the codemod :
    $CLI_NAME install-bridge --restore --apply

DONE
      else
        err "Bootstrap finished with partial success — see messages above."
        exit 1
      fi
      ;;
    version|-v|--version)
      echo "$CLI_NAME $VERSION"
      ;;
    help|-h|--help)
      cat <<EOF
Usage :
  $CLI_NAME                         Interactive menu
  $CLI_NAME bootstrap                 One-shot migration : codemod + deps + convert + DDL
                                      (interactive database picker unless config exists)
  $CLI_NAME bootstrap --dialect=postgres --uri=postgres://... --strategy=update
                                      Non-interactive bootstrap (for CI / scripts)
  $CLI_NAME install-bridge            Codemod only (dry-run ; add --apply to write)
  $CLI_NAME install-bridge --apply  Rewrite PrismaClient sites to use @mostajs/orm-bridge
  $CLI_NAME install-bridge --restore --apply     Undo a prior install-bridge
  $CLI_NAME convert                 Run conversion (auto-detect schema type)
  $CLI_NAME detect                  Print detected schemas
  $CLI_NAME health                  Run health checks
  $CLI_NAME hash <password> [cost]  Hash a password with bcrypt (cost default 10)
  $CLI_NAME verify <password> <hash> Check if a plain password matches a bcrypt hash
  $CLI_NAME diagnose [email] [pw]   Walk through login diagnostics
  $CLI_NAME version                 Print version

Examples:
  $CLI_NAME bootstrap               → zero-touch migrate a Prisma project to @mostajs/orm
  $CLI_NAME install-bridge          → preview rewrites without touching files
  $CLI_NAME hash 'Admin@123456'     → \$2b\$10\$N9qo8uLOickgx2ZMRZoMyeIjZA...
  $CLI_NAME verify 'Admin@123456' '\$2b\$10\$N9qo...'
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
  detect_project  # populates PKG_MANAGER, PROJECT_ROOT, etc.
  load_env        # optional config for subcommands that need it
  run_subcommand "$@"
  exit 0
fi

# Interactive menu
while true; do
  menu_main
done
