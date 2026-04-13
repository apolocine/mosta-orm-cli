#!/usr/bin/env bash
# install.sh — One-line installer for @mostajs/orm-cli
# Usage : curl -fsSL https://raw.githubusercontent.com/apolocine/mosta-orm-cli/main/install.sh | bash
# Author: Dr Hamid MADANI drmdh@msn.com

set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/apolocine/mosta-orm-cli/main/bin"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
NEEDS_SUDO=0

if [[ ! -w "$INSTALL_DIR" ]]; then
  NEEDS_SUDO=1
fi

echo "@mostajs/orm-cli — installer"
echo "  install dir : $INSTALL_DIR"
[[ $NEEDS_SUDO -eq 1 ]] && echo "  (needs sudo to write there)"

do_install() {
  local sudo_cmd=""
  [[ $NEEDS_SUDO -eq 1 ]] && sudo_cmd="sudo"
  curl -fsSL "$BASE_URL/mostajs.sh" -o /tmp/mostajs.sh.$$
  chmod +x /tmp/mostajs.sh.$$
  $sudo_cmd mv /tmp/mostajs.sh.$$ "$INSTALL_DIR/mostajs"
  echo
  echo "✓ Installed : $INSTALL_DIR/mostajs"
  echo
  echo "Try it :"
  echo "  cd your/project"
  echo "  mostajs"
}

do_install
