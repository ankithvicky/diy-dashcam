#!/bin/bash
# =============================================================================
#  gps-check.sh — GPS diagnostic for the dashcam (≈2 minutes)
#
#  Phase A: 60 s of raw GPS data with Wi-Fi ON
#  Phase B: 60 s with the Wi-Fi radio OFF (tests whether the Pi's own Wi-Fi drowns out GPS)
#  Then Wi-Fi goes back on, dashcam-sensors restarts and a report is written.
#  Recording keeps running the whole time.
#
#  Run it detached, because SSH drops while Wi-Fi is off:
#      sudo systemd-run --unit=gpscheck "$HOME/gps-check.sh"
#  Wait ~3 minutes, reconnect, then:   cat ~/gps-report.txt
#  (report goes next to this script, or to the path given as the first argument)
#
#  How to read it:
#    corrupt lines > 10 %            → loose GPS TX wire / UART problem
#    B clearly better than A         → Wi-Fi interference: move the antenna away from the Pi
#    A and B both 0–2 sats, weak dB  → blocked sky or damaged antenna / u.FL connector
#    6+ satellites at 30–45 dB       → healthy (a fix follows within minutes)
# =============================================================================
[[ $EUID -eq 0 ]] || { echo "run with sudo (ideally via systemd-run, see header)"; exit 1; }
OUT="${1:-$(dirname "$(readlink -f "$0")")/gps-report.txt}"
TMP="$(mktemp -d)"
exec > "$OUT" 2>&1
echo "GPS check  $(date)"
cleanup() { nmcli radio wifi on >/dev/null 2>&1; systemctl start dashcam-sensors; rm -rf "$TMP"; }
trap cleanup EXIT
systemctl stop dashcam-sensors          # free the GPS port (recording keeps running)
sleep 1
stty -F /dev/serial0 9600 raw -echo cs8 -parenb -cstopb clocal cread
echo "Wi-Fi now: $(nmcli -t -f NAME,DEVICE con show --active | grep wlan0 | cut -d: -f1 | sed 's/.*/(connected)/')"
echo "Power: $(vcgencmd get_throttled)   Temp: $(vcgencmd measure_temp)"
timeout 60 cat /dev/serial0 > "$TMP/a.txt"
nmcli radio wifi off; sleep 3
timeout 60 cat /dev/serial0 > "$TMP/b.txt"
nmcli radio wifi on
echo
python3 - "Phase A (Wi-Fi ON)" "$TMP/a.txt" "Phase B (Wi-Fi OFF)" "$TMP/b.txt" << 'PY'
import sys, functools
def ok(l):
    if not l.startswith("$") or "*" not in l: return False
    b, c = l[1:].rsplit("*", 1)
    try: return functools.reduce(lambda a, ch: a ^ ord(ch), b, 0) == int(c[:2], 16)
    except ValueError: return False
for name, path in zip(sys.argv[1::2], sys.argv[2::2]):
    try: raw = open(path, errors="ignore").read().replace("\r", "").split("\n")
    except OSError: print(f"{name}: no data file"); continue
    lines = [l.strip() for l in raw if l.strip().startswith("$")]
    good = [l for l in lines if ok(l)]
    view, sats, used, fix, timed = 0, {}, 0, "V", False
    for l in good:
        f = l.split("*")[0].split(",")
        t = f[0][3:]
        if t == "GSV":
            view = max(view, int(f[3] or 0))
            for i in range(4, len(f) - 3, 4):
                if f[i]: sats[f[i]] = max(sats.get(f[i], 0), int(f[i + 3] or 0))
        elif t == "GGA" and len(f) > 7: used = max(used, int(f[7] or 0))
        elif t == "RMC" and len(f) > 2:
            fix = "A" if f[2] == "A" or fix == "A" else "V"; timed = timed or bool(f[1])
    pct = 100 * (len(lines) - len(good)) / len(lines) if lines else 0
    print(f"{name}: {len(lines)} lines, {len(lines)-len(good)} corrupt ({pct:.0f}%)")
    print(f"   satellites in view (max): {view}   used: {used}   fix: {'YES' if fix=='A' else 'no'}   GPS time known: {'yes' if timed else 'no'}")
    print(f"   signal per satellite (dB, good = 30-45): " + (", ".join(f"#{k}={v}" for k, v in sorted(sats.items(), key=lambda x: -x[1])) or "none heard"))
PY
echo; echo "done $(date +%T)"
