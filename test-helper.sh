#!/bin/sh
# Checks juiceleft-helper.sh's request validation against a fake pmset — no root needed.
set -eu
cd "$(dirname "$0")"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/pmset" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
EOF
chmod +x "$T/pmset"
export JUICELEFT_DIR="$T" JUICELEFT_PMSET="$T/pmset" FAKE_LOG="$T/log"
: > "$T/log"

run() { sh juiceleft-helper.sh; }
N=0
request() { N=$((N + 1)); printf '%s\n' "$1" > "$T/powermode"; touch -t "203001010000.$(printf %02d $N)" "$T/powermode"; }   # each request strictly newer
expect() { [ "$(tail -n 1 "$T/log" 2>/dev/null)" = "$1" ] || { echo "FAIL: $2 (pmset got '$(tail -n 1 "$T/log")', want '$1')"; exit 1; }; echo "ok   $2"; }
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
echo "PASS"
