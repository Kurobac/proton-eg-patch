# proton-eg-patch

Patched GE-Proton build helpers and patch files for edgemap/dseuhid controller
compatibility fixes.

## Included patches

| Patch | File | Purpose |
|-------|------|---------|
| DualSense/Edge HD haptics ContainerId | `patches/proton-dualsense-containerid.patch` | Keeps the HID and USB audio endpoints associated so games can find HD haptics |
| DS4 UHID MI_03 identity | `patches/proton-ds4-uhid-mi03.patch` | Makes UHID DS4 hidraw devices appear as `VID_054C&PID_09CC&MI_03`, version `0100`, input interface `3` |

## What this fixes

Some games (e.g. Cyberpunk 2077) use Windows ContainerId to locate the USB audio endpoint
for DualSense HD haptics. When using [dseuhid](https://github.com/kurobac/edgemap), the UHID
virtual device lacks USB topology information, causing a ContainerId mismatch and loss of
HD haptics.

This patch special-cases DualSense (054C:0CE6) and DualSense Edge (054C:0DF2) in winebus.sys,
winepulse.drv, and winealsa.drv to always compute a consistent ContainerId.

Native DS4 games may also depend on the Windows HID interface identity for a
real USB DualShock 4. dseuhid's DS4 target is a UHID device, so unpatched Proton
can expose it without `MI_03`, with version `0000`, and with no input interface.
`proton-ds4-uhid-mi03.patch` special-cases UHID-backed DS4 hidraw nodes so games
that require the full Sony feature init path see the expected identity.

See [HD-HAPTICS-FIX.md](https://github.com/kurobac/edgemap/blob/main/docs/HD-HAPTICS-FIX.md) for details.

## Build approach

These patches are applied directly to ValveSoftware/wine. Wine-staging patches
and GE-Proton's own wine patches are **not** applied. The resulting binaries
may lack optional GE-Proton features (e.g. PulseAudio fast polling,
ALSA channel count override). If you need full GE-Proton equivalence,
apply these patches via GE-Proton's own build system instead.

## Install

### Option A: Patched files only (lightweight, ~300KB)

Download the `proton-patch-files-*` artifact from [Releases](../../releases), then run:

```bash
# Find your GE-Proton installation
GE_DIR=YOUR-PROTON-GE-DIR

# Replace files
cp winebus.sys "$GE_DIR/files/lib/wine/x86_64-windows/winebus.sys"
cp winebus.so  "$GE_DIR/files/lib/wine/x86_64-unix/winebus.so"
cp winepulse.so "$GE_DIR/files/lib/wine/x86_64-unix/winepulse.so"
cp winealsa.so "$GE_DIR/files/lib/wine/x86_64-unix/winealsa.so"

# Restart Steam and re-select the Proton version
```

### Option B: Full patched build (~500MB)

Download the `edgemap-GE-Proton*-*.tar.gz` artifact, extract into
`~/.local/share/Steam/compatibilitytools.d/` and restart Steam.

## Build from source

```bash
./build.sh GE-Proton10-34
```

Requires: curl, tar, patch, make, gcc, flex, bison, autoconf,
libasound2-dev, libpulse-dev, libudev-dev.
