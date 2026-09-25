# AGENTS.md — ASI Camera App (mono and colour ASI bodies)

Hand-off document so an agent (or a human) can pick this project back up quickly.
Everything here reflects the state of the code as of the last change.

**This file is the HUB — kept deliberately small (~17 KB) so it is never
truncated by instruction budgets. The detail lives in `docs/`, one file per
topic; read only the file your task needs.** Old `§x.y` section numbers (also
used in code comments and cross-refs) resolve through the map below.

| File | Sections | What it covers | Read when… |
|------|----------|----------------|------------|
| `AGENTS.md` (this file) | §1–3, §11 | What the app is, quick-start commands, file map, next steps | always (auto-loaded) |
| `docs/hardware.md` | §4 | Cameras, USB permissions, device-node fixes, one-process rule | touching the camera, USB, or a "waits for camera" report |
| `docs/build.md` | §5 | Qt/OpenCV/GStreamer build, SDK rpath, `make package`, portability constraints | changing the build or packaging |
| `docs/architecture.md` | §6 intro, §6.1 | Module list, threading model, locks, signals | orienting before any code change |
| `docs/capture-loop.md` | §6.2, §6.8, §6.9 | `CameraWorker::run` per-iteration flow, camera-loss, preview builder thread, `applyRoi`, `probeRois`, gain control, white-balance controls | touching capture, preview pacing, ROI, gain, or white balance |
| `docs/preview-colour.md` | §6.3, §6.4 | Bit depth, histogram, clipping, red-marked preview, `FrameView`, preview byte order | touching preview/display, histogram, or colour thumbnails |
| `docs/recording.md` | §6.5 | H.264/MP4 pipeline, `.ser` format (header, alignment, endianness), fps pacing | touching video output or `SerWriter` |
| `docs/stills-sequences.md` | §6.6, §6.7 | `doPhoto`, `saveStill`, interval sequences | touching photo or interval output |
| `docs/gui.md` | §7 | Panel layout, combos, sliders, buttons, fps ceiling logic | touching `MainWindow` widgets |
| `docs/gotchas.md` | §9 | Known issues and traps (the "do not revert this" list) | before changing anything subtle |
| `docs/testing.md` | §8, §10 | `--smoke` structure, verification history (colour support, probes) | running/extending tests, or reading history |

---

## 1. What this is

A C++ / Qt6 desktop app for **ZWO ASI cameras** (USB3), mono **and colour**
bodies — developed against an ASI178MM and an ASI178MC (same 3096×2080 sensor,
2.40 µm pixels; the MC is the Bayer version). It has three modes:

**Everything that depends on the camera is probed, not assumed** — see
`camera_caps.h/.cpp`: `probeCameraCaps()` reads the SDK's `ASI_CAMERA_INFO` +
control caps once per open and derives the resolution candidates, the offered
bit depths, the gain/exposure limits and the frame-rate ceiling. `MainWindow`
rebuilds the selectors from that on **every** successful open (`cameraReady`),
so swapping bodies re-labels and re-ranges the panel. The one rule that follows
from the probe and matters most: **`IsColorCam` bodies save RGB, mono bodies
save single-channel** — in every output (PNG/TIFF/MP4/`.ser`), see §6.5, §6.6,
§6.7 and `colour.h/.cpp`.

- **Photo mode** — a logarithmic exposure slider with a **range switch**
  (`0-1 s` / `1-60 s`, shown in photo **and** interval; hidden in video) and a
  big "Take photo" button that snaps one frame and saves it. Slider mapping is
  logarithmic `t = tmin·(tmax/tmin)^(pos/1000)` with `(tmin, tmax)` per mode,
  see `MainWindow::exposureRange()` (its `linear` out-flag): photo/interval
  32 µs…1 s or 1…60 s (switch — the long range is the exception: **linear,
  quantized to whole-second steps** via `sliderToSecondsLinear`, and the slider
  handle snaps to the step position in `onSliderMoved`), video 32 µs…1/fps. The **live preview is the camera's
  continuous video stream**. The loop switches per iteration:
  `wantSlow = (mode==Photo) && (exposureS > 1/fps)`. Fast → a short
  frame-period-safe stream exposure (clamped to `1/fps`). Slow → the **same
  video stream with the FULL exposure** set on it (`slowPreview_`): a long
  exposure simply stretches the frame period, so the camera delivers preview
  frames at **1/exposure** (physics: a 60 s exposure takes 60 s) — the preview
  updates once per exposure at the real exposure. The preview does *not* use
  standalone exposures: the camera reports `ASI_EXP_SUCCESS` only at
  exposure+~250 ms there, so that path made the preview update at
  1/(exposure+250 ms) instead of 1/exposure (§6.2). `doPhoto()`/
  `doSequence()` still use standalone exposures for their saved shots;
  returning to the preview restarts the video stream if a photo left it stopped.
- **Video mode** — a frame-rate **slider** (1 → the mode-aware max fps for the
  current ROI + format, §7), the same exposure slider, and a record button (turns
  red while recording). **8-bit H.264** video writes an **MP4**; **8/14-bit `.ser`**
  video writes an uncompressed **.ser** (LUCAM-RECORDER v3) file — 1 byte/px at
  8-bit, 2 bytes/px at 14-bit, **MONO on a mono body and RGB on a colour one**
  (§6.5).
- **Interval mode** — a back-to-back **long-exposure sequence**. The sequence
  takes its exposure from the **main exposure slider** (there is *no* separate
  exposure control); in this mode the slider uses the **same range switch as
  photo mode** — 32 µs…1 s (log) or 1…60 s (linear, whole-second steps) —
  so the sequence exposure tops out at 60 s (the worker still clamps to the
  SDK max `kExpSdkMaxS` = 2000 s as a safety bound). The next shot starts
  `interval` (min **1 s**) after the previous one *finished* — the interval is
  the time **between** images and always elapses, independent of the exposure
  (a long exposure is followed by the full interval, not shortened by it).
  A count field (0 = continuous) bounds the run. Images save to
  `sequences/seq_<ts>/NNNN.<ext>`.

A **colour body is captured as its Bayer mosaic** (RAW8 on the fast readout,
RAW16 on the deep one — *never* the camera's RGB24: 3 B/px at the SLOW rate, so
strictly worse; §9) and demosaiced on the host, which is what makes its files
RGB without costing frame rate. A mono body's path is unchanged, byte for byte
(§9, and `--colourtest` guards it).

There is a live preview on the left and **all controls in a side panel on the
right** (large, touch-friendly, dark theme). A 128-bin histogram and a
**clipping warning** (red banner + red-marked pixels in the preview) are also in
the panel. On a colour body the preview is an RGB thumbnail (quad-demosaic,
clipped blocks red) instead of a grayscale box-average.
The preview builder claims one of three raw frame buffers while it builds, and
OpenCV runs with one internal worker to keep full-resolution capture steady
(59.90 fps over 30.5 s on the ASI178MC after a 2026-09-24 stutter repair; §6.2).

Two bit depths are offered: **8-bit** and **14-bit** (a "Bit depth" combo
box). The combo is **mode-aware** *and* **camera-aware** (its items are built
from `CameraCaps::depths()`, so a body with no 2-byte readout has no deep entry;
a colour body's labels say RGB: "8-bit RGB (PNG)", "14-bit RGB (16-bit TIFF)",
"8-bit RGB (H.264)", "14-bit RGB (.ser)", §7): Photo/Interval offer 8/14-bit;
Video offers **8-bit H.264, 8-bit `.ser`, 14-bit `.ser`** (the 8-bit `.ser`
entry stores 1 byte/px/plane). A `.ser` is **MONO (ColorID=0, 1 plane) for a
mono body and RGB (ColorID=100, 3 channels per-pixel interleaved R,G,B —
*not* full planes) for a colour body** (§6.5). 14-bit `.ser` is captured as
16-bit RAW16 (the RAW16 path always reads out 14-bit — see §6.3); **8-bit
output (H.264 *and* `.ser`) captures RAW8 with `ASI_HIGH_SPEED_MODE=1`** —
the 10-bit "high speed" readout, delivered 1 byte/px (§6.3, §9). 14-bit
`.ser` stores the value **left-justified** in the 16-bit container and declares
`PixelDepthPerPlane = 16` in the header (the container width, not 14) — §6.5.
Stills save **8-bit→PNG, 14-bit→16-bit TIFF**; video saves **8-bit H.264→MP4,
8/14-bit `.ser`→`.ser`** (§6.5). (A 10-bit `.ser` entry existed until 2026-09-15:
it shared the 14-bit RAW16 readout, FPS, and 2 B/px file size with
14-bit `.ser` while silently truncating 4 bits, so it was dropped — the
worker/`SerWriter` still accept depth 10, reachable via `--vtest
--vtestbits 10`.)

A **gain slider** in 0.1 dB steps adjusts the sensor gain via the SDK `ASI_GAIN`
soft control; it applies in all modes, and its range is the **camera's** (probed:
ASI178MM 0–400 = 0.0–40.0 dB, ASI178MC 0–510 = 0.0–51.0 dB — §6.8).

**White balance (colour bodies only — §6.9, §7):** the SDK offers exactly two WB
registers (`ASI_WB_R`/`ASI_WB_B`) plus the `isAuto` flag of `ASISetControlValue` —
there is no WB-mode control, no colour-temperature control and no "what K did
AWB estimate" call, so every Kelvin number in the app is a model on top of two
gains. A panel row appears only when a **colour** camera with both WB controls is
connected: an **AWB** checkbox (**on by default** — the user asked for the
camera's automatic white balance as the colour default), and **Temperature**
(2500–10000 K) / **Tint** sliders that are inactive while AWB is checked and
retain the latest manual setting. AWB never moves either manual slider.
Switching AWB off applies the retained setting immediately. A drag updates the
image while it moves: the first change is sent immediately, subsequent camera
writes are paced at 80 ms, and release sends the final value. Neither slider
has a tooltip. The Kelvin/Tint pair maps onto the body's caps
through a Planckian locus (`white_balance.h/.cpp`, `--wbtest`) normalized at the
body's **measured neutral pair** (`wbMeasuredNeutral`, produced by
`./wb_probe --neutral` against a white target) — NOT at the factory default gains,
which are not neutral and made an earlier build read 8300 K under 6500 K light
while its 10000 K end sat exactly on neutral (§9, §10.4). Colour temperature
and Tint are **independent in the sliders AND in the values they show**: the
labels show EXACTLY the set balance (no read-back, no asterisk), the Tint
keeps its full −100..+100 range at every temperature, and the Temperature
never clamps, moves, or disables it (a per-temperature tint window used to
drag the user's tint, and the read-back labels used to show a `*`-flagged
delivered tint — both user-reported couplings, fixed the same day). The GAINS
pushed to the camera are still the model's: `wbToGains` clamps **per
channel** where the body is out of headroom (MC: the full balance only across
~4500..7300 K at tint 0) — the overflowing channel sits at its cap and the
free one keeps its temperature-correct value, so the temperature axis stays
on blue↔yellow-orange in the image and the body delivers the most of the
balance it can (the earlier pair-scale kept the R/B ratio exact but dragged
the free channel below neutral and read back as a **GREEN** image under a
3000 K light — user-reported the same day). The deliverable window
(`wbTintRangeForK`: MC −100..+15 at 6500 K, −100..−32 at 10000 K,
nothing below ~3500 K) limits the delivered image, never the manual slider
positions or displayed numbers. Mono bodies never see the row and their data is never
touched.


## 2. Quick start

```bash
cd /home/sh/development/asi_camera

make camera_app          # build the GUI app (same as make all)
make ARCH=armv8          # override the target SDK arch (x64|armv6|armv7|armv8);
                         #   auto-detected from uname -m, so on a Raspberry Pi /
                         #   Orange Pi plain `make` already picks the matching
                         #   ASI_SDK/<arch>/ library (docs/build.md §5)
./camera_app             # run the GUI
./camera_app --smoke     # headless self-test; prints SMOKE ... and exits 0 on success
make smoke               # same as above
./camera_app --uishot shot [--mode 0|1|2]
                         # offscreen UI self-check: saves a PNG screenshot of the
                         #   window to shot (+ the shutter button idle/busy to
                         #   shot.busy.png); --mode switches the mode first
                         #   (0 photo, 1 interval, 2 video)
./camera_app --sertest   # headless SerWriter self-test: writes + validates the
                         #   .ser ramp samples in samples/ (no camera): sample08/14.ser (RAW16 readout
                          #   path) and sample08hsm.ser (RAW8 10-bit HSM path, push8)
./camera_app --frametest # headless FrameView regression test (no camera): feeds the
                         #   exact stale-latestCh_ photo scenario that used to SIGSEGV
                         #   in QImage::copy and checks it now degrades to grayscale
./camera_app --seqtest --seqexp 0.5 --seqinterval 5 --seqcount 3
                         # hidden diagnostic: run a timed interval sequence
                         #   offscreen and print per-shot completion times
./camera_app --vtest --vtestroi 480x320 --vtestbits 8 --vtestfps 404 --vtestdur 4
                         # hidden diagnostic: record a .ser clip at the given
                         #   ROI / bit depth / fps and print the achieved rate
                         #   (frames written, measured + EMA fps, camera-side
                         #   and app-side dropped counts). With CAMDBG=1 the
                         #   worker's [perf] lines add the grab/push/period
                         #   breakdown and the builder's [perf-prev] lines the
                         #   downscale/hist cost — separate
                         #   USB/camera limits from app-side (display/disk)
                         #   limits.
./camera_app --prevtest --prevroi 3096x2080 --prevbits 14 --prevexp 0.1 --prevdur 6
./camera_app --prevtest --prevbits 14 --prevexp 0.5 --prevexp2 0.02 --prevdur 6
                     # hidden diagnostic: drive the REAL photo-mode GUI (mode /
                     # ROI / depth / exposure slider) into the SLOW preview and
                     # report the measured preview update rate over a window
                     # (expected = 1/exposure). --prevexp2 switches the exposure
                     # at the window midpoint to test the live slow<->fast
                     # transition (one line per phase).
./camera_app --fpstest
                      # hidden regression test: the video-mode fps slider keeps
                      # its value across a video->photo->video round trip (no
                      # format change), and a real format change (14-bit picked
                      # in photo mode) still re-snaps to the spec max.
                      # Prints FPSTEST PASS/FAIL, exit 0/1.
./camera_app --capstest    # headless capability-model self-test (no camera): the
                         #   resolution candidates / offered depths / fps ceilings
                         #   derived from what a camera reports, checked for an
                         #   ASI178MC, an ASI178MM and bodies that differ from both
./camera_app --colourtest # headless colour-pipeline self-test (no camera): the
                         #   Bayer->RGB mapping for all FOUR patterns at 8 and 16
                         #   bits, the RGB .ser frame order (PER-PIXEL INTERLEAVED
                         #   R,G,B / ColorID 100, pinned byte-for-byte + end to
                         #   end for all four patterns),
                         #   the mono output regression (ColorID 0, verbatim bytes),
                         #   the colour thumbnail + clip mask alignment, and the
                         #   thumbnail's RGB BYTE ORDER (both paths, all four
                         #   patterns — a BGR-ordered preview buffer shows swapped
                         #   red/blue live while every saved file stays correct)
./camera_app --wbtest    # headless white-balance model self-test (no camera): the
                         #   Planckian-locus p(T) monotonicity, the exact neutral-pair
                         #   <-> (6500 K, tint 0) anchor, slider round-trips across the
                         #   full range, clamping on tiny cap windows, and the MEASURED
                         #   ASI178MC case (caps 1..99, neutral 93/65): the anchor and the
                         #   camera's own AWB gains both display as ~6500 K, 10000 K
                         #   delivers a genuinely RED pair, the tint-0 authority range (4500..7300 K)
                         #   is reported, and the per-temperature Tint WINDOW is pinned (live inside
                         #   it, capped channel pinned and free channel tracking the tint outside,
                         #   whole slider on a body with headroom). Prints WBTEST PASS/FAIL, exit 0/1.
./camera_app --bayer rggb # diagnostic override of a colour camera's reported
                         #   BayerPattern (rggb|bggr|grbg|gbrg); mono ignores it
./camera_app --vtest --vtestser 0  # with --vtest: record 8-bit H.264 (MP4) instead
                         #   of the default .ser (frames counted from telemetry)
make probes             # build the standalone raw-SDK probes (camera_probe, usb_bench, wb_probe)
./wb_probe --neutral    # MEASURE a colour body's white balance: WB caps, is WB_R/WB_B
                        #   a linear multiplier, the gain pair that renders a white/grey
                        #   target FILLING THE FRAME neutral (hold one in the light you
                        #   want to call neutral!), where AWB converges, and how each
                        #   slider temperature's delivered colour compares to neutral
                        #   (u/v > 1 red) and how much WB headroom is left (auth < 1).
                        #   This is what produces/validates the anchor stored in
                        #   wbMeasuredNeutral() — see §6.9 for the measured numbers
./wb_probe --law        # only the caps + gain-law sweeps (no target needed): interval
                        #   slopes d ln(R/G)/d ln(WB_R), 1.000 = exact linear multiplier
./wb_probe --tint       # only the tint-liveness measurement: channel means at the ends and
                        #   middle of the deliverable Tint window and just past it, at a
                        #   saturated and a mid temperature — proof the slider moves the IMAGE
                        #   inside the window and the sensor stands still outside it
make package             # assemble a self-contained, portable package/ folder
make clean               # remove binaries, build/ (objects + moc), and the photos/ videos/ sequences/ samples/ + package/ dirs
```

**GUI launch on this machine** (Wayland session; the app needs XCB):

```bash
DISPLAY=:0 QT_QPA_PLATFORM=xcb nohup ./camera_app > /tmp/camera_gui.log 2>&1 &
```

Verify the window mapped: `DISPLAY=:0 xprop -root _NET_CLIENT_LIST`.

**Stop the GUI** (do NOT use `pkill -f camera_app` — it also matches the `make`
command line and kills the build):

```bash
pkill -x camera_app
```

## 3. Files

| File | Purpose |
|------|---------|
| `include/` | All headers, one per module (`camera_worker.h`, `main_window.h`, `camera_caps.h`, `white_balance.h`, `colour.h`, `ser_writer.h`, `gst_video_encoder.h`, `display_frame.h`, `exposure.h`, `fps_spec.h`, `depth_code.h`, `constants.h`, `util.h`, `crash_handler.h`, `style.h`, and the GUI widgets `frame_view.h`, `histogram_widget.h`, `mode_toggle.h`, `shutter_button.h`, `record_button.h`, `sequence_button.h`). The six `Q_OBJECT` classes are declared here; the Makefile runs `moc` on their headers into `build/moc_*.cpp`. |
| `src/` | Application sources, one `.cpp` per module: `main.cpp` (entry point + flag dispatch), `main_window.cpp` (GUI wiring; the constructor is split into `setupUi`/`setupConnections`/`setupInitialState`), `camera_worker.cpp` (all capture logic), `white_balance.cpp` (the Kelvin/Tint <-> gains model, §6.9), `ser_writer.cpp`, `gst_video_encoder.cpp`, `display_frame.cpp` (thumbnail downscale), `exposure.cpp` (slider mapping + formatting), `fps_spec.cpp` (ZWO fps table), `crash_handler.cpp`, `style.cpp` (stylesheet), `util.cpp` (`timestamp()` + the CAMDBG debug flag), and one `.cpp` per GUI widget (`frame_view`, `histogram_widget`, `mode_toggle`, `shutter_button`, `record_button`, `sequence_button`). |
| `tests/` | Headless self-test suites linked into the app and driven from `main()`: `ser_writer_test.cpp` (`--sertest`), `frame_view_test.cpp` (`--frametest`), `camera_caps_test.cpp` (`--capstest`), `colour_test.cpp` (`--colourtest`), `wb_test.cpp` (`--wbtest`), declared in `test_suites.h`. `camera_probe.cpp` is a **standalone** raw-SDK dump of everything a camera reports (info, control caps + live value readback, ROI acceptance per format) — `make probes && ./camera_probe`. `usb_bench.cpp` is a **standalone** raw-SDK USB throughput probe (its own `main`, built separately — see its header comment); it drains the video stream in a tight loop with no GUI/encoding/disk, isolating the camera→USB→host path from the app. `wb_probe.cpp` is a **standalone** white-balance MEASUREMENT probe: it checks the body's WB caps, whether the WB controls really are linear multipliers, where its AWB converges and whether that neutralizes a white target, and prints the neutral (6500 K) gain pair that `wbMeasuredNeutral()` in `white_balance.cpp` stores — re-run it when a colour body is added or its anchor is doubted. All three are excluded from the `camera_app` link by the Makefile (`make probes`). |
| `build/` | Generated artifacts: `moc_*.cpp`, `obj/*.o`, `*.d` (all removed by `make clean`). |
| `Makefile` | Builds the GUI app (camera_app). Links the ZWO SDK `.so` **by name** for the selected `ARCH` (`-LASI_SDK/<arch> -lASICamera2`, `ARCH` auto-detected from `uname -m`, overridable) with an `$ORIGIN` rpath (see §5). |
| `README.md` | **User-facing** guide (run the app + use Photo/Video/Interval). Shipped in `package/`. |
| `ASI_SDK/` | The build's SDK: a vendored, git-committable copy of ZWO SDK v1.41 for **all four Linux archs** — `libASICamera2.so.1.41` under `x64/`, `armv6/`, `armv7/`, `armv8/`, each with an unversioned `libASICamera2.so` symlink the Makefile links through by name (the SDK `.so` has **no SONAME** — linking the file path directly used to bake a CWD-relative `DT_NEEDED`, so the app only loaded from the project root), plus the shared `ASICamera2.h` and the ZWO `license.txt`. The Makefile picks `ASI_SDK/$(ARCH)`, `ARCH` auto-detected from `uname -m` and overridable (`make ARCH=armv8`), so the same checkout builds on Raspberry Pi / Orange Pi; the rpath `$ORIGIN/ASI_SDK/<arch>` makes binaries location-independent (docs/build.md §5). |
| `photos/` | Photo output (`photo_<yyyyMMdd_HHmmss>.png` or `.tif`). |
| `videos/` | Video output: `video_<yyyyMMdd_HHmmss>.mp4` (8-bit H.264) or `video_<yyyyMMdd_HHmmss>.ser` (8/14-bit, MONO on a mono body / interleaved RGB on a colour body). |
| `sequences/` | Interval-sequence output (`seq_<yyyyMMdd_HHmmss>/NNNN.<png\|tif>`). |
| `samples/` | `.ser` regression samples (`sample08.ser`, `sample08hsm.ser`, `sample14.ser`: 512×512, 5 frames, per-row full-range ramp; `sample08hsm.ser` is the 8-bit sample written through `push8`, the RAW8 10-bit HSM readout copied straight through), regenerated by `./camera_app --sertest`. The 14-bit convention (left-justified, declared 16, endianness field 0 — §6.5) is verified by opening them in a stacking tool. |
| `docs/` | The split-out detail files (see the map at the top): sections of the hand-off doc, read per topic; this hub stays the index. |

## 11. Possible next steps

- ~~10-bit H.264 or lossless video to preserve the full bit depth~~ — now done via
  the uncompressed **`.ser`** path (14-bit video, §6.5). (If a *compressed*
  16-bit MP4 is ever wanted, FFV1/UTVideo in an MKV would be the route.)
- A clipping threshold option (currently warns on *any* pixel at max; could
  require >0.1% of the frame to ignore isolated hot pixels).
- ~~White balance ... not yet exposed~~ — **done 2026-09-23** on user request:
  AWB (default on, colour bodies) + manual Temperature/Tint sliders (§1, §6.9,
  §7); `white_balance.h/.cpp` + `--wbtest`. The worker samples WB gains at open;
  AWB does not set the manual slider values. Focus remains
  unexposed, and the sensor temperature stays on the status line.
  **Re-anchored the same day** after the user reported the AWB reading 8300 K
  under 6500 K light and the 10000 K end not being red: both came from anchoring
  the model on the factory default WB gains, which are not the daylight neutral.
  The anchor is now measured per body (`wbMeasuredNeutral` + `tests/wb_probe.cpp`)
  and the GUI displays the balance the camera actually applies (§9, §10.4).
  **Tint independence fixed the same day**: the user then reported a `*` on the
  tint value and a slider that stopped doing anything, which was not the hardware
  running out but the GUI offering travel past the deliverable window (tint and
  the out-of-cap pair-fit being one factor made ~130 units deliver one pair).
  **Temperature/Tint decoupled the same day** (two user reports): making the
  Tint range `wbTintRangeForK()` per temperature coupled the controls — moving
  the Temperature clamped and moved the user's Tint — and the read-back labels
  then showed the *delivered* tint (a `*`-flagged value that was a function of
  the temperature alone where a WB channel is capped), so the user reported
  that the calculated values were still coupled and demanded "Color Temperature
  and Tint are independent!" Final state: the two manual sliders are
  independent settings (fixed −100..+100 Tint range at every temperature; the
  Temperature never clamps, moves, or disables the Tint) AND the labels show
  EXACTLY the set balance (no read-back, no asterisk). **Third fix the same
  day** (user: "I've got a light source at 3000 K. Reducing the colour
  temperature should shift the image to blue but it is shifted to green"): the
  ratio-preserving pair-scale in `wbToGains` dragged the free channel below
  neutral where one channel was capped — under a 3000 K light the delivered
  (23, 99) rendered the light GREEN. `wbToGains` now clamps PER CHANNEL: the
  overflowing channel sits at its cap, the free one keeps its temperature-correct
  value (the temperature axis stays on blue↔yellow-orange in the image; under a
  3000 K light the best this body can render is a slightly warm white, because
  its B gain tops out at 1.52x its neutral). The deliverable window affects the
  image and never changes the displayed manual values. Guarded by
  `--smoke` (the temperature move must leave the tint slider alone and the labels
  must show the set values, no `*`) + `--wbtest` (per-channel clamp pinned at the
  slider ends, the free channel tracking the tint outside the window) +
  `./wb_probe --tint` (§9, §10.4).
- **White-balance calibration in the GUI.** `wbMeasuredNeutral()` is a measured
  table, so a new colour body (or a different "daylight") still falls back to its
  factory defaults until `wb_probe` is run from a shell. A "measure neutral here"
  button — hold a white/grey target, click, store the pair per body (QSettings) —
  would move that last measurement step to where the user actually is.
- **Re-run `./camera_app --smoke` on the ASI178MM** when it is back on the bench.
  Every colour-era change was verified on the ASI178MC; the mono branch is
  covered by `--colourtest`'s byte-for-byte regression and by the code paths
  being the pre-colour ones, but not by live mono hardware in this session.
- The RGB `.ser` output is correct but 3× the bytes (§9); a half-measure worth
  having is an optional **1-plane** export on a colour body (raw Bayer or a
  luma-like channel) for fast full-res recording, plus a per-plane (R/G/B)
  histogram option instead of the current single mosaic-sampled one.
- ~~`make package` was not re-run in the colour session — worth a sanity pass~~ —
  **done 2026-09-25** with the ARM SDK vendoring: `make package` now ships
  `ASI_SDK/<arch>/` (versioned `.so` + the `libASICamera2.so` symlink) and was
  verified running from a foreign CWD. That exposed a real bug: the SDK `.so`
  has **no SONAME** and linking the file path directly baked a CWD-relative
  `DT_NEEDED` into the binaries, so `camera_app` (and the package) only loaded
  from the project root. Fix: each `ASI_SDK/<arch>/` carries an unversioned
  `libASICamera2.so` symlink and the Makefile links **by name**
  (`-LASI_SDK/<arch> -lASICamera2`) → `DT_NEEDED = libASICamera2.so` resolved
  by the `$ORIGIN/ASI_SDK/<arch>` rpath from any CWD (docs/build.md §5).
