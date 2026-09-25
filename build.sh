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
cp juiceleft-helper.sh LICENSE "$APP/Contents/Resources/"
cc -O2 -Wall -Wextra -Werror -target arm64-apple-macos13.0 -framework IOKit -framework CoreFoundation juiceleft-led.c -o "$APP/Contents/Resources/juiceleft-led"
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
