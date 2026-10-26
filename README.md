# DIY Dashcam on a Raspberry Pi 3 B+

A front dashcam for **incident capture** (accidents, insurance and police evidence) built from a
Raspberry Pi, a 175° camera, a GPS and an accelerometer.

- 🎥 Records non-stop in 1-minute clips. The oldest clips are deleted when the card fills up.
- 💥 A hard jolt (crash, hard brake) **locks** the clips from 60 s before to 30 s after. Normal rotation never deletes them.
- 🛰 GPS sets the clock (the Pi has no clock battery), names clips by real time, and saves speed and location next to every clip.
- 📶 Phone access with no internet. The Pi makes its own Wi-Fi hotspot in the car, and the phone opens clips over **SMB** in the iPhone Files app.
- 🩺 Health logging: start-up time, heat, power dips, GPS drops, SD errors, power cuts.
- 🧰 **One installer script** (like EC2 user-data): flash a card, run it, done.

> Status (Oct 2026): v8. The hardware works on the bench and the software is installed. The first car trial is next.

---

## Contents
1. [Hardware](#1-hardware)
2. [Wiring](#2-wiring)
3. [Install](#3-install)
4. [Getting clips on your phone](#4-getting-clips-on-your-phone)
5. [Wi-Fi modes: home vs hotspot](#5-wi-fi-modes-home-vs-hotspot)
6. [Daily commands](#6-daily-commands)
7. [How it works](#7-how-it-works)
8. [Storage and rotation](#8-storage-and-rotation)
9. [Settings](#9-settings-etcdashcamconf)
10. [Heat and safety](#10-heat-and-safety)
11. [Troubleshooting](#11-troubleshooting)
12. [Security notes](#12-security-notes)
13. [Roadmap](#13-roadmap)
14. [Changelog](#14-changelog)

---

## 1. Hardware

| Part | Used here | Notes |
|---|---|---|
| Board | Raspberry Pi 3 Model B+ (1 GB) | A Pi Zero 2 W would also work |
| Camera | Arducam 8MP IMX219, 175° ultra-wide, manual focus | Orange 22→15 pin ribbon: narrow end in the camera, wide end in the Pi |
| microSD | WD Purple 128 GB | Surveillance grade, rated to about 85 °C. Ordinary cards are rated to 70 °C |
| GPS | u-blox NEO-6M (GY-GPS6MV2) + ceramic patch antenna | Ceramic (tan) side **up**, toward the sky |
| Accelerometer | MPU-6050 6-axis breakout (I2C 0x68) | Must be **stuck down rigidly**, or rattles cause false locks |
| Heatsinks | Pi 3 copper heatsink set | |
| Case | Pi 3 B+ case with camera slot | Used open-topped |
| Power (car) | 12 V socket → USB car charger with **5 V 3 A on one port** → short, thick micro-USB cable | A weak charger causes under-voltage |
| Wires | 20 cm female–female Dupont jumpers | |

Never leave a power bank in a parked car (heat and fire risk).

## 2. Wiring

**Finding pin 1:** hold the Pi with the USB ports on the **left** and the 40 pins along the bottom edge.
Pin 1 is at the **right end of the inner row** and has a square solder pad. The inner row has the odd
pins (1, 3, 5 … 39, counting right to left); the edge row has the even pins (2, 4 … 40).
**Never use pins 2 and 4 (5 V).** The sensors need 3.3 V.

| Sensor pin | Pi pin | Signal |
|---|---|---|
| MPU-6050 VIN | 17 | 3.3 V |
| MPU-6050 GND | 9 | Ground |
| MPU-6050 SDA | 3 | I2C data |
| MPU-6050 SCL | 5 | I2C clock |
| MPU-6050 3Vo, INT | — | Leave empty |
| GPS VCC | 1 | 3.3 V |
| GPS GND | 6 | Ground |
| GPS TX | 10 (Pi RXD) | Crossed over: TX → RX |
| GPS RX | 8 (Pi TXD) | Crossed over: RX → TX |
| Camera | CSI slot | Ribbon contacts facing the right way |

## 3. Install

### 3.1 Flash the card
Raspberry Pi Imager → **Raspberry Pi OS Lite (64-bit)**, then in the settings:
- hostname `dashcam`
- your username
- your **home Wi-Fi**
- keyboard layout `us`
- SSH with password

### 3.2 Create your private `wifi.conf` (hotspot name and password)
```bash
git clone https://github.com/ankithvicky/diy-dashcam.git
cd diy-dashcam
cp wifi.conf.example wifi.conf
nano wifi.conf        # set HOTSPOT_SSID and HOTSPOT_PASS (keep the single quotes)
```
`wifi.conf` is git-ignored. Keep it on your own machine only.

### 3.3 Copy and run (from your laptop)
```bash
ssh-keygen -R dashcam.local                       # only needed after a re-flash
scp setup-dashcam.sh wifi.conf <user>@dashcam.local:~
ssh <user>@dashcam.local "sudo bash setup-dashcam.sh"
```
The Pi reboots by itself if interface settings changed. After about a minute:
```bash
ssh <user>@dashcam.local dashcam status
```

### 3.4 Updating
Copy the new `setup-dashcam.sh` (and `wifi.conf` if you changed it) and run the same command again.
Settings, clips and logs are kept. The script is safe to re-run any time.

## 4. Getting clips on your phone

The car has no internet and no router, so the **Pi makes its own Wi-Fi** and the phone joins it.
Wireless CarPlay also uses the phone's Wi-Fi, so CarPlay pauses while you're on the dashcam
network. That's fine: you fetch clips when parked.

1. Turn the ignition to **ACC/ON**. The Pi is powered by the car socket, so it's off when the car is off. Wait about 1 minute.
2. Phone → Wi-Fi → join **your hotspot name** → enter the password.
3. iPhone **Files** app → `…` → **Connect to Server** → `smb://10.42.0.1` → **Guest**.
4. Open **locked** (crash clips) or **clips** → tap a clip → Share → Save Video or send it.
5. Rejoin the car's Wi-Fi. CarPlay reconnects by itself.

At home (same Wi-Fi as the Pi) use `smb://dashcam.local`. On a Mac: Finder → Go → Connect to Server.
Android: any file manager with SMB support, or VLC.

The shares are **read-only**: the phone can view and copy, but it can't delete evidence.

| Port | Service | Used for |
|---|---|---|
| 22 | SSH | Terminal and SFTP (laptop) |
| 445 | SMB | Clips in the Files app / Finder |
| 67, 53 (hotspot only) | DHCP, DNS | Gives the phone an address on the hotspot |

## 5. Wi-Fi modes: home vs hotspot

The Pi 3 B+ has **one Wi-Fi radio**. It can either *join* a network or *be* a network, not both at once.
The `dashcam-wifi` service decides which:

```
power on
  └─ home Wi-Fi connects within 25 s? ── yes → HOME WI-FI ──(signal lost)──► HOTSPOT
                                     └── no  → HOTSPOT
                                                  │
                                                  └─ stays on until power-off
                                                     (a broadcasting radio can't scan)
```

| Trigger | What happens |
|---|---|
| Power on near home | Joins home Wi-Fi (SSH and updates as usual) |
| Power on anywhere else | Hotspot about 25–30 s after boot |
| Drive away from home | Home Wi-Fi drops → hotspot within about a minute |
| Back home with the Pi still on | Stays a hotspot until the next power-on |

**Recording never waits for Wi-Fi and is never affected by a switch.** Only an open SSH session drops.

Manual control. A forced mode lasts until the next reboot:
```bash
dashcam wifi            # mode, network name, IP, phones connected
dashcam wifi hotspot    # start the hotspot now (e.g. testing at home)
dashcam wifi home       # back to home Wi-Fi
dashcam wifi auto       # normal behaviour
```
If 5 GHz fails to start, the hotspot falls back to 2.4 GHz automatically and logs `WIFI_HOTSPOT_FALLBACK`.
To make 2.4 GHz permanent: `dashcam config set HOTSPOT_BAND bg`.

## 6. Daily commands

```
dashcam status | watch                 health now / live view
dashcam report [N]                     per-drive summary: start-up time, km, speed, GPS %, heat,
                                       under-voltage, locks, gaps, how it ended
dashcam restarts                       every power-on: off-time before, time to recording, cause
dashcam events [N]                     health events with Google Maps links
dashcam wifi [auto|home|hotspot]       Wi-Fi mode (see above)
dashcam start | stop | restart         recording services
dashcam logs [sensors|record|housekeeper|wifi]
dashcam config | config get KEY | config set KEY VALUE | config edit
dashcam clear clips|locked|logs|all [-y]
dashcam disk
```

## 7. How it works

| Service | Program | Job |
|---|---|---|
| `dashcam-record` | `/opt/dashcam/record.sh` | `rpicam-vid` 1640×1232 @ 30 fps, 6 Mbps H.264, 60 s segments named `S<drive>_<n>.h264` |
| `dashcam-sensors` | `/opt/dashcam/sensors.py` | GPS (NMEA, checksum-checked) + MPU-6050 at about 100 Hz; sets the clock from GPS; jolt ≥ 2.5 g → lock request; 1-row-per-second log; health events |
| `dashcam-housekeeper` | `/opt/dashcam/housekeeper.py` | Wraps .h264 → .mp4 (no re-encode), real-time names, per-clip .csv, crash locking, rotation, caps |
| `dashcam-wifi` | `/opt/dashcam/wifi.sh` | Keeps the Wi-Fi radio in the wanted mode (compares wanted vs actual every 3 s) |
| `smbd` | Samba | Read-only guest shares `clips` and `locked` |

```
~/dashcam/clips/    normal clips (.mp4 + .csv)          rotated
~/dashcam/locked/   crash clips (.mp4 + .csv)           never rotated (capped at 20 % of the card)
~/dashcam/logs/     boot_<time>_<boot>.csv, events.csv
~/dashcam/.state/   drive counter, heartbeat
/run/dashcam/       live state.json, clock.json, wifi.json, locks (cleared every boot)
```

**Clip names:** `20261026_183012.mp4` once the time is trusted (GPS or internet). Before that,
`S00042_0003.mp4` (drive 42, clip 3). These are renamed automatically, in the same power-on, once
GPS fixes the clock.

## 8. Storage and rotation

| Item | Rule | Size on a 128 GB card |
|---|---|---|
| Normal clips (~45 MB/min) | Oldest deleted when free space < 10 % | ~28–37 h of driving |
| Locked clips | Never rotated; capped at 20 % of the card (oldest locked go first) | ~8 h ≈ 500 clips |
| Sensor logs | 30 days, 200 MB cap | ≤ 200 MB |
| events.csv | Rotates at 5 MB, 1 old copy | ≤ 10 MB |
| System journal | 1 month, 50 MB cap | ≤ 50 MB |

## 9. Settings (`/etc/dashcam.conf`)

Change a setting with `dashcam config set KEY VALUE`. Re-running the installer keeps your values and only adds new keys.

| Key | Default | Meaning |
|---|---|---|
| `SENSOR_MODE`, `WIDTH`, `HEIGHT`, `FPS` | 1640:1232, 1640, 1232, 30 | Full sensor keeps the whole 175° view (1080p is a centre crop) |
| `BITRATE` | 6000000 | About 2.7 GB per hour |
| `SEGMENT_SEC` | 60 | Clip length |
| `MIN_FREE_PCT` | 10 | Rotation trigger |
| `LOCK_G` | 2.5 | Jolt that locks clips (potholes reach about 2 g) |
| `LOCK_BEFORE_SEC` / `LOCK_AFTER_SEC` | 60 / 30 | Window locked around a jolt |
| `LOCKED_MAX_PCT` | 20 | Cap for crash clips |
| `TEMP_HIGH_C` / `TEMP_CRIT_C` | 70 / 80 | Heat events |
| `TIMEZONE` | Asia/Kolkata | Clip names use local time |
| `HOTSPOT_BAND` | a | `a` = 5 GHz (faster), `bg` = 2.4 GHz |
| `HOTSPOT_CHANNEL` | 36 | 5 GHz channel (2.4 GHz always uses 6) |
| `WIFI_COUNTRY` | IN | Wi-Fi regulatory country |
| `WIFI_HOME_WAIT_SEC` | 25 | How long to look for home Wi-Fi before starting the hotspot |

The hotspot **name and password** are not here. They're in `/etc/dashcam-wifi.conf` (root only), which comes from your `wifi.conf`.

## 10. Heat and safety

| Spot (parked in strong sun) | Typical peak |
|---|---|
| Cabin air | 50–60 °C |
| Dashboard top, direct sun | 65–80 °C |
| Same, with a windshield sunshade | 45–55 °C |

- Use a sunshade when parked. Behind the rear-view mirror gets less sun than the dash top.
- Use **3M VHB / Dual Lock** adhesive. Ordinary foam tape and Velcro soften at 60–70 °C.
- Use the car charger only. It switches off with the ignition.
- Keep sensor boards insulated (Kapton or electrical tape) and away from the Pi's chips.
- Once a month: take it down, copy `locked/`, and check the card.

## 11. Troubleshooting

| Symptom | Fix |
|---|---|
| `throttled=0x50005`, red LED blinking | Charger too weak → 5 V 3 A charger, short thick cable |
| `no cameras available` | Re-seat the ribbon (orange 22→15, contacts the right way) |
| GPS: talking but no fix | Needs sky view. Antenna ceramic side up; metallic windshield film blocks GPS |
| `GPS_NO_DATA` | Wiring: TX→10, RX→8, VCC→1, GND→6 |
| Hotspot not visible | `dashcam wifi` and `dashcam logs wifi`. Check that `wifi.conf` was next to the script. Try `dashcam config set HOTSPOT_BAND bg` |
| Phone can't open `smb://10.42.0.1` | Make sure the phone is on the dashcam hotspot. Choose **Guest**. `sudo systemctl status smbd` |
| SSH dropped after `dashcam wifi hotspot` | Expected. Join the hotspot and run `ssh <user>@10.42.0.1` |
| "REMOTE HOST IDENTIFICATION HAS CHANGED" | `ssh-keygen -R dashcam.local` |
| `double free or corruption` when rpicam stops | Harmless; the clips are fine |
| Installer stops | Look for `!! setup FAILED at line N: <command>` and fix that line |

## 12. Security notes

- **Secrets never go in git.** `wifi.conf` is git-ignored. On the Pi the password lives only in `/etc/dashcam-wifi.conf` and NetworkManager's connection file, both readable by root only.
- The hotspot is **WPA2** (AES/CCMP). Use a password of at least 8 characters that isn't used anywhere else.
- SMB is **guest, read-only**. It's reachable only on your home Wi-Fi or the dashcam hotspot. Nothing is exposed to the internet, and there's no port forwarding.
- SSH still uses your user password. Consider switching to SSH keys.

## 13. Roadmap

- [ ] First car trial (car charger + short cable): drive 15–20 min, then `dashcam report`, `dashcam events`
- [ ] Desk tests: tap → `JOLT_LOCK`; 60-min soak (< 70 °C, about 60 clips, no power dips)
- [ ] Power-cut safety: read-only root + separate data partition; 50 sudden power pulls
- [ ] Boot time to 10–15 s (trim services, recorder first)
- [ ] Phone app: small web page or Node/Express API + React Native app (browse by time, lock, share)
- [ ] Speed/location overlay, case lid, tidy wiring (perma-proto board), better GPS antenna
- [ ] Phase 2: rear camera, supercapacitor UPS, better night camera (STARVIS / Camera Module 3 Wide)

## 14. Changelog

- **v8**:
  - Phone access: the Pi's own Wi-Fi hotspot (5 GHz, automatic 2.4 GHz fallback), with automatic home/hotspot switching through the `dashcam-wifi` service and `dashcam wifi auto|home|hotspot`.
  - Read-only guest SMB shares `clips` and `locked`.
  - Wi-Fi section in `dashcam status`, Wi-Fi events in `dashcam report` and `dashcam events`.
  - Hotspot secrets kept in git-ignored `wifi.conf`.
  - Removed duplicate install/config lines.
- **v7**:
  - Single installer.
  - GPS clock and real-time clip names.
  - Crash locking, rotation and caps.
  - Health events, `dashcam report / restarts / events`.
  - Persistent capped journal.
