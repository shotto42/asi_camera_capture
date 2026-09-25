# Makefile for the ASI178MM camera app.
#
#   make            - build the GUI camera app (camera_app) for the host arch
#   make camera_app - build the GUI camera app (Qt6 + OpenCV)
#   make gui        - build and launch the GUI camera app
#   make smoke      - headless self-test of the GUI app pipeline
#   make package    - assemble a self-contained, portable folder in package/
#   make clean      - remove build artifacts (and the package/ folder)
#
# Target architecture (ARCH = x64 | armv6 | armv7 | armv8):
#   x64    64-bit x86 desktops / servers (this development machine)
#   armv8  aarch64 64-bit: Raspberry Pi 3/4/5 on a 64-bit OS, Orange Pi
#          5/5B/5 Plus/6 and other aarch64 boards
#   armv7  32-bit ARM hard-float: Raspberry Pi 2/3/Zero 2 W on a 32-bit OS,
#          Orange Pi One/Lite/Rock/Plus on a 32-bit OS
#   armv6  32-bit ARM: Raspberry Pi 1 / Zero on a 32-bit OS
# ARCH defaults to the host machine (uname -m), so on a Pi or Orange Pi
# `make` just picks the right SDK library. Cross-compiling from an x86_64
# machine: make ARCH=armv8 CXX=aarch64-linux-gnu-g++ PKG_CONFIG=<aarch64
# pkg-config> — Qt6/OpenCV/GStreamer must be built for the target (the
# practical route is building on the device itself; see docs/build.md).
#
# Source layout:
#   include/  headers; the Q_OBJECT classes' headers are run through moc
#   src/      application sources (one .cpp per module)
#   tests/    headless self-test suites, linked into the app and driven from
#             main() via --sertest / --frametest (no camera needed)
#   build/    generated moc .cpp files + object files + dependency files
#
# The ZWO SDK ships one versioned shared object per CPU architecture
# (libASICamera2.so.1.41) and no unversioned symlink, so ASI_SDK/ vendors
# all four Linux archs — one subdirectory per arch (a git-committable copy
# of the full SDK tree's lib/<arch> libraries plus include/ASICamera2.h):
#   ASI_SDK/<arch>/libASICamera2.so.1.41   the real library (linked by name)
#   ASI_SDK/<arch>/libASICamera2.so        unversioned symlink (link-time
#     only — the SDK .so has no SONAME, so ld records the symlink's basename
#     in DT_NEEDED and the $ORIGIN rpath below resolves it at runtime)
# The rpath bakes $ORIGIN/ASI_SDK/<arch> into the binaries so they find the
# library at runtime without needing ldconfig — from any working directory.

SDK         := ASI_SDK
SDK_INCLUDE := -I$(SDK)
# ---- target architecture ---------------------------------------------------
# ARCH = x64 | armv6 | armv7 | armv8, mapped to the matching vendored SDK
# library. Defaults to the host arch so `make` works unchanged on an x86_64
# desktop AND on a Raspberry Pi / Orange Pi (aarch64 or 32-bit ARM); override
# for cross-compiling (then set CXX to the cross compiler and PKG_CONFIG to
# the target's pkg-config).
# Map the machine name to a vendored SDK arch. Done with $(subst) rather than
# a $(shell case ... esac) — literal ')' in a $(shell) argument (the case
# patterns) would terminate the function call early.
UNAME_M   := $(shell uname -m)
HOST_ARCH := $(UNAME_M)
HOST_ARCH := $(subst x86_64,x64,$(HOST_ARCH))
HOST_ARCH := $(subst aarch64,armv8,$(HOST_ARCH))
HOST_ARCH := $(subst armv7l,armv7,$(HOST_ARCH))
HOST_ARCH := $(subst armv6l,armv6,$(HOST_ARCH))
ifeq ($(ARCH),)
  ARCH := $(HOST_ARCH)
endif
ifeq ($(filter x64 armv6 armv7 armv8,$(ARCH)),)
  $(error Unsupported ARCH "$(ARCH)" — set ARCH to one of: x64 armv6 armv7 armv8)
endif
ifeq ($(ARCH),$(HOST_ARCH))
  $(info build: host arch $(ARCH) — linking $(SDK)/$(ARCH)/libASICamera2.so.1.41)
else ifeq ($(HOST_ARCH),unknown)
  $(info build: cross target $(ARCH) — linking $(SDK)/$(ARCH)/libASICamera2.so.1.41)
else ifeq ($(origin CXX),command line)
  $(info build: cross target $(ARCH) with $(CXX) (host is $(HOST_ARCH)) — linking $(SDK)/$(ARCH)/libASICamera2.so.1.41)
else
  $(warning ARCH=$(ARCH) but this host is $(HOST_ARCH); if this is a cross-build set CXX=<cross-compiler> (e.g. aarch64-linux-gnu-g++) and PKG_CONFIG=<target pkg-config>)
endif
ifeq ($(wildcard $(SDK)/$(ARCH)/libASICamera2.so.1.41),)
  $(error SDK library missing: $(SDK)/$(ARCH)/libASICamera2.so.1.41 — re-vendor it from a fresh ZWO ASI SDK download (asi-cam.com): copy lib/$(ARCH)/libASICamera2.so.1.41 in and re-create the libASICamera2.so symlink)
endif
LIBDIR    := $(SDK)/$(ARCH)
LIB       := $(LIBDIR)/libASICamera2.so.1.41
# The SDK .so has no SONAME, so link it BY NAME through the unversioned
# symlink (-lASICamera2): ld then records DT_NEEDED = "libASICamera2.so"
# (the symlink's basename, not a path) and the rpath below resolves it.
# Linking the file path directly (the old way) bakes a CWD-relative path
# into DT_NEEDED, which only loads when the app is started from the
# project root.
SDK_LIBS  := -L$(LIBDIR) -lASICamera2
# If this checkout has a rootless dependency prefix (.vendor/prefix/, see
# .vendor/build.sh), also bake $ORIGIN rpaths for its lib dirs so the
# binaries can be launched directly without LD_LIBRARY_PATH. Entries that
# point at directories that do not exist are silently ignored by the
# dynamic loader, so this is a no-op on machines without .vendor/.
# DT_RPATH (not DT_RUNPATH, which modern ld emits by default): RUNPATH only
# covers the executable's direct dependencies, so OpenCV's transitive NEEDED
# chain (libgdal/libgdcm/libtbb/libarmadillo) would not resolve at runtime.
# With RPATH the $ORIGIN entries apply transitively and bare ./camera_app
# works without LD_LIBRARY_PATH.
RPATH       := -Wl,--disable-new-dtags -Wl,-rpath,'$$ORIGIN/$(LIBDIR)'
ifneq ($(wildcard .vendor/prefix),)
RPATH      += -Wl,-rpath,'$$ORIGIN/.vendor/prefix/usr/lib/x86_64-linux-gnu' -Wl,-rpath,'$$ORIGIN/.vendor/prefix/usr/lib'
endif

CXX      := g++
CXXFLAGS := -O2 -Wall -Wextra
CPPFLAGS := -std=c++17 -fPIC -Iinclude -Itests $(SDK_INCLUDE)
LDLIBS   := -lpthread

# Qt6 + OpenCV + GStreamer (via pkg-config). PKG_CONFIG is overridable so a
# cross-build can point at the TARGET's pkg-config (with its sysroot):
#   make CXX=aarch64-linux-gnu-g++ PKG_CONFIG=aarch64-linux-gnu-pkg-config
PKG_CONFIG ?= pkg-config
QT_CFLAGS := $(shell $(PKG_CONFIG) --cflags Qt6Widgets)
QT_LIBS   := $(shell $(PKG_CONFIG) --libs Qt6Widgets)
CV_CFLAGS := $(shell $(PKG_CONFIG) --cflags opencv4)
CV_LIBS   := $(shell $(PKG_CONFIG) --libs opencv4)
GST_CFLAGS := $(shell $(PKG_CONFIG) --cflags gstreamer-1.0 gstreamer-app-1.0)
GST_LIBS   := $(shell $(PKG_CONFIG) --libs gstreamer-1.0 gstreamer-app-1.0)
MOC       := $(shell command -v moc 2>/dev/null || echo /usr/lib/qt6/libexec/moc)

# GStreamer plugins needed by the encoder pipeline (appsrc/videoconvert/
# x264enc/mp4mux/filesink) plus the plugin-scanner helper. The bundled GStreamer
# core only loads plugins from a path it trusts and rebuilds its registry with
# the scanner, so both must ship in the package. Default paths follow the
# distro's multiarch lib dir for the selected ARCH (standard Debian/Ubuntu
# locations); override on other distros, e.g. make package GST_PLUGIN_SRC=...
ifeq ($(ARCH),x64)
  MULTIARCH ?= x86_64-linux-gnu
else ifeq ($(ARCH),armv8)
  MULTIARCH ?= aarch64-linux-gnu
else ifeq ($(ARCH),armv7)
  MULTIARCH ?= arm-linux-gnueabihf
else
  MULTIARCH ?= arm-linux-uclibcgnueabi
endif
GST_PLUGIN_SRC  ?= /usr/lib/$(MULTIARCH)/gstreamer-1.0
GST_SCANNER_SRC ?= /usr/lib/$(MULTIARCH)/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner
GST_PLUGINS     := libgstapp.so libgstvideoconvertscale.so libgstx264.so \
                    libgstisomp4.so libgstcoreelements.so

# ---- sources ---------------------------------------------------------------
SRC      := $(wildcard src/*.cpp)
# tests/usb_bench.cpp, tests/camera_probe.cpp and tests/wb_probe.cpp are
# STANDALONE probes with their own main() — USB throughput, a dump of what the
# CONNECTED camera can do (sensor/formats/controls, ROI acceptance, Bayer
# pattern), and a white-balance MEASUREMENT run (gain law, AWB convergence, the
# neutral gain pair). They are built by `make probes` and never linked into
# camera_app.
TEST_SRC := $(filter-out tests/usb_bench.cpp tests/camera_probe.cpp tests/wb_probe.cpp,$(wildcard tests/*.cpp))
BUILD    := build

# Q_OBJECT headers: moc emits a standalone .cpp per header (it #includes the
# header), compiled as its own translation unit.
MOC_HDRS := include/camera_worker.h include/main_window.h include/mode_toggle.h \
            include/record_button.h include/sequence_button.h include/shutter_button.h
MOC_OUT  := $(MOC_HDRS:include/%.h=$(BUILD)/moc_%.cpp)

OBJS := $(SRC:src/%.cpp=$(BUILD)/obj/%.o) \
        $(TEST_SRC:tests/%.cpp=$(BUILD)/obj/%.o) \
        $(MOC_OUT:$(BUILD)/moc_%.cpp=$(BUILD)/obj/moc_%.o)

TARGETS  := camera_app
PACKAGE  := package

.PHONY: all gui smoke probes package clean
all: $(TARGETS)

# ---- build rules -----------------------------------------------------------
$(BUILD)/obj:
	mkdir -p $(BUILD)/obj

$(BUILD)/moc_%.cpp: include/%.h
	$(MOC) $< -o $@

$(BUILD)/obj/%.o: src/%.cpp | $(BUILD)/obj
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(QT_CFLAGS) $(CV_CFLAGS) $(GST_CFLAGS) -MMD -MP -c $< -o $@

$(BUILD)/obj/%.o: tests/%.cpp | $(BUILD)/obj
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(QT_CFLAGS) $(CV_CFLAGS) $(GST_CFLAGS) -MMD -MP -c $< -o $@

$(BUILD)/obj/moc_%.o: $(BUILD)/moc_%.cpp | $(BUILD)/obj
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(QT_CFLAGS) $(CV_CFLAGS) $(GST_CFLAGS) -MMD -MP -c $< -o $@

# Auto-generated header dependencies (moc .cpp files track their headers too).
-include $(OBJS:.o=.d)

camera_app: $(OBJS) $(LIB)
	$(CXX) -o $@ $(OBJS) $(RPATH) $(SDK_LIBS) $(QT_LIBS) $(CV_LIBS) $(GST_LIBS) $(LDLIBS)

gui: camera_app
	./camera_app

smoke: camera_app
	./camera_app --smoke

# Standalone hardware probes (each opens the camera itself, so stop the GUI
# first). ./camera_probe dumps the connected camera's capabilities;
# ./usb_bench measures raw USB throughput for a given ROI/format; ./wb_probe
# MEASURES the white balance of a colour body — its WB caps, whether WB_R/WB_B
# really are linear multipliers, where its AWB converges and whether that
# neutralizes a white target, and the neutral (6500 K) gain pair that
# wbMeasuredNeutral() in white_balance.cpp stores. Re-run it against a white or
# grey target in daylight when a colour body is added or its anchor is doubted.
probes: camera_probe usb_bench wb_probe

camera_probe: tests/camera_probe.cpp $(LIB)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(RPATH) -o $@ $< $(SDK_LIBS) $(LDLIBS)

wb_probe: tests/wb_probe.cpp src/white_balance.cpp include/white_balance.h $(LIB)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -Iinclude $(RPATH) -o $@ tests/wb_probe.cpp src/white_balance.cpp $(SDK_LIBS) $(LDLIBS)

usb_bench: tests/usb_bench.cpp $(LIB)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(RPATH) -o $@ $< $(SDK_LIBS) $(LDLIBS)

# ---- self-contained package ------------------------------------------------
# Assembles a portable folder (package/) with:
#   * the executable
#   * a README.md (how to run + use the app)
#   * the ZWO SDK license.txt (the .so ships under its license)
#   * the ZWO SDK .so for $(ARCH) (in its $ORIGIN-relative rpath location,
#     plus the libASICamera2.so symlink the loader's DT_NEEDED name needs)
#   * every runtime shared library the binary needs (collected via ldd)
#   * the GStreamer encoder plugins + plugin-scanner helper (and their deps)
#   * a run.sh launcher that sets LD_LIBRARY_PATH + the GStreamer plugin env
# Deliver package/ to another machine of the SAME architecture as the build
# (x86_64 or the ARM board you built on — run `make package` on the Pi /
# Orange Pi for an ARM package) with a same-or-newer glibc, and run
# package/run.sh - no system libraries, GStreamer plugins, or ldconfig required.
package: camera_app
	rm -rf $(PACKAGE)
	@test -d $(GST_PLUGIN_SRC) || { echo "error: GStreamer plugin dir $(GST_PLUGIN_SRC) not found — set GST_PLUGIN_SRC=/usr/lib/<multiarch>/gstreamer-1.0" >&2; exit 1; }
	mkdir -p $(PACKAGE)/lib $(PACKAGE)/$(LIBDIR) $(PACKAGE)/gstreamer-1.0
	cp camera_app $(PACKAGE)/camera_app
	cp README.md $(PACKAGE)/README.md
	cp ASI_SDK/license.txt $(PACKAGE)/license.txt
	cp -L $(LIB) $(PACKAGE)/$(LIBDIR)/
	ln -s libASICamera2.so.1.41 $(PACKAGE)/$(LIBDIR)/libASICamera2.so
	# all runtime shared libraries of the executable
	ldd camera_app | awk '/=>/ {print $$3}' | sort -u | \
	while read -r so; do cp -L "$$so" $(PACKAGE)/lib/; done
	# GStreamer encoder plugins + the plugin-scanner helper
	for p in $(GST_PLUGINS); do cp -L $(GST_PLUGIN_SRC)/$$p $(PACKAGE)/gstreamer-1.0/; done
	cp -L $(GST_SCANNER_SRC) $(PACKAGE)/gstreamer-1.0/gst-plugin-scanner
	chmod +x $(PACKAGE)/gstreamer-1.0/gst-plugin-scanner
	# the plugins' own runtime deps (e.g. libx264 for x264enc) that the
	# executable's ldd did not already pull in
	for p in $(PACKAGE)/gstreamer-1.0/*; do ldd "$$p" 2>/dev/null | awk '/=>/ {print $$3}'; done | \
	sort -u | while read -r so; do cp -L "$$so" $(PACKAGE)/lib/ 2>/dev/null || echo "  warn: missing plugin dep $$so"; done
	printf '#!/bin/sh\nDIR="$$(cd "$$(dirname "$$0")" && pwd)"\nexport LD_LIBRARY_PATH="$$DIR/lib:$$LD_LIBRARY_PATH"\nexport GST_PLUGIN_PATH="$$DIR/gstreamer-1.0"\nexport GST_PLUGIN_SYSTEM_PATH="$$DIR/gstreamer-1.0"\nexport GST_PLUGIN_SCANNER="$$DIR/gstreamer-1.0/gst-plugin-scanner"\nexport GST_REGISTRY="$$DIR/.gst-registry.bin"\nexec "$$DIR/camera_app" "$$@"\n' > $(PACKAGE)/run.sh
	chmod +x $(PACKAGE)/run.sh
	@echo "Packaged into $(PACKAGE)/  ->  run with: $(PACKAGE)/run.sh"
	@echo "  size: $$(du -sh $(PACKAGE) | cut -f1)   files: $$(find $(PACKAGE) -type f | wc -l)"

clean:
	rm -f $(TARGETS) camera_probe usb_bench wb_probe
	rm -rf $(BUILD) photos videos sequences samples $(PACKAGE)
