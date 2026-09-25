#!/bin/sh
# JuiceLeft helper — the only part that runs as root.
#   juiceleft-helper.sh install <user>   one-time, from the app's admin prompt
#   juiceleft-helper.sh uninstall        sudo, from ./build.sh uninstall
#   juiceleft-helper.sh                  launchd: apply the app's requests
#
# Two things need root and go through here, each as a one-line request file the app owns and rewrites:
#   powermode  "b 1" / "c 0" …  → `pmset -b|-c powermode 0|1|2`      (Low Power / Automatic / High Power per source)
#   led        "6", "4 0" …     → juiceleft-led (the MagSafe charging light, SMC key ACLC; a pair = colour, then hand back)
# Nothing but the exact whitelisted lines ever reaches pmset or the tool. launchd runs this on every write. A request
# is applied once: its modification time is remembered, so a reboot or a re-run never re-imposes an old choice.
set -u
LABEL=io.github.cyborgfingers.juiceleft.power
DIR="${JUICELEFT_DIR:-/Library/Application Support/JuiceLeft}"   # overrides exist only for test-helper.sh
PMSET="${JUICELEFT_PMSET:-/usr/bin/pmset}"
LEDTOOL="${JUICELEFT_LEDTOOL:-/Library/PrivilegedHelperTools/io.github.cyborgfingers.juiceleft.led}"
REQ="$DIR/powermode"    # user-owned files in a root-owned dir: the app can rewrite them, never swap them for links
DONE="$DIR/applied"     # markers carrying the modification time of the request last applied
LEDREQ="$DIR/led"
LEDDONE="$DIR/led-applied"
BIN=/Library/PrivilegedHelperTools/$LABEL.sh
PLIST=/Library/LaunchDaemons/$LABEL.plist

# The first line of a request file, if it is a plain file newer than its marker.
fresh() {   # $1 = request, $2 = marker → prints the line, or nothing
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  if [ -e "$2" ] && [ ! "$1" -nt "$2" ]; then return 1; fi
  head -c 8 "$1" 2>/dev/null | head -n 1
}

apply_power() {
  req=$(fresh "$REQ" "$DONE") || return 0
  case "$req" in
    "b 0"|"b 1"|"b 2") "$PMSET" -b powermode "${req#b }" ;;
    "c 0"|"c 1"|"c 2") "$PMSET" -c powermode "${req#c }" ;;
    *) ;;   # anything else is ignored
  esac
  touch -r "$REQ" "$DONE"
}

apply_led() {
  req=$(fresh "$LEDREQ" "$LEDDONE") || return 0
  case "$req" in
    0|1|3|4|5|6|7|"3 0"|"4 0"|"1 0") [ -x "$LEDTOOL" ] && "$LEDTOOL" $req ;;   # $req unquoted on purpose: one or two validated tokens
    *) ;;
  esac
  touch -r "$LEDREQ" "$LEDDONE"
}

install_helper() {
  install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools "$DIR"
  install -o root -g wheel -m 755 "$0" "$BIN"
  [ -f "$(dirname "$0")/juiceleft-led" ] && install -o root -g wheel -m 755 "$(dirname "$0")/juiceleft-led" "$LEDTOOL"
  for f in "$REQ" "$LEDREQ"; do
    [ -f "$f" ] || : > "$f"
    chown "$1" "$f"
    chmod 644 "$f"
  done
  touch -r "$REQ" "$DONE"        # whatever is in the files now is not a new request
  touch -r "$LEDREQ" "$LEDDONE"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>/bin/sh</string><string>$BIN</string></array>
	<key>WatchPaths</key><array><string>$REQ</string><string>$LEDREQ</string></array>
	<key>ThrottleInterval</key><integer>1</integer>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  chown root:wheel "$PLIST"
  chmod 644 "$PLIST"
  launchctl bootout system/$LABEL 2>/dev/null
  launchctl bootstrap system "$PLIST"
}

uninstall_helper() {
  launchctl bootout system/$LABEL 2>/dev/null
  [ -x "$LEDTOOL" ] && "$LEDTOOL" 0   # the charging light back to macOS
  rm -rf "$DIR" "$BIN" "$LEDTOOL" "$PLIST"
}

case "${1:-}" in
  install) install_helper "$2" ;;
  uninstall) uninstall_helper ;;
  *) apply_power; apply_led ;;
esac
