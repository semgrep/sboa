#!/bin/sh
# fetch.sh TARGET MANIFEST OUT_DIR [WORKSPACE_ROOT]
#
# Provides the CPython that pyembed embeds, for the OCaml target TARGET
# (dune's %{ocaml-config:target}: x86_64-pc-linux-gnu,
# x86_64-alpine-linux-musl, aarch64-apple-darwin24.0.0, x86_64-w64-mingw32...),
# and describes it in OUT_DIR/cpython-embed.config. Run by the rule in ./dune;
# nothing here is specific to an application.
#
# Two modes:
#
# 1. Default: the python-build-standalone archive that MANIFEST (pbs.json)
#    pins for TARGET. The archive is looked up in, or downloaded into, a cache
#    directory, and its sha256 is checked against the manifest before it is
#    used (a cached file with the wrong sha256 is downloaded again). The cache
#    directory is $PYEMBED_ARCHIVE_DIR if set (offline builds: put the archive
#    there), else toolchain/cache/ in the source tree (git-ignored, kept across
#    `dune clean`, cached by CI), found through dune's DUNE_SOURCEROOT and
#    WORKSPACE_ROOT (%{workspace_root}), else cache/ next to this script.
#    The archive is unpacked and the files the build needs are staged under
#    OUT_DIR/prefix (unix; Windows keeps the archive's layout):
#
#      include/python3.13/        C headers
#      lib/libpython3.13.so.1.0   shared library (.dylib on macOS)
#      lib/python3.13/            stdlib sources, empty lib-dynload/
#      bin/python3.13             interpreter (build time only)
#      LICENSE.txt                PSF licence
#
# 2. PYEMBED_PREFIX=<prefix of an installed CPython 3.13>: nothing is
#    downloaded or copied; the config points into that prefix (a Homebrew
#    formula builds against brew's python@3.13, which is
#    $(brew --prefix python@3.13)/Frameworks/Python.framework/Versions/3.13;
#    any CPython 3.13 built with a shared libpython works). The directories
#    are asked of its interpreter (sysconfig). runtime_files is empty: the
#    executables find libpython through the absolute rpath to the prefix's
#    libdir that probe.sh adds. Unix layouts only. OUT_DIR/prefix only holds
#    EXTERNAL, a note naming the prefix (dune rejects empty directory targets).
#
# cpython-embed.config is one sexp, a list of (field value) pairs, with
# absolute forward-slash paths; see ../README.md for the fields.
#
# POSIX sh and standard tools only: curl or wget, sha256sum or shasum, tar,
# sed, tr, find. CPYTHON_EMBED_MAGIC overrides the bytecode magic number
# (only needed when the interpreter cannot run on the build machine).
set -eu

die() {
  echo "fetch.sh: $*" >&2
  exit 1
}

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
  echo "usage: $0 TARGET MANIFEST OUT_DIR [WORKSPACE_ROOT]" >&2
  exit 2
fi
target=$1
manifest=$2
out=$3
wsroot=${4:-}
[ -f "$manifest" ] || die "no manifest $manifest"
mkdir -p "$out"

# Absolute path with forward slashes: Cygwin paths become C:/... (what
# mingw gcc, dune and CPython expect on Windows).
abspath() {
  p=$(cd "$1" && pwd -P)
  if command -v cygpath >/dev/null 2>&1; then
    p=$(cygpath -m "$p")
  fi
  printf '%s' "$p"
}

# --- manifest ----------------------------------------------------------------
# JSON without a JSON parser: flatten the file and cut it at every '}', so
# each target's object ends up on one line, whatever the formatting.
flat=$(tr '\r\n' '  ' <"$manifest" | tr '}' '\n')
# field TEXT KEY: the string value of "KEY": "..." in TEXT
field() {
  printf '%s\n' "$1" |
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

# OCaml target triple -> manifest key (python-build-standalone triple).
case "$target" in
  x86_64-*linux-musl*) key=x86_64-unknown-linux-musl ;;
  aarch64-*linux-musl* | arm64-*linux-musl*) key=aarch64-unknown-linux-musl ;;
  x86_64-*linux*) key=x86_64-unknown-linux-gnu ;;
  aarch64-*linux* | arm64-*linux*) key=aarch64-unknown-linux-gnu ;;
  x86_64-*darwin*) key=x86_64-apple-darwin ;;
  aarch64-*darwin* | arm64-*darwin*) key=aarch64-apple-darwin ;;
  x86_64-*mingw* | x86_64-*windows* | x86_64-*cygwin*) key=x86_64-pc-windows-msvc ;;
  *) die "no CPython archive for the OCaml target '$target'" ;;
esac
entry=$(printf '%s\n' "$flat" | grep "\"$key\"[[:space:]]*:[[:space:]]*{" | head -n 1 |
  sed "s/.*\"$key\"//")
[ -n "$entry" ] || die "$manifest has no entry for $key"
platform=$(field "$entry" platform)
file=$(field "$entry" file)
sha=$(field "$entry" sha256)
url_base=$(field "$flat" url_base)
version=$(field "$flat" python_version)
[ -n "$platform" ] && [ -n "$file" ] && [ -n "$sha" ] && [ -n "$url_base" ] &&
  [ -n "$version" ] || die "incomplete entry for $key in $manifest"
pyver=$(printf '%s' "$version" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/')
pyver_nodot=$(printf '%s' "$pyver" | tr -d .)

case "$platform" in
  linux-*) kind=elf ;;
  macos-*) kind=macho ;;
  windows-*) kind=windows ;;
  *) die "unknown platform '$platform' in $manifest" ;;
esac

rm -rf "$out/prefix" "$out/cpython-embed.config"
mkdir -p "$out/prefix"

write_config() { # write_config RUNTIME_FILES (incdir etc. are globals)
  cat >"$out/cpython-embed.config" <<CONFIG
((version "$version")
 (platform "$platform")
 (magic $magic)
 (prefix "$final")
 (incdir "$incdir")
 (libdir "$libdir")
 (lib_name "$lib_name")
 (lib_file "$lib_file")
 (stdlib_dir "$stdlib_dir")
 (libdynload_dir "$libdynload_dir")
 (python_exe "$python_exe")
 (runtime_subdir "$runtime_subdir")
 (runtime_libdynload "$runtime_libdynload")
 (runtime_files ($1
 )))
CONFIG
}

magic_of() { # magic_of PYTHON
  if [ -n "${CPYTHON_EMBED_MAGIC:-}" ]; then
    echo "$CPYTHON_EMBED_MAGIC"
  else
    "$1" -I -B -c 'import importlib.util as u; print(int.from_bytes(u.MAGIC_NUMBER[:2], "little"))'
  fi
}

# --- mode 2: an installed CPython --------------------------------------------
if [ -n "${PYEMBED_PREFIX:-}" ]; then
  [ "$kind" != windows ] || die "PYEMBED_PREFIX is not supported on Windows"
  final=$(abspath "$PYEMBED_PREFIX")
  python_exe=$final/bin/python$pyver
  [ -x "$python_exe" ] || die "no $python_exe"
  query() { "$python_exe" -I -B -c "$1"; }
  version=$(query 'import platform; print(platform.python_version())')
  case "$version" in
    "$pyver".*) ;;
    *) die "need CPython $pyver.x, $python_exe is $version" ;;
  esac
  incdir=$(query 'import sysconfig; print(sysconfig.get_path("include"))')
  stdlib_dir=$(query 'import sysconfig; print(sysconfig.get_path("stdlib"))')
  # LIBDIR is baked in at the CPython build (wrong for a relocated tree such
  # as python-build-standalone's), so look in PREFIX/lib first.
  case "$kind" in
    macho) shlib=libpython$pyver.dylib ;;
    *) shlib=libpython$pyver.so ;;
  esac
  libdir=$final/lib
  [ -e "$libdir/$shlib" ] ||
    libdir=$(query 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))')
  lib_file=$libdir/$shlib
  [ -f "$incdir/Python.h" ] || die "no $incdir/Python.h"
  [ -e "$lib_file" ] ||
    die "no $lib_file: the CPython must be built with a shared libpython"
  lib_name=python$pyver
  libdynload_dir=$stdlib_dir/lib-dynload
  runtime_subdir=libs
  runtime_libdynload=
  magic=$(magic_of "$python_exe")
  write_config ""
  echo "$final" >"$out/prefix/EXTERNAL"
  echo "fetch.sh: $out/cpython-embed.config for $python_exe ($version, $platform)"
  exit 0
fi

# --- mode 1: the pinned archive ----------------------------------------------
if [ -n "${PYEMBED_ARCHIVE_DIR:-}" ]; then
  cache=$PYEMBED_ARCHIVE_DIR
elif [ -n "${DUNE_SOURCEROOT:-}" ] && [ -n "$wsroot" ]; then
  # The rule runs in <build context>/<dir>; the cache lives in <source>/<dir>.
  src_root=$DUNE_SOURCEROOT
  if command -v cygpath >/dev/null 2>&1; then
    src_root=$(cygpath -u "$src_root")
  fi
  ws=$(cd "$wsroot" && pwd -P)
  here=$(cd "$out" && pwd -P)
  rel=${here#"$ws"}
  cache=$src_root$rel/cache
else
  cache=$(dirname "$0")/cache
fi
mkdir -p "$cache"
archive=$cache/$file

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | sed 's/[^0-9a-f].*//'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | sed 's/[^0-9a-f].*//'
  else
    die "need sha256sum or shasum"
  fi
}

tmp=$archive.part.$$
work=$out/prefix.unpack
cleanup() { rm -rf "$tmp" "$work"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ -f "$archive" ] && [ "$(sha256_of "$archive")" = "$sha" ]; then
  echo "fetch.sh: using $archive"
else
  # '+' must be percent-encoded in the release asset URL.
  url=$url_base/$(printf '%s' "$file" | sed 's/+/%2B/g')
  echo "fetch.sh: downloading $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$tmp" "$url" || die "download failed: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp" "$url" || die "download failed: $url"
  else
    die "need curl or wget to download $url (or set PYEMBED_ARCHIVE_DIR)"
  fi
  got=$(sha256_of "$tmp")
  [ "$got" = "$sha" ] || die "sha256 mismatch for $url: got $got, expected $sha"
  mv -f "$tmp" "$archive"
fi

rm -rf "$work"
mkdir -p "$work"
tar -xzf "$archive" -C "$work"
src=$work/python
[ -d "$src" ] || die "$archive does not contain python/"
stage=$out/prefix
final=$(abspath "$stage")

# --- stage the tree ----------------------------------------------------------
# Dropped: site-packages (pip), Tcl/Tk, man pages, terminfo, the
# pip/idle/pydoc launchers and the *-config scripts.
case "$kind" in
  elf | macho)
    mkdir -p "$stage/bin" "$stage/lib"
    mv "$src/include" "$stage/include"
    mv "$src/bin/python$pyver" "$stage/bin/python$pyver"
    case "$kind" in
      # Only the SONAME file: consumers link by full path (lib_file).
      elf) shlib=libpython$pyver.so.1.0 ;;
      macho) shlib=libpython$pyver.dylib ;;
    esac
    mv "$src/lib/$shlib" "$stage/lib/"
    mv "$src/lib/python$pyver" "$stage/lib/python$pyver"
    # pbs compiles the stdlib extensions into libpython; lib-dynload only
    # holds _dbm and _tkinter, which are not shipped (keep the directory).
    find "$stage/lib/python$pyver/lib-dynload" -name '*.so' -exec rm -f {} +
    rm -rf "$stage/lib/python$pyver/site-packages"
    incdir=$final/include/python$pyver
    libdir=$final/lib
    lib_name=python$pyver
    lib_file=$final/lib/$shlib
    stdlib_dir=$final/lib/python$pyver
    libdynload_dir=$final/lib/python$pyver/lib-dynload
    python_exe=$final/bin/python$pyver
    license_src=$stage/lib/python$pyver/LICENSE.txt
    runtime_subdir=libs
    runtime_libdynload=python$pyver/lib-dynload
    ;;
  windows)
    # python.exe, python3XY.dll, python3.dll, vcruntime*.dll side by side;
    # Lib/, DLLs/, include/, libs/python3XY.lib (MSVC import library).
    for d in include libs DLLs Lib; do
      mv "$src/$d" "$stage/$d"
    done
    for f in python.exe "python$pyver_nodot.dll" python3.dll vcruntime140.dll vcruntime140_1.dll; do
      mv "$src/$f" "$stage/$f"
    done
    rm -rf "$stage/Lib/site-packages"
    incdir=$final/include
    libdir=$final/libs
    lib_name=python$pyver_nodot
    lib_file=$final/libs/python$pyver_nodot.lib
    stdlib_dir=$final/Lib
    libdynload_dir=$final/DLLs
    python_exe=$final/python.exe
    license_src=$src/LICENSE.txt
    runtime_subdir=
    runtime_libdynload=
    ;;
esac
find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} +
cp "$license_src" "$stage/LICENSE.txt"
rm -rf "$work"

# --- runtime files -----------------------------------------------------------
# What must sit next to the final executable: (absolute source, destination
# relative to bin/<runtime_subdir>/). Tk is not shipped, so _tkinter and the
# Tcl/Tk DLLs are left out, and so are CPython's test extension modules.
# COUPLING: the Windows list is spelled out in ../runtime/runtime_files.dune.inc.
runtime=
add_runtime() {
  runtime="$runtime
  (\"$1\" \"$2\")"
}
case "$kind" in
  elf | macho)
    add_runtime "$final/lib/$shlib" "$shlib"
    ;;
  windows)
    for f in "python$pyver_nodot.dll" python3.dll vcruntime140.dll vcruntime140_1.dll; do
      add_runtime "$final/$f" "$f"
    done
    for f in "$stage/DLLs"/*.pyd "$stage/DLLs"/*.dll; do
      [ -e "$f" ] || continue
      b=$(basename "$f")
      case "$b" in
        _tkinter.* | tcl*.dll | tk*.dll | _test*.pyd | xxlimited*.pyd | _ctypes_test.pyd) continue ;;
      esac
      add_runtime "$final/DLLs/$b" "$b"
    done
    ;;
esac

if [ "$kind" = windows ]; then
  magic=$(magic_of "$stage/python.exe")
else
  magic=$(magic_of "$stage/bin/python$pyver")
fi
write_config "$runtime"
echo "fetch.sh: CPython $version ($platform) in $final"
