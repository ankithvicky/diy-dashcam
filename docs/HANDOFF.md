# Handoff — DIY Raspberry Pi Dashcam

> For the next engineer (or Claude Code) picking this up. Covers everything from day one to
> **27 Oct 2026**: goals, every decision and *why*, the current state, open problems and next steps.
> This repo is **public**. Private details (home Wi-Fi name, addresses, hotspot name, shopping
> notes) are kept out of it; they live in the owner's private project notes.

---

## 0. TL;DR

| Item | Status |
|---|---|
| Hardware | Assembled and working on the bench; has been in the car (front only) |
| Software | **v8** installer (`setup-dashcam.sh`) installed and running on the Pi: recording, crash lock, rotation, health logs, **own Wi-Fi hotspot**, **read-only SMB shares** |
| Phone access | Hotspot works (a phone joined: "1 device connected"). Clip playback in the iPhone Files app over SMB **not yet confirmed** |
| GPS | **Fixed on 27 Oct**: a fix 46 s after boot (hot start), 12–13 satellites visible, clock set from GPS. But the fix is **marginal**: only 4 used, and it briefly flickers to "no fix". An **active antenna** is still recommended for the car (§8.1) |
| Other open issues | One 22 s power loss in the car; one false-looking jolt lock at boot; `REC_GAP` events that look like false positives (code bug suspected, §8.3); jumper wires come loose with vibration |
| Repo | `main` = v8 (commit `f74d54b`) + this handoff. Push straight to `main` (single contributor) |

---

## 1. Owner and how to work with him

- **Vicky**: a lead backend developer (Node/NestJS/MERN), **no electronics background**. Explain hardware steps simply and avoid anything that needs real soldering skill.
- **One script, not scattered commands.** The model is EC2 user-data: flash a card, run one installer, done. Any change goes into `setup-dashcam.sh`.
- Give **numbered, simple steps**. Explain jargon (UART, I2C, NMEA, throttled bits…) the first time it comes up.
- **Ask him to paste command output**, and read his photos and videos of the hardware carefully.
- **Shopping:**
  - Give **3 options plus a ★ recommendation**, each with a link, price and delivery estimate.
  - **Never buy, and never change his carts.** He checks out himself. Amazon items go to a saved list, not the cart.
- **Safety comes first:** heat, power and short circuits. A power bank never stays in a parked car.
- **Before changing the repo or anything else hard to undo:** ask. When something is blocked, say what's pending.
- **Claude can't SSH into the Pi**, because that needs his password. Give him commands to run; for long jobs use `sudo systemd-run --unit=NAME …` so they survive an SSH drop.

---

## 2. Goal and requirements (decided at the start)

| Requirement | Decision | Why |
|---|---|---|
| Purpose | **Incident capture only** (accident, insurance and police evidence) | Not vlogging, so reliability matters more than image quality |
| Cameras | **Front only**; rear dropped | Cost. A rear camera can come in phase 2 |
| Boot time | Target **10–15 s** from power to recording | Recording must start before the car moves |
| Storage | Rolling (oldest deleted); crash clips protected | — |
| Sensors in v1 | **GPS** (time, speed, location) + **accelerometer/gyro** (crash detection) | Evidence needs time and place; crash detection protects clips |
| Power | Car 12 V socket → 5 V 3 A USB car charger → short thick micro-USB cable | It switches off with the ignition, so there's no parking mode (accepted) |
| Usage | Up to 10 h of driving a day; cabin ~27 °C with AC; often parked in the sun | Heat drives the part choices |
| Mounting | Adhesive on the dash, removed about once a month | — |
| Source of truth | **One idempotent installer script** | Re-flash and re-run must always rebuild everything |

---

## 3. Hardware decisions

### In use
| Part | Choice | Why / notes |
|---|---|---|
| Board | **Raspberry Pi 3 Model B+** (1 GB) | Pi Zero 2 W was out of stock everywhere |
| Camera | **Arducam 8MP IMX219, 175°**, manual focus, IR-cut (day) | Camera Module 3 is only 76° and misses side lanes; CM3 Wide costs about twice as much. A STARVIS sensor (better at night) is a later upgrade |
| Camera cable | Orange **22→15 pin** ribbon | Narrow end in the camera, wide end in the Pi. The white 22→22 cable doesn't fit the Pi 3 |
| microSD | **WD Purple 128 GB** | Surveillance grade, rated to ~85 °C. Ordinary cards are rated to 70 °C |
| GPS | **u-blox NEO-6M (GY-GPS6MV2)** + ceramic patch antenna on **u.FL** | Cheap and standard. Header pins soldered by the owner |
| Accel/gyro | **MPU-6050** breakout (I2C 0x68) | Header pins soldered by the owner |
| Heatsinks | Pi 3 copper set | — |
| Case | Ready-made Pi 3 B+ case with camera slot, used **open-topped** | No 3D printer. Parts held with tape; the camera is taped to the front wall |
| Wires | 20 cm female–female Dupont jumpers | ⚠ They work loose with car vibration (§8.4) |
| Home power | 5 V 3 A wall charger | A 5 V 1 A charger caused under-voltage (`0x50005`) |
| Car power | **Duracell 36 W QC3.0 dual-port** car charger (5 V 3 A on one port) + **Portronics 1 m 3 A braided** micro-USB | QC is safe because the Pi never asks for 9/12 V. A short, thick cable means less voltage drop. The cable is confirmed in use |

### Decided against / deferred
- **Rear camera** (USB webcam + extension): dropped for cost; phase 2.
- **Lithium UPS: rejected** because of dashboard heat. A **supercap UPS** is phase 2. **v1 power-cut safety is software only** (crash-safe naming and wrapping now; a read-only root is planned).
- **3D-printed case**: no printer. Ready-made case instead.
- **Suction mount**: considered. Current plan is **3M VHB / Dual Lock** on the dash (ordinary foam tape and Velcro soften at 60–70 °C).
- **12 V→5 V buck converter**: only for hardwiring later.
- **Camera Module 3 / CM3 Wide / STARVIS**: possible later upgrades.

### Still to buy (owner decides)
- **GPS fix (see §8.1).** Recommended: an **active GPS antenna** with a 3 m cable and SMA plug (≈ ₹210, e.g. Evelta "GPS External Active Antenna (3m) – SMA", 27 dB, 3–5 V, magnetic) plus a **u.FL/IPEX1 → SMA *female* pigtail** (≈ ₹119, Robu, 20 cm RG178). Total ≈ ₹330.
  - Not yet ordered. The owner wants to do an open-sky test first.
  - Check that the board powers the antenna: with the adapter fitted, measure about 3 V between the SMA centre pin and the shell. It isn't guaranteed on every GY-GPS6MV2.
- **Securing the jumpers:** hot glue now (recommended); a GPIO **screw-terminal** board later; a soldered perma-proto HAT eventually.
- Multimeter (for continuity and the antenna-power check), a case lid with a wire slot, VHB / Dual Lock tape.

---

## 4. Wiring (verified)

Hold the Pi with the USB ports on the **left** and the 40 pins along the bottom edge. **Pin 1 is at the right end of the inner row** and has a square pad. The inner row has the odd pins; the edge row has the even pins. **Never use 5 V pins 2 and 4.**

| Sensor pin | Pi pin |
|---|---|
| MPU-6050 VIN / GND / SDA / SCL | 17 (3.3 V) / 9 / 3 / 5 (3Vo and INT unused) |
| GPS VCC / GND / TX / RX | 1 (3.3 V) / 6 / **10 (RXD)** / **8 (TXD)** (TX→RX crossed over) |
| Camera | CSI slot, orange 22→15 ribbon |

Antenna: **ceramic (tan) side up**. The MPU must be stuck down **rigidly**, or rattles cause false locks. Insulate the backs of the boards and keep them off the Pi's chips.

---

## 5. OS and platform decisions

- **Raspberry Pi OS Lite 64-bit (Debian 13 Trixie)**, set up with Raspberry Pi Imager:
  - hostname `dashcam`
  - home Wi-Fi
  - **keyboard layout `us`** (the wrong layout typed the wrong characters)
  - SSH with password
- **I2C on; serial login console off; serial hardware on; `dtoverlay=disable-bt`.** This frees the good UART for the GPS (`/dev/serial0 → ttyAMA0`).
- **rpicam-apps lite build:** `--codec libav` doesn't exist there. **Decision:** record raw H.264 and wrap it to MP4 with `ffmpeg -c copy` (no re-encode).
- **Mode 1640×1232** (full sensor), not 1920×1080. 1080p is a centre crop and loses the 175° view.
- NetworkManager (`nmcli`) manages Wi-Fi. The home profile is created by Imager (netplan-generated name).
- **No RTC battery**, so after a reboot with no network the clock resumes at the last saved time. This drives the naming design (§6.3).

---

## 6. Software (v8) — architecture and decisions

### 6.1 Repo layout
```
setup-dashcam.sh     THE source of truth. Every program is embedded as a quoted heredoc.
README.md            user guide (install, phone access, commands, settings, troubleshooting)
wifi.conf.example    template for the private wifi.conf (hotspot SSID/password)
.gitignore           wifi.conf, recordings, logs, OS noise
tools/gps-check.sh   GPS diagnostic (Wi-Fi on vs off), see §8.1
docs/HANDOFF.md      this file
CLAUDE.md            short rules for Claude Code
```

### 6.2 Installer behaviour (`setup-dashcam.sh`)
- Runs as `sudo bash setup-dashcam.sh [user] [--no-reboot]`. The user defaults to `$SUDO_USER`.
- `set -euo pipefail` plus an ERR trap that prints `!! setup FAILED at line N: <cmd>`.
  - Lesson from v7: a failing `grep` inside `$(…)` silently killed the script, so every such lookup ends in `|| true`.
- **Idempotent.** `/etc/dashcam.conf` is kept; new keys are only *appended* (`add_conf`). Programs are always rewritten. It reboots **only** if config.txt, interface or Wi-Fi-country changes need it.
- Sections:
  1. packages (`ffmpeg python3-smbus2 i2c-tools samba dnsmasq-base iw`, rpicam-apps-lite if missing)
  2. interfaces, camera check (forces `dtoverlay=imx219` only if auto-detect fails), timezone, removal of the old `gpslog` test service
  3. config + journald (persistent, 50 MB)
  4. programs
  5. data folders
  6. hotspot
  7. SMB
  8. systemd units
  9. health check
- v8 also removed v7's duplicate `rpicam-apps` install block and duplicate `TIMEZONE` line.

### 6.3 Services and programs
| Service | Program | Responsibility |
|---|---|---|
| `dashcam-record` | `/opt/dashcam/record.sh` | `rpicam-vid` 1640×1232 @ 30 fps, 6 Mbps, `--intra 30 --inline`, **60 s segments** → `S<drive>_<n>.h264`. Each start increments the drive counter (`.state/session`) |
| `dashcam-sensors` | `/opt/dashcam/sensors.py` (runs as the user, `CAP_SYS_TIME`) | GPS NMEA (checksum-checked), **sets the system clock from GPS**, tracks clock jumps → `clock.json`; MPU-6050 at ~100 Hz (±8 g, ±500 °/s); jolt ≥ `LOCK_G` → lock request; health events; 1 row per second log; live `state.json` |
| `dashcam-housekeeper` | `/opt/dashcam/housekeeper.py` (every 10 s) | h264 → mp4 wrap; **naming**; per-clip `.csv`; crash lock; rotation; caps; gap and restart events |
| `dashcam-wifi` (v8) | `/opt/dashcam/wifi.sh` (root) | Keeps the single Wi-Fi radio in the wanted mode (§6.5) |
| `smbd` (v8) | Samba | Read-only guest shares `clips`, `locked` |

CLIs:
- `dashcam`: start/stop/restart, logs, wifi, config get/set/edit, clear, disk
- `dashcam-status` (`-w` for live view)
- `dashcam-report` (summary, `restarts`, `events`)

**Clip-naming decision:** with a trusted clock (GPS or NTP) a clip is named by its real start time, `YYYYMMDD_HHMMSS.mp4`. Otherwise it's `S00042_0003.mp4`, **renamed in the same power-on** once the clock is fixed, using recorded clock-jump offsets. Reason: no RTC.

**Crash-lock decision:** `LOCK_G=2.5` (Bangalore potholes and speed breakers reach about 2 g). It locks from **60 s before to 30 s after** the jolt, with a 30 s cooldown. Locked clips are never rotated but are capped at **20 % of the card** (oldest locked deleted first).

**Rotation and caps:**
- Normal clips are deleted oldest-first when free space drops below 10 % (about 28–37 h of driving on 128 GB).
- Logs: 30 days / 200 MB. `events.csv` rotates at 5 MB. journald: 50 MB, 1 month.

**Folders:**
- `~/dashcam/{clips,locked,logs,.state}`
- `/run/dashcam/` for live state (`state.json`, `clock.json`, `wifi.json`, `wifi-mode`, `locks`, `milestones.json`)

**Health events** (`logs/events.csv`: `local_time,boot,uptime_s,event,value,detail,lat,lon,kmh`):
- startup: `BOOT`, `REC_START`
- clock: `CLOCK_OK`, `CLOCK_JUMP`
- GPS: `GPS_FIRST_FIX`, `GPS_LOST`, `GPS_BACK`, `GPS_NO_DATA`
- power: `UNDERVOLTAGE_START/END`
- heat: `TEMP_HIGH/CRITICAL/NORMAL`
- crash: `JOLT_LOCK`
- card: `SD_ERROR`
- runs and restarts: `PREV_RUN_END` (clean / power_cut, from a heartbeat file), `OFF_TIME`, `SERVICE_RESTART`, `SENSORS_RESTART`
- recording: `REC_GAP`, `REC_RESTART`, `REC_DOWNTIME`
- Wi-Fi (v8): `WIFI_HOME`, `WIFI_HOTSPOT`, `WIFI_MODE`, `WIFI_HOTSPOT_FALLBACK`

### 6.4 Phone access — decisions (v8)
| Question | Decision | Why |
|---|---|---|
| How does the phone reach the Pi in the car? | **The Pi is its own hotspot** (NetworkManager AP, `ipv4.method shared`, Pi = **10.42.0.1/24**) | No router in the car. Fixed address; no dependence on iPhone hotspot quirks (auto-off, Maximise Compatibility); **anyone's phone can pull a clip** (police, insurance) |
| Phone hotspot instead? | Rejected | Only works with the owner's phone; changing IP; iOS turns it off when idle |
| CarPlay conflict | Accepted: **fetch clips when parked** | Wireless CarPlay: Bluetooth handshake, then **the car's head unit is the Wi-Fi AP** that the iPhone joins. An iPhone joins only one Wi-Fi network, so joining the dashcam pauses CarPlay. Clips are needed after an incident, when the car is stopped |
| Ignition | Fetch with the ignition in **ACC/ON** | The car charger is unpowered with the ignition off, so the Pi is off |
| Protocol | **SMB** for everyday phone access (the owner prefers it); **SFTP** (SSH, port 22) for admin | The iPhone **Files** app speaks SMB natively (Connect to Server → `smb://10.42.0.1`); SMB is lighter than SFTP on the Pi 3 (no hardware crypto) |
| Plain FTP? | **Rejected** | Unencrypted password; the iPhone Files app can't open FTP |
| SMB login | **Guest**, no password | Hotspot already needs WPA2; anyone helping after an accident can pull clips |
| SMB access | **Read-only** | The phone can't delete evidence. SFTP logs in as the user with full rights, so use it for admin only |
| Shares | `clips` + `locked` (not `logs`) | Default chosen. `.h264` and `.tmp.mp4` are hidden (`veto files`) |
| Hotspot band | **5 GHz, channel 36** (`HOTSPOT_BAND=a`), **automatic fallback to 2.4 GHz channel 6** if it fails to start | About 2× faster transfers and less clash with the car's CarPlay radio. The fallback is logged as `WIFI_HOTSPOT_FALLBACK` |
| Security | WPA2-PSK (RSN/CCMP); country `IN`; IPv6 off on the AP; SMB2 minimum; NetBIOS (`nmbd`) off; avahi advertises `_smb._tcp` | — |
| Ports | 22 SSH/SFTP, 445 SMB, DHCP/DNS on the hotspot only | No internet exposure, **no port forwarding** |
| Secrets | Hotspot SSID and password in **`wifi.conf` next to the script** (git-ignored) → copied to `/etc/dashcam-wifi.conf` (root, 600). **Parsed, not sourced**, so `#` and spaces are allowed; 8–63 characters | Public repo |

### 6.5 Wi-Fi mode switching (`dashcam-wifi`)
The Pi 3 B+ has **one radio**: it can join a network **or** be one, not both.

```
boot ─ home Wi-Fi connects within WIFI_HOME_WAIT_SEC (25 s)? ─ yes → HOME ─(lost)→ HOTSPOT
                                                               └ no  → HOTSPOT
HOTSPOT stays on until power-off (a broadcasting radio can't scan).
```

- The loop compares **wanted vs actual every 3 s**. "Wanted" is `/run/dashcam/wifi-mode` (tmpfs).
- **`dashcam wifi auto|home|hotspot`**: a forced mode lasts **until reboot**, then it's back to auto. Switching to `auto` from the hotspot re-decides as if freshly booted. Forced `home` retries every 30 s.
- The hotspot profile has `autoconnect no`: only the service starts it.
- **Decision: no "switch back to home" watcher in v1.** The car charger cuts power every trip, so the next boot decides again.
- Recording never waits for Wi-Fi. A switch only drops SSH.
- `dashcam wifi` (status) shows mode, SSID, IP and connected clients; `dashcam status` includes it.

### 6.6 Settings (`/etc/dashcam.conf`)
- Camera: `SENSOR_MODE=1640:1232 WIDTH=1640 HEIGHT=1232 FPS=30 BITRATE=6000000 SEGMENT_SEC=60`
- Rotation and time: `MIN_FREE_PCT=10 TIMEZONE=Asia/Kolkata`
- Crash lock: `LOCK_G=2.5 LOCK_BEFORE_SEC=60 LOCK_AFTER_SEC=30 LOCK_COOLDOWN_SEC=30 LOCKED_MAX_PCT=20`
- GPS: `GPS_DEVICE=/dev/serial0 GPS_SET_CLOCK=1 GPS_LOST_SEC=10`
- Logs and heat: `LOG_KEEP_DAYS=30 LOGS_MAX_MB=200 EVENTS_MAX_MB=5 TEMP_HIGH_C=70 TEMP_CRIT_C=80`
- Wi-Fi (v8): `HOTSPOT_BAND=a HOTSPOT_CHANNEL=36 WIFI_COUNTRY=IN WIFI_HOME_WAIT_SEC=25`

`dashcam config set KEY VALUE` restarts the recording services. For `HOTSPOT_*` / `WIFI_*` keys it restarts `dashcam-wifi`; the new hotspot settings apply the next time the hotspot starts.

---

## 7. Repo, security and delivery decisions

- **Public repo** `ankithvicky/diy-dashcam`; work goes **straight to `main`** (single contributor). Commits so far are authored as `Claude <noreply@anthropic.com>`, so the owner's email isn't exposed.
- **Never commit:** `wifi.conf`, home Wi-Fi name, home or Pi IPs, street addresses or PIN codes, GPS coordinates from test logs, any password. Run a grep scan before every push.
- **Audit done 26 Oct:** fresh clone; full history (1 commit); detect-secrets; pattern search. **No leaks.**
  - One minor item: the login name `vicky` appears 3 times in `setup-dashcam.sh`: a usage example on line 8 and two fallback defaults in `dashcam-status`.
  - Removing them was offered; **owner hasn't decided** (pending).
- **Owner's Mac:** clone in `~/Documents/diy-dashcam`, with the real `wifi.conf` there (`chmod 600`, git-ignored).
- **Deploy:** `scp setup-dashcam.sh wifi.conf <user>@dashcam.local:~ && ssh <user>@dashcam.local "sudo bash setup-dashcam.sh"`.
- **A copy of the installer** is also kept in the owner's private project notes. Keep it in sync when releasing. The private project overview doc still says v7 and needs a v8 refresh.

---

## 8. Current state and open problems (as of 26–27 Oct 2026)

### 8.0 Verified working
- **v7** ran cleanly on the Pi (owner confirmed). **v8** is installed. `dashcam status` on 26 Oct showed:
  - all services running, current clip growing (+1.2 MB / 2 s), 57 clips in the last hour
  - 104 GB free of 117 GB, 59.6 °C
  - **hotspot ON with 1 device connected**, SMB on
  - clock confirmed via Wi-Fi
- Boot timing: `REC_START` = **20.4 s after kernel start** (≈24 s from power). The 10–15 s target is **not met yet**.
- The accelerometer works; `JOLT_LOCK` triggers.

### 8.1 GPS: no fix → fixed, but marginal

**Update, 27 Oct 22:32:** `dashcam status` shows `FIX ✓ 4 used, 12 visible`, `GPS fix 46.0 s` after kernel start, and the clock set from GPS. Thirty seconds earlier it showed "13 visible, 4 used, no fix yet". With exactly 4 satellites (the minimum for a 3-D fix), one weak satellite dropping out loses the fix for a moment, so it flickers. The original problem was the antenna path (re-seated); the remaining issue is signal margin.

History:
Timeline and evidence:
1. It worked on the bench before going in the case. The first fix was in a car at a window (44.5 km/h, correct location).
2. After it went into the case and car: **blue LED never blinks** (it blinks only with a fix). `dashcam status`: "talking, no fix yet — 0 satellites visible".
3. `$GPGSV,1,1,00*79` (valid checksum): the receiver works and talks to the Pi, but hears **zero satellites**. Antenna path suspected.
4. The owner re-seated the antenna. Now **1–2 satellites at a time, 8–28 dB, flickering**, with different PRNs (#04–#32). It needs ≥4 satellites at ~30–45 dB. GPS time is unknown (cold start).
5. Diagnostic (`tools/gps-check.sh`, 60 s Wi-Fi ON vs 60 s Wi-Fi OFF), indoors at a window:
   - **720 lines, 0 % corrupt**: **wiring and UART are fine**.
   - **No improvement with Wi-Fi off**: **Wi-Fi interference ruled out**.
6. Conclusion: **weak antenna path or sky view.**
   - Candidates: blocked sky (window grill, concrete overhang, antenna lying on the case) or a **damaged u.FL plug, socket, cable or patch** (it fits "worked before the case").
   - The garbled lines seen earlier were **two readers on the serial port** (`cat` while `dashcam-sensors` ran), not wiring.

Next actions:
- **(a) Open-sky test.** Terrace or open ground; antenna ceramic up, about 20 cm from the Pi; `dashcam watch` for 15–20 min.
  - 6+ satellites and a fix: placement was the issue.
  - Still 1–2: replace the antenna.
- **(b) The recommended fix either way:** an active antenna on the windshield (§3), with the u.FL joint taped.
- **(c)** A close-up photo of the u.FL socket was requested to check for damage.
- Never read `/dev/serial0` while `dashcam-sensors` is running. Use `dashcam watch`, or stop the service first.

### 8.2 Power and heat
- `PREV_RUN_END power_cut` + `OFF_TIME 22 s` in the car: **power was lost for 22 s and the Pi restarted**. Suspects: a loose micro-USB plug or a charger dropout. Make sure the plug is fully in, then watch `dashcam restarts` for "quick restart" flags.
- Indoors, with the new Portronics cable: `throttled=0x50000`, later `0xd0000`.
  - `0x10000`: an under-voltage happened since boot.
  - `0x40000`: throttled at some point.
  - `0x80000`: the soft temperature limit (~60 °C) was hit.
  - These flags last until reboot, so they need a **fresh boot** on the car charger and new cable to judge.
- Temperature: **~57–60 °C indoors in the open case**. The car in sun will be hotter. A sunshade is required; a lid needs vents.

### 8.3 Suspected software bug: false `REC_GAP`
- Observed: `REC_GAP 47 s` before `S00005_0001` and `REC_GAP 230 s` before `S00005_0002`. But the same hour shows **57 clips in 60 min**, so there was no real loss.
- The 230 s gap came right after **`CLOCK_JUMP +180.4 s`**. In `housekeeper.py` `wrap_finished()`, the gap is `start_raw - last_end[sess]` using **uncorrected** file times, so any clock jump between two clips shows up as a gap.
- **Fix:** compare `correct(start_raw, jumps)` with `correct(last_end, jumps)`, or use monotonic time. Re-check `REC_DOWNTIME` the same way.
- The remaining ~47–50 s is unexplained. A possibility: `ffprobe` duration ≠ real time if the camera drops frames in low light (wrapping assumes `-framerate 30`). Check that duration vs mtime spacing is ~60 s.

### 8.4 Hardware robustness
- Dupont jumpers work loose with vibration. Recommended: **hot glue** on both ends now; a **GPIO screw-terminal board** later; perma-proto eventually. Tape over the antenna's u.FL joint.
- **A jolt of 2.87 g 10 s after boot locked 8 clips.** Probably a bump while placing the Pi or starting the car. If it repeats with no real bump, the MPU isn't fixed rigidly (or raise `LOCK_G`).

---

## 9. Roadmap (priority order)

1. **GPS margin:** it gets a fix now, but with only 4 satellites. Check in the car under the windshield. If it still drops, add an active antenna + adapter. Consider a `GPS_FLICKER` event (fix lost <10 s), so marginal reception shows in reports.
2. **Secure the wiring:** hot glue the jumpers, tape the u.FL joint, rigid MPU mount.
3. **Power:** fresh-boot check on the car charger (`dashcam status`, `dashcam restarts`); find the 22 s dropout.
4. **Phone flow end-to-end in the car**, with the secondary phone: join hotspot → Files → `smb://10.42.0.1` → play and save a clip from `locked/`.
5. **Fix the `REC_GAP` false positives** (§8.3), bump to v9, update README and changelog.
6. **Desk tests:** tap → `JOLT_LOCK`; a 60-minute soak (<70 °C, ~60 clips, no dips).
7. **Power-cut safety:** read-only root (overlay) + separate data partition, built into the installer; 50 sudden power pulls.
8. **Boot time to 10–15 s:** trim services, recorder first, `boot_delay=0`, no splash. Measure with `dashcam restarts`. Buildroot is the v2 fallback.
9. **Repo housekeeping:** decide on the `vicky` defaults; refresh the private v8 overview.
10. **Phone app:** a small web page or a Node/Express API (list, download, stream, lock) + a React Native app.
11. **Optional:** speed/location overlay on the video; fully hands-off first boot (cloud-init runs the installer); case lid.
12. **Phase 2:** rear camera, supercap UPS, better night camera, microphone.

**"Done" checks:**
- 24 h of recording with the card wrapping around
- 50 power pulls with no corruption
- <15 s on 10 cold starts
- chip <75 °C
- GPS speed matches the speedometer
- a hard brake locks the clip
- yesterday's clip pulled to the phone in the car
- 2 weeks of daily driving with no missed recording

---

## 10. Useful commands

```bash
# deploy / update (from the Mac clone)
scp setup-dashcam.sh wifi.conf <user>@dashcam.local:~ && ssh <user>@dashcam.local "sudo bash setup-dashcam.sh"
ssh-keygen -R dashcam.local                       # after a re-flash

# on the Pi
dashcam status | watch | report | restarts | events
dashcam wifi [auto|home|hotspot]                  # hotspot from home: SSH drops → join hotspot → ssh <user>@10.42.0.1
dashcam logs [sensors|record|housekeeper|wifi]
vcgencmd get_throttled                            # 0x0 good; low bits = now, 0x10000+ = since boot

# GPS diagnostic (≈2 min; SSH drops during the Wi-Fi-off half; report in the script's folder)
scp tools/gps-check.sh <user>@dashcam.local:~ && ssh <user>@dashcam.local \
  'sudo systemd-run --unit=gpscheck "$HOME/gps-check.sh"'
#   …wait ~3 min, reconnect:  cat ~/gps-report.txt

# raw GPS check (stop the reader first!)
dashcam stop; sudo timeout 15 cat /dev/serial0 | grep GSV; dashcam start

# copy the last 15 min of clips to the Mac (use 10.42.0.1 on the hotspot)
mkdir -p ~/Downloads/dashcam-last15 && ssh <user>@dashcam.local \
  'cd ~/dashcam && find clips locked \( -name "*.mp4" -o -name "*.csv" \) -mmin -15 -print0 | tar -cf - --null -T -' \
  | tar -xf - -C ~/Downloads/dashcam-last15

# SFTP / port checks
sftp <user>@dashcam.local          # iPhone apps: host 10.42.0.1 (car) or dashcam.local (home), port 22
nc -vz dashcam.local 22
```

Phone (iPhone): Wi-Fi → hotspot → Files → `…` → Connect to Server → `smb://10.42.0.1` → **Guest**. At home: `smb://dashcam.local`. SFTP apps: Termius (SFTP tab), FE File Explorer, Documents by Readdle.

---

## 11. Testing checklist before any push (what v8 went through)

1. `bash -n setup-dashcam.sh`
2. Extract every `cat > … << '__DASHCAM_EOF_*__'` heredoc. Run `bash -n` on the shell ones and `python3 -m py_compile` on the Python ones.
3. `shellcheck -S error` on the installer and the extracted shell programs.
4. Render the Samba block and run `testparm -s` on it.
5. Test helper functions under `set -euo pipefail`, e.g. the `secret()` parser with `#` in the password, CRLF, double quotes, and a missing file.
6. Logic changes in `wifi.sh` were checked with a **fake `nmcli`/`iw`/`ip` simulation**:
   - boot without home Wi-Fi → hotspot
   - forced home, out of range → retry → joins
   - forced hotspot
   - `auto` re-decides
   - home lost + 5 GHz failure → 2.4 GHz fallback + event
7. Scan the tree for secrets and personal data before committing.
8. Final proof is always on the real Pi: the owner runs it and pastes `dashcam status`.

---

## 12. Lessons learned
| Symptom | Cause → fix |
|---|---|
| `throttled=0x50005`, red LED blinking | Weak 1 A charger → 5 V 3 A + short thick cable |
| SSH dead after a power change; screen shows 127.0.1.1 | No Wi-Fi → re-flash with Wi-Fi settings |
| Wrong characters on the console | Keyboard layout → `us` in Imager |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | `ssh-keygen -R dashcam.local` |
| `no cameras available` | Re-seat the ribbon (22→15, correct orientation) |
| `--codec libav` unknown | Lite build → raw H.264 + ffmpeg wrap |
| `double free or corruption` on rpicam exit | Harmless |
| Installer stopped silently (v7) | `set -e` + failing `grep` in `$(…)` → `|| true` + ERR trap |
| Background job died with SSH | Use `sudo systemd-run --unit=…` |
| `/dev/serial0` busy / garbled NMEA | Two readers → only `dashcam-sensors` reads it; stop it for raw checks |
| Session name earlier than the real time | No RTC → GPS/NTP time + rename |
| GPS 0 satellites after re-housing | u.FL plug unseated; re-seat it, tape it, keep the antenna away from the Pi with open sky |

---

## 13. Side threads (not part of the build)
- An always-on "memory device" idea (local STT/TTS on a Pi, remote LLM): discussed, not started.
- Why commercial dashcams boot fast (RTOS / custom firmware) and use supercaps instead of batteries (heat).
