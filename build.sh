#!/bin/bash
set -euo pipefail

# Build patched GE-Proton with edgemap/dseuhid controller fixes.
#
# Usage:
#   ./build.sh GE-Proton11-14
#   ./build.sh GE-Proton11-14 <expected-wine-commit>

log()  { echo ":: $*" >&2; }
err()  { echo "ERROR: $*" >&2; exit 1; }
check() { command -v "$1" >/dev/null || err "Missing: $1 (apt install $2)"; }

GE_TAG="${1:-}"
WINE_COMMIT="${2:-}"

if [[ ! $GE_TAG =~ ^GE-Proton[0-9][a-zA-Z0-9._-]*$ || $# -gt 2 ]]; then
    echo "Usage: $0 <GE-Proton-tag> [expected-wine-commit]" >&2
    echo "Example: $0 GE-Proton11-14" >&2
    exit 1
fi

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
BUILDDIR="$WORKDIR/build"
GE_SOURCE="$BUILDDIR/source-$GE_TAG"
WINE_SRCDIR="$GE_SOURCE/wine"
WINE_BUILDDIR="$BUILDDIR/wine-build-$GE_TAG"
EDGEMAP_TAG="${GE_TAG}-eg"
PATCHFILES=(
    "$WORKDIR/patches/proton-dualsense-containerid.patch"
    "$WORKDIR/patches/proton-ds4-uhid-mi03.patch"
    "$WORKDIR/patches/proton-edgemap-audio-containerid.patch"
)

DRIVERS=(
    dlls/winebus.sys/x86_64-windows/winebus.sys
    dlls/winebus.sys/winebus.so
    dlls/winepulse.drv/winepulse.so
    dlls/winepipewire.drv/winepipewire.so
    dlls/winealsa.drv/winealsa.so
)

GITHUB_API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom"
GE_REPO="https://github.com/GloriousEggroll/proton-ge-custom.git"
release_token=${GITHUB_TOKEN:-}
unset GITHUB_TOKEN

# ---- Check deps ----
check_deps() {
    check git        git
    check autoreconf autoconf
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
    pkg-config --atleast-version=1.2 libpipewire-0.3 || err "PipeWire >= 1.2 development files required (libpipewire-0.3-dev)"
    pkg-config --exists libudev || err "Missing: libudev (apt install libudev-dev)"
}

get_ge_release_asset_url() {
    local tag="$1"
    local auth_header=()
    if [ -n "$release_token" ]; then
        auth_header=(-H "Authorization: Bearer $release_token")
    fi

    curl -sL --fail "${auth_header[@]}" "$GITHUB_API/releases/tags/$tag" | python3 -c '
import json, sys

tag = sys.argv[1]
supported_names = {f"{tag}.tar.gz", f"{tag}-x86_64.tar.gz"}
matches = [
    asset for asset in json.load(sys.stdin).get("assets", [])
    if asset.get("name") in supported_names
]

if len(matches) != 1:
    names = ", ".join(sorted(asset.get("name", "<unnamed>") for asset in matches)) or "none"
    print(f"Expected exactly one x86_64 release asset for {tag}; found: {names}", file=sys.stderr)
    sys.exit(1)

print(matches[0]["browser_download_url"])
' "$tag"
}

# ---- Prepare the Wine tree used by this GE release ----
prepare_wine() (
    if [[ ! -d "$GE_SOURCE/.git" ]]; then
        git clone --depth 1 --branch "$GE_TAG" "$GE_REPO" "$GE_SOURCE"
    fi

    cd "$GE_SOURCE"
    local pinned patchfile
    pinned=$(git rev-parse HEAD:wine)
    [[ $(git rev-parse HEAD) == "$(git rev-parse "refs/tags/$GE_TAG^{commit}")" ]] ||
        err "Unexpected checkout in $GE_SOURCE"
    [[ -z "$WINE_COMMIT" || "$WINE_COMMIT" == "$pinned" ]] ||
        err "$GE_TAG pins Wine $pinned (requested $WINE_COMMIT)"

    # These submodules are used by GE's preparation script. WineOpenXR
    # and the Proton helpers are already in the superproject checkout.
    git submodule update --init --checkout --filter=tree:0 --jobs 6 -- \
        wine wine-staging dxvk d7vk openvr vkd3d-proton dxvk-nvapi vklayers/low_latency_layer
    bash -e -o pipefail patches/protonprep-valve-staging.sh
    cd wine
    for patchfile in "${PATCHFILES[@]}"; do
        log "Applying ${patchfile##*/}"
        git apply "$patchfile"
    done

    # GE's .wine-post-source step generates headers needed by makedep.
    XDG_CACHE_HOME="$WINE_BUILDDIR" dlls/winevulkan/make_vulkan -x vk.xml -X video.xml
    tools/make_specfiles
)

download_ge_proton() {
    local tag="$1"
    local dst="$BUILDDIR/$tag"
    if [[ -f "$dst/proton" && -f "$dst/version" ]]; then
        log "Using $dst"
        return
    fi
    local url
    url=$(get_ge_release_asset_url "$tag")
    log "Downloading $tag..."
    rm -rf "$dst.partial"
    mkdir -p "$dst.partial"
    curl -fLsS "$url" | tar xz --strip-components=1 -C "$dst.partial"
    [[ -f "$dst.partial/proton" && -f "$dst.partial/version" ]] || err "Incomplete $tag release"
    mv -T "$dst.partial" "$dst"
}

# ---- Create clean edgemap output tree from cached GE-Proton ----
prepare_edgemap_tree() {
    local src="$BUILDDIR/$GE_TAG"
    local dst="$BUILDDIR/$EDGEMAP_TAG"

    if [ ! -f "$src/proton" ]; then
        err "GE-Proton source tree not found: $src"
    fi

    log "Preparing edgemap tree at $dst..."
    rm -rf "$dst"
    cp -a "$src" "$dst"
}

# ---- Build wine 64-bit, patched modules ----
build_wine() (
    local jobs
    jobs=$(nproc)
    mkdir -p "$WINE_BUILDDIR"
    cd "$WINE_BUILDDIR"
    log "Configuring Wine..."
    "$WINE_SRCDIR/configure" --enable-win64 --with-pipewire \
        --without-x --without-freetype --without-oss \
        --without-opengl --without-vulkan --without-cups --without-dbus \
        --without-gettext --without-opencl > /dev/null
    log "Building the 64-bit driver modules..."
    make -j"$jobs" "${DRIVERS[@]}" > /dev/null
)

# Install and package the same drivers for both downloads.
replace_files() {
    local ge_lib="$BUILDDIR/$EDGEMAP_TAG/files/lib/wine"
    local bundle="$WINE_BUILDDIR/proton-patch"
    local driver arch dest
    mkdir -p "$bundle"
    for driver in "${DRIVERS[@]}"; do
        case "$driver" in
            *.sys) arch=x86_64-windows ;;
            *.so)  arch=x86_64-unix ;;
        esac
        dest="$ge_lib/$arch/${driver##*/}"
        [[ -f "$dest" ]] || err "Driver missing from $GE_TAG: $dest"
        install -s -m 555 "$WINE_BUILDDIR/$driver" "$dest"
        install -m 555 "$dest" "$bundle/"
    done
    tar czf "$WINE_BUILDDIR/proton-patch.tar.gz.partial" -C "$WINE_BUILDDIR" proton-patch
    mv "$WINE_BUILDDIR/proton-patch.tar.gz.partial" "$WINE_BUILDDIR/proton-patch.tar.gz"
}

# ---- Repack to tar.gz ----
repack() {
    local outname="$EDGEMAP_TAG.tar.gz"
    local outpath="$BUILDDIR/$outname"

    log "Repacking $outname..."
    tar czf "$outpath.partial" -C "$BUILDDIR" "$EDGEMAP_TAG"
    mv "$outpath.partial" "$outpath"
    log "Done: $outpath"
    echo "$outpath"
}

update_compatibilitytool_vdf() {
    local vdf="$1"
    local tool_name="$2"

    python3 - "$vdf" "$tool_name" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
tool_name = sys.argv[2]
text = path.read_text()

internal_pattern = re.compile(r'("compat_tools"\s*\{\s*)"[^"\r\n]+"')
display_pattern = re.compile(r'(^[ \t]*"display_name"[ \t]+)"[^"\r\n]+"', re.MULTILINE)

updated, internal_count = internal_pattern.subn(
    lambda match: f'{match.group(1)}"{tool_name}"', text
)
updated, display_count = display_pattern.subn(
    lambda match: f'{match.group(1)}"{tool_name}"', updated
)

if internal_count != 1 or display_count != 1:
    print(
        f"Expected one internal name and one display_name in {path}; "
        f"found {internal_count} and {display_count}",
        file=sys.stderr,
    )
    sys.exit(1)

path.write_text(updated)
PY
}

# ---- Rename and tag as edgemap build ----
tag_edgemap() {
    local vdf="$BUILDDIR/$EDGEMAP_TAG/compatibilitytool.vdf"

    [ -f "$vdf" ] || err "compatibilitytool.vdf not found: $vdf"
    update_compatibilitytool_vdf "$vdf" "$EDGEMAP_TAG"
    log "Updated compatibilitytool.vdf: internal_name = $EDGEMAP_TAG, display_name = $EDGEMAP_TAG"
}

# ---- Main ----
main() {
    check_deps

    mkdir -p "$BUILDDIR"
    exec 9>"$BUILDDIR/$GE_TAG.lock"
    flock -n 9 || err "Another build of $GE_TAG is running"

    log "=== Preparing $GE_TAG Wine sources ==="
    prepare_wine

    log "=== Building wine ==="
    build_wine

    log "=== Downloading $GE_TAG ==="
    download_ge_proton "$GE_TAG"

    log "=== Preparing $EDGEMAP_TAG ==="
    prepare_edgemap_tree

    log "=== Replacing files ==="
    replace_files

    log "=== Tagging as edgemap build ==="
    tag_edgemap

    log "=== Repacking ==="
    repack
}

main
