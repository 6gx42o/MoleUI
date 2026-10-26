#!/bin/bash
# Builds MoleUI and assembles a runnable .app bundle.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"
# The macOS 27 SDK turned SwiftUI's @State into a macro whose compiler plugin
# (libSwiftUIMacros) ships only with full Xcode, not the Command Line Tools —
# so with CLT alone every view fails to compile. Fall back to the newest
# macOS 26 SDK, where @State is still an ordinary property wrapper. The app
# targets macOS 14, so nothing it uses needs the 27 SDK.
PLUGINS="$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins"
if [ -z "$SDKROOT" ] && ! ls "$PLUGINS"/libSwiftUIMacros* >/dev/null 2>&1; then
  SDK="$(ls -d "$(xcrun --show-sdk-platform-path 2>/dev/null || echo /Library/Developer/CommandLineTools)"/../SDKs/MacOSX26.*.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)"
  if [ -n "$SDK" ]; then
    export SDKROOT="$SDK"
    echo "▸ SwiftUI macro plugin missing — building against $(basename "$SDK")"
  fi
fi

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/MoleUI"
APP="MoleUI.app"

# Icon is generated from code (Sources/MoleUI/Core/IconRenderer.swift) rather
# than committed as a binary, so it can be edited like everything else.
echo "▸ Generating app icon…"
mkdir -p Resources
ICON_PNG="/tmp/moleui_icon.png"
if "$BIN" --icon "$ICON_PNG" > /dev/null 2>&1 && [ -f "$ICON_PNG" ]; then
  ICONSET="/tmp/MoleUI.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" > /dev/null 2>&1
    sips -z $((s*2)) $((s*2)) "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns > /dev/null 2>&1 \
    && echo "  ✓ Resources/AppIcon.icns"
fi

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MoleUI"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer a stable signing identity over ad-hoc so TCC grants (Full Disk Access,
# which `mo` needs for system caches) survive rebuilds. Ad-hoc signatures change
# every build and silently invalidate those grants.
# Prefer a real Apple identity when one exists. Otherwise fall back to the
# local self-signed one — note the second lookup drops `-v`: a self-signed cert
# reports CSSMERR_TP_NOT_TRUSTED and so never appears in the "valid identities"
# list, but codesign signs with it perfectly well. Trust is a Gatekeeper /
# distribution concern; all we need here is a *stable* signing identity.
#
# That stability is the whole point. Ad-hoc signatures produce a designated
# requirement of `cdhash H"..."`, which is derived from the binary's contents and
# therefore changes on every build, invalidating Full Disk Access each time.
# Signing with a certificate produces
#   identifier "dev.rushil.moleui" and certificate leaf = H"<cert hash>"
# which is identical across rebuilds, so the TCC grant survives.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')
[ -z "$IDENTITY" ] && IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
  | awk -F'"' '/MoleUI Self Signed/{print $2; exit}')
SIGN="${IDENTITY:--}"
if [ "$SIGN" = "-" ]; then
  echo "▸ Ad-hoc signing (no signing identity found)…"
else
  echo "▸ Signing as: $SIGN"
fi
# Signing is retried rather than silently downgraded. A transient
# errSecInternalComponent (a momentary keychain hiccup) used to fall through to
# the ad-hoc branch without a word, which swaps the stable certificate
# requirement for a per-build cdhash and quietly voids Full Disk Access — the
# app then under-reports every scan with no visible cause.
sign_app() {
  codesign --force --options runtime \
    --entitlements MoleUI.entitlements --sign "$SIGN" "$APP" 2>&1
}

if [ "$SIGN" != "-" ]; then
  SIGN_OUT=$(sign_app) || SIGN_OUT="$SIGN_OUT"
  if ! codesign -d -r- "$APP" 2>&1 | grep -q 'certificate leaf'; then
    echo "  ⚠ First signing attempt did not take: $SIGN_OUT"
    echo "  ▸ Retrying…"
    SIGN_OUT=$(sign_app) || SIGN_OUT="$SIGN_OUT"
  fi
fi

if codesign -d -r- "$APP" 2>&1 | grep -q 'certificate leaf'; then
  echo "✓ Built $APP (stable certificate requirement)"
else
  codesign --force --sign - "$APP" > /dev/null 2>&1 || true
  echo "✓ Built $APP"
  echo
  echo "  ⚠ AD-HOC SIGNED — the requirement is a per-build cdhash, so any"
  echo "    Full Disk Access grant stops applying and scans under-report."
  echo "    Last codesign message: ${SIGN_OUT:-none}"
  echo "    If this says errSecInternalComponent, the keychain would not release"
  echo "    the key; re-run ./build.sh, or authorise it once with:"
  echo "      security set-key-partition-list -S apple-tool:,apple:,codesign: \\"
  echo "        -s ~/Library/Keychains/login.keychain-db"
fi

# Install to /Applications so it launches from Spotlight and Launchpad. TCC keys
# on the bundle path, so the installed copy is the one that holds Full Disk
# Access — building without installing would leave you granting it twice.
if [ "${2:-}" = "--no-install" ] || [ "${1:-}" = "--no-install" ]; then
  echo "  (skipping install to /Applications)"
else
  DEST="/Applications/MoleUI.app"
  # ditto, not cp -R: cp does not carry the extended attributes an app bundle's
  # code signature depends on, and the copy silently degrades to an ad-hoc
  # cdhash requirement — which is exactly the thing the certificate exists to
  # avoid, and would cost a Full Disk Access re-grant on every build.
  if rm -rf "$DEST" 2> /dev/null && ditto "$APP" "$DEST" 2> /dev/null; then
    echo "✓ Installed $DEST"
    INSTALLED_REQ=$(codesign -d -r- "$DEST" 2>&1 | grep -c 'certificate leaf' || true)
    if [ "$INSTALLED_REQ" = "0" ]; then
      echo "  ⚠ Installed copy is not certificate-signed — FDA will not persist."
    fi
  else
    echo "  ⚠ Could not write to /Applications — run: ditto $APP /Applications/MoleUI.app"
  fi
fi

# An ad-hoc signature is derived from the binary's contents, so it changes on
# every build — which invalidates any Full Disk Access grant and silently
# degrades every scan (`mo` just reports less). Say so rather than let it be
# discovered as a mysteriously smaller result.
if [ "$SIGN" = "-" ]; then
  echo
  echo "  ⚠ Ad-hoc signed, so the designated requirement is a cdhash that"
  echo "    changes every build — any Full Disk Access grant stops applying"
  echo "    and scans quietly under-report."
  echo "    Fix: create a stable signing identity (see README → Permissions)."
fi
