# Build system notes (AGENTS.md §5)

## 5. Build system notes

- The ZWO SDK ships a **versioned** `libASICamera2.so.1.41` per CPU
  architecture and no unversioned symlink. `ASI_SDK/` vendors **all four
  Linux archs** (a git-committable copy of the full SDK tree's `lib/<arch>`
  libraries, `include/ASICamera2.h` and the ZWO `license.txt`):

  ```
  ASI_SDK/
    ASICamera2.h                 # identical on all archs
    license.txt
    x64/      libASICamera2.so.1.41   (+ libASICamera2.so symlink)
    armv6/    libASICamera2.so.1.41   (+ libASICamera2.so symlink)
    armv7/    libASICamera2.so.1.41   (+ libASICamera2.so symlink)
    armv8/    libASICamera2.so.1.41   (+ libASICamera2.so symlink)
  ```

- The Makefile picks `ASI_SDK/$(ARCH)` (ARCH auto-detected from `uname -m`,
  override with `make ARCH=armv8`, see "Building on ARM boards" below) and
  bakes an rpath (`-Wl,--disable-new-dtags -Wl,-rpath,'$ORIGIN/ASI_SDK/<arch>'`)
  so the binaries find the library at runtime without `ldconfig`.
- **Link by name, not by path.** The SDK `.so` has **no SONAME**, so what
  `ld` records in `DT_NEEDED` depends on how it is given: linking the file
  path directly (the old way, `g++ … ASI_SDK/libASICamera2.so.1.41`) baked the
  *relative path* into `DT_NEEDED`, and the loader only found it when the app
  was started **from the project root** (running `camera_app` from anywhere
  else failed with "cannot open shared object file"). The fix: each
  `ASI_SDK/<arch>/` carries an unversioned `libASICamera2.so` symlink and the
  Makefile links with `-L ASI_SDK/<arch> -lASICamera2`; `ld` then records
  `DT_NEEDED = libASICamera2.so` (the symlink's basename), which the
  `$ORIGIN` rpath resolves next to the binary from **any** working directory.
  `make package` ships the symlink with the package for the same reason.
- The app is split into modules: `include/` (headers; the `Q_OBJECT` classes
  are declared there), `src/` (one `.cpp` per module) and `tests/` (headless
  self-test suites, linked into the app and run via
  `--sertest`/`--frametest`/`--capstest`/`--colourtest`).
  The Makefile runs `moc` on each `Q_OBJECT` header (`camera_worker`,
  `main_window`, `mode_toggle`, `shutter_button`, `record_button`,
  `sequence_button`) into `build/moc_*.cpp`, compiled as their own
  translation units, and builds every source into `build/obj/*.o` with
  generated `.d` dependency files (a header edit recompiles only the objects
  that include it). All generated artifacts live in `build/`, so `make clean`
  removes them all — there is no stale-moc issue anymore.
- The GUI app is compiled with `-std=c++17 -fPIC`.

### Build requirements (system Qt)

The build uses the **system** Qt6 dev packages (the former rootless
`.vendor/` prefix folder was deleted after the machine gained root access;
the build now goes straight to `/usr`)

Full prerequisites (mirrors the README "Prerequisites" section):

```
sudo apt install g++ make pkg-config \
                 qt6-base-dev qt6-base-dev-tools \
                 libopencv-dev \
                 libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
```

That is exactly what the Makefile's `pkg-config` calls resolve
(`Qt6Widgets` → qt6-base-dev, `opencv4` → libopencv-dev,
`gstreamer-1.0` → libgstreamer1.0-dev, and `gstreamer-app-1.0` →
libgstreamer-plugins-base1.0-dev — the app-lib's `.pc` file ships in the
plugins-base dev package;
`moc` → qt6-base-dev-tools at /usr/lib/qt6/libexec/moc). Qt 6.8.3 on this
machine; the ZWO SDK needs no install — the per-arch libraries + header are
bundled in `ASI_SDK/` (the full ZWO vendor SDK v1.41 tree can be re-downloaded
from asi-cam.com if a not-vendored arch, e.g. macOS or 32-bit x86, is ever
needed). Runtime-only extra for H.264 recording:
`gstreamer1.0-plugins-ugly` (x264enc). Entry points:

```
make camera_app     # build
make smoke          # headless self-test (needs a live camera)
make package        # portable package/ folder
```

The Makefile still carries a *dormant* conditional block that would bake
`$ORIGIN` rpaths for a `.vendor/prefix` — a no-op now that the folder is
gone; it only reactivates if such a prefix appears again.

### Building on ARM boards (Orange Pi / Raspberry Pi)

All four Linux SDK libraries are vendored, so the same checkout builds on
ARM. `ARCH` defaults to the host (`uname -m`), so on a board you just run
`make` — the Makefile resolves:

| `uname -m` | ARCH  | Boards (typical) |
|------------|-------|------------------|
| `aarch64`  | `armv8` | Raspberry Pi 3/4/5 on a **64-bit** OS; Orange Pi 3B/5/5B/5 Plus/6 (Debian/Armbian bookworm aarch64) |
| `armv7l`   | `armv7` | Raspberry Pi 2/3/4/Zero 2 W on a **32-bit** OS; Orange Pi One/Lite/Rock/Plus (32-bit OS) |
| `armv6l`   | `armv6` | Raspberry Pi 1 / Zero (32-bit OS) |
| `x86_64`   | `x64`   | this development machine |

On-device build (the practical route — the app's dependencies are the
system's):

```
sudo apt update
sudo apt install g++ make pkg-config \
                 qt6-base-dev qt6-base-dev-tools \
                 libopencv-dev \
                 libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
                 gstreamer1.0-plugins-ugly
make          # ARCH auto-detected; use make ARCH=armv7 to force it
make smoke    # headless self-test (camera connected)
./camera_app  # GUI (X11 session; on Wayland: QT_QPA_PLATFORM=xcb)
```

Notes:

- The apt names above are Debian/Ubuntu/Raspberry Pi OS package names and
  work as-is on Orange Pi (Debian/Armbian) images. The same
  `gstreamer1.0-plugins-ugly` runtime extra for H.264 recording applies.
- If a build is *cross-compiled* from an x86_64 machine, the Qt6/OpenCV/
  GStreamer packages must exist for the target too — build them for the
  target and point the Makefile at them:
  `make ARCH=armv8 CXX=aarch64-linux-gnu-g++ PKG_CONFIG=aarch64-linux-gnu-pkg-config`
  (with the target `pkg-config` sysroot set). Building on the device avoids
  all of that.
- USB: the SBC's `usbfs` buffer and udev rules are the same story as on the
  x86_64 machine (docs/hardware.md §4) — including
  `cat /sys/module/usbcore/parameters/usbfs_memory_mb` (the vendor SDK asks
  for 200) and the udev rule for non-root camera access (the README's
  "First time on a new machine" section has the complete `99-asi.rules`
  content inline).
- `make package` on a board packages **that board's** architecture
  (GStreamer plugin defaults follow `ARCH`, `GST_PLUGIN_SRC=` overrides):
  deliver `package/` to another board of the same arch + same-or-newer
  glibc.

### Self-contained package (`make package`)

The app is **dynamically linked** (~150 shared libs), so the bare executable is
not portable. `make package` assembles a self-contained `package/` folder:

```
package/
  camera_app                     # the executable
  README.md                      # user-facing guide (how to run + use the app)
  run.sh                         # launcher (sets LD_LIBRARY_PATH + GStreamer env)
  ASI_SDK/<arch>/libASICamera2.so.1.41      # found via $ORIGIN rpath; <arch>
  ASI_SDK/<arch>/libASICamera2.so           # is the built ARCH (x64,
                                            # armv6/armv7/armv8); the symlink
                                            # is the DT_NEEDED name, see above
  license.txt                                  # the ZWO SDK license (ships with the .so)
  lib/                           # every runtime .so from `ldd camera_app`,
                                 #   plus the GStreamer plugins' own deps (libx264…)
  gstreamer-1.0/                 # the 5 encoder plugins + gst-plugin-scanner
```

Run it with `package/run.sh` (add `--smoke` for the headless self-test). On the
target machine it needs **no system libraries, no GStreamer plugins, and no
ldconfig** — `run.sh` sets `LD_LIBRARY_PATH`, `GST_PLUGIN_PATH`,
`GST_PLUGIN_SYSTEM_PATH`, `GST_PLUGIN_SCANNER`, and a package-local
`GST_REGISTRY`.

**Why the GStreamer plugins + scanner must ship:** the bundled GStreamer core
only loads plugins from a path it trusts and rebuilds its registry with the
`gst-plugin-scanner` helper. If you bundle the core `lib/` but not the plugins,
the elements (`appsrc`, `x264enc`, …) silently fail to register and the encoder
errors out. So `make package` copies the 5 plugins the pipeline uses
(`libgstapp`, `libgstvideoconvertscale`, `libgstx264`, `libgstisomp4`,
`libgstcoreelements`) **and** the `gst-plugin-scanner` binary, then bundles
their transitive deps. The plugin source paths are `GST_PLUGIN_SRC` /
`GST_SCANNER_SRC` (standard Ubuntu locations; override for other distros).

**Constraints:**
- **Architecture-specific.** The package only runs on machines of the
  **same architecture as the build host** (x86_64, or the ARM board you built
  on — `make package` on a Pi / Orange Pi yields an armv8/armv7/armv6
  package). See "Building on ARM boards" above.
- **glibc:** the target needs a same-or-newer glibc than the build host.
- `make clean` removes `package/` (it's a generated artifact).

