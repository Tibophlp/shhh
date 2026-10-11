#!/bin/bash
# Builds Shhh.app into ./build.
#   ./scripts/build.sh            build only
#   ./scripts/build.sh --install  build, copy to /Applications and (re)launch
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Shhh.app"
SIGN_ID="Shhh Local Signing"

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Shhh" "$APP/Contents/MacOS/Shhh"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$BIN/llama.framework" "$APP/Contents/Frameworks/"
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Shhh" 2>/dev/null || true

# Sign with the local certificate if it exists (keeps macOS permissions across rebuilds),
# otherwise ad-hoc. Run ./scripts/make-signing-cert.sh once to create it.
# SHHH_ADHOC=1 forces ad-hoc signing (used for release downloads).
if [ -z "${SHHH_ADHOC:-}" ] && security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  IDENTITY="$SIGN_ID"
else
  IDENTITY="-"
  echo "Note: signing ad-hoc. Run ./scripts/make-signing-cert.sh so permissions survive rebuilds."
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Shhh 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Shhh.app
  cp -R "$APP" /Applications/Shhh.app
  open /Applications/Shhh.app
  echo "Installed to /Applications and launched."
fi
