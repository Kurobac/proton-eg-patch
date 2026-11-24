# proton-eg-patch

This project builds an x86-64 GE-Proton compatibility tool for controllers managed by
[edgemap and dseuhid](https://github.com/Kurobac/edgemap). It pairs a virtual DualSense
or DualSense Edge with its audio endpoint for HD haptics and gives a virtual DualShock 4
the USB interface identity that native DS4 games expect.

## Included patches

| Patch | Purpose |
|-------|---------|
| [DualSense/Edge ContainerId](patches/proton-dualsense-containerid.patch) | Pairs the virtual HID device with the physical controller's USB audio endpoint in `winepulse`, `winepipewire` and `winealsa`. |
| [edgemap Bluetooth audio](patches/proton-edgemap-audio-containerid.patch) | Assigns the matching ContainerId to the `edgemap.dualsense` playback endpoint in `winepulse` and `winepipewire`. |
| [DS4 UHID interface](patches/proton-ds4-uhid-mi03.patch) | Exposes USB interface 3 (`MI_03`) for UHID-backed DS4 devices and supplies version `0100` when the device reports zero. |

## What this fixes

Some games, including Cyberpunk 2077, use the Windows ContainerId to find the audio
endpoint that drives the controller's grips. The virtual USB HID device that dseuhid
creates has no physical USB parent from which Wine can derive that ID.

With a **wired** controller, the game sends haptics to the controller's physical USB audio
endpoint. With a **Bluetooth** controller, edgemap provides the four-channel PipeWire sink
`edgemap.dualsense`. Both the default `winepulse` driver and native `winepipewire` assign the matching
ID at startup and on reconnection. To select native PipeWire, use
`PROTON_USE_PIPEWIRE=1 %command%` in the game's Steam launch options. See the
[HD haptics notes](https://github.com/Kurobac/edgemap/blob/main/docs/HD-HAPTICS-FIX.md).

In the `-eg` build, both drivers create GE's physical Bluetooth audio endpoints only
when explicitly enabled. To use GE's native Bluetooth audio with Steam Input disabled,
set `PROTON_DUALSENSE_BT_HAPTICS=1 %command%` for DualSense/Edge or
`PROTON_DUALSHOCK4_BT_AUDIO=1 %command%` for DS4 in the game's Steam launch options.
The edgemap sink works with the default settings.

In **DS4 output mode**, games see dseuhid's virtual controller as
`VID_054C&PID_09CC&MI_03`, so they can identify the expected USB HID interface.

## Build approach

`build.sh` checks out the requested GE-Proton tag and runs its Wine preparation script,
including Wine Staging and GE's own patches. It then applies the three patches above,
rebuilds `winebus.sys`, `winepulse.drv`, `winepipewire.drv` and `winealsa.drv`, and installs the five driver
files into a copy of the matching GE-Proton release. Source and build directories are
separate for each GE tag, including tags that share a Wine commit.

The daily workflow checks the latest upstream release and publishes both archives after
a successful build if this repository has no release for that tag. GE-Proton11-13 and
GE-Proton11-14 have both been built locally from clean directories.

## Install

Choose the archive for your GE-Proton version from [Releases](../../releases).
The examples below use GE-Proton11-14 and run from the directory containing the
downloaded archive.

### Option A — Patch an existing installation

Download `proton-patch.tar.gz` from the release matching your **exact GE tag**.
Close games using that installation, then set `GE_DIR` to its installed directory
and replace the five drivers.

```bash
GE_DIR="$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton11-14-x86_64"
tar -xzf proton-patch.tar.gz
install -m 555 proton-patch/winebus.sys "$GE_DIR/files/lib/wine/x86_64-windows/"
install -m 555 proton-patch/{winebus,winepulse,winepipewire,winealsa}.so "$GE_DIR/files/lib/wine/x86_64-unix/"
```

Launch the game with that GE-Proton installation selected.

### Option B — Install a separate Steam compatibility tool

Download `GE-Proton11-14-eg.tar.gz` and extract it into Steam's compatibility tools directory.

```bash
tools_dir="$HOME/.local/share/Steam/compatibilitytools.d"
mkdir -p "$tools_dir"
tar -xzf GE-Proton11-14-eg.tar.gz -C "$tools_dir"
```

Restart Steam and select **GE-Proton11-14-eg** under the game's **Properties → Compatibility**.

## Build from source

On x86-64 Linux, install Git, curl, wget, tar, patch, Python 3, GCC, GNU Make, binutils,
MinGW-w64, Flex, Bison, Autoconf, Automake, Libtool and pkg-config. The build uses the
development packages for ALSA, PulseAudio, PipeWire 1.2 or newer, udev and SDL2. The
[build workflow](.github/workflows/build.yml) lists the Debian package names.

```bash
./build.sh GE-Proton11-14
```

The full tool is written to `build/GE-Proton11-14-eg.tar.gz` and the five-driver bundle to
`build/wine-build-GE-Proton11-14/proton-patch.tar.gz`. An optional second argument checks
that the GE tag pins the expected Wine commit.
