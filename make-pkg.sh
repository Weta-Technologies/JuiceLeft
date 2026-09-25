#!/bin/bash
# ./make-pkg.sh  ->  build/JuiceLeft.pkg, the Installer package attached to GitHub releases.
# Keep the asset name fixed: https://github.com/Weta-Technologies/JuiceLeft/releases/latest/download/JuiceLeft.pkg
# (the download button) always serves the newest release.
#
# One package, three clicks — Continue, Agree, Install. The app goes into /Applications; pkg/scripts/preinstall quits a
# running copy properly; pkg/scripts/postinstall (root, under Installer's own admin prompt — password or Touch ID) hands
# the app to the logged-in user, installs the root helper for them and opens the app. So the install prompt is the one
# prompt: lid-closed mode and the charging light are ready when the menu-bar icon appears. Panes: pkg/welcome.txt, the
# licence (LICENSE, Agree/Disagree), pkg/conclusion.txt; branded backgrounds for light and dark from
# assets/make-pkg-background.swift. The component never relocates (BundleIsRelocatable=false), so Installer can't
# "upgrade" some other copy of the app it finds — build/, say — instead of /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=JuiceLeft
ID=io.github.cyborgfingers.juiceleft
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Info.plist)
[[ -n "${SKIP_BUILD:-}" ]] || ./build.sh   # release.sh builds, notarizes and staples the app first, then packages it as is
# Signed with the Developer ID Installer certificate when it is in the keychain (or CF_SIGN_PKG names one); unsigned otherwise.
SIGN_PKG=${CF_SIGN_PKG:-$(security find-identity -v -p basic 2>/dev/null | awk -F'"' '/Developer ID Installer:/ {print $2; exit}')}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root" "$WORK/resources"
cp -R "build/$APP.app" "$WORK/root/"

cat > "$WORK/component.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<dict>
		<key>BundleHasStrictIdentifier</key><true/>
		<key>BundleIsRelocatable</key><false/>
		<key>BundleIsVersionChecked</key><true/>
		<key>BundleOverwriteAction</key><string>upgrade</string>
		<key>RootRelativeBundlePath</key><string>$APP.app</string>
	</dict>
</array>
</plist>
EOF
pkgbuild --quiet --root "$WORK/root" --component-plist "$WORK/component.plist" --scripts pkg/scripts \
  --identifier "$ID.pkg" --version "$VERSION" --install-location /Applications "$WORK/$APP-component.pkg"

swiftc -O assets/make-pkg-background.swift -o "$WORK/bg"
"$WORK/bg" assets/icon-512.png "$WORK/resources"
cp pkg/welcome.txt pkg/conclusion.txt "$WORK/resources/"
cp LICENSE "$WORK/resources/license.txt"
cat > "$WORK/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>$APP</title>
    <organization>io.github.cyborgfingers</organization>
    <domains enable_localSystem="true"/>
    <options customize="never" rootVolumeOnly="true" hostArchitectures="arm64"/>
    <volume-check>
        <allowed-os-versions><os-version min="$MIN_OS"/></allowed-os-versions>
    </volume-check>
    <background file="background.png" mime-type="image/png" alignment="bottomleft" scaling="proportional"/>
    <background-darkAqua file="background-dark.png" mime-type="image/png" alignment="bottomleft" scaling="proportional"/>
    <welcome file="welcome.txt" mime-type="text/plain"/>
    <license file="license.txt" mime-type="text/plain"/>
    <conclusion file="conclusion.txt" mime-type="text/plain"/>
    <choices-outline>
        <line choice="default"><line choice="app"/></line>
    </choices-outline>
    <choice id="default"/>
    <choice id="app" visible="false"><pkg-ref id="$ID.pkg"/></choice>
    <pkg-ref id="$ID.pkg" version="$VERSION" onConclusion="none">$APP-component.pkg</pkg-ref>
</installer-gui-script>
EOF
rm -f "build/$APP.pkg"
if [[ -n "$SIGN_PKG" ]]; then
  productbuild --quiet --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" --version "$VERSION" \
    --sign "$SIGN_PKG" --timestamp "build/$APP.pkg"
  echo "Built build/$APP.pkg ($APP $VERSION, signed: $SIGN_PKG)"
else
  productbuild --quiet --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" --version "$VERSION" "build/$APP.pkg"
  echo "Built build/$APP.pkg ($APP $VERSION) — UNSIGNED: no Developer ID Installer certificate in the keychain (Gatekeeper's Open Anyway step for downloads)"
fi
shasum -a 256 "build/$APP.pkg"
