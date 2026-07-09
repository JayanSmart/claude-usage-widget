#!/usr/bin/env bash
# Builds and installs Claude Usage to /Applications.
# Requirements: macOS 13+, Xcode Command Line Tools (xcode-select --install)
set -euo pipefail

APP="ClaudeUsage.app"
INSTALL_DIR="/Applications"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$REPO_ROOT"

# ── Build ──────────────────────────────────────────────────────────────────────
bash build-app.sh

# ── Install ────────────────────────────────────────────────────────────────────
echo "→ Installing to ${INSTALL_DIR}…"
rm -rf "${INSTALL_DIR}/${APP}"
cp -r "${APP}" "${INSTALL_DIR}/"

# ── Launch ────────────────────────────────────────────────────────────────────
echo "→ Launching…"
open "${INSTALL_DIR}/${APP}"

cat <<'EOF'

✓ Claude Usage is running in your menu bar.

To start automatically at login:
  System Settings → General → Login Items & Extensions
  → click + under "Open at Login" → select ClaudeUsage

EOF
