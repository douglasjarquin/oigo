#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "usage: $0 <Oigo.app>"
    exit 64
fi

app="${1%/}"
executable="$app/Contents/MacOS/Oigo"
if [[ ! -x "$executable" ]]; then
    print -u2 "FAIL: executable is missing or not executable: $executable"
    exit 1
fi
/usr/bin/python3 - "$executable" <<'PY'
import os
import signal
import subprocess
import sys
import time

executable = sys.argv[1]
crash_signals = {
    signal.SIGABRT,
    signal.SIGSEGV,
    signal.SIGILL,
    signal.SIGBUS,
    signal.SIGTRAP,
}

window_server_running = (
    subprocess.call(["/usr/bin/pgrep", "-qx", "WindowServer"]) == 0
)

try:
    process = subprocess.Popen([executable])
except OSError as error:
    if not window_server_running:
        print(
            "INCONCLUSIVE: could not start Oigo.app because WindowServer is not running: "
            + str(error)
        )
        sys.exit(0)
    sys.stderr.write("FAIL: could not start Oigo.app: %s\n" % error)
    sys.exit(1)

time.sleep(3)
status = process.poll()
if status is None:
    print("GREEN: bounded Oigo.app process stayed alive")
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        print("sending SIGKILL after terminate grace period")
        process.kill()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.kill(process.pid, signal.SIGKILL)
            sys.stderr.write("FAIL: Oigo.app did not die after SIGKILL\n")
            sys.exit(1)
    sys.exit(0)

if status < 0:
    received = -status
    try:
        name = signal.Signals(received).name
    except ValueError:
        name = str(received)
    if received in crash_signals:
        sys.stderr.write("FAIL: Oigo.app crashed with %s\n" % name)
        sys.exit(1)
    if not window_server_running:
        print(
            "INCONCLUSIVE: Oigo.app terminated by %s and WindowServer is not running"
            % name
        )
        sys.exit(0)
    sys.stderr.write("FAIL: Oigo.app terminated by %s\n" % name)
    sys.exit(1)

if status != 0:
    sys.stderr.write("FAIL: Oigo.app exited %s\n" % status)
    sys.exit(1)

if not window_server_running:
    print("INCONCLUSIVE: Oigo.app exited 0 and WindowServer is not running")
    sys.exit(0)

sys.stderr.write("FAIL: Oigo.app exited 0 before the smoke window\n")
sys.exit(1)
PY

print "INCONCLUSIVE: microphone permission"
print "INCONCLUSIVE: Speech recognition"
print "INCONCLUSIVE: Accessibility"
print "INCONCLUSIVE: hardware capture"
print "INCONCLUSIVE: Developer ID signing and notarization"
print "INCONCLUSIVE: clean-account dogfood"
print "This job validates the Xcode Oigo.app bundle only. It is not the SwiftPM contract harness."
