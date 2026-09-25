#!/bin/bash
# ./release.sh <version> [--dry-run]   — cuts a JuiceLeft release.
#
# Sets the version (Info.plist, the site); builds the app, Developer ID signed with the hardened runtime (build.sh finds
# the certificate in the keychain); notarizes and staples the app; builds the Installer package from it (make-pkg.sh,
# signed with the Developer ID Installer certificate), notarizes and staples that too; zips the stapled app for the
# in-app updater (JuiceLeft.app.zip) and signs the zip with the CyborgFingers publisher key from the login Keychain;
# writes the SHA-256s and a draft of the notes; then commits, tags v<version>, pushes and publishes the GitHub release
# with JuiceLeft.pkg, JuiceLeft.app.zip and JuiceLeft.app.zip.sig (the asset names are fixed: the download button and
# the updater rely on them). A real release is refused unless it is Developer ID signed and notarized. Notarization
# uses the keychain profile "cyborgfingers-notary" (xcrun notarytool store-credentials cyborgfingers-notary).
#
# --dry-run does everything up to the commit — nothing is committed, tagged, pushed or uploaded — leaves the artefacts
# in build/ and puts the version files back; without the certificates or the notary profile it says so loudly and
# carries on unsigned / unnotarized. Run it first; edit build/RELEASE_NOTES.md if you like (a real run for the same
# version keeps your edits).
set -euo pipefail
cd "$(dirname "$0")"

APP=JuiceLeft
VERSION="" DRY=0
for arg in "$@"; do case "$arg" in --dry-run) DRY=1 ;; *) VERSION=$arg ;; esac; done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: ./release.sh <major.minor.patch> [--dry-run]"; exit 1; }
die() { echo "release.sh: $*" >&2; exit 1; }

if [[ $DRY = 0 ]] && ! (git diff --quiet && git diff --cached --quiet); then die "commit or stash your changes first"; fi
[[ $DRY = 1 ]] || [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "release from main"
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "v$VERSION is already tagged"
security find-generic-password -a cyborgfingers-updates -s "CyborgFingers update signing key" >/dev/null 2>&1 || die "no publisher key in the login Keychain (tools/sign-update.swift keygen, or restore it from your password manager)"
command -v gh >/dev/null || die "gh (GitHub CLI) is needed"

# Developer ID + notarization: required for a real release; a dry run warns and goes on without.
NOTARY=cyborgfingers-notary
SIGN_APP=${CF_SIGN_APP:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/ {print $2; exit}')}
SIGN_PKG=${CF_SIGN_PKG:-$(security find-identity -v -p basic 2>/dev/null | awk -F'"' '/Developer ID Installer:/ {print $2; exit}')}
NOTARIZE=1
if [[ -z "$SIGN_APP" || -z "$SIGN_PKG" ]]; then
  [[ $DRY = 1 ]] || die "a release must be Developer ID signed: no Developer ID Application / Installer certificate in the keychain"
  echo "WARNING: no Developer ID certificates in the keychain — this dry run is unsigned and can't be notarized"
  NOTARIZE=0
elif ! xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1; then
  [[ $DRY = 1 ]] || die "a release must be notarized: no '$NOTARY' keychain profile (xcrun notarytool store-credentials $NOTARY)"
  echo "WARNING: no '$NOTARY' keychain profile — this dry run skips notarization"
  NOTARIZE=0
fi
notarize() {   # $1 = file: submit, wait, insist on Accepted, staple, validate
  local out
  out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY" --wait 2>&1) || { echo "$out"; die "notarization of $1 failed"; }
  echo "$out" | grep -q "status: Accepted" || { echo "$out"; die "notarization of $1 was not accepted (xcrun notarytool log <id> --keychain-profile $NOTARY)"; }
  xcrun stapler staple "$2" >/dev/null && xcrun stapler validate "$2" >/dev/null || die "stapling $2 failed"
  echo "Notarized and stapled $2"
}

mkdir -p build
[[ build/sign-update -nt tools/sign-update.swift ]] || swiftc -O tools/sign-update.swift -o build/sign-update
PUB=$(build/sign-update pubkey)
[[ "$PUB" == "$(cat cyborgfingers.pub)" ]] || die "cyborgfingers.pub is not the Keychain key's public half"
grep -q "publisherKey = \"$PUB\"" Updater.swift || die "Updater.swift embeds a different public key"

# The version, in Info.plist (build number +1) and on the site. Kept aside for --dry-run.
WORK=$(mktemp -d)
cp Info.plist "$WORK/Info.plist"; cp docs/index.html "$WORK/index.html"
restore() { [[ $DRY = 1 ]] && { cp "$WORK/Info.plist" Info.plist; cp "$WORK/index.html" docs/index.html; }; rm -rf "$WORK"; }
trap restore EXIT
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Info.plist
sed -i '' "s/Version [0-9.]* · /Version $VERSION · /" docs/index.html

./build.sh   # Developer ID signed, hardened runtime; the helper manifest signed with the publisher key
if [[ $NOTARIZE = 1 ]]; then   # the app first, so the stapled app goes into the package and the updater zip
  ditto -c -k --keepParent "build/$APP.app" "$WORK/notarize-app.zip"
  notarize "$WORK/notarize-app.zip" "build/$APP.app"
fi
SKIP_BUILD=1 ./make-pkg.sh   # the Installer package, from that app, signed with the Developer ID Installer certificate
if [[ $NOTARIZE = 1 ]]; then
  notarize "build/$APP.pkg" "build/$APP.pkg"
  spctl --assess --type install -v "build/$APP.pkg" 2>&1 | grep -q "Notarized Developer ID" || die "Gatekeeper doesn't accept build/$APP.pkg"
  echo "Gatekeeper accepts build/$APP.pkg (Notarized Developer ID)"
fi

rm -f "build/$APP.app.zip" "build/$APP.app.zip.sig"
ditto -c -k --keepParent "build/$APP.app" "build/$APP.app.zip"
build/sign-update sign "build/$APP.app.zip" >/dev/null
build/sign-update verify "build/$APP.app.zip" "$PUB" >/dev/null
build/sign-update verify "build/$APP.app/Contents/Resources/helper-manifest" "$PUB" >/dev/null
(cd build && shasum -a 256 "$APP.pkg" "$APP.app.zip" | tee SHA256SUMS.txt)

# Notes: every commit since the last tag, plus what the update means for the helper.
LAST=$(git describe --tags --abbrev=0 2>/dev/null || true)
if ! [[ -f build/RELEASE_NOTES.md && $DRY = 0 ]] || ! head -n 1 build/RELEASE_NOTES.md | grep -q "$APP $VERSION"; then
  {
    echo "**$APP $VERSION**"
    echo
    echo "### Changes"
    git log --no-merges --format='- %s' ${LAST:+$LAST..}HEAD | grep -v '^- release:' || echo "- (fill in)"
    echo
    if ! git diff --quiet ${LAST:-HEAD} -- juiceleft-helper.sh juiceleft-led.c tools/helper-verify.swift cyborgfingers.pub; then
      echo "### Helper"
      echo "This version updates $APP's helper. Copies that already have the self-updating helper take it automatically (it is signed);"
      echo "older copies show the one-time setup card — your password or Touch ID, once."
      echo
    fi
    echo "### Install or update"
    echo "New here: download **$APP.pkg** and open it — Continue, Agree, Install (your password or Touch ID, once) — and $APP opens in the"
    echo "menu bar with its helper set up. Already running $APP: click **Update Now** in the panel (or run the package). Your settings are kept."
    echo "By installing or updating you accept the [$APP licence](https://github.com/CyborgFingers/$APP/blob/main/LICENSE)."
    echo
    echo '```'
    cat build/SHA256SUMS.txt
    echo '```'
  } > build/RELEASE_NOTES.md
fi

echo
echo "Release artefacts in build/: $APP.pkg, $APP.app.zip, $APP.app.zip.sig, SHA256SUMS.txt, RELEASE_NOTES.md"
if [[ $DRY = 1 ]]; then
  echo "Dry run: nothing committed, tagged, pushed or uploaded; Info.plist and docs/index.html put back."
  exit 0
fi

git add Info.plist docs/index.html
git commit -q -m "release: $APP $VERSION"
git tag -a "v$VERSION" -m "$APP $VERSION"
git push origin HEAD --tags
gh release create "v$VERSION" "build/$APP.pkg" "build/$APP.app.zip" "build/$APP.app.zip.sig" --title "$APP $VERSION" --notes-file build/RELEASE_NOTES.md
echo "Published https://github.com/CyborgFingers/$APP/releases/tag/v$VERSION"
