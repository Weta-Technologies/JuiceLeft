#!/bin/bash
# ./release.sh <version> [--dry-run]   — cuts a JuiceLeft release.
#
# Sets the version (Info.plist, the site), builds the app and the DMG (make-dmg.sh), zips the app for the in-app
# updater (JuiceLeft.app.zip) and signs the zip with the CyborgFingers publisher key from the login Keychain, writes
# the SHA-256s and a draft of the notes, then commits, tags v<version>, pushes and publishes the GitHub release with
# JuiceLeft.dmg, JuiceLeft.app.zip and JuiceLeft.app.zip.sig (the asset names are fixed: the download button and the
# updater rely on them).
#
# --dry-run does everything up to the commit — nothing is committed, tagged, pushed or uploaded — leaves the artefacts
# in build/ and puts the version files back. Run it first; edit build/RELEASE_NOTES.md if you like (a real run for the
# same version keeps your edits).
set -euo pipefail
cd "$(dirname "$0")"

APP=JuiceLeft
VERSION="" DRY=0
for arg in "$@"; do case "$arg" in --dry-run) DRY=1 ;; *) VERSION=$arg ;; esac; done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: ./release.sh <major.minor.patch> [--dry-run]"; exit 1; }
die() { echo "release.sh: $*" >&2; exit 1; }

[[ $DRY = 1 ]] || git diff --quiet && git diff --cached --quiet || die "commit or stash your changes first"
[[ $DRY = 1 ]] || [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "release from main"
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "v$VERSION is already tagged"
security find-generic-password -a cyborgfingers-updates -s "CyborgFingers update signing key" >/dev/null 2>&1 || die "no publisher key in the login Keychain (tools/sign-update.swift keygen, or restore it from your password manager)"
command -v gh >/dev/null || die "gh (GitHub CLI) is needed"

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
sed -i '' "s/Version [0-9.]* · DMG/Version $VERSION · DMG/" docs/index.html

./make-dmg.sh   # builds the app (and signs its helper manifest, since the key is here), then the DMG

rm -f "build/$APP.app.zip" "build/$APP.app.zip.sig"
ditto -c -k --keepParent "build/$APP.app" "build/$APP.app.zip"
build/sign-update sign "build/$APP.app.zip" >/dev/null
build/sign-update verify "build/$APP.app.zip" "$PUB" >/dev/null
build/sign-update verify "build/$APP.app/Contents/Resources/helper-manifest" "$PUB" >/dev/null
(cd build && shasum -a 256 "$APP.dmg" "$APP.app.zip" | tee SHA256SUMS.txt)

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
    echo "New here: download **$APP.dmg**, open it, drag $APP to Applications. Already running $APP: click **Update Now** in the panel"
    echo "(or download the DMG). Your settings are kept. By installing or updating you accept the [$APP licence](https://github.com/CyborgFingers/$APP/blob/main/LICENSE)."
    echo
    echo '```'
    cat build/SHA256SUMS.txt
    echo '```'
  } > build/RELEASE_NOTES.md
fi

echo
echo "Release artefacts in build/: $APP.dmg, $APP.app.zip, $APP.app.zip.sig, SHA256SUMS.txt, RELEASE_NOTES.md"
if [[ $DRY = 1 ]]; then
  echo "Dry run: nothing committed, tagged, pushed or uploaded; Info.plist and docs/index.html put back."
  exit 0
fi

git add Info.plist docs/index.html
git commit -q -m "release: $APP $VERSION"
git tag -a "v$VERSION" -m "$APP $VERSION"
git push origin HEAD --tags
gh release create "v$VERSION" "build/$APP.dmg" "build/$APP.app.zip" "build/$APP.app.zip.sig" --title "$APP $VERSION" --notes-file build/RELEASE_NOTES.md
echo "Published https://github.com/CyborgFingers/$APP/releases/tag/v$VERSION"
