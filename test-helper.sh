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
echo "PASS"
