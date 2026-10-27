#!/bin/bash
# =============================================================================
#  setup-dashcam.sh  (v9) — one-shot installer for the Pi 3 B+ dashcam
#
#  THIS FILE IS THE SOURCE OF TRUTH. On a freshly flashed card (Raspberry Pi
#  Imager: hostname, user, Wi-Fi, SSH) this one command builds the whole dashcam:
#      sudo bash setup-dashcam.sh            # uses the user who ran sudo
#      sudo bash setup-dashcam.sh vicky      # or name the user explicitly
#      add --no-reboot to skip the automatic reboot at the end
#  Put wifi.conf (hotspot name + password, see wifi.conf.example) in the SAME
#  folder as this script before running it. It is copied to /etc and kept.
#  Safe to re-run any time (keeps /etc/dashcam.conf, installs the latest programs).
#  Needs internet once (apt packages).
#
#  Installs / updates:
#    /etc/dashcam.conf               all settings in ONE place (kept; new keys appended)
#    /etc/dashcam-wifi.conf          hotspot name + password (root only, from wifi.conf)
#    /opt/dashcam/record.sh          camera → 1-minute H.264 segments, numbered per drive
#    /opt/dashcam/housekeeper.py     .mp4 wrap, real-time names, sensor .csv, crash-lock,
#                                    rolling delete
#    /opt/dashcam/sensors.py         GPS + accelerometer, sets clock from GPS, jolt detect
#    /opt/dashcam/wifi.sh            Wi-Fi mode keeper: home Wi-Fi or the Pi's own hotspot
#    /usr/local/bin/dashcam          control: start/stop, config, wifi, clear media/logs, disk
#    /usr/local/bin/dashcam-status   one-command live health report
#    /usr/local/bin/dashcam-report   trip + health history (startup time, GPS, heat, power, gaps)
#    dashcam-sensors / dashcam-record / dashcam-housekeeper / dashcam-wifi   systemd services
#    Samba (SMB) read-only shares "clips" and "locked" for the phone
#  Also: enables I2C + serial (GPS), disables Bluetooth on the serial port.
#
#  Folders:  ~/dashcam/clips   normal clips (+ .csv), oldest deleted when disk is full
#            ~/dashcam/locked  crash clips, never removed by normal rotation
#            ~/dashcam/logs    per-boot sensor log (1 row per second) + events.csv
# =============================================================================
set -euo pipefail
trap 'echo "!! setup FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

VERSION=v9
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_REBOOT=1
ARGS=()
for a in "$@"; do [[ "$a" == "--no-reboot" ]] && AUTO_REBOOT=0 || ARGS+=("$a"); done
DASH_USER="${ARGS[0]:-${SUDO_USER:-}}"
[[ $EUID -eq 0 ]] || { echo "Please run with sudo:  sudo bash $0" >&2; exit 1; }
[[ -n "$DASH_USER" && "$DASH_USER" != "root" ]] || { echo "Usage: sudo bash $0 <username>" >&2; exit 1; }
HOME_DIR="$(getent passwd "$DASH_USER" | cut -d: -f6)"
[[ -n "$HOME_DIR" ]] || { echo "User '$DASH_USER' not found" >&2; exit 1; }
echo "==> Setting up dashcam $VERSION for '$DASH_USER' ($HOME_DIR)"

# ---------- 1. packages ----------
echo "==> Installing packages…"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ffmpeg python3-smbus2 i2c-tools samba dnsmasq-base iw >/dev/null
if ! command -v rpicam-vid >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rpicam-apps-lite >/dev/null \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rpicam-apps >/dev/null
fi

# ---------- 2. interfaces: I2C (accelerometer) + serial (GPS) ----------
echo "==> Enabling I2C and serial port…"
REBOOT_NEEDED=0
if command -v raspi-config >/dev/null; then
  raspi-config nonint do_i2c 0 || true
  raspi-config nonint do_serial_cons 1 || true     # no login console on serial
  raspi-config nonint do_serial_hw 0 || true       # serial hardware ON
fi
CFG=/boot/firmware/config.txt
add_cfg() {   # add a line to config.txt under an [all] section (once)
  grep -q "^$1\$" "$CFG" && return 0
  [[ "$(grep -E '^\[' "$CFG" | tail -1 || true)" == "[all]" ]] || printf '\n[all]\n' >> "$CFG"
  echo "$1" >> "$CFG"; REBOOT_NEEDED=1
}
add_cfg "dtparam=i2c_arm=on"
add_cfg "enable_uart=1"
add_cfg "dtoverlay=disable-bt"
# interfaces that only become live after a reboot
[[ -e /dev/i2c-1 ]] || REBOOT_NEEDED=1
[[ "$(readlink /dev/serial0 2>/dev/null || true)" == "ttyAMA0" ]] || REBOOT_NEEDED=1
usermod -aG dialout,i2c,video "$DASH_USER"

# ---------- 2b. camera ----------
echo "==> Checking camera…"
if systemctl is-active --quiet dashcam-record; then
  echo "    camera in use by the recorder — OK"
elif rpicam-hello --list-cameras 2>&1 | grep -qi "imx219"; then
  echo "    IMX219 camera detected"
elif grep -q "^dtoverlay=imx219" "$CFG"; then
  echo "    !! camera not detected yet (overlay already set) — check the ribbon after reboot"
else
  echo "    camera not auto-detected → forcing the IMX219 driver"
  sed -i 's/^camera_auto_detect=1/camera_auto_detect=0/' "$CFG"
  add_cfg "dtoverlay=imx219"
fi

# ---------- 2c. timezone (clip names use local time) ----------
conf_val() {   # value of KEY in /etc/dashcam.conf, without "# comment" (empty if missing)
  grep -E "^$1=" /etc/dashcam.conf 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/#.*//; s/[[:space:]]*$//' || true
}
TZ_WANT="$(conf_val TIMEZONE)"
TZ_WANT="${TZ_WANT:-Asia/Kolkata}"
if [[ "$(timedatectl show -p Timezone --value 2>/dev/null || true)" != "$TZ_WANT" ]]; then
  timedatectl set-timezone "$TZ_WANT" && echo "==> Timezone set to $TZ_WANT"
fi

# remove the temporary GPS logger from testing (it blocks the GPS port)
if systemctl list-unit-files gpslog.service >/dev/null 2>&1; then
  systemctl disable --now gpslog >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/gpslog.service
fi

# ---------- 3. config ----------
if [[ ! -f /etc/dashcam.conf ]]; then
  echo "==> Writing /etc/dashcam.conf"
  cat > /etc/dashcam.conf << EOF
# ---- Dashcam settings (edit, then: dashcam restart)
CLIPS_DIR=$HOME_DIR/dashcam/clips
LOCKED_DIR=$HOME_DIR/dashcam/locked

# Camera: full-sensor mode keeps the whole 175° view
SENSOR_MODE=1640:1232
WIDTH=1640
HEIGHT=1232
FPS=30
BITRATE=6000000        # 6 Mbps ≈ 2.7 GB/hour
SEGMENT_SEC=60         # length of each clip

# Storage: delete oldest clips when free space drops below this %
MIN_FREE_PCT=10
EOF
fi
add_conf() { grep -q "^$1=" /etc/dashcam.conf || echo "$1=$2" >> /etc/dashcam.conf; }
grep -q "Crash lock" /etc/dashcam.conf || printf '\n# ---- Crash lock + GPS (v2)\n' >> /etc/dashcam.conf
add_conf TIMEZONE          "Asia/Kolkata"
add_conf LOCK_G            "2.5      # jolt (g-force) that locks a clip; lower = more sensitive"
add_conf LOCK_BEFORE_SEC   "60"
add_conf LOCK_AFTER_SEC    "30"
add_conf LOCK_COOLDOWN_SEC "30"
add_conf GPS_DEVICE        "/dev/serial0"
add_conf GPS_SET_CLOCK     "1"
add_conf LOG_KEEP_DAYS     "30       # sensor logs older than this are deleted"
add_conf LOGS_MAX_MB       "200      # sensor logs never use more than this"
add_conf TEMP_HIGH_C       "70       # log a TEMP_HIGH event above this"
add_conf TEMP_CRIT_C       "80"
add_conf GPS_LOST_SEC      "10       # log GPS_LOST after this many seconds without fix"
add_conf EVENTS_MAX_MB     "5        # events.csv rotates at this size (1 old copy kept)"
add_conf LOCKED_MAX_PCT    "20       # crash clips may use at most this % of the card (oldest go first)"
grep -q "Phone access" /etc/dashcam.conf || printf '\n# ---- Phone access: Wi-Fi hotspot + SMB (v8). Name/password live in /etc/dashcam-wifi.conf\n' >> /etc/dashcam.conf
add_conf HOTSPOT_BAND        "a        # a = 5 GHz (faster), bg = 2.4 GHz (works with every phone)"
add_conf HOTSPOT_CHANNEL     "36       # 36 for 5 GHz; 2.4 GHz always uses channel 6"
add_conf WIFI_COUNTRY        "IN       # Wi-Fi regulatory country (needed for 5 GHz)"
add_conf WIFI_HOME_WAIT_SEC  "25       # seconds to wait for home Wi-Fi before starting the hotspot"
grep -q "Camera mounting" /etc/dashcam.conf || printf '\n# ---- Camera mounting (v9)\n' >> /etc/dashcam.conf
add_conf CAMERA_ROTATION     "0        # 0 = normal, 180 = camera mounted upside down (picture is turned back upright)"

# ---------- 3b. system journal: capped at 50 MB, survives reboots (to debug car trips) ----------
mkdir -p /etc/systemd/journald.conf.d /var/log/journal
cat > /etc/systemd/journald.conf.d/dashcam.conf << 'JEOF'
[Journal]
Storage=persistent
SystemMaxUse=50M
SystemMaxFileSize=10M
MaxRetentionSec=1month
JEOF
systemctl restart systemd-journald

# ---------- 4. program files ----------
mkdir -p /opt/dashcam
echo "==> Writing programs to /opt/dashcam"
cat > /opt/dashcam/record.sh << '__DASHCAM_EOF_RECORD_SH__'
#!/bin/bash
# Continuous recording in 1-minute H.264 segments.
# Every start = a new "drive" number:  S00042_0001.h264, S00042_0002.h264 …
# (the housekeeper renames them to real times once the clock is trusted)
source /etc/dashcam.conf
STATE="$(dirname "$CLIPS_DIR")/.state"
mkdir -p "$CLIPS_DIR" "$LOCKED_DIR" "$STATE"
n=$(( $(cat "$STATE/session" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STATE/session"
SESSION=$(printf 'S%05d' "$n")
echo "$SESSION $(cat /proc/sys/kernel/random/boot_id)" >> "$STATE/sessions"
# camera mounted upside down? the sensor flips the image itself (no CPU cost)
ROT="${CAMERA_ROTATION:-0}"
if [[ "$ROT" != 0 && "$ROT" != 180 ]]; then
  echo "CAMERA_ROTATION=$ROT not supported (use 0 or 180) — recording unrotated"; ROT=0
fi
exec rpicam-vid -n -t 0 \
  --mode "$SENSOR_MODE" --width "$WIDTH" --height "$HEIGHT" --framerate "$FPS" \
  --rotation "$ROT" \
  --bitrate "$BITRATE" --intra "$FPS" --inline \
  --segment $((SEGMENT_SEC * 1000)) \
  -o "$CLIPS_DIR/${SESSION}_%04d.h264"
__DASHCAM_EOF_RECORD_SH__

cat > /opt/dashcam/sensors.py << '__DASHCAM_EOF_SENSORS_PY__'
#!/usr/bin/env python3
"""
dashcam sensors service
  * reads the GPS (NMEA over /dev/serial0) and the MPU-6050 (I2C, 0x68)
  * sets the system clock from GPS time (needs CAP_SYS_TIME)
  * watches for clock jumps (GPS or Wi-Fi/NTP) and records them so clips
    recorded before the jump can be renamed to their real time
  * detects jolts above LOCK_G and asks the housekeeper to lock the clip
  * logs health events (power dips, GPS loss, heat, SD errors, startup timing,
    power cuts) with GPS position to <base>/logs/events.csv
  * writes:  /run/dashcam/state.json   (live status, every second)
             /run/dashcam/clock.json   (time_ok + list of clock jumps)
             /run/dashcam/locks        (one line per crash/jolt event)
             <base>/logs/boot_*.csv    (1 row per second: GPS + g-force)
"""
import os, sys, time, json, math, threading, termios, select, calendar, subprocess, glob

# ---------------------------------------------------------------- config
def load_conf(path="/etc/dashcam.conf"):
    c = {}
    try:
        for line in open(path):
            line = line.split("#", 1)[0].strip()
            if "=" in line:
                k, v = line.split("=", 1)
                c[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return c

C = load_conf()
CLIPS_DIR   = C.get("CLIPS_DIR", os.path.expanduser("~/dashcam/clips"))
BASE        = os.path.dirname(CLIPS_DIR.rstrip("/"))
LOGS_DIR    = os.path.join(BASE, "logs")
RUN         = "/run/dashcam"
GPS_DEV     = C.get("GPS_DEVICE", "/dev/serial0")
GPS_SET     = C.get("GPS_SET_CLOCK", "1") == "1"
LOCK_G      = float(C.get("LOCK_G", "2.5"))
LOCK_COOL   = float(C.get("LOCK_COOLDOWN_SEC", "30"))
LOG_KEEP_D  = int(C.get("LOG_KEEP_DAYS", "30"))

os.makedirs(RUN, exist_ok=True)
os.makedirs(LOGS_DIR, exist_ok=True)

def log(*a):
    print(*a, flush=True)          # goes to journalctl -u dashcam-sensors

def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)

lock = threading.Lock()
S = {   # shared live state
    "gps": {"alive": False, "fix": False, "sats_used": 0, "sats_visible": 0,
            "lat": None, "lon": None, "kmh": None, "heading": None, "utc": None,
            "last_sentence": 0.0},
    "imu": {"ok": False, "g": None, "g_peak_10s": None, "gyro": None},
    "last_lock": None,
}
sec = {"gmax": 0.0, "gyromax": 0.0, "event": ""}     # per-second aggregates
clock = {"time_ok": False, "source": "none", "jumps": []}
gps_clock_set = False

# ---------------------------------------------------------------- GPS
def nmea_ok(line):
    if not line.startswith("$") or "*" not in line:
        return False
    body, cs = line[1:].rsplit("*", 1)
    x = 0
    for ch in body:
        x ^= ord(ch)
    try:
        return x == int(cs[:2], 16)
    except ValueError:
        return False

def dm_to_deg(v, hemi, deg_len):
    if not v:
        return None
    d = float(v[:deg_len]) + float(v[deg_len:]) / 60.0
    return -d if hemi in ("S", "W") else d

def handle_nmea(line):
    global gps_clock_set
    if not nmea_ok(line):
        return
    f = line.split("*")[0].split(",")
    t = f[0][3:]                         # RMC / GGA / GSV (works for $GP and $GN)
    with lock:
        g = S["gps"]
        g["alive"] = True
        g["last_sentence"] = time.monotonic()
        if t == "RMC" and len(f) >= 10:
            if f[2] == "A":
                g["fix"] = True
                g["lat"] = dm_to_deg(f[3], f[4], 2)
                g["lon"] = dm_to_deg(f[5], f[6], 3)
                g["kmh"] = round(float(f[7] or 0) * 1.852, 1)
                g["heading"] = float(f[8]) if f[8] else None
                try:
                    hh, mm, ss = int(f[1][0:2]), int(f[1][2:4]), float(f[1][4:])
                    dd, mo, yy = int(f[9][0:2]), int(f[9][2:4]), 2000 + int(f[9][4:6])
                    utc = calendar.timegm((yy, mo, dd, hh, mm, 0)) + ss
                    g["utc"] = utc
                except (ValueError, IndexError):
                    utc = None
            else:
                g["fix"] = False
                utc = None
        elif t == "GGA" and len(f) >= 8:
            g["sats_used"] = int(f[7] or 0)
            utc = None
        elif t == "GSV" and len(f) >= 4:
            g["sats_visible"] = int(f[3] or 0)
            utc = None
        else:
            utc = None
    # set the system clock from GPS (outside the lock)
    if utc and GPS_SET and (not gps_clock_set or abs(utc - time.time()) > 2):
        try:
            time.clock_settime(time.CLOCK_REALTIME, utc)
            if not gps_clock_set:
                log(f"clock set from GPS: {time.strftime('%Y-%m-%d %H:%M:%S')}")
            gps_clock_set = True
        except PermissionError:
            log("cannot set clock (missing CAP_SYS_TIME)")
            gps_clock_set = True          # don't spam

def gps_thread():
    while True:
        fd = None
        try:
            fd = os.open(GPS_DEV, os.O_RDONLY | os.O_NOCTTY)
            a = termios.tcgetattr(fd)
            a[0] = 0
            a[1] = 0
            a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
            a[3] = 0
            a[4] = a[5] = termios.B9600
            a[6][termios.VMIN] = 1
            a[6][termios.VTIME] = 0
            termios.tcsetattr(fd, termios.TCSANOW, a)
            termios.tcflush(fd, termios.TCIFLUSH)
            buf = b""
            while True:
                r, _, _ = select.select([fd], [], [], 5)
                if not r:
                    with lock:
                        S["gps"]["alive"] = False
                    continue
                chunk = os.read(fd, 1024)
                if not chunk:
                    raise OSError("serial closed")
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    handle_nmea(line.decode("ascii", "ignore").strip())
                if len(buf) > 4096:
                    buf = b""
        except Exception as e:
            log(f"GPS error: {e}; retrying in 3 s")
            with lock:
                S["gps"]["alive"] = False
            time.sleep(3)
        finally:
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass

# ---------------------------------------------------------------- IMU
def imu_thread():
    try:
        from smbus2 import SMBus
    except ImportError:
        log("smbus2 missing: sudo apt install python3-smbus2")
        return
    ADDR = 0x68
    w = lambda h, l: ((h << 8) | l) - 65536 if ((h << 8) | l) > 32767 else ((h << 8) | l)
    while True:
        try:
            with SMBus(1) as bus:
                bus.write_byte_data(ADDR, 0x6B, 0x00)   # wake up
                bus.write_byte_data(ADDR, 0x1A, 0x03)   # low-pass filter ~44 Hz
                bus.write_byte_data(ADDR, 0x1B, 0x08)   # gyro  ±500 °/s  (65.5 LSB per °/s)
                bus.write_byte_data(ADDR, 0x1C, 0x10)   # accel ±8 g      (4096 LSB per g)
                time.sleep(0.1)
                # gyro bias from first ~1 s (assumes not shaking at start)
                bx = by = bz = 0.0
                for _ in range(50):
                    d = bus.read_i2c_block_data(ADDR, 0x43, 6)
                    bx += w(d[0], d[1]); by += w(d[2], d[3]); bz += w(d[4], d[5])
                    time.sleep(0.02)
                bx, by, bz = bx / 50, by / 50, bz / 50
                log("MPU-6050 ready (±8 g, ±500 °/s)")
                window = []                              # (mono, g) for 10 s peak
                last_lock_mono = -1e9
                while True:
                    d = bus.read_i2c_block_data(ADDR, 0x3B, 14)
                    ax, ay, az = (w(d[i], d[i + 1]) / 4096.0 for i in (0, 2, 4))
                    gx = (w(d[8], d[9]) - bx) / 65.5
                    gy = (w(d[10], d[11]) - by) / 65.5
                    gz = (w(d[12], d[13]) - bz) / 65.5
                    g = math.sqrt(ax * ax + ay * ay + az * az)
                    rot = math.sqrt(gx * gx + gy * gy + gz * gz)
                    now = time.monotonic()
                    window.append((now, g))
                    while window and now - window[0][0] > 10:
                        window.pop(0)
                    with lock:
                        S["imu"].update(ok=True, g=round(g, 2),
                                        g_peak_10s=round(max(x[1] for x in window), 2),
                                        gyro=[round(gx, 1), round(gy, 1), round(gz, 1)])
                        sec["gmax"] = max(sec["gmax"], g)
                        sec["gyromax"] = max(sec["gyromax"], rot)
                        if g >= LOCK_G and now - last_lock_mono > LOCK_COOL:
                            last_lock_mono = now
                            wall = time.time()
                            S["last_lock"] = {"wall": wall, "g": round(g, 2)}
                            sec["event"] = f"LOCK {g:.2f}g"
                            with open(os.path.join(RUN, "locks"), "a") as f:
                                f.write(f"{wall:.2f} {g:.2f}\n")
                            log(f"JOLT {g:.2f} g -> clip lock requested")
                    time.sleep(0.01)                     # ~100 readings / s
        except Exception as e:
            log(f"IMU error: {e}; retrying in 3 s")
            with lock:
                S["imu"]["ok"] = False
            time.sleep(3)

def ntp_synced():
    try:
        out = subprocess.run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return out == "yes"
    except Exception:
        return False

# ---------------------------------------------------------------- health / events
EVENTS = os.path.join(LOGS_DIR, "events.csv")
EV_MAX = float(C.get("EVENTS_MAX_MB", "5")) * 1024 * 1024
TEMP_HIGH = float(C.get("TEMP_HIGH_C", "70"))
TEMP_CRIT = float(C.get("TEMP_CRIT_C", "80"))
GPS_LOST_SEC = float(C.get("GPS_LOST_SEC", "10"))
STATE_DIR = os.path.join(BASE, ".state")
BOOT8 = open("/proc/sys/kernel/random/boot_id").read().strip()[:8]

def uptime():
    return float(open("/proc/uptime").read().split()[0])

def event(name, value="", detail="", gps=None, up=None):
    """append one line to logs/events.csv (rotates at EVENTS_MAX_MB, keeps 1 old file)"""
    try:
        if os.path.exists(EVENTS) and os.path.getsize(EVENTS) > EV_MAX:
            os.replace(EVENTS, EVENTS[:-4] + ".1.csv")
        new = not os.path.exists(EVENTS)
        with open(EVENTS, "a") as f:
            if new:
                f.write("local_time,boot,uptime_s,event,value,detail,lat,lon,kmh\n")
            lat = lon = kmh = ""
            if gps and gps.get("fix") and gps.get("alive"):
                lat, lon, kmh = f"{gps['lat']:.6f}", f"{gps['lon']:.6f}", f"{gps['kmh']}"
            detail = str(detail).replace(",", ";")
            u = uptime() if up is None else up
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')},{BOOT8},{u:.1f},{name},{value},{detail},{lat},{lon},{kmh}\n")
        log(f"EVENT {name} {value} {detail}")
    except OSError as e:
        log(f"event write failed: {e}")

def read_temp():
    try:
        return int(open("/sys/class/thermal/thermal_zone0/temp").read()) / 1000.0
    except (OSError, ValueError):
        return None

def find_uv_alarm():
    for d in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            if open(os.path.join(d, "name")).read().strip() == "rpi_volt":
                return os.path.join(d, "in0_lcrit_alarm")
        except OSError:
            pass
    return None

def read_throttled():
    try:
        out = subprocess.run(["vcgencmd", "get_throttled"], capture_output=True, text=True, timeout=3).stdout
        return out.strip().split("=")[1]
    except Exception:
        return ""

def gps_now():
    with lock:
        g = dict(S["gps"])
    if time.monotonic() - g["last_sentence"] > 5:
        g["alive"] = False
    return g

def kernel_watch():
    """follow the kernel log: under-voltage start/end and SD-card errors (with GPS position)"""
    posf = os.path.join(RUN, "kmsg_pos")
    try:
        last = float(open(posf).read())
    except (OSError, ValueError):
        last = -1.0
    uv_start = None
    while True:
        try:
            p = subprocess.Popen(["journalctl", "-k", "-b", "-f", "-o", "short-monotonic", "--no-pager"],
                                 stdout=subprocess.PIPE, text=True)
            for line in p.stdout:
                if not line.startswith("["):
                    continue
                try:
                    up = float(line[1:line.index("]")])
                except ValueError:
                    continue
                if up <= last:
                    continue
                last = up
                open(posf, "w").write(f"{up}")
                msg = line[line.index("]") + 1:]
                if "Undervoltage detected" in msg:
                    uv_start = up
                    event("UNDERVOLTAGE_START", "", "power supply dipped below 4.63 V", gps_now(), up)
                elif "Voltage normalised" in msg:
                    dur = f"{up - uv_start:.1f}" if uv_start is not None else ""
                    event("UNDERVOLTAGE_END", dur, "seconds below safe voltage", gps_now(), up)
                    uv_start = None
                elif ("mmc0" in msg and ("error" in msg.lower() or "timeout" in msg.lower())) \
                        or "EXT4-fs error" in msg or "I/O error" in msg:
                    event("SD_ERROR", "", msg.strip()[:150], gps_now(), up)
        except Exception as e:
            log(f"kernel watch error: {e}")
        time.sleep(5)

def boot_milestones():
    p = os.path.join(RUN, "milestones.json")
    try:
        return json.load(open(p))
    except Exception:
        return {}

def save_milestones(m):
    write_json(os.path.join(RUN, "milestones.json"), m)

def check_previous_run(m):
    """first start in this boot: did the previous run end cleanly or by a power cut?"""
    hb = os.path.join(STATE_DIR, "heartbeat")
    try:
        parts = open(hb).read().split()
        wall, boot, status = parts[:3]
        m["prev"] = {"last_wall": float(wall), "status": status,
                     "time_ok": len(parts) > 3 and parts[3] == "1"}
        last_seen = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(float(wall)))
        if boot != BOOT8:
            if status == "clean":
                event("PREV_RUN_END", "clean", f"previous run shut down cleanly at {last_seen}")
            else:
                event("PREV_RUN_END", "power_cut", f"previous run lost power (last alive {last_seen})")
    except (OSError, ValueError):
        pass
    m["boot_checked"] = True

def heartbeat(status="running"):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = os.path.join(STATE_DIR, "heartbeat.tmp")
        ok = "1" if clock.get("time_ok") else "0"
        open(tmp, "w").write(f"{time.time():.0f} {BOOT8} {status} {ok}\n")
        os.replace(tmp, os.path.join(STATE_DIR, "heartbeat"))
    except OSError:
        pass

def nrestarts(unit):
    try:
        out = subprocess.run(["systemctl", "show", "-p", "NRestarts", "--value", unit],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return int(out or 0)
    except Exception:
        return None

def current_session():
    try:
        lines = [l.split() for l in open(os.path.join(STATE_DIR, "sessions")) if l.strip()]
        full = open("/proc/sys/kernel/random/boot_id").read().strip()
        mine = [l[0] for l in lines if len(l) == 2 and l[1] == full]
        return mine[-1] if mine else None
    except OSError:
        return None

def recording_started(sess):
    if not sess:
        return False
    for p in glob.glob(os.path.join(CLIPS_DIR, f"{sess}_*")):
        try:
            if os.path.getsize(p) > 0:
                return True
        except OSError:
            pass
    return False

# ---------------------------------------------------------------- main loop
def main():
    import signal
    boot_id = open("/proc/sys/kernel/random/boot_id").read().strip()
    COLS = "wall,gps_utc,fix,lat,lon,kmh,heading,sats,g_max,rot_max_dps,event,temp_c,undervolt,throttled"
    existing = sorted(glob.glob(os.path.join(LOGS_DIR, f"boot_*_{boot_id[:8]}.csv")))
    logpath = existing[-1] if existing else os.path.join(
        LOGS_DIR, f"boot_{time.strftime('%Y%m%d_%H%M%S')}_{boot_id[:8]}.csv")
    if os.path.exists(logpath) and open(logpath).readline().strip() != COLS:   # older format
        logpath = logpath[:-4].rsplit("_", 1)[0] + f"_v4_{boot_id[:8]}.csv"
    new = not os.path.exists(logpath)
    lf = open(logpath, "a", buffering=1)
    if new:
        lf.write(COLS + "\n")
    try:
        old = json.load(open(os.path.join(RUN, "clock.json")))
        if old.get("boot_id") == boot_id:
            clock.update(old)
    except Exception:
        pass
    clock["boot_id"] = boot_id

    ms = boot_milestones()
    if not ms.get("boot_checked"):
        check_previous_run(ms)
        ms["sensors_start"] = round(uptime(), 1)
        event("BOOT", ms["sensors_start"], "seconds from kernel start to sensor service start")
        save_milestones(ms)
    else:
        event("SENSORS_RESTART", f"{uptime():.0f}", "sensor service restarted (uptime s); GPS/jolt data paused briefly")
    heartbeat()

    def on_term(*_):
        heartbeat("clean")                       # systemd stops us on a normal shutdown
        sys.exit(0)
    signal.signal(signal.SIGTERM, on_term)

    threading.Thread(target=gps_thread, daemon=True).start()
    threading.Thread(target=imu_thread, daemon=True).start()
    threading.Thread(target=kernel_watch, daemon=True).start()
    log(f"sensors started; log -> {logpath}")

    uv_path = find_uv_alarm()
    prev_off = time.time() - time.monotonic()
    last_ntp_check = 0
    next_tick = time.monotonic()
    tick = 0
    throttled = ""
    temp_state = "ok"; temp_since = None; temp_peak = 0.0
    had_fix = bool(ms.get("first_fix"))
    lost_since = None; lost_reported = False; last_good = None
    no_data_reported = False
    seen_lock = None
    while True:
        next_tick += 1.0
        time.sleep(max(0, next_tick - time.monotonic()))
        tick += 1

        # ---- clock-jump watcher
        off = time.time() - time.monotonic()
        jump = off - prev_off
        changed = False
        if abs(jump) > 2:
            at_old = time.monotonic() + prev_off
            clock["jumps"].append({"at_old": round(at_old, 2), "offset": round(jump, 2)})
            event("CLOCK_JUMP", f"{jump:+.1f}", "seconds the clock was corrected by")
            changed = True
        prev_off = off
        if gps_clock_set and clock["source"] != "gps":
            clock.update(time_ok=True, source="gps"); changed = True
        if not clock["time_ok"] and time.monotonic() - last_ntp_check > 15:
            last_ntp_check = time.monotonic()
            if ntp_synced():
                clock.update(time_ok=True, source="wifi"); changed = True
        if changed or not os.path.exists(os.path.join(RUN, "clock.json")):
            write_json(os.path.join(RUN, "clock.json"), clock)
        if clock["time_ok"] and not ms.get("clock_ok"):
            ms["clock_ok"] = round(uptime(), 1); save_milestones(ms)
            event("CLOCK_OK", ms["clock_ok"], f"time confirmed by {clock['source']} (seconds after kernel start)")
            p = ms.get("prev")
            if p and p.get("time_ok") and not ms.get("off_logged"):
                boot_wall = time.time() - uptime()               # real time the kernel started
                off = boot_wall - p["last_wall"]
                if off > -60:
                    event("OFF_TIME", f"{max(off, 0):.0f}",
                          f"seconds without power before this start (previous end: {p['status']})")
                ms["off_logged"] = True; save_milestones(ms)

        # ---- service crash/restart counter (systemd NRestarts), every 30 s
        if tick % 30 == 5:
            nr = ms.setdefault("nrestarts", {})
            for unit in ("dashcam-record", "dashcam-housekeeper"):
                n = nrestarts(unit)
                if n is None:
                    continue
                if unit in nr and n > nr[unit]:
                    event("SERVICE_RESTART", unit, f"systemd restarted it (total {n} this boot)", gps_now())
                nr[unit] = n
            save_milestones(ms)

        g = gps_now()
        fix = g["fix"] and g["alive"]

        # ---- startup milestone: recording really started
        if not ms.get("rec_start") and recording_started(current_session()):
            ms["rec_start"] = round(uptime(), 1); save_milestones(ms)
            event("REC_START", ms["rec_start"], "seconds from kernel start to first video data (+~3-5 s firmware before kernel)")

        # ---- GPS events
        if not g["alive"] and tick > 15 and not no_data_reported:
            event("GPS_NO_DATA", "", "no NMEA from GPS for >5 s (wiring/power?)"); no_data_reported = True
        if g["alive"]:
            no_data_reported = False
        if fix:
            last_good = dict(g)
            if not had_fix:
                had_fix = True
                ms["first_fix"] = round(uptime(), 1); save_milestones(ms)
                event("GPS_FIRST_FIX", ms["first_fix"], f"seconds after kernel start; {g['sats_used']} sats", g)
            if lost_since is not None:
                if lost_reported:
                    event("GPS_BACK", f"{time.monotonic() - lost_since:.0f}", "seconds without fix", g)
                lost_since = None; lost_reported = False
        elif had_fix:
            if lost_since is None:
                lost_since = time.monotonic()
            elif not lost_reported and time.monotonic() - lost_since >= GPS_LOST_SEC:
                event("GPS_LOST", f"{g['sats_visible']}", "satellites visible; position = last known", last_good)
                lost_reported = True

        # ---- temperature events (with hysteresis 3 °C)
        t = read_temp()
        if t is not None:
            level = "crit" if t >= TEMP_CRIT else "high" if t >= TEMP_HIGH else "ok"
            if temp_state == "ok" and level != "ok":
                temp_state, temp_since, temp_peak = level, time.monotonic(), t
                event("TEMP_HIGH" if level == "high" else "TEMP_CRITICAL", f"{t:.1f}", "°C", g)
            elif temp_state != "ok":
                temp_peak = max(temp_peak, t)
                if temp_state == "high" and level == "crit":
                    temp_state = "crit"; event("TEMP_CRITICAL", f"{t:.1f}", "°C", g)
                if t < TEMP_HIGH - 3:
                    event("TEMP_NORMAL", f"{time.monotonic() - temp_since:.0f}",
                          f"seconds hot; peak {temp_peak:.1f} °C", g)
                    temp_state = "ok"
        uv = ""
        if uv_path:
            try:
                uv = open(uv_path).read().strip()
            except OSError:
                pass
        if tick % 5 == 1:
            throttled = read_throttled()

        # ---- jolt → event (the IMU thread already requested the clip lock)
        with lock:
            ll = S["last_lock"]
        if ll and ll is not seen_lock:
            seen_lock = ll
            event("JOLT_LOCK", f"{ll['g']}", "g-force; clip moved to locked/", g)

        if tick % 10 == 0:
            heartbeat()

        # ---- per-second log row + live state
        with lock:
            gmax, rmax, ev = sec["gmax"], sec["gyromax"], sec["event"]
            sec.update(gmax=0.0, gyromax=0.0, event="")
            state = {"updated": time.time(), "uptime": round(uptime()), "gps": g, "imu": dict(S["imu"]),
                     "last_lock": S["last_lock"], "time": {"ok": clock["time_ok"], "source": clock["source"]},
                     "health": {"temp": t, "undervolt": uv, "throttled": throttled},
                     "milestones": ms}
        utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(g["utc"])) if fix and g["utc"] else ""
        lf.write(",".join([
            f"{time.time():.1f}", utc, "1" if fix else "0",
            f"{g['lat']:.6f}" if fix else "", f"{g['lon']:.6f}" if fix else "",
            f"{g['kmh']}" if fix else "", f"{g['heading']}" if fix and g["heading"] is not None else "",
            str(g["sats_used"]), f"{gmax:.2f}" if gmax else "", f"{rmax:.0f}" if rmax else "", ev,
            f"{t:.1f}" if t is not None else "", uv, throttled]) + "\n")
        write_json(os.path.join(RUN, "state.json"), state)

if __name__ == "__main__":
    main()
__DASHCAM_EOF_SENSORS_PY__

cat > /opt/dashcam/housekeeper.py << '__DASHCAM_EOF_HOUSEKEEPER_PY__'
#!/usr/bin/env python3
"""
dashcam housekeeper
  1. wraps finished .h264 segments into .mp4 (no re-encode)
  2. names each clip by its real start time when the clock is trusted,
     otherwise S<session>_<n>.mp4 — renamed later once GPS/Wi-Fi fixes the clock
  3. writes a .csv next to each clip (GPS position/speed + g-force per second)
  4. moves clips around a crash/jolt into locked/ (never auto-deleted)
  5. deletes the oldest normal clips when free space < MIN_FREE_PCT
"""
import os, re, sys, time, json, glob, shutil, subprocess

def load_conf(path="/etc/dashcam.conf"):
    c = {}
    try:
        for line in open(path):
            line = line.split("#", 1)[0].strip()
            if "=" in line:
                k, v = line.split("=", 1)
                c[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return c

C = load_conf()
CLIPS   = C.get("CLIPS_DIR", os.path.expanduser("~/dashcam/clips"))
LOCKED  = C.get("LOCKED_DIR", os.path.expanduser("~/dashcam/locked"))
BASE    = os.path.dirname(CLIPS.rstrip("/"))
STATE   = os.path.join(BASE, ".state")
LOGS    = os.path.join(BASE, "logs")
RUN     = "/run/dashcam"
FPS     = C.get("FPS", "30")
SEG     = float(C.get("SEGMENT_SEC", "60"))
MINFREE = float(C.get("MIN_FREE_PCT", "10"))
LBEFORE = float(C.get("LOCK_BEFORE_SEC", "60"))
LAFTER  = float(C.get("LOCK_AFTER_SEC", "30"))
LOCKMAX = float(C.get("LOCKED_MAX_PCT", "20"))      # locked/ may use at most this % of the card
LOGMAXB = float(C.get("LOGS_MAX_MB", "200")) * 1024 * 1024
LOGDAYS = float(C.get("LOG_KEEP_DAYS", "30"))

UNSYNCED = re.compile(r"^(S\d{5})_(\d{4})$")
for d in (CLIPS, LOCKED, LOGS):
    os.makedirs(d, exist_ok=True)

def log(*a):
    print(*a, flush=True)

BOOT_ID = open("/proc/sys/kernel/random/boot_id").read().strip()
EVENTS = os.path.join(LOGS, "events.csv")

def event(name, value="", detail=""):
    """same format as the sensor service: logs/events.csv"""
    try:
        new = not os.path.exists(EVENTS)
        up = float(open("/proc/uptime").read().split()[0])
        lat = lon = kmh = ""
        try:
            g = json.load(open(os.path.join(RUN, "state.json")))["gps"]
            if g.get("fix") and g.get("alive"):
                lat, lon, kmh = f"{g['lat']:.6f}", f"{g['lon']:.6f}", f"{g['kmh']}"
        except Exception:
            pass
        with open(EVENTS, "a") as f:
            if new:
                f.write("local_time,boot,uptime_s,event,value,detail,lat,lon,kmh\n")
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')},{BOOT_ID[:8]},{up:.1f},{name},{value},"
                    f"{str(detail).replace(',', ';')},{lat},{lon},{kmh}\n")
        log(f"EVENT {name} {value} {detail}")
    except OSError:
        pass

last_end = {}          # session -> raw end time of the previous clip (gap detection)
last_any = {"end": None, "sess": None}   # last clip of ANY session (recorder-restart downtime)

def check_restarts(sessions):
    """more than one recording session in this boot = the recorder crashed/restarted"""
    p = os.path.join(RUN, "reported_sessions")
    try:
        done = set(open(p).read().split())
    except OSError:
        done = set()
    ordered = sorted(sessions)
    for s in ordered[1:]:
        if s not in done:
            event("REC_RESTART", s, "recorder restarted during this power-on (short gap in video)")
            done.add(s)
    if ordered and ordered[0] not in done:
        done.add(ordered[0])
    try:
        open(p, "w").write(" ".join(sorted(done)))
    except OSError:
        pass

def this_boot_sessions():
    s = set()
    try:
        for line in open(os.path.join(STATE, "sessions")):
            p = line.split()
            if len(p) == 2 and p[1] == BOOT_ID:
                s.add(p[0])
    except FileNotFoundError:
        pass
    return s

def ntp_synced():
    try:
        return subprocess.run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"],
                              capture_output=True, text=True, timeout=5).stdout.strip() == "yes"
    except Exception:
        return False

def read_clock():
    try:
        ck = json.load(open(os.path.join(RUN, "clock.json")))
        if ck.get("boot_id") == BOOT_ID:
            return ck
    except Exception:
        pass
    return {"time_ok": ntp_synced(), "jumps": []}     # sensors service not running

def correct(t, jumps):
    """convert a timestamp taken with the (possibly wrong) clock into real time"""
    for j in jumps:
        if t < j["at_old"]:
            t += j["offset"]
    return t

def read_locks(jumps):
    out = []
    try:
        for line in open(os.path.join(RUN, "locks")):
            p = line.split()
            if p:
                out.append(correct(float(p[0]), jumps))
    except FileNotFoundError:
        pass
    return out

def duration(path):
    try:
        r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                            "-of", "csv=p=0", path], capture_output=True, text=True, timeout=30)
        return float(r.stdout.strip())
    except Exception:
        return SEG

def boot_log():
    m = glob.glob(os.path.join(LOGS, f"boot_*_{BOOT_ID[:8]}.csv"))
    return m[0] if m else None

def write_sidecar(dst_mp4, start_raw, end_raw, jumps):
    """copy the per-second sensor rows for this clip into <clip>.csv"""
    src = boot_log()
    if not src:
        return
    rows = []
    try:
        with open(src) as f:
            header = f.readline().rstrip("\n")
            for line in f:
                try:
                    w = float(line.split(",", 1)[0])
                except ValueError:
                    continue
                if start_raw - 0.5 <= w <= end_raw + 0.5:
                    real = correct(w, jumps)
                    rows.append(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(real)) + "," + line.rstrip("\n"))
    except OSError:
        return
    if rows:
        with open(dst_mp4[:-4] + ".csv", "w") as f:
            f.write("local_time," + header + "\n" + "\n".join(rows) + "\n")

def unique(path):
    if not os.path.exists(path):
        return path
    base, ext = os.path.splitext(path)
    i = 2
    while os.path.exists(f"{base}_{i}{ext}"):
        i += 1
    return f"{base}_{i}{ext}"

def clip_name(stem, start_raw, ck, sessions):
    """real-time name if we trust the clock for this clip, else keep S-number"""
    m = UNSYNCED.match(stem)
    this_boot = (m and m.group(1) in sessions)
    if this_boot and ck["time_ok"]:
        real = correct(start_raw, ck["jumps"])
        return time.strftime("%Y%m%d_%H%M%S", time.localtime(real))
    return stem

def locked_window(start, end, locks):
    return any(start <= lt + LAFTER and end >= lt - LBEFORE for lt in locks)

def move_pair(src_mp4, dst_mp4):
    os.replace(src_mp4, dst_mp4)
    csv = src_mp4[:-4] + ".csv"
    if os.path.exists(csv):
        os.replace(csv, dst_mp4[:-4] + ".csv")

def wrap_finished(ck, sessions, locks):
    raws = sorted(glob.glob(os.path.join(CLIPS, "*.h264")), key=os.path.getmtime)
    for f in raws[:-1]:                                   # newest is still being recorded
        stem = os.path.basename(f)[:-5]
        tmp = os.path.join(CLIPS, stem + ".tmp.mp4")
        r = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y",
                            "-framerate", FPS, "-i", f, "-c", "copy", "-f", "mp4", tmp])
        if r.returncode != 0:
            log(f"wrap failed: {f}")
            if os.path.getsize(f) < 1024:                 # empty segment from a power cut
                os.remove(f)
            continue
        end_raw = os.path.getmtime(f)
        dur = duration(tmp)
        start_raw = end_raw - dur
        sess = stem.split("_")[0]
        if sess in last_end and start_raw - last_end[sess] > 3:
            event("REC_GAP", f"{start_raw - last_end[sess]:.0f}", f"seconds missing before {stem}")
        if sess not in last_end and last_any["end"] and last_any["sess"] != sess and sess in sessions and last_any["sess"] in sessions:
            gap = start_raw - last_any["end"]
            if 0 <= gap < 3600:
                event("REC_DOWNTIME", f"{gap:.0f}", f"seconds of video missing while recorder restarted ({last_any['sess']}->{sess})")
        last_end[sess] = end_raw
        last_any.update(end=end_raw, sess=sess)
        os.utime(tmp, (end_raw, end_raw))                 # mp4 keeps the recording time
        name = clip_name(stem, start_raw, ck, sessions)
        real_s, real_e = correct(start_raw, ck["jumps"]), correct(end_raw, ck["jumps"])
        dest_dir = LOCKED if locked_window(real_s, real_e, locks) else CLIPS
        dst = unique(os.path.join(dest_dir, name + ".mp4"))
        write_sidecar(dst, start_raw, end_raw, ck["jumps"])
        os.replace(tmp, dst)
        os.remove(f)
        if dest_dir == LOCKED:
            log(f"LOCKED {os.path.basename(dst)}")

def rename_unsynced(ck, sessions):
    """once the clock is trusted, give this drive's S-numbered clips real names"""
    if not ck["time_ok"]:
        return
    for d in (CLIPS, LOCKED):
        for p in glob.glob(os.path.join(d, "S?????_????.mp4")):
            stem = os.path.basename(p)[:-4]
            m = UNSYNCED.match(stem)
            if not m or m.group(1) not in sessions:
                continue
            end_raw = os.path.getmtime(p)
            start_raw = end_raw - duration(p)
            dst = unique(os.path.join(d, clip_name(stem, start_raw, ck, sessions) + ".mp4"))
            write_sidecar(p, start_raw, end_raw, ck["jumps"])   # refresh times in csv
            move_pair(p, dst)
            log(f"renamed {stem} -> {os.path.basename(dst)}")

def lock_existing(ck, locks):
    """a jolt can arrive after the previous clip was already wrapped — move it too"""
    if not locks:
        return
    for p in glob.glob(os.path.join(CLIPS, "*.mp4")):
        if p.endswith(".tmp.mp4"):
            continue
        end = correct(os.path.getmtime(p), ck["jumps"])
        start = end - SEG
        if locked_window(start, end, locks):
            dst = unique(os.path.join(LOCKED, os.path.basename(p)))
            move_pair(p, dst)
            log(f"LOCKED {os.path.basename(dst)}")

def free_pct():
    st = os.statvfs(CLIPS)
    return 100.0 * st.f_bavail / st.f_blocks

def rolling_delete():
    while free_pct() < MINFREE:
        clips = [p for p in glob.glob(os.path.join(CLIPS, "*.mp4")) if not p.endswith(".tmp.mp4")]
        if not clips:
            break
        oldest = min(clips, key=os.path.getmtime)
        os.remove(oldest)
        csv = oldest[:-4] + ".csv"
        if os.path.exists(csv):
            os.remove(csv)
        log(f"deleted (space) {os.path.basename(oldest)}")

def cap_locked():
    """locked/ is skipped by normal rotation, but must not eat the whole card:
    if it grows past LOCKED_MAX_PCT of the card, the OLDEST locked clips go first"""
    st = os.statvfs(LOCKED)
    limit = st.f_blocks * st.f_frsize * LOCKMAX / 100
    files = glob.glob(os.path.join(LOCKED, "*.mp4"))
    def size(p):
        c = p[:-4] + ".csv"
        return os.path.getsize(p) + (os.path.getsize(c) if os.path.exists(c) else 0)
    total = sum(size(p) for p in files)
    for p in sorted(files, key=os.path.getmtime):
        if total <= limit:
            break
        total -= size(p)
        os.remove(p)
        if os.path.exists(p[:-4] + ".csv"):
            os.remove(p[:-4] + ".csv")
        log(f"deleted (locked folder over {LOCKMAX:.0f}%) {os.path.basename(p)}")

def cap_logs():
    """sensor logs: drop files older than LOG_KEEP_DAYS, then the oldest while over LOGS_MAX_MB"""
    current = boot_log()
    files = [p for p in glob.glob(os.path.join(LOGS, "boot_*.csv")) if p != current]
    now = time.time()
    for p in list(files):
        if now - os.path.getmtime(p) > LOGDAYS * 86400:
            os.remove(p)
            files.remove(p)
    total = sum(os.path.getsize(p) for p in files) + (os.path.getsize(current) if current else 0)
    for p in sorted(files, key=os.path.getmtime):
        if total <= LOGMAXB:
            break
        total -= os.path.getsize(p)
        os.remove(p)

def main():
    for t in glob.glob(os.path.join(CLIPS, "*.tmp.mp4")):  # leftovers from a power cut
        os.remove(t)
    log("housekeeper started")
    while True:
        try:
            ck = read_clock()
            sessions = this_boot_sessions()
            check_restarts(sessions)
            locks = read_locks(ck["jumps"])
            wrap_finished(ck, sessions, locks)
            rename_unsynced(ck, sessions)
            lock_existing(ck, locks)
            cap_locked()
            rolling_delete()
            cap_logs()
        except Exception as e:
            log(f"housekeeper error: {e}")
        time.sleep(10)

if __name__ == "__main__":
    main()
__DASHCAM_EOF_HOUSEKEEPER_PY__

cat > /opt/dashcam/wifi.sh << '__DASHCAM_EOF_WIFI_SH__'
#!/bin/bash
# =============================================================================
#  dashcam-wifi — keeps the Pi's ONE Wi-Fi radio in the wanted mode
#
#  auto     (every boot) join home Wi-Fi if it connects within WIFI_HOME_WAIT_SEC,
#           otherwise start the hotspot. Home Wi-Fi lost later → hotspot.
#           Once the hotspot is on it stays until power-off: a radio that is
#           broadcasting can't look for other networks.
#  home     force home Wi-Fi (hotspot off)        set with:  dashcam wifi home|hotspot|auto
#  hotspot  force the hotspot (home Wi-Fi off)    a forced mode lasts until the next reboot
#
#  The wanted mode lives in /run/dashcam/wifi-mode (tmpfs → back to auto on boot).
#  This loop compares wanted vs actual every 3 s and fixes the difference.
#  Live state for `dashcam wifi` / `dashcam status`: /run/dashcam/wifi.json
# =============================================================================
CON=dashcam-hotspot
IFACE=wlan0
RUN=/run/dashcam
MODE_FILE=$RUN/wifi-mode
STATE_FILE=$RUN/wifi.json
mkdir -p "$RUN"

conf() {
  source /etc/dashcam.conf 2>/dev/null
  WAIT=${WIFI_HOME_WAIT_SEC:-25}; BAND=${HOTSPOT_BAND:-a}; CH=${HOTSPOT_CHANNEL:-36}
}
log() { echo "$*"; }
uptime_s() { cut -d. -f1 /proc/uptime; }          # monotonic seconds (GPS can move the wall clock)

event() {   # same format as the other services; only appends if events.csv already exists
  local f; f="$(dirname "$CLIPS_DIR")/logs/events.csv"
  [[ -f "$f" ]] || { log "EVENT $1 $2 $3"; return 0; }
  local v="${2//,/;}" d="${3//,/;}"
  printf '%s,%s,%s,%s,%s,%s,,,\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$(cut -c1-8 /proc/sys/kernel/random/boot_id)" "$(cut -d' ' -f1 /proc/uptime)" "$1" "$v" "$d" >> "$f"
  log "EVENT $1 $2 $3"
}

active_con() { nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v d="$IFACE" '$2==d {print $1; exit}'; }
current() {
  local a; a="$(active_con)"
  if [[ -z "$a" ]]; then echo none; elif [[ "$a" == "$CON" ]]; then echo hotspot; else echo home; fi
}
have_hotspot() { nmcli -t -f NAME con show 2>/dev/null | grep -qx "$CON"; }

hotspot_up() {
  if ! have_hotspot; then
    [[ -n "$warned" ]] || log "hotspot not configured — put wifi.conf next to setup-dashcam.sh and re-run it"
    warned=1; return 1
  fi
  conf
  local ch=$CH
  [[ "$BAND" == "bg" ]] && (( ch > 14 )) && ch=6
  nmcli con modify "$CON" 802-11-wireless.band "$BAND" 802-11-wireless.channel "$ch" >/dev/null 2>&1
  nmcli --wait 20 con up "$CON" >/dev/null 2>&1 && return 0
  if [[ "$BAND" == "a" ]]; then
    log "5 GHz hotspot failed; trying 2.4 GHz"
    nmcli con modify "$CON" 802-11-wireless.band bg 802-11-wireless.channel 6 >/dev/null 2>&1
    if nmcli --wait 20 con up "$CON" >/dev/null 2>&1; then
      event WIFI_HOTSPOT_FALLBACK "2.4GHz" "5 GHz hotspot failed; running on 2.4 GHz channel 6"
      return 0
    fi
  fi
  log "hotspot failed to start"; return 1
}

hotspot_down() { nmcli con down "$CON" >/dev/null 2>&1; }

home_up() {   # try every saved Wi-Fi client profile (the one Raspberry Pi Imager made, etc.)
  nmcli dev wifi rescan >/dev/null 2>&1; sleep 3
  local name type
  while IFS=: read -r name type; do
    [[ "$type" == "802-11-wireless" && "$name" != "$CON" ]] || continue
    nmcli --wait 20 con up "$name" >/dev/null 2>&1 && return 0
  done < <(nmcli -t -f NAME,TYPE con show 2>/dev/null)
  return 1
}

write_state() {   # $1 mode  $2 current  $3 ssid
  local ip clients=0
  ip=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [[ "$2" == hotspot ]] && clients=$(iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station' || true)
  printf '{"mode":"%s","current":"%s","ssid":"%s","ip":"%s","clients":%s,"updated":%s}\n' \
    "$1" "$2" "${3//\"/}" "$ip" "${clients:-0}" "$(date +%s)" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

conf
last_mode=""; last_cur=""; ssid=""; tried_home=0
none_since=$(uptime_s)
log "dashcam-wifi started (home Wi-Fi wait ${WAIT}s, hotspot band $BAND)"
while true; do
  mode=$(cat "$MODE_FILE" 2>/dev/null || true)
  [[ "$mode" == home || "$mode" == hotspot ]] || mode=auto
  cur=$(current)
  now=$(uptime_s)

  if [[ "$mode" != "$last_mode" ]]; then
    if [[ -n "$last_mode" ]]; then
      event WIFI_MODE "$mode" "set by: dashcam wifi $mode"
      if [[ "$mode" == auto && "$cur" == hotspot ]]; then   # re-decide like a fresh boot
        hotspot_down; cur=none
      fi
      none_since=$now; tried_home=0
    fi
    last_mode=$mode
  fi

  case "$mode" in
    hotspot)
      [[ "$cur" == hotspot ]] || { hotspot_up; cur=$(current); } ;;
    home)
      if [[ "$cur" == hotspot ]]; then hotspot_down; cur=none; tried_home=0; fi
      if [[ "$cur" == none ]] && (( now - tried_home >= 30 )); then
        tried_home=$now; home_up; cur=$(current)
      fi ;;
    auto)
      if [[ "$cur" == none ]]; then
        [[ -n "$none_since" ]] || none_since=$now
        if (( now - none_since >= WAIT )); then
          log "no home Wi-Fi for ${WAIT}s -> starting hotspot"
          hotspot_up; cur=$(current); none_since=""
        fi
      else
        none_since=""
      fi ;;
  esac

  if [[ "$cur" != "$last_cur" ]]; then
    case "$cur" in
      hotspot) ssid=$(nmcli -g 802-11-wireless.ssid con show "$CON" 2>/dev/null)
               event WIFI_HOTSPOT "$ssid" "hotspot on: join it; files at smb://10.42.0.1" ;;
      home)    ssid=$(nmcli -g 802-11-wireless.ssid con show "$(active_con)" 2>/dev/null)
               event WIFI_HOME "$ssid" "joined home Wi-Fi" ;;
      none)    ssid=""; [[ -n "$last_cur" ]] && log "Wi-Fi disconnected" ;;
    esac
    last_cur=$cur
  fi
  write_state "$mode" "$cur" "$ssid"
  sleep 3
done
__DASHCAM_EOF_WIFI_SH__

cat > /usr/local/bin/dashcam-status << '__DASHCAM_EOF_DASHCAM_STATUS__'
#!/bin/bash
# =============================================================================
#  dashcam-status — one-shot health report for the Pi dashcam
#     dashcam-status        one report
#     dashcam-status -w     live view, refresh every 5 s (Ctrl+C to stop)
# =============================================================================
if [[ $EUID -ne 0 ]]; then exec sudo "$0" "$@"; fi

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
ok()   { echo "  ${G}✔${N} $*"; }
bad()  { echo "  ${R}✘${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }

report() {
  source /etc/dashcam.conf 2>/dev/null
  CLIPS_DIR=${CLIPS_DIR:-/home/${SUDO_USER:-vicky}/dashcam/clips}
  LOCKED_DIR=${LOCKED_DIR:-/home/${SUDO_USER:-vicky}/dashcam/locked}

  echo "${B}===== DASHCAM STATUS  $(date '+%d %b %H:%M:%S')  (up since $(uptime -s | cut -c12-16)) =====${N}"

  # ---------- RECORDING ----------
  echo "${B}🎥 Recording${N}"
  for s in dashcam-record dashcam-housekeeper dashcam-sensors; do
    systemctl is-active --quiet $s && ok "$s running" || bad "$s NOT running  → sudo systemctl start $s ; journalctl -u $s -n 20"
  done
  cur=$(ls -1t "$CLIPS_DIR"/*.h264 2>/dev/null | head -1)
  if [[ -n "$cur" ]]; then
    s1=$(stat -c %s "$cur"); sleep 2; s2=$(stat -c %s "$cur" 2>/dev/null || echo 0)
    if (( s2 > s1 )); then ok "writing $(basename "$cur")  (+$(( (s2-s1)/1024 )) KB in 2 s)"
    else
      nxt=$(ls -1t "$CLIPS_DIR"/*.h264 2>/dev/null | head -1)
      [[ "$nxt" != "$cur" ]] && ok "new segment started: $(basename "$nxt")" || bad "current file is NOT growing"
    fi
  else
    bad "no clip being recorded right now"
  fi
  hour=$(find "$CLIPS_DIR" "$LOCKED_DIR" -name '*.mp4' -mmin -60 2>/dev/null | wc -l)
  boot=$(find "$CLIPS_DIR" "$LOCKED_DIR" -name '*.mp4' -newermt "$(uptime -s)" 2>/dev/null | wc -l)
  nlock=$(ls -1 "$LOCKED_DIR"/*.mp4 2>/dev/null | wc -l)
  echo "    clips last 60 min: $hour   |   since boot: $boot   |   locked: $nlock"
  last=$(ls -1t "$CLIPS_DIR"/*.mp4 2>/dev/null | head -1)
  [[ -n "$last" ]] && echo "    last finished clip: $(basename "$last")  ($(du -h "$last" | cut -f1))"
  lastlock=$(ls -1t "$LOCKED_DIR"/*.mp4 2>/dev/null | head -1)
  [[ -n "$lastlock" ]] && echo "    last locked clip:   $(basename "$lastlock")"

  # ---------- STORAGE ----------
  echo "${B}💾 Storage${N}"
  read -r size used avail pct <<<"$(df -h --output=size,used,avail,pcent "$CLIPS_DIR" | tail -1)"
  free_pct=$((100 - ${pct%\%}))
  msg="$avail free of $size ($free_pct% free)  |  clips use $(du -sh "$CLIPS_DIR" 2>/dev/null | cut -f1), locked $(du -sh "$LOCKED_DIR" 2>/dev/null | cut -f1)"
  (( free_pct > ${MIN_FREE_PCT:-10} + 5 )) && ok "$msg" || warn "$msg  (rolling delete active)"

  # ---------- POWER & HEAT ----------
  echo "${B}⚡ Power & heat${N}"
  t=$(vcgencmd measure_temp | grep -o '[0-9.]*'); ti=${t%.*}
  if (( ti < 70 )); then ok "temperature ${t}°C"; elif (( ti < 80 )); then warn "temperature ${t}°C (warm)"; else bad "temperature ${t}°C (TOO HOT)"; fi
  th=$(( $(vcgencmd get_throttled | cut -d= -f2) ))
  (( th & 0x1 ))     && bad  "UNDER-VOLTAGE right now  → weak charger/cable" || ok "power OK right now"
  (( th & 0x4 ))     && bad  "CPU slowed down right now (throttled)"
  (( th & 0x10000 )) && warn "voltage dipped at least once since boot"
  (( th & 0x40000 )) && warn "CPU was throttled at least once since boot"
  dips=$(journalctl -k -b 2>/dev/null | grep -c "Undervoltage detected")
  (( dips > 0 )) && echo "    under-voltage events since boot: $dips (last: $(journalctl -k -b | grep 'Undervoltage detected' | tail -1 | awk '{print $3}'))"

  # ---------- WI-FI + PHONE ACCESS ----------
  echo "${B}📶 Wi-Fi & phone access${N}"
  if systemctl is-active --quiet dashcam-wifi; then
    /usr/local/bin/dashcam wifi status
  else
    bad "dashcam-wifi NOT running  → sudo systemctl start dashcam-wifi"
  fi
  systemctl is-active --quiet smbd && ok "file sharing (SMB) on — read-only shares: clips, locked" \
                                   || bad "file sharing (SMB) NOT running  → sudo systemctl start smbd"

  # ---------- CLOCK + GPS + ACCELEROMETER ----------
  if systemctl is-active --quiet dashcam-sensors && [[ -f /run/dashcam/state.json ]]; then
    MODE=service python3 - <<'PY'
import json, time
G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[1m"; N="\033[0m"
ok=lambda s: print(f"  {G}✔{N} {s}"); bad=lambda s: print(f"  {R}✘{N} {s}"); warn=lambda s: print(f"  {Y}!{N} {s}")
s = json.load(open("/run/dashcam/state.json"))
age = time.time() - s["updated"]
print(f"{B}🕒 Clock{N}")
src = {"gps": "GPS satellites", "wifi": "internet (Wi-Fi)"}.get(s["time"]["source"], "")
ok(f"time is correct (from {src})") if s["time"]["ok"] else warn("time NOT confirmed yet → new clips named S<drive>_<n>.mp4 until GPS/Wi-Fi fixes it")
print(f"{B}🛰  GPS{N}")
g = s["gps"]
if age > 5: bad(f"sensor service not updating ({age:.0f} s old)")
elif not g["alive"]: bad("no data from GPS  → check TX→pin10, RX→pin8, VCC→pin1, GND→pin6")
elif g["fix"]:
    ok(f"FIX ✓  {g['sats_used']} satellites used, {g['sats_visible']} visible")
    print(f"    position: {g['lat']:.5f}, {g['lon']:.5f}   → https://maps.google.com/?q={g['lat']:.5f},{g['lon']:.5f}")
    print(f"    speed: {g['kmh']} km/h   heading: {g['heading'] if g['heading'] is not None else '-'}°")
else:
    warn(f"talking, no fix yet — {g['sats_visible']} satellites visible, {g['sats_used']} used (need 4+ and sky view)")
print(f"{B}📐 Accelerometer / gyro{N}")
m = s["imu"]
if not m["ok"]: bad("MPU-6050 not responding  → check VIN→pin17, GND→pin9, SDA→pin3, SCL→pin5")
else:
    ok(f"now {m['g']}g   |   peak last 10 s: {m['g_peak_10s']}g   |   gyro °/s {m['gyro']}")
m = s.get("milestones", {})
print(f"{B}🚀 This power-on{N}")
fmt = lambda k: f"{m[k]} s" if m.get(k) else "—"
print(f"    after kernel start → recording {fmt('rec_start')} · GPS fix {fmt('first_fix')} · clock OK {fmt('clock_ok')}")
print(f"    (power-on to kernel start adds ≈3–5 s)   ·   history: dashcam-report")
ll = s.get("last_lock")
if ll: print(f"    last jolt lock: {time.strftime('%d %b %H:%M:%S', time.localtime(ll['wall']))}  ({ll['g']}g)")
PY
  else
    warn "dashcam-sensors not running → reading GPS/accelerometer directly"
    stty -F /dev/serial0 9600 raw -echo cs8 -parenb -cstopb -crtscts clocal cread 2>/dev/null
    python3 - <<'PY'
import os, time, select, math
G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[1m"; N="\033[0m"
ok=lambda s: print(f"  {G}✔{N} {s}"); bad=lambda s: print(f"  {R}✘{N} {s}"); warn=lambda s: print(f"  {Y}!{N} {s}")
print(f"{B}🛰  GPS{N}")
try:
    fd = os.open("/dev/serial0", os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    buf, end = b"", time.time() + 3
    while time.time() < end:
        if select.select([fd], [], [], 0.5)[0]:
            buf += os.read(fd, 4096)
    os.close(fd)
    lines = [l.strip() for l in buf.decode("ascii", "ignore").splitlines() if l.startswith("$G")]
    if not lines:
        bad("no data from GPS  → check TX→pin10, RX→pin8, VCC/GND, and serial enabled")
    else:
        rmc = next((l.split(",") for l in reversed(lines) if l[3:6] == "RMC"), None)
        gga = next((l.split(",") for l in reversed(lines) if l[3:6] == "GGA"), None)
        gsv = next((l.split(",") for l in reversed(lines) if l[3:6] == "GSV"), None)
        used = int(gga[7] or 0) if gga else 0
        vis = int(gsv[3].split("*")[0] or 0) if gsv else 0
        if rmc and rmc[2] == "A":
            lat = float(rmc[3][:2]) + float(rmc[3][2:]) / 60
            lon = float(rmc[5][:3]) + float(rmc[5][3:]) / 60
            ok(f"FIX ✓  {used} used, {vis} visible   → https://maps.google.com/?q={lat:.5f},{lon:.5f}")
        else:
            warn(f"talking, no fix yet — {vis} visible, {used} used")
except Exception as e:
    bad(f"cannot read /dev/serial0: {e}")
print(f"{B}📐 Accelerometer / gyro{N}")
try:
    from smbus2 import SMBus
    with SMBus(1) as bus:
        bus.write_byte_data(0x68, 0x6B, 0); bus.write_byte_data(0x68, 0x1C, 0x10)   # ±8 g
        time.sleep(0.05)
        w = lambda h, l: ((h << 8) | l) - 65536 if ((h << 8) | l) > 32767 else ((h << 8) | l)
        d = bus.read_i2c_block_data(0x68, 0x3B, 6)
        ax, ay, az = (w(d[i], d[i+1]) / 4096 for i in (0, 2, 4))
        ok(f"responding — total {math.sqrt(ax*ax+ay*ay+az*az):.2f}g")
except Exception as e:
    bad(f"MPU-6050 problem: {e}")
PY
  fi
  echo
}

if [[ "$1" == "-w" ]]; then
  while true; do clear; report; sleep 5; done
else
  report
fi
__DASHCAM_EOF_DASHCAM_STATUS__

cat > /usr/local/bin/dashcam-report << '__DASHCAM_EOF_DASHCAM_REPORT__'
#!/usr/bin/env python3
"""
dashcam-report — trip & health report built from the sensor logs.

  dashcam-report              summary of the last 5 power-ons (drives)
  dashcam-report 20           summary of the last 20
  dashcam-report restarts     restart log: every power-on, off-time, time to record, cause
  dashcam-report events       last 40 health events (with location)
  dashcam-report events 100   last 100 events
"""
import os, sys, csv, glob, math, time

def load_conf(path="/etc/dashcam.conf"):
    c = {}
    try:
        for line in open(path):
            line = line.split("#", 1)[0].strip()
            if "=" in line:
                k, v = line.split("=", 1)
                c[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return c

C = load_conf()
CLIPS = C.get("CLIPS_DIR", os.path.expanduser("~/dashcam/clips"))
LOGS = os.path.join(os.path.dirname(CLIPS.rstrip("/")), "logs")
TEMP_HIGH = float(C.get("TEMP_HIGH_C", "70").split()[0])
B, D, R, Y, G, N = "\033[1m", "\033[2m", "\033[31m", "\033[33m", "\033[32m", "\033[0m"

def read_events():
    rows = []
    for p in (os.path.join(LOGS, "events.1.csv"), os.path.join(LOGS, "events.csv")):
        if os.path.exists(p):
            with open(p) as f:
                rows += list(csv.DictReader(f))
    return rows

def hav(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 6371.0 * 2 * math.asin(math.sqrt(h))

def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None

def summarize(path):
    boot = os.path.basename(path).rsplit("_", 1)[-1][:-4]
    n = fix_n = hot = uv_s = 0
    last_wall = None
    temps, speeds, moving = [], [], []
    dist = 0.0
    prev = None
    with open(path) as f:
        for r in csv.DictReader(f):
            n += 1
            last_wall = fnum(r.get("wall")) or last_wall
            t = fnum(r.get("temp_c"))
            if t is not None:
                temps.append(t)
                hot += t >= TEMP_HIGH
            if r.get("undervolt") == "1":
                uv_s += 1
            if r.get("fix") == "1":
                fix_n += 1
                lat, lon, kmh = fnum(r["lat"]), fnum(r["lon"]), fnum(r["kmh"]) or 0
                speeds.append(kmh)
                if kmh > 3:
                    moving.append(kmh)
                    if prev:
                        dist += hav(prev, (lat, lon))
                    prev = (lat, lon)
                else:
                    prev = (lat, lon) if prev is None else prev
    return {"boot": boot, "rows": n, "end": last_wall, "fix_pct": 100 * fix_n / n if n else 0,
            "dist": dist, "vmax": max(speeds) if speeds else None,
            "vavg": sum(moving) / len(moving) if moving else None,
            "tmax": max(temps) if temps else None, "hot_s": hot, "uv_s": uv_s}

def fmt_t(sec):
    sec = int(sec)
    return f"{sec // 3600}h {sec % 3600 // 60:02d}m" if sec >= 3600 else f"{sec // 60}m {sec % 60:02d}s"

def load_all():
    logs = sorted(glob.glob(os.path.join(LOGS, "boot_*.csv")), key=os.path.getmtime)
    by_boot = {}
    for e in read_events():
        by_boot.setdefault(e["boot"], []).append(e)
    # 'PREV_RUN_END' / 'OFF_TIME' are written by the NEXT boot; map the end cause back
    order = [os.path.basename(p).rsplit("_", 1)[-1][:-4] for p in logs]
    ended = {}
    for i, b in enumerate(order[1:], 1):
        for e in by_boot.get(b, []):
            if e["event"] == "PREV_RUN_END":
                ended[order[i - 1]] = e["value"]
    return logs, by_boot, ended

def val(E, name, agg=None):
    v = [fnum(e["value"]) for e in E if e["event"] == name and fnum(e["value"]) is not None]
    if agg is None:
        return v[0] if v else None
    return agg(v) if v else None

def overall(logs, by_boot, ended):
    """uptime metrics across all logged power-ons"""
    sums = [summarize(p) for p in logs]
    if not sums:
        return
    up = sum(s["rows"] for s in sums)
    starts = [val(by_boot.get(s["boot"], []), "REC_START") for s in sums]
    starts = [x + 4 for x in starts if x is not None]          # + ~4 s firmware before kernel
    ttff = [x for x in (val(by_boot.get(s["boot"], []), "GPS_FIRST_FIX") for s in sums) if x is not None]
    downs = sum(val(by_boot.get(s["boot"], []), "REC_DOWNTIME", sum) or 0 for s in sums)
    gaps = sum(val(by_boot.get(s["boot"], []), "REC_GAP", sum) or 0 for s in sums)
    rec = max(0, up - sum(starts) - downs - gaps)
    unexpected = 0
    for s in sums:
        off = val(by_boot.get(s["boot"], []), "OFF_TIME")
        if off is not None and off < 60:
            unexpected += 1
    svc = sum(len([e for e in by_boot.get(s["boot"], []) if e["event"] in ("SERVICE_RESTART", "SENSORS_RESTART")]) for s in sums)
    first = time.strftime("%d %b", time.localtime(sums[0]["end"] - sums[0]["rows"])) if sums[0]["end"] else "?"
    print(f"{B}═══ Uptime summary  ({len(sums)} power-ons since {first}) ═══{N}")
    print(f"  ⏱  powered {fmt_t(up)} · recording ≈{fmt_t(rec)} "
          f"({100 * rec / up if up else 0:.1f}% of powered time)")
    if starts:
        print(f"  🚀 power-on → recording: avg {sum(starts) / len(starts):.0f} s · best {min(starts):.0f} s · worst {max(starts):.0f} s")
    if ttff:
        print(f"  🛰  GPS first fix: avg {sum(ttff) / len(ttff):.0f} s · worst {max(ttff):.0f} s after kernel start")
    print(f"  🔁 longest power-on {fmt_t(max(s['rows'] for s in sums))} · avg {fmt_t(up / len(sums))}")
    col = G if unexpected == 0 else R
    print(f"  ⚠  quick restarts (<60 s off — brown-out/loose plug?): {col}{unexpected}{N} · "
          f"service restarts: {svc} · video lost to recorder restarts {downs:.0f} s")
    print()

def restarts(count):
    logs, by_boot, ended = load_all()
    print(f"{B}{'started':<17} {'off before':>11} {'→ recording':>12} {'GPS fix':>8} {'ran for':>9}  ended{N}")
    for p in logs[-count:]:
        s = summarize(p)
        E = by_boot.get(s["boot"], [])
        start = s["end"] - s["rows"] + 1 if s["end"] else None
        when = time.strftime("%d %b %H:%M:%S", time.localtime(start)) if start else "?"
        off = val(E, "OFF_TIME")
        rec = val(E, "REC_START")
        ff = val(E, "GPS_FIRST_FIX")
        offs = fmt_t(off) if off is not None else "?"
        warn = f" {R}⚠ quick restart{N}" if off is not None and off < 60 else ""
        end = {"power_cut": "power cut", "clean": "clean"}.get(ended.get(s["boot"]), "running/unknown")
        extra = [e["event"].lower() for e in E if e["event"] in ("SERVICE_RESTART", "SENSORS_RESTART", "REC_DOWNTIME")]
        print(f"{when:<17} {offs:>11} {(f'{rec + 4:.0f} s' if rec is not None else '?'):>12} "
              f"{(f'{ff:.0f} s' if ff is not None else '-'):>8} {fmt_t(s['rows']):>9}  {end}{warn}"
              + (f"  {Y}[{', '.join(extra)}]{N}" if extra else ""))
    print(f"{D}'→ recording' = power-on to first video (kernel time + ≈4 s firmware). "
          f"'off before' needs GPS/Wi-Fi time on both runs.{N}")

def report(count):
    logs, by_boot, ended = load_all()
    if not logs:
        print("no sensor logs yet"); return
    overall(logs, by_boot, ended)
    for p in logs[-count:]:
        s = summarize(p)
        E = by_boot.get(s["boot"], [])
        get = lambda name: [e for e in E if e["event"] == name]
        first = lambda name: (get(name)[0]["value"] if get(name) else None)
        start = s["end"] - s["rows"] + 1 if s["end"] else None
        when = time.strftime("%d %b %Y %H:%M", time.localtime(start)) if start else "?"
        print(f"{B}━━ Drive {when}  ·  {fmt_t(s['rows'])}  ·  boot {s['boot']}{N}")

        # startup
        rec, ff, ck = first("REC_START"), first("GPS_FIRST_FIX"), first("CLOCK_OK")
        line = f"  🚀 Startup: recording {rec} s after kernel start" if rec else "  🚀 Startup: recording start not seen"
        line += f" (≈{float(rec) + 4:.0f} s from power-on)" if rec else ""
        line += (f" · GPS fix {ff} s" if ff else " · GPS fix ✓" if s["fix_pct"] else " · GPS: no fix this drive")
        line += f" · clock OK {ck} s" if ck else " · clock never confirmed"
        print(line)

        # travel
        if s["vmax"] is not None:
            print(f"  🚗 {s['dist']:.1f} km · max {s['vmax']:.0f} km/h · avg (moving) "
                  f"{s['vavg']:.0f} km/h" if s["vavg"] else f"  🚗 {s['dist']:.1f} km · stationary")
        # gps
        lost = get("GPS_LOST")
        backs = [fnum(e["value"]) or 0 for e in get("GPS_BACK")]
        col = G if s["fix_pct"] > 90 else Y if s["fix_pct"] > 50 else R
        print(f"  🛰  GPS fix {col}{s['fix_pct']:.0f}%{N} of the time · {len(lost)} drop(s)"
              + (f", longest {max(backs):.0f} s" if backs else "")
              + (f" · {R}no GPS data (wiring?){N}" if get("GPS_NO_DATA") else ""))
        # heat
        if s["tmax"] is not None:
            col = G if s["tmax"] < TEMP_HIGH else Y if s["tmax"] < 80 else R
            print(f"  🌡  max {col}{s['tmax']:.1f}°C{N} · {fmt_t(s['hot_s'])} at ≥{TEMP_HIGH:.0f}°C")
        # power
        uv = get("UNDERVOLTAGE_START")
        col = G if not uv else R
        print(f"  ⚡ under-voltage: {col}{len(uv)}{N} time(s)" + (f", {s['uv_s']} s total" if s["uv_s"] else ""))
        # recording + events
        gaps = get("REC_GAP")
        print(f"  🎥 jolt locks {len(get('JOLT_LOCK'))} · recording gaps {len(gaps)}"
              + (f" ({sum(fnum(e['value']) or 0 for e in gaps):.0f} s)" if gaps else "")
              + f" · recorder restarts {len(get('REC_RESTART'))}"
              + (f" · {R}SD errors {len(get('SD_ERROR'))}{N}" if get("SD_ERROR") else ""))
        off = val(E, "OFF_TIME")
        svc = [e["value"] for e in E if e["event"] in ("SERVICE_RESTART",)] + \
              ["sensors" for e in E if e["event"] == "SENSORS_RESTART"]
        down = val(E, "REC_DOWNTIME", sum)
        print(f"  🔁 off before start: {fmt_t(off) if off is not None else '?'}"
              + (f" {R}(quick restart){N}" if off is not None and off < 60 else "")
              + f" · service restarts: {len(svc)}" + (f" ({', '.join(svc)})" if svc else "")
              + (f" · video lost {down:.0f} s" if down else ""))
        wifi = [e for e in E if e["event"] in ("WIFI_HOME", "WIFI_HOTSPOT")]
        if wifi:
            print(f"  📶 Wi-Fi: " + " → ".join(
                ("home" if e["event"] == "WIFI_HOME" else "hotspot") + f" {e['local_time'][11:16]}" for e in wifi[:6])
                + (" …" if len(wifi) > 6 else ""))
        end = ended.get(s["boot"])
        print(f"  ⏹  ended: " + ({"power_cut": f"{Y}power cut (ignition off / unplugged){N}",
                                  "clean": f"{G}clean shutdown{N}"}.get(end, "still running / unknown")))
        print()

def events(count):
    ev = read_events()[-count:]
    if not ev:
        print("no events yet"); return
    for e in ev:
        loc = f" @ https://maps.google.com/?q={e['lat']},{e['lon']}" if e.get("lat") else ""
        spd = f" {e['kmh']} km/h" if e.get("kmh") else ""
        col = R if e["event"] in ("UNDERVOLTAGE_START", "TEMP_CRITICAL", "SD_ERROR", "GPS_NO_DATA") else \
              Y if e["event"] in ("GPS_LOST", "TEMP_HIGH", "REC_GAP", "REC_RESTART", "JOLT_LOCK", "PREV_RUN_END",
                                  "WIFI_HOTSPOT_FALLBACK") else D
        print(f"{e['local_time']}  {col}{e['event']:<21}{N} {e['value']:>7}  {e['detail']}{spd}{loc}")

if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "events":
        events(int(a[1]) if len(a) > 1 else 40)
    elif a and a[0] == "restarts":
        restarts(int(a[1]) if len(a) > 1 else 30)
    else:
        report(int(a[0]) if a else 5)
__DASHCAM_EOF_DASHCAM_REPORT__

cat > /usr/local/bin/dashcam << '__DASHCAM_EOF_DASHCAM__'
#!/bin/bash
# =============================================================================
#  dashcam — one command to control the Pi dashcam
#
#    dashcam status | watch               health report (watch = live, every 5 s)
#    dashcam report [N] | restarts | events [N]
#    dashcam start | stop | restart       all recording services
#    dashcam logs [sensors|record|housekeeper|wifi]   follow service logs (Ctrl+C)
#    dashcam wifi                         Wi-Fi mode, hotspot name, phones connected
#    dashcam wifi auto|home|hotspot       switch Wi-Fi mode (until the next reboot)
#    dashcam config                       show all settings
#    dashcam config get KEY
#    dashcam config set KEY VALUE         change a setting + restart services
#    dashcam config edit                  open the file in nano, restart after
#    dashcam clear clips|locked|logs|all  delete media/logs (asks first; -y to skip)
#    dashcam disk                         space used by clips / locked / logs
# =============================================================================
CONF=/etc/dashcam.conf
SERVICES="dashcam-sensors dashcam-housekeeper dashcam-record"
B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'

need_root() { [[ $EUID -eq 0 ]] || exec sudo "$0" "${ORIG_ARGS[@]}"; }
ORIG_ARGS=("$@")
# shellcheck disable=SC1090
[[ -f $CONF ]] && source "$CONF"
BASE="$(dirname "${CLIPS_DIR:-$HOME/dashcam/clips}")"
LOGS_DIR="$BASE/logs"

confirm() {
  [[ "$YES" == 1 ]] && return 0
  read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[yY]$ ]]
}

svc() {   # svc start|stop|restart
  need_root
  case "$1" in
    stop)    systemctl stop dashcam-record dashcam-housekeeper dashcam-sensors ;;
    start)   systemctl start dashcam-sensors dashcam-housekeeper dashcam-record ;;
    restart) systemctl restart dashcam-sensors dashcam-housekeeper dashcam-record ;;
  esac
  for s in $SERVICES; do
    systemctl is-active --quiet "$s" && echo "  ${G}●${N} $s running" || echo "  ${R}●${N} $s stopped"
  done
}

config() {
  case "$1" in
    ""|show)
      echo "${B}$CONF${N}"
      grep -v '^\s*$' "$CONF" | sed -E "s/^([A-Z_]+)=([^#]*)/  ${G}\1${N}=${B}\2${N}/" ;;
    get)
      [[ -n "$2" ]] || { echo "usage: dashcam config get KEY"; exit 1; }
      v=$(grep -E "^$2=" "$CONF" | head -1 | cut -d= -f2- | sed 's/#.*//; s/[[:space:]]*$//')
      [[ -n "$v" ]] && echo "$v" || { echo "${R}no such key: $2${N}"; exit 1; } ;;
    set)
      [[ -n "$2" && -n "$3" ]] || { echo "usage: dashcam config set KEY VALUE"; exit 1; }
      need_root
      [[ "$2" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "${R}bad key name: $2${N}"; exit 1; }
      [[ "$3" =~ ^[A-Za-z0-9_./:+-]+$ ]] || { echo "${R}value may only contain letters, numbers and _ . / : + -${N}"; exit 1; }
      cp "$CONF" "$CONF.bak"
      if grep -qE "^$2=" "$CONF"; then
        old=$(grep -E "^$2=" "$CONF" | head -1 | cut -d= -f2- | sed 's/#.*//; s/[[:space:]]*$//')
        # replace the value, keep any trailing "# comment"
        sed -i -E "s|^($2=)[^#]*[^#[:space:]]([[:space:]]*#.*)?$|\1$3\2|" "$CONF"
        echo "  $2: ${Y}$old${N} → ${G}$3${N}   (backup: $CONF.bak)"
      else
        echo "$2=$3" >> "$CONF"
        echo "  ${Y}new key${N} $2=${G}$3${N}   (check spelling — unknown keys are ignored)"
      fi
      if [[ "$2" == HOTSPOT_* || "$2" == WIFI_* ]]; then
        systemctl restart dashcam-wifi
        echo "  Wi-Fi setting: used the next time the hotspot starts (next boot, or: dashcam wifi home; dashcam wifi hotspot)"
      else
        echo "  restarting services…"; svc restart
      fi ;;
    edit)
      need_root
      cp "$CONF" "$CONF.bak"
      "${EDITOR:-nano}" "$CONF"
      if cmp -s "$CONF" "$CONF.bak"; then echo "  no changes"; else echo "  restarting services…"; svc restart; systemctl restart dashcam-wifi; fi ;;
    *) echo "usage: dashcam config [show|get KEY|set KEY VALUE|edit]"; exit 1 ;;
  esac
}

hotspot_ssid() { nmcli -g 802-11-wireless.ssid con show dashcam-hotspot 2>/dev/null; }

wifi() {
  local st=/run/dashcam/wifi.json
  case "$1" in
    ""|status)
      if [[ ! -f $st ]]; then echo "  ${R}✘${N} no Wi-Fi state yet (is dashcam-wifi running?  sudo systemctl status dashcam-wifi)"; return 1; fi
      python3 - "$st" "$(hotspot_ssid)" <<'PY'
import json, sys, time
G="\033[32m"; R="\033[31m"; Y="\033[33m"; D="\033[2m"; N="\033[0m"
s = json.load(open(sys.argv[1])); hs = sys.argv[2] or "(not configured)"
mode = {"auto": "auto (home Wi-Fi if seen at boot, else hotspot)",
        "home": f"home {Y}(forced until reboot){N}", "hotspot": f"hotspot {Y}(forced until reboot){N}"}[s["mode"]]
print(f"    mode: {mode}")
if s["current"] == "hotspot":
    print(f"  {G}✔{N} hotspot ON  '{s['ssid']}'  ·  {s['clients']} device(s) connected  ·  Pi = {s['ip'] or '10.42.0.1'}")
    print(f"    phone: Wi-Fi → {s['ssid']} → Files app → Connect to Server → smb://{s['ip'] or '10.42.0.1'}  (Guest)")
elif s["current"] == "home":
    print(f"  {G}✔{N} home Wi-Fi '{s['ssid']}'  ·  Pi = {s['ip']}  ·  files: smb://dashcam.local or smb://{s['ip']}")
    print(f"    {D}hotspot '{hs}' starts by itself when home Wi-Fi isn't around{N}")
else:
    print(f"  {Y}!{N} not connected right now (looking for home Wi-Fi; hotspot '{hs}' starts if none is found)")
if time.time() - s["updated"] > 15:
    print(f"  {R}✘{N} Wi-Fi state is {time.time() - s['updated']:.0f} s old — is dashcam-wifi running?")
PY
      ;;
    auto|home|hotspot)
      need_root
      systemctl is-active --quiet dashcam-wifi || systemctl start dashcam-wifi
      mkdir -p /run/dashcam
      echo "$1" > /run/dashcam/wifi-mode
      local hs; hs="$(hotspot_ssid)"
      case "$1" in
        hotspot)
          [[ -n "$hs" ]] || { echo "  ${R}hotspot not configured${N} — copy wifi.conf next to setup-dashcam.sh and re-run it"; exit 1; }
          echo "  ${G}→ hotspot '$hs'${N} in a few seconds (until reboot; 'dashcam wifi auto' to undo)."
          echo "  ${Y}If you are on SSH over home Wi-Fi, this session will drop.${N}"
          echo "  Reconnect: join '$hs' on the laptop/phone, then  ssh $(logname 2>/dev/null || echo "$SUDO_USER")@10.42.0.1" ;;
        home)
          echo "  ${G}→ home Wi-Fi${N} in a few seconds (until reboot; 'dashcam wifi auto' to undo)."
          echo "  ${Y}If you are on SSH over the hotspot, this session will drop.${N} Reconnect via dashcam.local on home Wi-Fi." ;;
        auto)
          echo "  ${G}→ auto${N}: home Wi-Fi if it is around, otherwise the hotspot. Your SSH session may drop for a moment." ;;
      esac ;;
    *) echo "usage: dashcam wifi [status|auto|home|hotspot]"; exit 1 ;;
  esac
}

human() { du -sh "$1" 2>/dev/null | cut -f1; }

disk() {
  echo "${B}Storage${N}"
  printf "  %-8s %6s  %s files\n" clips  "$(human "$CLIPS_DIR")"  "$(ls -1 "$CLIPS_DIR"/*.mp4 2>/dev/null | wc -l)"
  printf "  %-8s %6s  %s files\n" locked "$(human "$LOCKED_DIR")" "$(ls -1 "$LOCKED_DIR"/*.mp4 2>/dev/null | wc -l)"
  printf "  %-8s %6s  %s files\n" logs   "$(human "$LOGS_DIR")"   "$(ls -1 "$LOGS_DIR" 2>/dev/null | wc -l)"
  printf "  %-8s %6s\n" journal "$(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]*[KMG]' | head -1)"
  df -h --output=size,used,avail,pcent "$CLIPS_DIR" | tail -1 | awk '{print "  card     "$3" free of "$1" ("$4" used)"}'
}

clear_what() {
  need_root
  case "$1" in
    clips)
      n=$(ls -1 "$CLIPS_DIR"/*.mp4 2>/dev/null | wc -l)
      confirm "Delete $n normal clips ($(human "$CLIPS_DIR"))? Locked clips are kept." || exit 0
      cur=$(ls -1t "$CLIPS_DIR"/*.h264 2>/dev/null | head -1)          # keep the one being recorded
      find "$CLIPS_DIR" -maxdepth 1 -type f \( -name '*.mp4' -o -name '*.csv' -o -name '*.h264' \) \
           ! -path "$cur" -delete
      echo "  ${G}clips cleared${N}" ;;
    locked)
      n=$(ls -1 "$LOCKED_DIR"/*.mp4 2>/dev/null | wc -l)
      confirm "${R}Delete ALL $n LOCKED (crash) clips?${N} Copy anything important first." || exit 0
      find "$LOCKED_DIR" -maxdepth 1 -type f -delete
      echo "  ${G}locked clips cleared${N}" ;;
    logs)
      confirm "Delete sensor logs, events and system journal history?" || exit 0
      systemctl stop dashcam-sensors
      find "$LOGS_DIR" -maxdepth 1 -type f -delete
      journalctl --rotate >/dev/null 2>&1; journalctl --vacuum-time=1s >/dev/null 2>&1
      systemctl start dashcam-sensors
      echo "  ${G}logs cleared${N}" ;;
    all)
      confirm "${R}Delete EVERYTHING: clips, locked clips and logs?${N}" || exit 0
      YES=1; clear_what clips; clear_what locked; clear_what logs ;;
    *) echo "usage: dashcam clear clips|locked|logs|all [-y]"; exit 1 ;;
  esac
}

usage() { awk 'NR > 3 && /^# =+$/ {exit} NR > 3 {sub(/^#[ ]?[ ]?/, ""); print}' "$0"; }

YES=0
args=()
for a in "$@"; do [[ "$a" == "-y" || "$a" == "--yes" ]] && YES=1 || args+=("$a"); done
set -- "${args[@]}"

case "$1" in
  status)   exec dashcam-status ;;
  watch)    exec dashcam-status -w ;;
  report)   shift; exec dashcam-report "$@" ;;
  restarts) exec dashcam-report restarts "${@:2}" ;;
  events)   exec dashcam-report events "${@:2}" ;;
  start|stop|restart) svc "$1" ;;
  logs)
    case "$2" in
      sensors|record|housekeeper|wifi) exec journalctl -u "dashcam-$2" -f -n 30 ;;
      *) exec journalctl -u dashcam-sensors -u dashcam-record -u dashcam-housekeeper -u dashcam-wifi -f -n 30 ;;
    esac ;;
  wifi)     wifi "$2" ;;
  config)   shift; config "$@" ;;
  clear)    clear_what "$2" ;;
  disk)     disk ;;
  ""|help|-h|--help) usage ;;
  *) echo "unknown command: $1"; usage; exit 1 ;;
esac
__DASHCAM_EOF_DASHCAM__

rm -f /opt/dashcam/housekeeper.sh    # replaced by housekeeper.py
chmod 755 /opt/dashcam/record.sh /opt/dashcam/wifi.sh /opt/dashcam/*.py \
          /usr/local/bin/dashcam-status /usr/local/bin/dashcam-report /usr/local/bin/dashcam

# ---------- 5. data folders ----------
# shellcheck disable=SC1091
source /etc/dashcam.conf
BASE="$(dirname "$CLIPS_DIR")"
mkdir -p "$CLIPS_DIR" "$LOCKED_DIR" "$BASE/logs" "$BASE/.state"
chown -R "$DASH_USER:$DASH_USER" "$BASE"

# ---------- 6. phone access: Wi-Fi hotspot ----------
echo "==> Setting up the Wi-Fi hotspot…"
WIFI_SECRET=/etc/dashcam-wifi.conf
if [[ -f "$SCRIPT_DIR/wifi.conf" ]]; then
  install -m 600 -o root -g root "$SCRIPT_DIR/wifi.conf" "$WIFI_SECRET"
  echo "    copied wifi.conf → $WIFI_SECRET (root only)"
fi
secret() {   # read KEY='value' from the secrets file WITHOUT running it; '#' allowed in values
  local v
  v="$(grep -E "^$1=" "$WIFI_SECRET" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  v="${v%$'\r'}"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  if [[ ${#v} -ge 2 && ( ( "${v:0:1}" == "'" && "${v: -1}" == "'" ) || ( "${v:0:1}" == '"' && "${v: -1}" == '"' ) ) ]]; then
    v="${v:1:${#v}-2}"
  fi
  printf '%s' "$v"
}
HS_SSID="$(secret HOTSPOT_SSID)"
HS_PASS="$(secret HOTSPOT_PASS)"

# Wi-Fi country (5 GHz needs it)
WC="$(conf_val WIFI_COUNTRY)"; WC="${WC:-IN}"
if command -v raspi-config >/dev/null && command -v iw >/dev/null; then
  REG="$(iw reg get 2>/dev/null | awk '/^country/ {sub(":", "", $2); print $2; exit}' || true)"
  if [[ "$REG" != "$WC" ]]; then
    raspi-config nonint do_wifi_country "$WC" >/dev/null 2>&1 || true
    echo "    Wi-Fi country set to $WC"; REBOOT_NEEDED=1
  fi
fi

HAVE_HOTSPOT=0
if ! command -v nmcli >/dev/null; then
  echo "    !! NetworkManager (nmcli) not found — hotspot skipped"
elif [[ -n "$HS_SSID" && ${#HS_PASS} -ge 8 && ${#HS_PASS} -le 63 ]]; then
  BAND="$(conf_val HOTSPOT_BAND)"; BAND="${BAND:-a}"
  CH="$(conf_val HOTSPOT_CHANNEL)"; CH="${CH:-36}"
  [[ "$BAND" == "bg" ]] && (( CH > 14 )) && CH=6
  if ! nmcli -t -f NAME con show | grep -qx dashcam-hotspot; then
    nmcli con add type wifi ifname wlan0 con-name dashcam-hotspot ssid "$HS_SSID" autoconnect no >/dev/null
  fi
  # autoconnect stays OFF: the dashcam-wifi service decides when the hotspot runs
  nmcli con modify dashcam-hotspot \
    connection.autoconnect no \
    802-11-wireless.ssid "$HS_SSID" 802-11-wireless.mode ap \
    802-11-wireless.band "$BAND" 802-11-wireless.channel "$CH" \
    ipv4.method shared ipv4.addresses 10.42.0.1/24 ipv6.method disabled \
    wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp \
    wifi-sec.psk "$HS_PASS"
  HAVE_HOTSPOT=1
  echo "    hotspot '$HS_SSID' ready ($([[ $BAND == a ]] && echo "5 GHz, channel $CH" || echo "2.4 GHz, channel $CH")) — Pi address 10.42.0.1"
elif nmcli -t -f NAME con show 2>/dev/null | grep -qx dashcam-hotspot; then
  HAVE_HOTSPOT=1
  echo "    hotspot already configured (no new wifi.conf) — kept as is"
else
  echo "    !! no wifi.conf found next to the script (or password not 8–63 characters)"
  echo "       → hotspot NOT set up. Create wifi.conf (see wifi.conf.example) and re-run."
fi
unset HS_PASS

# ---------- 7. phone access: SMB file sharing (read-only, guest) ----------
echo "==> Setting up SMB file sharing…"
[[ -f /etc/samba/smb.conf && ! -f /etc/samba/smb.conf.orig ]] && cp /etc/samba/smb.conf /etc/samba/smb.conf.orig
cat > /etc/samba/smb.conf << EOF
# Written by setup-dashcam.sh $VERSION — re-running the installer overwrites this file.
# Read-only guest shares: anyone on the home Wi-Fi or the dashcam hotspot can VIEW
# and COPY clips, nobody can delete or change them over the network.
[global]
   server string = dashcam
   workgroup = WORKGROUP
   server role = standalone server
   map to guest = Bad User
   guest account = nobody
   server min protocol = SMB2
   disable netbios = yes
   smb ports = 445
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   log file = /var/log/samba/log.%m
   max log size = 200
   logging = file

[clips]
   comment = Dashcam clips (normal, rotated)
   path = $CLIPS_DIR
   read only = yes
   guest ok = yes
   guest only = yes
   force user = $DASH_USER
   veto files = /*.h264/*.tmp.mp4/

[locked]
   comment = Dashcam crash clips (locked)
   path = $LOCKED_DIR
   read only = yes
   guest ok = yes
   guest only = yes
   force user = $DASH_USER
   veto files = /*.h264/*.tmp.mp4/
EOF
testparm -s /etc/samba/smb.conf >/dev/null 2>&1 || { echo "    !! smb.conf check failed: testparm -s" >&2; false; }
systemctl disable --now nmbd >/dev/null 2>&1 || true      # NetBIOS not needed (phones use IP / .local)
systemctl enable smbd >/dev/null 2>&1
systemctl restart smbd
# let Macs/Finder see it without typing the address
if [[ -d /etc/avahi/services ]]; then
  cat > /etc/avahi/services/smb.service << 'AEOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h</name>
  <service><type>_smb._tcp</type><port>445</port></service>
</service-group>
AEOF
fi
echo "    shares: clips, locked (read-only, guest)"

# ---------- 8. systemd services ----------
echo "==> Installing systemd services"
cat > /etc/systemd/system/dashcam-sensors.service << EOF
[Unit]
Description=Dashcam sensors (GPS + accelerometer + GPS clock)
Before=dashcam-record.service dashcam-housekeeper.service

[Service]
User=$DASH_USER
SupplementaryGroups=dialout i2c systemd-journal
AmbientCapabilities=CAP_SYS_TIME
RuntimeDirectory=dashcam
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
ExecStart=/usr/bin/python3 /opt/dashcam/sensors.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/dashcam-record.service << EOF
[Unit]
Description=Dashcam recorder
After=local-fs.target

[Service]
User=$DASH_USER
SupplementaryGroups=video
ExecStart=/opt/dashcam/record.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/dashcam-housekeeper.service << EOF
[Unit]
Description=Dashcam housekeeper (mp4 wrap, naming, crash-lock, rolling delete)
After=local-fs.target dashcam-sensors.service

[Service]
User=$DASH_USER
ExecStart=/usr/bin/python3 /opt/dashcam/housekeeper.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/dashcam-wifi.service << 'EOF'
[Unit]
Description=Dashcam Wi-Fi mode keeper (home Wi-Fi or own hotspot)
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
ExecStart=/opt/dashcam/wifi.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dashcam-sensors dashcam-record dashcam-housekeeper dashcam-wifi >/dev/null
systemctl restart dashcam-sensors dashcam-housekeeper dashcam-record
systemctl restart dashcam-wifi      # it only starts the hotspot if home Wi-Fi is missing

# ---------- 9. health check ----------
echo
echo "==> Waiting 8 s for services to settle…"
sleep 8
for s in dashcam-sensors dashcam-record dashcam-housekeeper dashcam-wifi smbd; do
  systemctl is-active --quiet $s && echo "  [OK]   $s" || echo "  [FAIL] $s  → journalctl -u $s -n 30"
done
[[ $HAVE_HOTSPOT -eq 1 ]] && echo "  [OK]   hotspot configured" || echo "  [WARN] hotspot not configured (wifi.conf missing)"
echo
cat << EOF
Done ($VERSION). Everything starts automatically on every boot.

  dashcam status            health report        (dashcam watch = live)
  dashcam report            trips + uptime       (dashcam restarts · dashcam events)
  dashcam wifi              Wi-Fi / hotspot      (dashcam wifi auto|home|hotspot)
  dashcam start|stop|restart
  dashcam logs              follow service logs
  dashcam config            show settings        (config set KEY VALUE · config edit)
  dashcam clear clips|locked|logs|all
  dashcam disk              space used
  dashcam help

Clips on the phone: join the hotspot → Files app → Connect to Server → smb://10.42.0.1 (Guest)
           at home: smb://dashcam.local
EOF

if [[ $REBOOT_NEEDED -eq 1 ]]; then
  echo
  echo "!! I2C / serial / camera / Wi-Fi country settings changed — a reboot is needed to activate them."
  if [[ $AUTO_REBOOT -eq 1 ]]; then
    echo "   Rebooting in 10 s (Ctrl+C to cancel). After ~1 minute: ssh in and run  dashcam status"
    sleep 10; systemctl reboot
  else
    echo "   Run:  sudo reboot"
  fi
fi
