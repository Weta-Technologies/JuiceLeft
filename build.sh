#!/bin/bash
# ./build.sh            -> build/JuiceLeft.app
# ./build.sh install    -> also copy to /Applications and launch
# ./build.sh uninstall  -> quit the app (which puts Apple's battery item back), remove the helper, the package receipt and the app
set -euo pipefail
cd "$(dirname "$0")"

# A quit event, not a kill: only a proper quit puts Apple's battery item back and hands the charging light to macOS.
quit_app() {
  osascript -e 'tell application id "io.github.cyborgfingers.juiceleft" to quit' 2>/dev/null || true
  for _ in $(seq 1 50); do pgrep -x JuiceLeft >/dev/null || return 0; sleep 0.2; done
  pkill -x JuiceLeft || true
}

if [[ "${1:-}" == "uninstall" ]]; then
  quit_app
  defaults -currentHost delete com.apple.controlcenter Battery 2>/dev/null || true   # Apple's battery item, in case the quit path didn't run
  [[ -f /Library/PrivilegedHelperTools/io.github.cyborgfingers.juiceleft.power.sh ]] && sudo /bin/sh juiceleft-helper.sh uninstall
  sudo pkgutil --forget io.github.cyborgfingers.juiceleft.pkg 2>/dev/null || true   # the Installer package's receipt, if it came that way
  rm -rf /Applications/JuiceLeft.app
  echo "Removed. Also untick JuiceLeft in System Settings > General > Login Items if it's still listed."
  exit 0
fi

APP=build/JuiceLeft.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp juiceleft-helper.sh LICENSE cyborgfingers.pub "$APP/Contents/Resources/"
cc -O2 -Wall -Wextra -Werror -target arm64-apple-macos13.0 -framework IOKit -framework CoreFoundation juiceleft-led.c -o "$APP/Contents/Resources/juiceleft-led"
# The root-side gate on helper updates (tools/helper-verify.swift), cached: it only changes when its source does.
[[ build/helper-verify -nt tools/helper-verify.swift ]] || swiftc -O tools/helper-verify.swift -o build/helper-verify
cp build/helper-verify "$APP/Contents/Resources/juiceleft-verify"
[[ -f assets/AppIcon.icns ]] && cp assets/AppIcon.icns "$APP/Contents/Resources/"
# FoundationModels (Apple Intelligence, macOS 26+) is weak-linked so the app still launches on macOS 13–15.
swiftc -O -parse-as-library -target arm64-apple-macosx13.0 \
  -Xlinker -weak_framework -Xlinker FoundationModels \
  *.swift -o "$APP/Contents/MacOS/JuiceLeft"

# Signing: Developer ID when the certificate is in the keychain (or CF_SIGN_APP names an identity), ad-hoc otherwise —
# hardened runtime either way, so a dev build behaves like a release. The tools first (their hashes go into the helper
# manifest), the manifest next (signed with the publisher key when it is in the Keychain; release.sh insists on it —
# without it, an installed helper can't update itself from this build), the app last, sealing all of it.
SIGN_APP=${CF_SIGN_APP:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/ {print $2; exit}')}
if [[ -n "$SIGN_APP" ]]; then
  SIGN=(--sign "$SIGN_APP" --options runtime --timestamp)
else
  SIGN=(--sign - --options runtime)
  echo "note: no Developer ID Application certificate in the keychain — ad-hoc signed (a download of this build would need Gatekeeper's Open Anyway)"
fi
codesign --force "${SIGN[@]}" "$APP/Contents/Resources/juiceleft-led" "$APP/Contents/Resources/juiceleft-verify"
(cd "$APP/Contents/Resources" && { echo "version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ../Info.plist)"
   shasum -a 256 juiceleft-helper.sh juiceleft-led juiceleft-verify cyborgfingers.pub; } > helper-manifest)
if security find-generic-password -a cyborgfingers-updates -s "CyborgFingers update signing key" >/dev/null 2>&1; then
  [[ build/sign-update -nt tools/sign-update.swift ]] || swiftc -O tools/sign-update.swift -o build/sign-update
  build/sign-update sign "$APP/Contents/Resources/helper-manifest" >/dev/null
else
  echo "note: no publisher key in the Keychain, helper-manifest left unsigned (an installed helper won't update itself from this build)"
fi
codesign --force "${SIGN[@]}" "$APP"
echo "Built $APP${SIGN_APP:+ (Developer ID: $SIGN_APP)}"

if [[ "${1:-}" == "install" ]]; then
  quit_app   # a real quit, so it puts Apple's battery item back on the way out
  rm -rf /Applications/JuiceLeft.app
  cp -R "$APP" /Applications/
  open /Applications/JuiceLeft.app
  echo "Installed + launched /Applications/JuiceLeft.app"
fi
