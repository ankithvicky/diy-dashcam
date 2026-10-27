# CLAUDE.md — DIY Raspberry Pi Dashcam

**Read `docs/HANDOFF.md` first.** It holds the full history, every decision and why, the current
state, open problems and the roadmap. This file is the short list of rules.

## What this is
A front dashcam for incident capture on a Raspberry Pi 3 B+: an IMX219 175° camera, a NEO-6M GPS and
an MPU-6050. The whole system is built by **one idempotent installer**, `setup-dashcam.sh`
(currently **v8**). README.md is the user guide.

## Rules
1. **`setup-dashcam.sh` is the only source of truth.** Every program (`record.sh`, `sensors.py`,
   `housekeeper.py`, `wifi.sh`, `dashcam`, `dashcam-status`, `dashcam-report`) is embedded as a quoted
   heredoc (`<< '__DASHCAM_EOF_*__'`). Edit them there; never ship separate copies.
2. **Keep it idempotent and safe to re-run.**
   - `/etc/dashcam.conf` is never overwritten. New keys go in only through `add_conf`.
   - Reboot only when config.txt, interface or Wi-Fi-country changes need it.
   - The script runs under `set -euo pipefail`, so every lookup that may fail inside `$(…)` needs `|| true`.
3. **On every release:**
   - bump `VERSION` and the header comment
   - update the README changelog and any changed sections
   - update `docs/HANDOFF.md` §0 and §8
4. **Test before pushing.** Follow `docs/HANDOFF.md` §11: `bash -n`, extract the heredocs and syntax-check them, `shellcheck -S error`, `testparm` for Samba, and a simulation for `wifi.sh` logic changes.
5. **This repo is PUBLIC.**
   - Never commit `wifi.conf`, passwords, the home Wi-Fi name, IPs, addresses, PIN codes or GPS coordinates.
   - Hotspot secrets come only from the git-ignored `wifi.conf`, which is parsed, never sourced.
   - Grep the tree for secrets before every commit.
6. **Git:** commit and push straight to `main` (single contributor).
7. **No Pi access from here.** Claude can't SSH into the Pi (password). Give the owner one block of commands to run and ask for the pasted output. Long jobs use `sudo systemd-run --unit=…`.
8. **Never read `/dev/serial0` while `dashcam-sensors` runs**: two readers garble the NMEA stream.
9. **Working with the owner:**
   - simple numbered steps; explain jargon the first time
   - one script, not scattered commands
   - shopping: 3 options + ★, and never buy or edit his carts
   - heat, power and short-circuit safety first

## Current priorities (details in HANDOFF §8–9)
1. **GPS fix is marginal** (fixed 27 Oct; 4 used / 12 visible, flickers): check in the car; active antenna + u.FL→SMA-female adapter if it still drops.
2. Secure the loose jumpers (hot glue) and tape the antenna's u.FL joint.
3. A 22 s in-car power dropout → fresh-boot power check.
4. Confirm SMB clip playback on the phone over the hotspot.
5. Bug: `REC_GAP` false positives after `CLOCK_JUMP`, because `housekeeper.py` `wrap_finished()` compares uncorrected file times.
6. Then: power-cut safety (read-only root), boot time ≤15 s, phone app.
