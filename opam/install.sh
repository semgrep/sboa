#!/bin/sh
# install.sh PLATFORM ARCHIVE STAGE FINAL_PREFIX
#
# Shared build step of every cpython-embed-<platform> opam package.
#
# Unpacks a python-build-standalone `install_only_stripped` archive (already
# downloaded and sha256-verified by opam through `extra-source`) and lays out
# the files the rest of the build needs under STAGE.  STAGE is later installed
# by opam, through `lib_root` in <package>.install, as
# `%{lib}%/cpython-embed/` -- the same path for every platform child -- so
# FINAL_PREFIX (= `%{lib}%/cpython-embed`) is what ends up in the config file.
#
# Layout after install (unix; Windows keeps the archive's layout instead):
#   include/python3.13/        C headers
#   lib/libpython3.13.so.1.0   shared library (.dylib on macOS), single copy
#   lib/python3.13/            stdlib sources, empty lib-dynload/ (build time only)
#   bin/python3.13             interpreter (build time only)
#   LICENSE.txt                PSF license
#   cpython-embed.config       sexp read by pyembed's dune rules
#   META                       findlib stub so %{lib:cpython-embed:...} works
#
# Nothing here is semgrep specific.  Stdlib only: sh, tar, find, cp, sed.
set -eu

if [ $# -ne 4 ]; then
  echo "usage: $0 PLATFORM ARCHIVE STAGE FINAL_PREFIX" >&2
  exit 2
fi
platform=$1
archive=$2
stage=$3
final=$4

version=3.13.16
pyver=3.13

case "$platform" in
  linux-gnu-x86_64 | linux-gnu-aarch64 | linux-musl-x86_64 | linux-musl-aarch64)
    kind=elf
    ;;
  macos-x86_64 | macos-arm64)
    kind=macho
    ;;
  windows-x86_64)
    kind=windows
    ;;
  *)
    echo "install.sh: unknown platform '$platform'" >&2
    exit 2
    ;;
esac

work=./unpack
rm -rf "$work" "$stage"
mkdir -p "$work" "$stage"
tar -xzf "$archive" -C "$work"
src=$work/python
if [ ! -d "$src" ]; then
  echo "install.sh: archive does not contain python/" >&2
  exit 1
fi

# --- copy the tree -----------------------------------------------------------
# We drop what is never needed: site-packages (pip), Tcl/Tk, man pages,
# terminfo, the pip/idle/pydoc launchers and the *-config scripts.
case "$kind" in
  elf | macho)
    mkdir -p "$stage/bin" "$stage/lib"
    cp -RP "$src/include" "$stage/include"
    cp -P "$src/bin/python$pyver" "$stage/bin/python$pyver"
    case "$kind" in
      elf)
        shlib=libpython$pyver.so.1.0
        # Only the SONAME file is installed: the unversioned libpython3.13.so
        # is a symlink upstream and opam would copy it as a second copy.
        # Consumers link by full path (config field lib_file).
        cp -P "$src/lib/libpython$pyver.so.1.0" "$stage/lib/"
        ;;
      macho)
        shlib=libpython$pyver.dylib
        cp -P "$src/lib/libpython$pyver.dylib" "$stage/lib/"
        ;;
    esac
    cp -RP "$src/lib/python$pyver" "$stage/lib/python$pyver"
    # pbs compiles the stdlib extensions into libpython; lib-dynload only
    # holds _dbm and _tkinter, which we do not ship (keep the directory).
    find "$stage/lib/python$pyver/lib-dynload" -name '*.so' -exec rm -f {} +
    rm -rf "$stage/lib/python$pyver/site-packages"
    find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} +
    incdir=$final/include/python$pyver
    libdir=$final/lib
    lib_name=python$pyver
    lib_file=$final/lib/$shlib
    stdlib_dir=$final/lib/python$pyver
    libdynload_dir=$final/lib/python$pyver/lib-dynload
    python_exe=$final/bin/python$pyver
    license_src=$src/lib/python$pyver/LICENSE.txt
    runtime_subdir=libs
    runtime_libdynload=python$pyver/lib-dynload
    ;;
  windows)
    # python-build-standalone Windows layout: python.exe, python313.dll,
    # python3.dll, vcruntime*.dll next to each other; Lib/, DLLs/, include/,
    # libs/python313.lib (MSVC import library).
    cp -RP "$src/include" "$stage/include"
    cp -RP "$src/libs" "$stage/libs"
    cp -RP "$src/DLLs" "$stage/DLLs"
    cp -RP "$src/Lib" "$stage/Lib"
    for f in python.exe python313.dll python3.dll vcruntime140.dll vcruntime140_1.dll; do
      cp -P "$src/$f" "$stage/$f"
    done
    rm -rf "$stage/Lib/site-packages"
    find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} +
    incdir=$final/include
    libdir=$final/libs
    lib_name=python313
    lib_file=$final/libs/python313.lib
    stdlib_dir=$final/Lib
    libdynload_dir=$final/DLLs
    python_exe=$final/python.exe
    license_src=$src/LICENSE.txt
    runtime_subdir=
    runtime_libdynload=
    ;;
esac
cp "$license_src" "$stage/LICENSE.txt"

# --- runtime files -----------------------------------------------------------
# Exactly what must sit next to the final binary: the shared library (unix) or
# the DLLs and extension modules (Windows).  Each entry is (absolute source, destination relative to
# bin/<runtime_subdir>/).  Tk is not shipped, so _tkinter (and the Tcl/Tk
# DLLs) are left out; so are the CPython test extension modules on Windows.
runtime=
add_runtime() {
  runtime="$runtime
  (\"$1\" \"$2\")"
}
case "$kind" in
  elf | macho)
    # The shared library only (no lib-dynload extensions to ship).
    add_runtime "$final/lib/$shlib" "$shlib"
    ;;
  windows)
    for f in python313.dll python3.dll vcruntime140.dll vcruntime140_1.dll; do
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

# --- magic number ------------------------------------------------------------
# importlib's bytecode magic (first two bytes, little endian) of the unpacked
# interpreter, so that bundlers can check .pyc compatibility.  The environment
# variable is a testing escape hatch for inspecting other platforms' archives
# on a machine that cannot run their interpreter.
if [ "$kind" = windows ]; then
  exe=$stage/python.exe
else
  exe=$stage/bin/python$pyver
fi
magic=${CPYTHON_EMBED_MAGIC:-$("$exe" -I -B -c 'import importlib.util as u; print(int.from_bytes(u.MAGIC_NUMBER[:2], "little"))')}

# --- config ------------------------------------------------------------------
# Schema documented in docs/single-binary/notes/u2.md.
cat >"$stage/cpython-embed.config" <<CONFIG
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
 (runtime_files ($runtime
 )))
CONFIG

# --- findlib stub ------------------------------------------------------------
cat >"$stage/META" <<META
description = "CPython $version runtime (python-build-standalone) for pyembed"
version = "$version"
requires = ""
META

# --- .install ----------------------------------------------------------------
# lib_root / libexec_root install relative to the switch's lib/ directory, so
# every platform child lands in lib/cpython-embed/ (they are mutually
# exclusive).  opam's .install format has no directory entries, hence one
# entry per file.  libexec_root keeps the executable bit, which the
# interpreter, shared libraries and extension modules need; opam copies a
# symlink as a regular file, so libpython3.13.so is a second copy of the
# library (needed so that -lpython3.13 resolves).
pkg=cpython-embed-$platform
list=./files.list
find "$stage" \( -type f -o -type l \) | LC_ALL=C sort >"$list"
emit() { # emit SECTION GLOB-MATCHES-EXEC(0|1)
  echo "$1: ["
  while IFS= read -r f; do
    rel=${f#"$stage"/}
    case "$rel" in
      bin/* | lib/*.so | lib/*.so.* | lib/*.dylib | */lib-dynload/*.so | *.exe | *.dll | *.pyd)
        is_exec=1 ;;
      *) is_exec=0 ;;
    esac
    if [ "$is_exec" = "$2" ]; then
      echo "  \"$f\" {\"cpython-embed/$rel\"}"
    fi
  done <"$list"
  echo "]"
}
{
  emit lib_root 0
  emit libexec_root 1
} >"./$pkg.install"
