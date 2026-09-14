#!/bin/sh
# Loads the diffTerm session daemon under launchd and reports what happened.
# Run as root:   sudo sh /var/jb/var/mobile/proj/diffTerm/Tools/load-sessiond.sh
#
# Self-contained: it writes the plist itself, so it does not depend on the repo
# layout, and it does NOT hide launchctl errors — if the daemon will not load,
# the reason prints.

PLIST=/var/jb/Library/LaunchDaemons/dev.diffterm.sessiond.plist
BIN=/var/jb/Applications/diffTerm.app/sessiond
SOCK="/var/jb/var/mobile/Library/Application Support/diffTerm/sessiond.sock"

if [ "$(id -u)" != "0" ]; then
    echo "must run as root:  sudo sh $0"
    exit 1
fi

if [ ! -x "$BIN" ]; then
    echo "daemon binary missing at $BIN — run 'make install' first"
    exit 1
fi

mkdir -p /var/jb/Library/LaunchDaemons

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.diffterm.sessiond</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
		<string>$SOCK</string>
	</array>
	<key>UserName</key>
	<string>mobile</string>
	<key>KeepAlive</key>
	<true/>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Adaptive</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>/var/jb/var/mobile</string>
	</dict>
</dict>
</plist>
EOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# Remove any stale socket left by a manual test so the fresh daemon owns it.
rm -f "$SOCK"

echo "=== bootout any running copy ==="
launchctl bootout system/dev.diffterm.sessiond 2>&1
echo "=== bootstrap ==="
launchctl bootstrap system "$PLIST" 2>&1 \
    || { echo "(bootstrap failed; trying legacy load)"; launchctl load -w "$PLIST" 2>&1; }

sleep 1
echo
echo "=== plist installed ==="
ls -l "$PLIST"
echo "=== launchctl list ==="
launchctl list | grep diffterm || echo "(NOT listed — did not load)"
echo "=== process ==="
ps -Ao pid,uid,comm | grep sessiond | grep -v grep || echo "(NO sessiond process)"
echo "=== socket ==="
ls -l "$SOCK" 2>&1
echo
echo "done — if the daemon is listed and has a process, open a FRESH diffTerm tab."
