#!/bin/bash
# Installation rapide : clone, compile, copie dans /Applications et ouvre RailRouter.
#   curl -fsSL https://raw.githubusercontent.com/Hugo291/RailRouter/main/install.sh | bash
set -euo pipefail
command -v swift >/dev/null || { echo "Swift toolchain not found: run 'xcode-select --install' first." >&2; exit 1; }
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
git clone --depth 1 https://github.com/Hugo291/RailRouter.git "$DIR"
make -C "$DIR" install
open /Applications/RailRouter.app
