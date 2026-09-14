#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Recover from an inaccessible inherited working directory.
# This MUST happen before anything that can call getcwd().
# ============================================================
cd /

# ============================================================
# Resolve this script from its absolute path.
# ============================================================
SCRIPT_PATH="${BASH_SOURCE[0]}"

case "$SCRIPT_PATH" in
    /*)
        ;;
    *)
        echo "ERROR: build-lemonade.sh must be launched using an absolute path."
        exit 1
        ;;
esac

SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
ROOT_DIR="$(cd "$SCRIPT_DIR" && pwd -P)"

cd "$ROOT_DIR"

# ============================================================
# Paths
# ============================================================
TOOLS_DIR="$ROOT_DIR/.tools"
LEMONADE_DIR="$ROOT_DIR/.lemonade-tools"

MICROMAMBA_DIR="$TOOLS_DIR/micromamba"
MICROMAMBA="$MICROMAMBA_DIR/bin/micromamba"

LLVM_MINGW_DIR="$TOOLS_DIR/llvm-mingw"
LLVM_MINGW_BIN="$LLVM_MINGW_DIR/bin"

PREBUILT_ENV="$LEMONADE_DIR/prebuilt-env"

BUILD_DIR="$LEMONADE_DIR/build-lemonade"
STAGE_DIR="$LEMONADE_DIR/install-stage"

APP_DIR="$ROOT_DIR/lemonade.app"

JOBS="${JOBS:-$(sysctl -n hw.activecpu 2>/dev/null || echo 4)}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

# ============================================================
# Temporary space-free path alias
#
# IMPORTANT:
# This is ONLY a symlink.
#
# All real source, dependency, build, and output files remain
# underneath Visual Studio Code.app.
# ============================================================
PATH_ALIAS="/tmp/lemonade-build"

# ============================================================
# Helpers
# ============================================================
section() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
}

die() {
    echo
    echo "ERROR: $*"
    exit 1
}

cleanup() {
    if [[ -L "$PATH_ALIAS" ]]; then
        rm -f "$PATH_ALIAS"
    fi
}

trap cleanup EXIT

# ============================================================
# Create working directory
# ============================================================
mkdir -p "$LEMONADE_DIR"

# ============================================================
# MICROMAMBA
# ============================================================
section "Prebuilt micromamba"

if [[ ! -x "$MICROMAMBA" ]]; then
    die "micromamba was not found at:

  $MICROMAMBA"
fi

echo "Using:"
echo "$MICROMAMBA"

# ============================================================
# PREBUILT DEPENDENCY ENVIRONMENT
# ============================================================
section "Prebuilt dependency environment"

REQUIRED_TOOLS=(
    m4
    flex
    bison
)

MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if [[ ! -x "$PREBUILT_ENV/bin/$tool" ]]; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -ne 0 ]]; then

    echo "Missing required tools:"
    printf '  %s\n' "${MISSING_TOOLS[@]}"

    echo
    echo "Creating environment..."

    rm -rf "$PREBUILT_ENV"

    "$MICROMAMBA" create \
        --yes \
        --no-rc \
        --root-prefix "$LEMONADE_DIR/micromamba-root" \
        --prefix "$PREBUILT_ENV" \
        -c conda-forge \
        m4=1.4.21 \
        flex=2.6.4 \
        bison=3.8.2 \
        freetype \
        zlib \
        bzip2 \
        libpng \
        brotli
else
    echo "Using existing prebuilt environment:"
    echo "$PREBUILT_ENV"
fi

# ============================================================
# Validate native build tools
# ============================================================
section "Validate build tools"

for tool in "${REQUIRED_TOOLS[@]}"; do
    if [[ ! -x "$PREBUILT_ENV/bin/$tool" ]]; then
        die "Missing:

  $PREBUILT_ENV/bin/$tool"
    fi
done

echo "m4:"
"$PREBUILT_ENV/bin/m4" --version | head -1

echo "flex:"
"$PREBUILT_ENV/bin/flex" --version | head -1

echo "bison:"
"$PREBUILT_ENV/bin/bison" --version | head -1

# ============================================================
# FREETYPE
# ============================================================
section "FreeType"

FREETYPE_INCLUDE="$PREBUILT_ENV/include"
FREETYPE_INCLUDE2="$PREBUILT_ENV/include/freetype2"
FREETYPE_LIB="$PREBUILT_ENV/lib"

if [[ ! -d "$FREETYPE_INCLUDE" ]]; then
    die "Missing FreeType include directory:

  $FREETYPE_INCLUDE"
fi

if [[ ! -d "$FREETYPE_INCLUDE2" ]]; then
    die "Missing FreeType freetype2 directory:

  $FREETYPE_INCLUDE2"
fi

if [[ ! -f "$FREETYPE_LIB/libfreetype.dylib" ]] &&
   [[ ! -f "$FREETYPE_LIB/libfreetype.a" ]]; then
    die "Missing FreeType library:

  $FREETYPE_LIB"
fi

echo "Include:"
echo "$FREETYPE_INCLUDE2"

echo
echo "Library:"
echo "$FREETYPE_LIB"

# ============================================================
# LLVM-MINGW
# ============================================================
section "Prebuilt LLVM-MinGW"

if [[ ! -d "$LLVM_MINGW_BIN" ]]; then
    die "LLVM-MinGW was not found:

  $LLVM_MINGW_BIN"
fi

CROSSCC="$LLVM_MINGW_BIN/aarch64-w64-mingw32-clang"
CROSSCXX="$LLVM_MINGW_BIN/aarch64-w64-mingw32-clang++"
DLLTOOL="$LLVM_MINGW_BIN/aarch64-w64-mingw32-dlltool"
AR="$LLVM_MINGW_BIN/aarch64-w64-mingw32-ar"
WINDRES="$LLVM_MINGW_BIN/aarch64-w64-mingw32-windres"

for tool in \
    "$CROSSCC" \
    "$CROSSCXX" \
    "$DLLTOOL" \
    "$AR" \
    "$WINDRES"
do
    if [[ ! -x "$tool" ]]; then
        die "Missing LLVM-MinGW tool:

  $tool"
    fi
done

echo "LLVM-MinGW:"
echo "$LLVM_MINGW_DIR"

echo
echo "AArch64 PE compiler:"
"$CROSSCC" --version | head -1

echo
echo "AArch64 PE C++ compiler:"
"$CROSSCXX" --version | head -1

# ============================================================
# LOCAL BUILD TOOL ALIASES
# ============================================================
section "Local build tools"

LOCAL_BIN="$LEMONADE_DIR/bin"

mkdir -p "$LOCAL_BIN"

ln -sfn "$PREBUILT_ENV/bin/m4" \
    "$LOCAL_BIN/m4"

ln -sfn "$PREBUILT_ENV/bin/flex" \
    "$LOCAL_BIN/flex"

ln -sfn "$PREBUILT_ENV/bin/bison" \
    "$LOCAL_BIN/bison"

ln -sfn "$CROSSCC" \
    "$LOCAL_BIN/aarch64-w64-mingw32-clang"

ln -sfn "$CROSSCXX" \
    "$LOCAL_BIN/aarch64-w64-mingw32-clang++"

ln -sfn "$DLLTOOL" \
    "$LOCAL_BIN/aarch64-w64-mingw32-dlltool"

ln -sfn "$AR" \
    "$LOCAL_BIN/aarch64-w64-mingw32-ar"

ln -sfn "$WINDRES" \
    "$LOCAL_BIN/aarch64-w64-mingw32-windres"

export PATH="$LOCAL_BIN:/usr/bin:/bin:/usr/sbin:/sbin"

# ============================================================
# Compiler command names
# ============================================================
CC="/usr/bin/cc"
CXX="/usr/bin/c++"

export CC
export CXX

export CROSSCC="aarch64-w64-mingw32-clang"
export CROSSCXX="aarch64-w64-mingw32-clang++"
export DLLTOOL="aarch64-w64-mingw32-dlltool"
export AR="aarch64-w64-mingw32-ar"
export WINDRES="aarch64-w64-mingw32-windres"

export M4="m4"
export FLEX="flex"
export BISON="bison"

# ============================================================
# NATIVE COMPILER TEST
#
# Arrays prevent Bash from splitting the paths containing
# "Visual Studio Code.app".
# ============================================================
section "Native compiler test"

TEST_DIR="$LEMONADE_DIR/compiler-test"

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

cat > "$TEST_DIR/test.c" <<'EOF'
int main(void)
{
    return 0;
}
EOF

NATIVE_CPPFLAGS=(
    "-I$FREETYPE_INCLUDE2"
    "-I$FREETYPE_INCLUDE"
)

NATIVE_LDFLAGS=(
    "-L$FREETYPE_LIB"
)

echo "Compiling native test..."

(
    cd "$TEST_DIR"

    "$CC" \
        "${NATIVE_CPPFLAGS[@]}" \
        "$TEST_DIR/test.c" \
        "${NATIVE_LDFLAGS[@]}" \
        -o "$TEST_DIR/test"
)

"$TEST_DIR/test"

rm -rf "$TEST_DIR"

echo "Native compiler test passed."

# ============================================================
# BUILD DIRECTORY
# ============================================================
section "Build directory"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Build:"
echo "$BUILD_DIR"

# ============================================================
# CREATE SPACE-FREE PATH ALIAS
# ============================================================
section "Space-free build alias"

if [[ -e "$PATH_ALIAS" || -L "$PATH_ALIAS" ]]; then
    rm -rf "$PATH_ALIAS"
fi

ln -s "$LEMONADE_DIR" "$PATH_ALIAS"

if [[ ! -L "$PATH_ALIAS" ]]; then
    die "Could not create temporary path alias:

  $PATH_ALIAS"
fi

echo "Alias:"
echo "  $PATH_ALIAS"

echo
echo "Real directory:"
echo "  $LEMONADE_DIR"

# ============================================================
# Configure through the space-free alias.
#
# The real files remain inside Visual Studio Code.app.
# ============================================================
section "Configure Lemonade"

SPACE_FREE_BUILD="$PATH_ALIAS/build-lemonade"
SPACE_FREE_SOURCE="$PATH_ALIAS/../"

cd "$SPACE_FREE_BUILD"

echo "Configure working directory:"
pwd

echo
echo "Source:"
echo "$SPACE_FREE_SOURCE"

# Relative dependency paths from the aliased build directory.
CONFIGURE_CPPFLAGS=(
    "-I../prebuilt-env/include/freetype2"
    "-I../prebuilt-env/include"
)

CONFIGURE_LDFLAGS=(
    "-L../prebuilt-env/lib"
)

CONFIGURE_FREETYPE_CFLAGS=(
    "-I../prebuilt-env/include/freetype2"
    "-I../prebuilt-env/include"
)

CONFIGURE_FREETYPE_LIBS=(
    "-L../prebuilt-env/lib"
    "-lfreetype"
)

echo
echo "FreeType CFLAGS:"
printf '  %s\n' "${CONFIGURE_FREETYPE_CFLAGS[@]}"

echo
echo "FreeType LIBS:"
printf '  %s\n' "${CONFIGURE_FREETYPE_LIBS[@]}"

../source/configure \
    --enable-win64 \
    CC="$CC" \
    CXX="$CXX" \
    CROSSCC="$CROSSCC" \
    CROSSCXX="$CROSSCXX" \
    DLLTOOL="$DLLTOOL" \
    AR="$AR" \
    WINDRES="$WINDRES" \
    M4="$M4" \
    FLEX="$FLEX" \
    BISON="$BISON" \
    CPPFLAGS="-I../prebuilt-env/include/freetype2 -I../prebuilt-env/include" \
    LDFLAGS="-L../prebuilt-env/lib" \
    FREETYPE_CFLAGS="-I../prebuilt-env/include/freetype2 -I../prebuilt-env/include" \
    FREETYPE_LIBS="-L../prebuilt-env/lib -lfreetype"

# ============================================================
# BUILD
#
# top_builddir keeps the dependency paths valid in recursive
# Wine make directories.
# ============================================================
section "Build Lemonade"

make -j"$JOBS" \
    'CPPFLAGS=-I$(top_builddir)/../prebuilt-env/include/freetype2 -I$(top_builddir)/../prebuilt-env/include' \
    'LDFLAGS=-L$(top_builddir)/../prebuilt-env/lib' \
    'FREETYPE_CFLAGS=-I$(top_builddir)/../prebuilt-env/include/freetype2 -I$(top_builddir)/../prebuilt-env/include' \
    'FREETYPE_LIBS=-L$(top_builddir)/../prebuilt-env/lib -lfreetype'

# ============================================================
# INSTALL
# ============================================================
section "Install"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

make install \
    prefix=/wine \
    DESTDIR="$STAGE_DIR"

if [[ ! -d "$STAGE_DIR/wine" ]]; then
    die "Installation failed; expected:

  $STAGE_DIR/wine"
fi

# ============================================================
# PACKAGE APP
# ============================================================
section "Package Lemonade.app"

rm -rf "$APP_DIR"

mkdir -p \
    "$APP_DIR/Contents/MacOS" \
    "$APP_DIR/Contents/Resources"

cp -R \
    "$STAGE_DIR/wine" \
    "$APP_DIR/Contents/Resources/wine"

# ============================================================
# LAUNCHER
# ============================================================
cat > "$APP_DIR/Contents/MacOS/Lemonade" <<'EOF'
#!/bin/bash
set -e

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WINE_ROOT="$APP_ROOT/Resources/wine"

export WINEPREFIX="${WINEPREFIX:-"$HOME/Library/Application Support/Lemonade"}"

if [[ -x "$WINE_ROOT/bin/wine" ]]; then
    exec "$WINE_ROOT/bin/wine" "$@"
fi

if [[ -x "$WINE_ROOT/bin/wine64" ]]; then
    exec "$WINE_ROOT/bin/wine64" "$@"
fi

echo "Lemonade: Wine executable not found."
exit 1
EOF

chmod +x "$APP_DIR/Contents/MacOS/Lemonade"

# ============================================================
# INFO.PLIST
# ============================================================
cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>

    <key>CFBundleExecutable</key>
    <string>Lemonade</string>

    <key>CFBundleIdentifier</key>
    <string>com.darealcoolgaming.lemonade</string>

    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>

    <key>CFBundleName</key>
    <string>Lemonade</string>

    <key>CFBundleDisplayName</key>
    <string>Lemonade</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleShortVersionString</key>
    <string>11.17</string>

    <key>CFBundleVersion</key>
    <string>11.17</string>

    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
</dict>
</plist>
EOF

# ============================================================
# CODE SIGN
# ============================================================
section "Code signing"

if [[ -x "/usr/bin/codesign" ]]; then
    /usr/bin/codesign \
        --force \
        --deep \
        --sign "$SIGNING_IDENTITY" \
        "$APP_DIR"
fi

# ============================================================
# COMPLETE
# ============================================================
section "Build complete"

echo "Lemonade.app:"
echo "  $APP_DIR"

echo
echo "Build directory:"
echo "  $BUILD_DIR"

echo
echo "Dependency environment:"
echo "  $PREBUILT_ENV"