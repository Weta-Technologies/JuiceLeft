#!/bin/bash
# ./build.sh            -> build/JuiceLeft.app
# ./build.sh install    -> also copy to /Applications and launch
# ./build.sh uninstall  -> quit the app (which puts Apple's battery item back), remove the energy-mode helper and the app
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "uninstall" ]]; then
  pkill -x JuiceLeft || true
  sleep 1
  defaults -currentHost delete com.apple.controlcenter Battery 2>/dev/null || true   # Apple's battery item, in case the quit path didn't run
  [[ -f /Library/PrivilegedHelperTools/io.github.cyborgfingers.juiceleft.power.sh ]] && sudo /bin/sh juiceleft-helper.sh uninstall
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
# The root-side gate on helper updates, and the manifest it checks: signed here when the publisher key is in the
# Keychain (release.sh insists on it); otherwise this build's helper can only be installed through the setup prompt.
[[ build/helper-verify -nt tools/helper-verify.swift ]] || swiftc -O tools/helper-verify.swift -o build/helper-verify
cp build/helper-verify "$APP/Contents/Resources/juiceleft-verify"
(cd "$APP/Contents/Resources" && { echo "version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ../Info.plist)"
   shasum -a 256 juiceleft-helper.sh juiceleft-led juiceleft-verify cyborgfingers.pub; } > helper-manifest)
if security find-generic-password -a cyborgfingers-updates -s "CyborgFingers update signing key" >/dev/null 2>&1; then
  [[ build/sign-update -nt tools/sign-update.swift ]] || swiftc -O tools/sign-update.swift -o build/sign-update
  build/sign-update sign "$APP/Contents/Resources/helper-manifest" >/dev/null
else
  echo "note: no publisher key in the Keychain, helper-manifest left unsigned (an installed helper won't update itself from this build)"
fi
[[ -f assets/AppIcon.icns ]] && cp assets/AppIcon.icns "$APP/Contents/Resources/"
# FoundationModels (Apple Intelligence, macOS 26+) is weak-linked so the app still launches on macOS 13–15.
swiftc -O -parse-as-library -target arm64-apple-macosx13.0 \
  -Xlinker -weak_framework -Xlinker FoundationModels \
  *.swift -o "$APP/Contents/MacOS/JuiceLeft"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x JuiceLeft || true
  while pgrep -x JuiceLeft >/dev/null; do sleep 0.2; done   # let it quit (it puts Apple's battery item back on the way out)
  rm -rf /Applications/JuiceLeft.app
  cp -R "$APP" /Applications/
  open /Applications/JuiceLeft.app
  echo "Installed + launched /Applications/JuiceLeft.app"
fi
