# Hardware / environment (AGENTS.md §4)

## 4. Hardware / environment

- **Cameras:** an ASI178MM (mono) and, attached to the development machine now,
  an **ASI178MC** (colour): `IsColorCam=1`, `BayerPattern=0` (RGGB),
  `BitDepth=14`, formats {RAW8, RGB24, Y8, RAW16}, bins 1–4, gain 0–510
  (default 210), exposure 32 µs…2000 s, BandWidth 40–100 (persists 60; the app
  raises it to 100 on open), HighSpeedMode present, and — measured 2026-09-23 with `camera_probe` —
  `WB_R` **1..99 (factory default 70)** and `WB_B` **1..99 (factory default 90)**,
  both writable and **both auto-capable** (the camera's own AWB): the app exposes
  them as the colour-only white-balance controls, **AWB on by default** (§1, §6.9,
  §7). Meaningless on a mono body (no Bayer colour to balance), and the app never
  touches them there.
  On the MC, `ASIGetControlCaps` **works** (it fails on the MM — §6.8), and ROI
  widths must be divisible by 8 (1548/774/618/516 are rejected; 1032×692,
  1920×1080, 1280×720, 2080×2080 are accepted) — which is why
  `CameraCaps::roiCandidates()` aligns widths to 8 and heights to 4 (§6.2).
  Bus/device numbers change on re-plug (seen on
  this machine: `002/003` then `002/005`), so never hardcode them — read the
  current ones from `lsusb` (vendor `03c3`) and `/sys/bus/usb/devices/`.
- **"App waits for camera" = the app user cannot open the device node.** The
  node `/dev/bus/usb/NNN/NNN` exists (udev/devtmpfs creates it) but is
  `0664` root-owned, so a non-root user gets `EACCES`. The SDK still
  *enumerates* the camera (that only needs `/sys`), so the failure looks
  like "no camera" even though one is plugged in. The telling pair: the node
  exists but opens with `Permission denied` (e.g. `ls -l /dev/bus/usb/NNN/NNN`
  shows `root:root 0664`), while the SDK enumerates the camera
  (`ASIGetNumOfConnectedCameras = 1` but `ASIGetCameraProperty` fails).
  - **Immediate fix:** `sudo chmod 0666 /dev/bus/usb/NNN/NNN` (the number
    from `lsusb` — it changes after every re-plug).
  - **Persistent fix:** `/etc/udev/rules.d/99-asi.rules`
    `SUBSYSTEM=="usb", ATTR{idVendor}=="03c3", MODE="0666"` then
    `sudo udevadm control --reload-rules && sudo udevadm trigger` (or just
    unplug/replug). Then `./camera_app` connects.
  - **If the node is missing entirely** (no udev/devtmpfs managing `/dev`),
    create it by hand: read `major minor` from
    `cat /sys/bus/usb/devices/<usbX>/<X-Y>/dev` (the camera's entry under
    `/sys/bus/usb/devices/`, e.g. `usb3/3-4`) and run
    `sudo mknod -m 0666 /dev/bus/usb/<bus>/<dev> c <major> <minor>`
    (needs mknod permission, i.e. run via sudo if the plain user is denied).
- **Only one process can hold the camera at a time.** Stop the GUI (`pkill -x
  camera_app`) before running any other binary that opens the camera.
- **Camera bad-state after a kill:** occasionally, right after killing the app,
  the camera enters a state where `ASIOpenCamera`/`ASIInitCamera` return error
  `2` (INVALID_ID) in a *fresh* process. Relaunching the app (or waiting a few
  seconds) recovers it. This is a USB/SDK quirk, not a code bug.
- **Dependencies**: Qt6 (Widgets), OpenCV 4.x, GStreamer 1.x, g++. Build flags
  come from `pkg-config` against the **system** packages (Qt6 dev packages
  installed via apt; see "Build system notes" below).

