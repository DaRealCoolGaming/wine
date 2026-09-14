#!/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

BUILD_DIR="${BUILD_DIR:-"$ROOT_DIR/build-lemonade"}"
APP_DIR="${APP_DIR:-"$ROOT_DIR/lemonade.app"}"
TOOLS_DIR="${TOOLS_DIR:-"$ROOT_DIR/.tools"}"
JOBS="${JOBS:-$(sysctl -n hw.activecpu 2>/dev/null || printf '2')}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

###############################################################################
# Tool versions / locations
###############################################################################

BISON_VERSION="3.8.2-1"
BISON_PREFIX="$TOOLS_DIR/bison"
BISON_ARCHIVE="$TOOLS_DIR/xpack-bison-$BISON_VERSION-darwin-arm64.tar.gz"
BISON_URL="https://sourceforge.net/projects/bison-xpack/files/v3.8.2-1/xpack-bison-3.8.2-1-darwin-arm64.tar.gz/download"

LLVM_MINGW_PREFIX="$TOOLS_DIR/llvm-mingw"
LLVM_MINGW_API="https://api.github.com/repos/mstorsjo/llvm-mingw/releases/latest"
LLVM_MINGW_ARCHIVE="$TOOLS_DIR/llvm-mingw-macos-universal.tar.xz"
LLVM_MINGW_RELEASE_JSON="$TOOLS_DIR/llvm-mingw-release.json"
LLVM_MINGW_TEMP="$TOOLS_DIR/llvm-mingw-extract"

###############################################################################
# Platform checks
###############################################################################

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' "ERROR: This script must be run on macOS." >&2
    exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    printf '%s\n' "ERROR: This script requires Apple Silicon (arm64)." >&2
    printf 'Detected architecture: %s\n' "$(uname -m)" >&2
    exit 1
fi

if ! command -v xcode-select >/dev/null 2>&1; then
    printf '%s\n' "ERROR: Xcode Command Line Tools are required." >&2
    exit 1
fi

if ! command -v make >/dev/null 2>&1; then
    printf '%s\n' "ERROR: make is required." >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' "ERROR: curl is required." >&2
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    printf '%s\n' "ERROR: tar is required." >&2
    exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
    printf '%s\n' "ERROR: unzip is required." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "ERROR: python3 is required (used to parse conda-forge package metadata)." >&2
    exit 1
fi

if ! command -v cc >/dev/null 2>&1; then
    printf '%s\n' "ERROR: a native C compiler (cc) is required." >&2
    exit 1
fi

mkdir -p "$TOOLS_DIR"

# Apple's Command Line Tools also provide a non-GNU gm4 that Bison may find
# first. Wine's generated parsers require GNU M4's --gnu option.
M4="${M4:-/usr/bin/m4}"
M4_PREFIX="$TOOLS_DIR/m4"
M4_METADATA="$TOOLS_DIR/m4-conda-forge.json"
M4_ARCHIVE="$TOOLS_DIR/m4-conda-forge.tar.bz2"
M4_EXTRACT="$TOOLS_DIR/m4-conda-forge-extract"

if [[ ! -x "$M4" ]] || ! "$M4" --gnu </dev/null >/dev/null 2>&1 || \
   [[ "$("$M4" --version 2>/dev/null | sed -n '1s/.* \([0-9][0-9.]*\).*/\1/p')" < "1.4.8" ]]; then
    if [[ ! -x "$M4_PREFIX/bin/m4" ]]; then
        printf '%s\n' "Downloading prebuilt GNU M4 for Apple Silicon..."
        rm -f "$M4_ARCHIVE"
        curl -fL --retry 3 --retry-delay 2 \
            "https://api.anaconda.org/package/conda-forge/m4/files" \
            -o "$M4_METADATA"
        M4_URL="$(
            python3 - "$M4_METADATA" <<'PYEOF'
import json
import sys

files = json.load(open(sys.argv[1]))
candidates = [
    item for item in files
    if item.get("attrs", {}).get("subdir") == "osx-arm64"
    and item.get("basename", "").endswith(".tar.bz2")
]
if not candidates:
    raise SystemExit("no osx-arm64 GNU M4 package found")
candidates.sort(key=lambda item: item.get("attrs", {}).get("timestamp", 0), reverse=True)
url = candidates[0]["download_url"]
if url.startswith("//"):
    url = "https:" + url
if not url.startswith("https://"):
    raise SystemExit("conda-forge returned a non-HTTPS download URL")
print(url)
PYEOF
        )"
        curl -fL --retry 3 --retry-delay 2 "$M4_URL" \
            -o "$M4_ARCHIVE"
        rm -rf "$M4_PREFIX"
        rm -rf "$M4_EXTRACT"
        mkdir -p "$M4_PREFIX" "$M4_EXTRACT"
        tar -xjf "$M4_ARCHIVE" -C "$M4_EXTRACT"
        cp -R "$M4_EXTRACT/bin" "$M4_PREFIX/"
        rm -rf "$M4_EXTRACT" "$M4_METADATA" "$M4_ARCHIVE"
    fi
    M4="$M4_PREFIX/bin/m4"
fi
[[ -x "$M4" ]] || { printf '%s\n' "ERROR: GNU M4 is unavailable." >&2; exit 1; }
export M4

###############################################################################
# Flex
###############################################################################

FLEX_PREFIX="$TOOLS_DIR/flex"
FLEX_METADATA="$TOOLS_DIR/flex-conda-forge.json"
FLEX_ARCHIVE="$TOOLS_DIR/flex-conda-forge.tar.bz2"
FLEX_EXTRACT="$TOOLS_DIR/flex-conda-forge-extract"

if [[ ! -x "$FLEX_PREFIX/bin/flex" ]]; then
    printf '%s\n' "Downloading prebuilt Flex for Apple Silicon..."
    curl -fL --retry 3 --retry-delay 2 \
         "https://api.anaconda.org/download/conda-forge/flex/2.6.4/osx-arm64/flex-2.6.4-h1474e2a_1004.tar.bz2" \
        -o "$FLEX_METADATA"
    FLEX_URL="$(
        python3 - "$FLEX_METADATA" <<'PYEOF'
import json
import sys

files = json.load(open(sys.argv[1]))
candidates = [
    item for item in files
    if item.get("attrs", {}).get("subdir") == "osx-arm64"
    and item.get("basename", "").endswith(".tar.bz2")
]
if not candidates:
    raise SystemExit("no osx-arm64 Flex package found")
candidates.sort(key=lambda item: item.get("attrs", {}).get("timestamp", 0), reverse=True)
url = candidates[0]["download_url"]
if url.startswith("//"):
    url = "https:" + url
if not url.startswith("https://"):
    raise SystemExit("conda-forge returned a non-HTTPS download URL")
print(url)
PYEOF
    )"
    curl -fL --retry 3 --retry-delay 2 "$FLEX_URL" -o "$FLEX_ARCHIVE"
    rm -rf "$FLEX_PREFIX" "$FLEX_EXTRACT"
    mkdir -p "$FLEX_PREFIX" "$FLEX_EXTRACT"
    tar -xjf "$FLEX_ARCHIVE" -C "$FLEX_EXTRACT"
    cp -R "$FLEX_EXTRACT/bin" "$FLEX_PREFIX/"
    rm -rf "$FLEX_EXTRACT" "$FLEX_METADATA" "$FLEX_ARCHIVE"
fi

[[ -x "$FLEX_PREFIX/bin/flex" ]] || {
    printf '%s\n' "ERROR: Flex installation failed." >&2
    exit 1
}
export PATH="$FLEX_PREFIX/bin:$PATH"
export FLEX="$FLEX_PREFIX/bin/flex"
printf 'Using Flex: %s\n' "$(command -v flex)"
flex --version | head -1

###############################################################################
# Bison
###############################################################################

if [[ ! -x "$BISON_PREFIX/bin/bison" ]]; then
    printf '\n'
    printf '%s\n' "Downloading precompiled Bison 3.8.2 for Apple Silicon..."
    printf '\n'

    rm -f "$BISON_ARCHIVE"

    curl -fL \
        --retry 3 \
        --retry-delay 2 \
        "$BISON_URL" \
        -o "$BISON_ARCHIVE"

    if [[ ! -s "$BISON_ARCHIVE" ]]; then
        printf '%s\n' "ERROR: Bison download is empty." >&2
        exit 1
    fi

    rm -rf "$BISON_PREFIX"
    mkdir -p "$BISON_PREFIX"

    tar -xzf "$BISON_ARCHIVE" \
        --strip-components=1 \
        -C "$BISON_PREFIX"
fi

if [[ ! -x "$BISON_PREFIX/bin/bison" ]]; then
    printf '%s\n' "ERROR: Bison installation failed." >&2
    exit 1
fi

export PATH="$BISON_PREFIX/bin:$PATH"

printf 'Using Bison: %s\n' "$(command -v bison)"
bison --version | head -1

###############################################################################
# llvm-mingw
###############################################################################

PE_COMPILER_NAME="aarch64-w64-mingw32-clang"
PE_COMPILER=""

find_pe_compiler() {
    local candidate

    if [[ -x "$LLVM_MINGW_PREFIX/bin/$PE_COMPILER_NAME" ]]; then
        PE_COMPILER="$LLVM_MINGW_PREFIX/bin/$PE_COMPILER_NAME"
        return 0
    fi

    candidate="$(
        find "$LLVM_MINGW_PREFIX" \
            -type f \
            -name "$PE_COMPILER_NAME" \
            -perm -111 \
            -print \
            -quit 2>/dev/null || true
    )"

    if [[ -n "$candidate" ]]; then
        PE_COMPILER="$candidate"
        return 0
    fi

    return 1
}

if ! find_pe_compiler; then
    printf '\n'
    printf '%s\n' "Finding latest precompiled llvm-mingw release..."
    printf 'API: %s\n' "$LLVM_MINGW_API"
    printf '\n'

    rm -f "$LLVM_MINGW_RELEASE_JSON"

    curl -fL \
        --retry 3 \
        --retry-delay 2 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: lemonade-build-script' \
        "$LLVM_MINGW_API" \
        -o "$LLVM_MINGW_RELEASE_JSON"

    if [[ ! -s "$LLVM_MINGW_RELEASE_JSON" ]]; then
        printf '%s\n' "ERROR: GitHub release information was empty." >&2
        exit 1
    fi

    LLVM_MINGW_URL="$(
        grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
            "$LLVM_MINGW_RELEASE_JSON" \
        | sed -E \
            's/^"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/' \
        | grep -E 'llvm-mingw-[^/]+-ucrt-macos-universal\.tar\.xz$' \
        | head -1
    )"

    if [[ -z "$LLVM_MINGW_URL" ]]; then
        printf '%s\n' "ERROR: Could not find the macOS llvm-mingw archive." >&2
        printf '%s\n' "Available llvm-mingw assets:" >&2

        grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
            "$LLVM_MINGW_RELEASE_JSON" \
        | sed -E \
            's/^"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/' \
        | grep 'llvm-mingw' \
        | while IFS= read -r asset; do
            printf '  %s\n' "$asset" >&2
        done

        exit 1
    fi

    printf '%s\n' "Found llvm-mingw archive:"
    printf '%s\n' "$LLVM_MINGW_URL"
    printf '\n'

    rm -f "$LLVM_MINGW_ARCHIVE"

    curl -fL \
        --retry 3 \
        --retry-delay 2 \
        -H 'User-Agent: lemonade-build-script' \
        "$LLVM_MINGW_URL" \
        -o "$LLVM_MINGW_ARCHIVE"

    if [[ ! -s "$LLVM_MINGW_ARCHIVE" ]]; then
        printf '%s\n' "ERROR: llvm-mingw download is empty." >&2
        exit 1
    fi

    if ! tar -tJf "$LLVM_MINGW_ARCHIVE" >/dev/null 2>&1; then
        printf '%s\n' "ERROR: Downloaded llvm-mingw archive is invalid." >&2
        exit 1
    fi

    printf '%s\n' "llvm-mingw archive verified."

    rm -rf "$LLVM_MINGW_PREFIX"
    rm -rf "$LLVM_MINGW_TEMP"

    mkdir -p "$LLVM_MINGW_TEMP"

    printf '%s\n' "Extracting llvm-mingw..."

    tar -xJf "$LLVM_MINGW_ARCHIVE" \
        -C "$LLVM_MINGW_TEMP"

    EXTRACTED_DIR="$(
        find "$LLVM_MINGW_TEMP" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -print \
            -quit
    )"

    if [[ -n "$EXTRACTED_DIR" ]]; then
        mv "$EXTRACTED_DIR" "$LLVM_MINGW_PREFIX"
    else
        mkdir -p "$LLVM_MINGW_PREFIX"
        cp -R "$LLVM_MINGW_TEMP"/. "$LLVM_MINGW_PREFIX"/
    fi

    rm -rf "$LLVM_MINGW_TEMP"

    printf '%s\n' "llvm-mingw extraction complete."

    if ! find_pe_compiler; then
        printf '\n'
        printf '%s\n' "ERROR: llvm-mingw was extracted, but the AArch64 PE compiler could not be found." >&2
        printf '\n'
        printf '%s\n' "Searching for possible PE compilers:" >&2

        find "$LLVM_MINGW_PREFIX" \
            -type f \
            \( \
                -name '*aarch64*clang*' -o \
                -name '*aarch64*gcc*' -o \
                -name '*aarch64*ld*' -o \
                -name '*aarch64*dlltool*' \
            \) \
            -print 2>/dev/null \
            | head -100 >&2

        exit 1
    fi
fi

###############################################################################
# Configure llvm-mingw PATH
###############################################################################

PE_BIN_DIR="$(cd "$(dirname "$PE_COMPILER")" && pwd)"

export PATH="$PE_BIN_DIR:$LLVM_MINGW_PREFIX/bin:$BISON_PREFIX/bin:$PATH"

# Re-resolve after PATH modification.
PE_COMPILER="$(command -v "$PE_COMPILER_NAME" || true)"

if [[ -z "$PE_COMPILER" ]]; then
    printf '%s\n' "ERROR: AArch64 PE compiler is still not visible on PATH." >&2
    printf 'Expected compiler: %s\n' "$PE_COMPILER_NAME" >&2
    printf 'Compiler directory: %s\n' "$PE_BIN_DIR" >&2
    exit 1
fi

###############################################################################
# Verify PE toolchain
###############################################################################

printf '\n'
printf '%s\n' "AArch64 PE toolchain:"
printf '  clang:   %s\n' "$PE_COMPILER"

if command -v aarch64-w64-mingw32-clang++ >/dev/null 2>&1; then
    printf '  clang++: %s\n' "$(command -v aarch64-w64-mingw32-clang++)"
fi

if command -v aarch64-w64-mingw32-dlltool >/dev/null 2>&1; then
    printf '  dlltool: %s\n' "$(command -v aarch64-w64-mingw32-dlltool)"
fi

if command -v aarch64-w64-mingw32-ar >/dev/null 2>&1; then
    printf '  ar:      %s\n' "$(command -v aarch64-w64-mingw32-ar)"
fi

if command -v aarch64-w64-mingw32-windres >/dev/null 2>&1; then
    printf '  windres: %s\n' "$(command -v aarch64-w64-mingw32-windres)"
fi

printf '\n'
"$PE_COMPILER" --version | head -1

###############################################################################
# FreeType + pkg-config (native macOS host build, not the PE cross toolchain)
#
# Wine's *host* build (the part that runs directly on macOS) needs FreeType
# headers/libs to build its font code. We can't use Homebrew, so:
#   1. Try to grab precompiled osx-arm64 binaries from conda-forge (plain
#      package archives on anaconda.org -- no conda installation needed).
#   2. Actually compile+link a tiny test program against what we got, to
#      confirm it works rather than just hoping the paths are right.
#   3. If that fails for any reason, fall back to building a small,
#      dependency-free FreeType from source with the system compiler.
###############################################################################

NATIVE_DEPS_PREFIX="$TOOLS_DIR/native-deps"
CONDA_FORGE_SUBDIR="osx-arm64"

mkdir -p "$NATIVE_DEPS_PREFIX"

# Looks up a conda-forge package's file list via the Anaconda API and prints
# the download URL of the newest osx-arm64 build, preferring the old
# .tar.bz2 format (a plain tarball) over the newer .conda container format.
fetch_conda_forge_url() {
    local pkg_name="$1"
    local json_file="$TOOLS_DIR/conda-${pkg_name}.json"

    curl -fsSL \
        --retry 3 \
        --retry-delay 2 \
        "https://api.anaconda.org/package/conda-forge/${pkg_name}/files" \
        -o "$json_file" || return 1

    [[ -s "$json_file" ]] || return 1

    python3 - "$json_file" "$CONDA_FORGE_SUBDIR" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
subdir = sys.argv[2]
candidates = [f for f in data if f.get("attrs", {}).get("subdir") == subdir]
if not candidates:
    sys.exit(1)
def sort_key(f):
    is_tarbz2 = f["basename"].endswith(".tar.bz2")
    return (is_tarbz2, f.get("attrs", {}).get("timestamp", 0))
candidates.sort(key=sort_key, reverse=True)
print(candidates[0]["download_url"])
PYEOF
}

# Downloads one conda-forge package and merges its bin/lib/include
# directories into NATIVE_DEPS_PREFIX.
extract_conda_forge_package() {
    local pkg_name="$1"
    local url
    url="$(fetch_conda_forge_url "$pkg_name")" || {
        printf 'WARNING: Could not find an osx-arm64 build of %s on conda-forge.\n' "$pkg_name" >&2
        return 1
    }

    local archive="$TOOLS_DIR/conda-${pkg_name}-download"
    local extract_dir="$TOOLS_DIR/conda-${pkg_name}-extract"

    rm -f "$archive"
    curl -fL --retry 3 --retry-delay 2 "$url" -o "$archive"

    if [[ ! -s "$archive" ]]; then
        printf 'WARNING: Download of %s from conda-forge failed.\n' "$pkg_name" >&2
        return 1
    fi

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    case "$url" in
        *.tar.bz2)
            tar -xjf "$archive" -C "$extract_dir"
            ;;
        *.conda)
            # .conda files are zip containers holding zstd-compressed tarballs.
            (cd "$extract_dir" && unzip -q "$archive")
            for pkgtar in "$extract_dir"/pkg-*.tar.zst; do
                [[ -e "$pkgtar" ]] || continue
                tar --zstd -xf "$pkgtar" -C "$extract_dir"
            done
            ;;
        *)
            printf 'WARNING: Unrecognized archive format for %s: %s\n' "$pkg_name" "$url" >&2
            return 1
            ;;
    esac

    for sub in bin lib include; do
        if [[ -d "$extract_dir/$sub" ]]; then
            mkdir -p "$NATIVE_DEPS_PREFIX/$sub"
            cp -R "$extract_dir/$sub/." "$NATIVE_DEPS_PREFIX/$sub/"
        fi
    done

    rm -rf "$extract_dir" "$archive"
}

printf '\n'
printf '%s\n' "Attempting to fetch precompiled FreeType + pkg-config from conda-forge..."
printf '\n'

for pkg in zlib bzip2 libpng brotli freetype pkg-config; do
    extract_conda_forge_package "$pkg" || true
done

# Conda .pc files hardcode the original build prefix; repoint it at ours.
if [[ -f "$NATIVE_DEPS_PREFIX/lib/pkgconfig/freetype2.pc" ]]; then
    sed -i '' \
        -e "s#^prefix=.*#prefix=$NATIVE_DEPS_PREFIX#" \
        "$NATIVE_DEPS_PREFIX/lib/pkgconfig/freetype2.pc"
fi

export PATH="$NATIVE_DEPS_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$NATIVE_DEPS_PREFIX/lib/pkgconfig"
export DYLD_LIBRARY_PATH="$NATIVE_DEPS_PREFIX/lib:${DYLD_LIBRARY_PATH:-}"

# Sibling libs (libpng, brotli, etc.) may not resolve via their baked-in
# rpaths once extracted outside a real conda environment -- point every
# extracted dylib back at our merged lib dir as a safety net.
for dylib in "$NATIVE_DEPS_PREFIX"/lib/*.dylib; do
    [[ -e "$dylib" ]] || continue
    install_name_tool -add_rpath "$NATIVE_DEPS_PREFIX/lib" "$dylib" 2>/dev/null || true
done

if compgen -G "$NATIVE_DEPS_PREFIX/lib/libfreetype*.dylib" >/dev/null; then
    printf '\n'
    printf '%s\n' "Extracted FreeType library dependencies:"
    otool -L "$NATIVE_DEPS_PREFIX"/lib/libfreetype*.dylib 2>/dev/null || true
fi

# Builds a minimal, dependency-free FreeType from source using the native
# macOS compiler. Used only if the precompiled route above didn't pan out.
build_freetype_from_source() {
    local ft_version="2.13.3"
    local ft_url="https://sourceforge.net/projects/freetype/files/freetype2/${ft_version}/freetype-${ft_version}.tar.xz/download"
    local ft_archive="$TOOLS_DIR/freetype-${ft_version}.tar.xz"
    local ft_src_dir="$TOOLS_DIR/freetype-src"

    printf '\n'
    printf '%s\n' "Precompiled FreeType didn't check out -- building a minimal FreeType from source instead."
    printf '\n'

    rm -f "$ft_archive"
    curl -fL --retry 3 --retry-delay 2 "$ft_url" -o "$ft_archive"

    if [[ ! -s "$ft_archive" ]]; then
        printf '%s\n' "ERROR: FreeType source download failed." >&2
        exit 1
    fi

    rm -rf "$ft_src_dir"
    mkdir -p "$ft_src_dir"
    tar -xJf "$ft_archive" --strip-components=1 -C "$ft_src_dir"

    (
        cd "$ft_src_dir"
        ./configure \
            --prefix="$NATIVE_DEPS_PREFIX" \
            --without-harfbuzz \
            --without-bz2 \
            --without-png \
            --without-brotli
        make -j"$JOBS"
        make install
    )

    rm -rf "$ft_src_dir" "$ft_archive"
}

# Compiles+links a tiny program against whatever is currently in
# NATIVE_DEPS_PREFIX to confirm FreeType actually works, rather than just
# hoping the extracted paths are right.
verify_freetype_usable() {
    local test_dir
    test_dir="$(mktemp -d)"

    cat > "$test_dir/test.c" <<'EOF'
#include <ft2build.h>
#include FT_FREETYPE_H
int main(void) {
    FT_Library lib;
    return FT_Init_FreeType(&lib);
}
EOF

    if cc \
        -I"$NATIVE_DEPS_PREFIX/include/freetype2" \
        -I"$NATIVE_DEPS_PREFIX/include" \
        -L"$NATIVE_DEPS_PREFIX/lib" \
        -lfreetype \
        "$test_dir/test.c" \
        -o "$test_dir/test" 2>"$test_dir/err.log"
    then
        rm -rf "$test_dir"
        return 0
    fi

    printf '%s\n' "FreeType verification build failed:" >&2
    cat "$test_dir/err.log" >&2
    rm -rf "$test_dir"
    return 1
}

if ! verify_freetype_usable; then
    build_freetype_from_source
    if ! verify_freetype_usable; then
        printf '%s\n' "ERROR: Could not obtain a working FreeType, precompiled or from source." >&2
        exit 1
    fi
fi

printf '%s\n' "FreeType is ready: $NATIVE_DEPS_PREFIX"

###############################################################################
# Clean previous build output
###############################################################################

rm -rf "$APP_DIR"
mkdir -p "$BUILD_DIR"

###############################################################################
# Configure Wine
###############################################################################

printf '\n'
printf '%s\n' "Configuring Wine..."
printf '\n'

(
    cd "$BUILD_DIR"

    export CPPFLAGS="-I$NATIVE_DEPS_PREFIX/include -I$NATIVE_DEPS_PREFIX/include/freetype2 ${CPPFLAGS:-}"
    export LDFLAGS="-L$NATIVE_DEPS_PREFIX/lib ${LDFLAGS:-}"

    "$ROOT_DIR/configure" \
        FLEX="$FLEX" \
        --enable-win64 \
        --prefix="$APP_DIR/Contents/Resources" \
        --bindir="$APP_DIR/Contents/MacOS" \
        --libdir="$APP_DIR/Contents/Resources/lib" \
        --datadir="$APP_DIR/Contents/Resources/share"
)

###############################################################################
# Build Wine
###############################################################################

printf '\n'
printf '%s\n' "Building Wine..."
printf 'Using %s parallel jobs.\n' "$JOBS"
printf '\n'

make -C "$BUILD_DIR" -j"$JOBS"

###############################################################################
# Install Wine
###############################################################################

printf '\n'
printf '%s\n' "Installing Wine into lemonade.app..."
printf '\n'

make -C "$BUILD_DIR" install

###############################################################################
# Generate Info.plist
###############################################################################

mkdir -p "$APP_DIR/Contents"

WINE_VERSION="$(
    sed -n 's/^Wine version //p' "$ROOT_DIR/VERSION"
)"

if [[ -z "$WINE_VERSION" ]]; then
    printf '%s\n' "ERROR: Could not determine Wine version." >&2
    exit 1
fi

sed "s/@PACKAGE_VERSION@/$WINE_VERSION/g" \
    "$ROOT_DIR/loader/wine_info.plist.in" \
    > "$APP_DIR/Contents/Info.plist"

###############################################################################
# Optional code signing
###############################################################################

if [[ -n "$SIGNING_IDENTITY" ]]; then
    printf '\n'
    printf '%s\n' "Code signing lemonade.app..."

    codesign \
        --deep \
        --force \
        --options runtime \
        --sign "$SIGNING_IDENTITY" \
        "$APP_DIR"
fi

###############################################################################
# Complete
###############################################################################

printf '\n'
printf '%s\n' "============================================================"
printf '%s\n' " LEMONADE BUILD COMPLETE"
printf '%s\n' "============================================================"
printf '\n'
printf 'App: %s\n' "$APP_DIR"
printf 'Run: %s/Contents/MacOS/lemonade\n' "$APP_DIR"
printf '\n'