#!/bin/sh
# Checks juiceleft-helper.sh's request validation against a fake pmset and a fake juiceleft-led — no root needed.
set -eu
cd "$(dirname "$0")"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/pmset" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
EOF
cat > "$T/ledtool" <<'EOF'
#!/bin/sh
echo "led $*" >> "$FAKE_LOG"
EOF
chmod +x "$T/pmset" "$T/ledtool"
export JUICELEFT_DIR="$T" JUICELEFT_PMSET="$T/pmset" JUICELEFT_LEDTOOL="$T/ledtool" FAKE_LOG="$T/log"
: > "$T/log"

run() { sh juiceleft-helper.sh; }
N=0
stamp() { N=$((N + 1)); touch -t "203001010000.$(printf %02d $N)" "$1"; }   # each request strictly newer than the last
request() { printf '%s\n' "$1" > "$T/powermode"; stamp "$T/powermode"; }
led() { printf '%s\n' "$1" > "$T/led"; stamp "$T/led"; }
expect() { [ "$(tail -n 1 "$T/log" 2>/dev/null)" = "$1" ] || { echo "FAIL: $2 (got '$(tail -n 1 "$T/log")', want '$1')"; exit 1; }; echo "ok   $2"; }
count() { wc -l < "$T/log" | tr -d ' '; }

request "b 1"; run; expect "-b powermode 1" "battery → low power"
request "c 2"; run; expect "-c powermode 2" "adapter → high power"
request "b 0"; run; expect "-b powermode 0" "battery → automatic"
n=$(count); run; [ "$(count)" = "$n" ] || { echo "FAIL: an applied request was applied again"; exit 1; }; echo "ok   same request is never re-applied"
for bad in "b 3" "x 1" "b 1; rm -rf /" "a 0" "" "1 b" "c -1" "bb 1"; do
  n=$(count); request "$bad"; run
  [ "$(count)" = "$n" ] || { echo "FAIL: '$bad' reached pmset: $(tail -n 1 "$T/log")"; exit 1; }
done
echo "ok   only b|c × 0|1|2 reach pmset"
rm -f "$T/powermode"; ln -s /etc/passwd "$T/powermode"; n=$(count); run; [ "$(count)" = "$n" ] || { echo "FAIL: symlink request was followed"; exit 1; }; echo "ok   a symlinked request is ignored"
rm -f "$T/powermode"

led "6"; run; expect "led 6" "light → slow blink"
led "4 0"; run; expect "led 4 0" "light → orange, then handed back"
led "3 0"; run; expect "led 3 0" "light → green, then handed back"
led "0"; run; expect "led 0" "light → macOS"
n=$(count); run; [ "$(count)" = "$n" ] || { echo "FAIL: an applied light request was applied again"; exit 1; }; echo "ok   same light request is never re-applied"
for bad in "2" "8" "6 0" "0 0 0" "6; rm -rf /" "" "-1" "3 x" "33" "7 7"; do
  n=$(count); led "$bad"; run
  [ "$(count)" = "$n" ] || { echo "FAIL: '$bad' reached the light tool: $(tail -n 1 "$T/log")"; exit 1; }
done
echo "ok   only 0|1|3|4|5|6|7 and the hand-back pairs reach the light tool"
rm -f "$T/led"; ln -s /etc/passwd "$T/led"; n=$(count); run; [ "$(count)" = "$n" ] || { echo "FAIL: symlinked light request was followed"; exit 1; }; echo "ok   a symlinked light request is ignored"
rm -f "$T/led"

# Signed helper updates, from a fake app bundle. Only a manifest signed by the (test) publisher key, with every hash
# matching and no downgrade, gets installed; everything else leaves the installed helper exactly as it was.
TOOLS="$T/tools"; mkdir -p "$TOOLS"; export JUICELEFT_TOOLS="$TOOLS"
[ build/sign-update -nt tools/sign-update.swift ] || swiftc -O tools/sign-update.swift -o build/sign-update
[ build/helper-verify -nt tools/helper-verify.swift ] || swiftc -O tools/helper-verify.swift -o build/helper-verify
PUB=$(build/sign-update testkey "$T/key")
build/sign-update testkey "$T/badkey" >/dev/null
LABEL=io.github.cyborgfingers.juiceleft.power
RES="$T/Fake.app/Contents/Resources"; mkdir -p "$RES"
bundle() {   # $1 = version, $2 = key dir: a fake app bundle carrying this helper, a new led tool, the verifier, the key, a signed manifest
  cp juiceleft-helper.sh "$RES/"; printf '#!/bin/sh\necho new-led\n' > "$RES/juiceleft-led"; cp build/helper-verify "$RES/juiceleft-verify"; echo "$PUB" > "$RES/cyborgfingers.pub"
  (cd "$RES" && { echo "version $1"; shasum -a 256 juiceleft-helper.sh juiceleft-led juiceleft-verify cyborgfingers.pub; } > helper-manifest)
  build/sign-update sign "$RES/helper-manifest" --key-file "$2/private.key" >/dev/null
}
installed() {   # the installed set before the update: an old script, the verifier, the key, a 1.1.0 manifest
  echo old > "$TOOLS/$LABEL.sh"; cp build/helper-verify "$TOOLS/$LABEL.verify"; echo "$PUB" > "$TOOLS/$LABEL.pub"; echo "version 1.1.0" > "$TOOLS/$LABEL.manifest"
  rm -f "$T/update" "$T/update-applied"
}
ask() { echo "$T/Fake.app" > "$T/update"; stamp "$T/update"; run; }
untouched() { [ "$(cat "$TOOLS/$LABEL.sh")" = old ] && [ "$(cat "$TOOLS/$LABEL.manifest")" = "version 1.1.0" ] || { echo "FAIL: $1 changed the installed helper"; exit 1; }; echo "ok   $1"; }

installed; bundle 1.2.0 "$T/key"; ask
cmp -s "$TOOLS/$LABEL.sh" juiceleft-helper.sh && [ "$(head -n 1 "$TOOLS/$LABEL.manifest")" = "version 1.2.0" ] && [ "$(sh "$JUICELEFT_LEDTOOL")" = new-led ] \
  && cmp -s "$TOOLS/$LABEL.verify" build/helper-verify && [ ! -e "$TOOLS/$LABEL.sh.new" ] && [ -z "$(ls -d "$T"/stage.* 2>/dev/null)" ] \
  || { echo "FAIL: a signed update was not installed"; exit 1; }; echo "ok   signed helper update installed: script, light tool, verifier, manifest; stage removed"
echo old > "$TOOLS/$LABEL.sh"; run; [ "$(cat "$TOOLS/$LABEL.sh")" = old ] || { echo "FAIL: an applied update request was applied again"; exit 1; }; echo "ok   the same request is never applied again"
installed; bundle 1.2.0 "$T/key"; echo tampered >> "$RES/juiceleft-led"; ask; untouched "a file changed after signing is refused"
installed; bundle 1.2.0 "$T/badkey"; ask; untouched "a manifest signed with the wrong key is refused"
installed; bundle 1.0.0 "$T/key"; ask; untouched "a downgrade is refused"
installed; bundle 1.2.0 "$T/key"; rm "$RES/helper-manifest.sig"; ask; untouched "an unsigned bundle is refused"
installed; bundle 1.2.0 "$T/key"; ln -s "$T/Fake.app" "$T/update"; run; untouched "a symlinked request is ignored"
installed; bundle 1.2.0 "$T/key"; echo "/etc" > "$T/update"; stamp "$T/update"; run; untouched "a request that isn't an app bundle path is ignored"
echo "PASS"
