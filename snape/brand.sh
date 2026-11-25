#!/usr/bin/env bash
# snape/brand.sh: turn the upstream-built <App>.app into "<App> (Snape).app".
#
# Lives only on the `snape` branch as a NEW file. It changes no upstream file, so a rebase onto
# upstream can never conflict on it. Run after `packaging/macos/package.sh --arch aarch64`.
#
#   in : $CARGO_TARGET_DIR/macos-package/<App>.app       (built by package.sh, ad-hoc signed)
#   out: dist/snape/<App> (Snape).app
#
# What it changes in the copy:
#   - CFBundleIdentifier  ai.storyteller.<app>  -> com.snape888.<app>
#   - CFBundleName / CFBundleDisplayName        -> "<App> (Snape)"
#   - Contents/MacOS/<App> becomes a tiny launcher that sets <APP>_CONFIG_DIR to
#     ~/Library/Application Support/<App> (Snape) and execs the real binary (<App>-bin),
#     so settings, recovery files and the single-instance lock stay apart from the official app.
#   - re-signs ad-hoc, inside-out, with the repo's own entitlements, then verifies.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERE="$ROOT/packaging/macos"
PB=/usr/libexec/PlistBuddy

APP_NAME="$(sed -n 's/^APP="\$WORK\/\(.*\)\.app"$/\1/p' "$HERE/package.sh")"
[[ -n "$APP_NAME" ]] || { echo "brand: can't read APP= from packaging/macos/package.sh (upstream changed it?)" >&2; exit 1; }
SRC="${CARGO_TARGET_DIR:-$ROOT/target}/macos-package/$APP_NAME.app"
[[ -d "$SRC" ]] || { echo "brand: $SRC not found; run packaging/macos/package.sh --arch aarch64 first" >&2; exit 1; }

OLD_ID="$($PB -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist")"   # ai.storyteller.photocraft
SLUG="${OLD_ID##*.}"                                                          # photocraft
NEW_ID="com.snape888.$SLUG"
NEW_NAME="$APP_NAME (Snape)"
ENV_VAR="$(echo "$SLUG" | tr '[:lower:]-' '[:upper:]_')_CONFIG_DIR"           # PHOTOCRAFT_CONFIG_DIR
OUT="$ROOT/dist/snape/$NEW_NAME.app"

echo "==> $SRC -> $OUT"
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
ditto "$SRC" "$OUT"

P="$OUT/Contents/Info.plist"
$PB -c "Set :CFBundleIdentifier $NEW_ID" "$P"
$PB -c "Set :CFBundleName $NEW_NAME" "$P"
$PB -c "Set :CFBundleDisplayName $NEW_NAME" "$P" 2>/dev/null || $PB -c "Add :CFBundleDisplayName string $NEW_NAME" "$P"
plutil -lint "$P"

EXE="$($PB -c 'Print :CFBundleExecutable' "$P")"
mv "$OUT/Contents/MacOS/$EXE" "$OUT/Contents/MacOS/$EXE-bin"
cat >"$OUT/Contents/MacOS/$EXE" <<EOF
#!/bin/sh
# Snape build launcher: own settings folder, then the real app.
export $ENV_VAR="\${$ENV_VAR:-\$HOME/Library/Application Support/$NEW_NAME}"
exec "\$(dirname "\$0")/$EXE-bin" "\$@"
EOF
chmod 755 "$OUT/Contents/MacOS/$EXE"

# Re-sign inside-out (ad-hoc): real binary, launcher, then the bundle.
codesign --force --sign - --timestamp=none --options runtime --entitlements "$HERE/entitlements.plist" "$OUT/Contents/MacOS/$EXE-bin"
codesign --force --sign - --timestamp=none "$OUT/Contents/MacOS/$EXE"
codesign --force --sign - --timestamp=none --options runtime --entitlements "$HERE/entitlements.plist" "$OUT"
codesign --verify --strict --deep --verbose=2 "$OUT"
echo "==> $NEW_NAME  id=$NEW_ID  settings=~/Library/Application Support/$NEW_NAME ($ENV_VAR)"
