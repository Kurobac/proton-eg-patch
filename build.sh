#!/bin/bash
set -euo pipefail

# Build patched GE-Proton with DualSense ContainerId fix.
#
# Usage:
#   ./build.sh GE-Proton10-34                    # auto-detect wine commit from GitHub API
#   ./build.sh GE-Proton10-34 <wine-commit-sha>  # specify wine commit manually

GE_TAG="${1:-}"
WINE_COMMIT="${2:-}"
WINE_SRCDIR=""
WINE_BUILDDIR=""

if [ -z "$GE_TAG" ]; then
    echo "Usage: $0 <GE-Proton-tag> [wine-commit]" >&2
    echo "Example: $0 GE-Proton10-34" >&2
    exit 1
fi

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
BUILDDIR="$WORKDIR/build"
PATCHFILE="$WORKDIR/patches/proton-dualsense-containerid.patch"

GITHUB_API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom"
GE_RELEASE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download"
VALVE_WINE="https://github.com/ValveSoftware/wine"

log()  { echo ":: $*" >&2; }
err()  { echo "ERROR: $*" >&2; exit 1; }
check() { command -v "$1" >/dev/null || err "Missing: $1 (apt install $2)"; }

# ---- Check deps ----
check_deps() {
    check curl       curl
    check tar        tar
    check patch      patch
    check make       make
    check gcc        build-essential
    check strip      binutils
    check flex       flex
    check bison      bison
    pkg-config --exists alsa    || err "Missing: alsa (apt install libasound2-dev)"
    pkg-config --exists libpulse|| err "Missing: libpulse (apt install libpulse-dev)"
    pkg-config --exists libudev || err "Missing: libudev (apt install libudev-dev)"
}

# ---- Get wine commit from GE-Proton GitHub API tree ----
get_wine_commit_api() {
    local tag="$1"
    local auth_header=()
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    log "Detecting wine commit for $tag via GitHub API..."
    curl -sL "${auth_header[@]}" "$GITHUB_API/git/trees/$tag" | python3 -c "
import json, sys
for item in json.load(sys.stdin).get('tree', []):
    if item['path'] == 'wine':
        print(item['sha'])
        sys.exit(0)
sys.exit(1)
"
}

# ---- Download & extract ----
download_wine() {
    local commit="$1"
    local dst="$WINE_SRCDIR"
    if [ -f "$dst/configure.ac" ]; then
        log "Wine source already at $dst"
        return
    fi
    rm -rf "$dst"
    local url="$VALVE_WINE/archive/$commit.tar.gz"
    log "Downloading wine source ($commit)..."
    mkdir -p "$(dirname "$dst")"
    curl -sL "$url" | tar xz -C "$BUILDDIR"
}

download_ge_proton() {
    local tag="$1"
    local dst="$BUILDDIR/$tag"
    if [ -d "$dst/proton" ]; then
        log "GE-Proton already at $dst"
        return
    fi
    rm -rf "$dst"
    local url="$GE_RELEASE_URL/$tag/$tag.tar.gz"
    log "Downloading $tag (this may take a while)..."
    mkdir -p "$(dirname "$dst")"
    curl -sL "$url" | tar xz -C "$BUILDDIR"
    # The tarball extracts to a subdirectory, move it
    local subdir
    subdir=$(ls "$BUILDDIR" | grep -i "$tag" | head -1)
    if [ "$subdir" != "$tag" ] && [ -d "$BUILDDIR/$subdir" ]; then
        mv "$BUILDDIR/$subdir" "$dst"
    fi
}

# ---- Build wine 64-bit, just our 3 modules ----
build_wine() {
    local winedir="$WINE_SRCDIR"
    local winebuild="$WINE_BUILDDIR"

    if [ ! -f "$winedir/configure" ]; then
        log "Running autogen.sh..."
        (cd "$winedir" && ./autogen.sh) > /dev/null
    fi

    if [ ! -f "$winebuild/Makefile" ]; then
        log "Running configure..."
        mkdir -p "$winebuild"
        (cd "$winebuild" && "$winedir/configure" --enable-win64 \
            --without-x --without-freetype --without-oss \
            --without-gstreamer --without-opengl --without-vulkan \
            --without-cups --without-dbus \
            --without-gettext --without-opencl) > /dev/null
    fi

    log "Building wine (64-bit, only our 3 modules)..."
    (cd "$winebuild" && make -k -j"$(nproc)" \
        dlls/winebus.sys/x86_64-windows/winebus.sys \
        dlls/winebus.sys/winebus.so \
        dlls/winepulse.drv/winepulse.so \
        dlls/winealsa.drv/winealsa.so > /dev/null)

    # Verify our 4 output files exist
    local files=(
        "dlls/winebus.sys/x86_64-windows/winebus.sys"
        "dlls/winebus.sys/winebus.so"
        "dlls/winepulse.drv/winepulse.so"
        "dlls/winealsa.drv/winealsa.so"
    )
    for f in "${files[@]}"; do
        if [ ! -f "$winebuild/$f" ]; then
            err "Build failed: $f not found"
        fi
        strip "$winebuild/$f" 2>/dev/null || true
        log "  built: $f ($(ls -lh "$winebuild/$f" | awk '{print $5}'))"
    done
}

# ---- Replace patched files in GE-Proton tree ----
replace_files() {
    local ge_lib="$BUILDDIR/$GE_TAG/files/lib/wine"
    local wb="$WINE_BUILDDIR"

    if [ ! -d "$ge_lib" ]; then
        err "GE-Proton lib directory not found: $ge_lib"
    fi

    log "Replacing patched files..."

    # winebus.sys PE (main.c patch → get_container_id)
    cp -v "$wb/dlls/winebus.sys/x86_64-windows/winebus.sys" \
          "$ge_lib/x86_64-windows/winebus.sys"

    # winebus.sys Unix (bus_udev.c et al)
    cp -v "$wb/dlls/winebus.sys/winebus.so" \
          "$ge_lib/x86_64-unix/winebus.so"

    # winepulse.drv Unix (pulse.c patch → get_container_id override)
    cp -v "$wb/dlls/winepulse.drv/winepulse.so" \
          "$ge_lib/x86_64-unix/winepulse.so"

    # winealsa.drv Unix (alsa.c patch → ContainerId property)
    cp -v "$wb/dlls/winealsa.drv/winealsa.so" \
          "$ge_lib/x86_64-unix/winealsa.so"
}

# ---- Repack to tar.gz ----
repack() {
    local src_dir="$BUILDDIR/$EDGEMAP_TAG"
    local outname="$EDGEMAP_TAG.tar.gz"
    local outpath="$BUILDDIR/$outname"

    log "Repacking $outname..."
    tar czf "$outpath" -C "$BUILDDIR" "$EDGEMAP_TAG"
    log "Done: $outpath ($(ls -lh "$outpath" | awk '{print $5}'))"
    echo "$outpath"
}

# ---- Rename and tag as edgemap build ----
tag_edgemap() {
    EDGEMAP_TAG="${GE_TAG}-eg"

    if [ "$EDGEMAP_TAG" != "$GE_TAG" ]; then
        mv "$BUILDDIR/$GE_TAG" "$BUILDDIR/$EDGEMAP_TAG"
    fi

    local vdf="$BUILDDIR/$EDGEMAP_TAG/compatibilitytool.vdf"
    if [ -f "$vdf" ]; then
        sed -i "s|\"${GE_TAG}\"|\"${EDGEMAP_TAG}\"|g" "$vdf"
        log "Updated compatibilitytool.vdf: display_name = $EDGEMAP_TAG"
    fi
}

# ---- Main ----
main() {
    check_deps

    if [ -z "$WINE_COMMIT" ]; then
        WINE_COMMIT=$(get_wine_commit_api "$GE_TAG")
    fi
    log "Wine commit: $WINE_COMMIT"
    WINE_SRCDIR="$BUILDDIR/wine-$WINE_COMMIT"
    WINE_BUILDDIR="$BUILDDIR/wine-build-$WINE_COMMIT"

    log "=== Downloading wine source ==="
    download_wine "$WINE_COMMIT"

    log "=== Applying patch ==="
    local patch_output
    if (cd "$WINE_SRCDIR" && patch -N -p1 --dry-run < "$PATCHFILE" > /dev/null); then
        patch_output=$(cd "$WINE_SRCDIR" && patch -N -p1 < "$PATCHFILE" 2>&1) || {
            printf '%s\n' "$patch_output" | grep -v "^patching file" >&2 || true
            err "Patch failed to apply cleanly."
        }
        printf '%s\n' "$patch_output" | grep -v "^patching file" >&2 || true
        log "Patch applied."
    elif (cd "$WINE_SRCDIR" && patch -R -p1 --dry-run < "$PATCHFILE" > /dev/null); then
        log "Patch already applied."
    else
        err "Patch failed to apply cleanly."
    fi

    log "=== Building wine ==="
    build_wine

    log "=== Downloading $GE_TAG ==="
    download_ge_proton "$GE_TAG"

    log "=== Replacing files ==="
    replace_files

    log "=== Tagging as edgemap build ==="
    tag_edgemap

    log "=== Repacking ==="
    repack
}

main
