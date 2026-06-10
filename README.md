# proton-eg-patch

Patched GE-Proton build with DualSense Edge HD haptics ContainerId fix.

## What this fixes

Some games (e.g. Cyberpunk 2077) use Windows ContainerId to locate the USB audio endpoint
for DualSense HD haptics. When using [dseuhid](https://github.com/kurobac/edgemap), the UHID
virtual device lacks USB topology information, causing a ContainerId mismatch and loss of
HD haptics.

This patch special-cases DualSense (054C:0CE6) and DualSense Edge (054C:0DF2) in winebus.sys,
winepulse.drv, and winealsa.drv to always compute a consistent ContainerId.

See [HD-HAPTICS-FIX.md](https://github.com/kurobac/edgemap/blob/main/docs/HD-HAPTICS-FIX.md) for details.

## Install

### Option A: Patched files only (lightweight, ~300KB)

Download the `proton-patch-files-*` artifact from [Releases](../../releases), then run:

```bash
# Find your GE-Proton installation
GE_DIR=$(find ~/.local/share/Steam/compatibilitytools.d -maxdepth 1 -name "GE-Proton*" | sort -V | tail -1)

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
