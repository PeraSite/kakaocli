#!/bin/bash
# Build kakaocli, sign it and install it to ~/.local/bin/kakaocli.
#
# Signing matters for macOS permissions (TCC). An ad-hoc signature is tied to the exact binary, so every
# rebuild silently loses Full Disk Access and Accessibility. If an "Apple Development" (or "Developer ID
# Application") identity is in your keychain, it is used instead: the permission is then tied to
# "this certificate + identifier com.github.kakaocli" and survives rebuilds.
#   KAKAOCLI_SIGN_IDENTITY="Apple Development: …"   choose an identity
#   KAKAOCLI_SIGN_IDENTITY=-                        force ad-hoc
set -euo pipefail
cd "$(dirname "$0")/.."
prefix="${PREFIX:-$HOME/.local}"
swift build -c release
ident="${KAKAOCLI_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Apple Development|Developer ID Application): [^"]+"' | head -1 | tr -d '"')}"
bin=.build/release/kakaocli
# No hardened runtime: its library validation refuses Homebrew's libsqlcipher (different Team ID).
codesign --force --sign "${ident:--}" --identifier com.github.kakaocli "$bin"
mkdir -p "$prefix/bin"
if [ -f "$prefix/bin/kakaocli" ]; then cp -p "$prefix/bin/kakaocli" "$prefix/bin/kakaocli.previous"; fi
install -m 0755 "$bin" "$prefix/bin/kakaocli"
echo "Installed $prefix/bin/kakaocli (signed: ${ident:-ad-hoc})"
codesign -d -r- "$prefix/bin/kakaocli" 2>&1 | tail -1
cat <<MSG

Next: give the permissions to kakaocli itself (System Settings → Privacy & Security):
  • Full Disk Access  → +  → $prefix/bin/kakaocli     (read the local DB)
  • Accessibility     → +  → $prefix/bin/kakaocli     (send)
If an older kakaocli entry is listed, remove it with − first: it is tied to the old signature.
In the file picker press ⌘⇧G and paste the path. Then check:  kakaocli permissions
MSG
