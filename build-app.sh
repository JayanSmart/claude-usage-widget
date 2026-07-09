#!/usr/bin/env bash
# Builds ClaudeUsage.swift package and assembles a proper macOS .app bundle.
set -euo pipefail

BINARY_NAME="ClaudeUsage"
APP="${BINARY_NAME}.app"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Prerequisites ──────────────────────────────────────────────────────────────
if ! command -v swift &>/dev/null; then
    echo "✗ Swift not found. Install Xcode Command Line Tools:"
    echo "    xcode-select --install"
    exit 1
fi

cd "$REPO_ROOT"

# ── Build ──────────────────────────────────────────────────────────────────────
echo "→ Building (release)…"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
    BINARY=".build/apple/Products/Release/${BINARY_NAME}"
    echo "→ Universal binary (Apple Silicon + Intel)"
else
    echo "→ Apple Silicon only (universal build requires full Xcode)"
    swift build -c release 2>&1
    BINARY=".build/release/${BINARY_NAME}"
fi

# ── Assemble bundle ────────────────────────────────────────────────────────────
echo "→ Assembling ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

cp "$BINARY"              "${APP}/Contents/MacOS/${BINARY_NAME}"
cp Resources/Info.plist   "${APP}/Contents/"

# ── Ad-hoc sign ───────────────────────────────────────────────────────────────
echo "→ Ad-hoc signing…"
codesign --force --deep --sign - "${APP}"

echo "✓ ${APP} ready."
