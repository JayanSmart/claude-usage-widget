#!/usr/bin/env bash
# Builds ClaudeUsage and packages it as a DMG for distribution.
# Requirements: macOS 13+, Xcode Command Line Tools
set -euo pipefail

APP="ClaudeUsage.app"
DMG="ClaudeUsage.dmg"
VOL="Claude Usage"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$REPO_ROOT"

# ── Build ──────────────────────────────────────────────────────────────────────
bash build-app.sh

# ── Assemble staging folder ────────────────────────────────────────────────────
echo "→ Staging DMG contents…"
STAGING=$(mktemp -d)
trap "rm -rf '$STAGING'" EXIT

cp -r "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# ── Create DMG ─────────────────────────────────────────────────────────────────
echo "→ Creating ${DMG}…"
rm -f "$DMG"
hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

echo ""
echo "✓ ${DMG} ready ($(du -sh "$DMG" | cut -f1))"
echo ""
echo "Share this file with your team. First-run instructions:"
echo "  1. Open the DMG and drag ClaudeUsage to Applications"
echo "  2. Right-click ClaudeUsage in Applications → Open"
echo "     (required once to bypass Gatekeeper on ad-hoc-signed builds)"
echo "  3. Log in with the 'Log in…' button and enter your org ID when prompted"
echo ""
