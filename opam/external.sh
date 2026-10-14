#!/bin/sh
# external.sh PREFIX [DIR]
#
# Stand-in for the cpython-embed opam package when the CPython to embed is NOT
# the python-build-standalone one that the package downloads, but a CPython 3.13
# installed on the build machine: the Homebrew formula builds semgrep against
# brew's python@3.13 (Homebrew forbids downloading prebuilt binaries), and the
# same works on Linux with any CPython 3.13 built with a shared libpython.
#
# It only writes metadata, it copies nothing from PREFIX: DIR (default
# `$(opam var lib)/cpython-embed`, where %{lib:cpython-embed:...} looks) gets
#
#   cpython-embed.config   the same sexp as the package's (see install.sh and
#                          docs/single-binary/notes/u2.md), pointing into PREFIX
#   META                   findlib stub, so the package counts as available
#
# `runtime_files` is empty: there is no libpython to ship next to the binary,
# the executables find it through the absolute rpath to PREFIX's libdir that
# probe.sh adds at link time (a Homebrew formula installs `bin/semgrep` only and
# depends on python@3.13).  `make core` still produces an (empty but for the
# licence notices) bin/libs, which is not installed by the formula.
#
# PREFIX is the CPython install tree: PREFIX/bin/python3.13, include/python3.13,
# lib/libpython3.13.{so,dylib}.  On macOS that is the Framework version
# directory, `$(brew --prefix python@3.13)/Frameworks/Python.framework/Versions/3.13`.
# The directories are asked of the interpreter (sysconfig), not guessed.
#
# This only needs sh and the interpreter.  Use:
#
#   sh libs/pyembed/opam/external.sh "$PREFIX"            # into the opam switch
#   sh libs/pyembed/opam/external.sh "$PREFIX" /some/dir  # elsewhere, then
#   PYEMBED_CONFIG=/some/dir/cpython-embed.config make ...
set -eu

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: $0 PREFIX [DIR]" >&2
  exit 2
fi
prefix=$1
pyver=3.13
exe=$prefix/bin/python$pyver
[ -x "$exe" ] || { echo "external.sh: no $exe" >&2; exit 1; }
out=${2:-$(opam var lib)/cpython-embed}

query() { "$exe" -I -B -c "$1"; }

version=$(query 'import platform; print(platform.python_version())')
case "$version" in
  3.13.*) ;;
  *) echo "external.sh: need CPython 3.13.x, $exe is $version" >&2; exit 1 ;;
esac
incdir=$(query 'import sysconfig; print(sysconfig.get_path("include"))')
stdlib=$(query 'import sysconfig; print(sysconfig.get_path("stdlib"))')
# LIBDIR is baked in at the CPython build (wrong for a relocated tree such as
# python-build-standalone's), so look in PREFIX/lib first.
libdir=$prefix/lib
case "$(uname -s)" in
  Darwin) shlib=libpython$pyver.dylib ;;
  *) shlib=libpython$pyver.so ;;
esac
[ -e "$libdir/$shlib" ] ||
  libdir=$(query 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))')
magic=$(query 'import importlib.util as u; print(int.from_bytes(u.MAGIC_NUMBER[:2], "little"))')
lib_file=$libdir/$shlib
[ -f "$incdir/Python.h" ] || { echo "external.sh: no $incdir/Python.h" >&2; exit 1; }
[ -e "$lib_file" ] || {
  echo "external.sh: no $lib_file: the CPython must be built with a shared libpython" >&2
  exit 1
}

# The platform id selects the marker environment of the bundled wheels
# (pyembed_bundle.py), so it must be one of the package children's ids.
arch=$(uname -m)
case "$arch" in
  arm64 | aarch64) arch_id=aarch64; mac_arch=arm64 ;;
  *) arch_id=x86_64; mac_arch=x86_64 ;;
esac
case "$(uname -s)" in
  Darwin) platform=macos-$mac_arch ;;
  *)
    if [ -e /etc/alpine-release ]; then libc=musl; else libc=gnu; fi
    platform=linux-$libc-$arch_id
    ;;
esac

mkdir -p "$out"
cat >"$out/cpython-embed.config" <<CONFIG
((version "$version")
 (platform "$platform")
 (magic $magic)
 (prefix "$prefix")
 (incdir "$incdir")
 (libdir "$libdir")
 (lib_name "python$pyver")
 (lib_file "$lib_file")
 (stdlib_dir "$stdlib")
 (libdynload_dir "$stdlib/lib-dynload")
 (python_exe "$exe")
 (runtime_subdir "libs")
 (runtime_libdynload "")
 (runtime_files ()))
CONFIG
cat >"$out/META" <<META
description = "CPython $version (external install, $prefix) for pyembed"
version = "$version"
requires = ""
META
echo "external.sh: wrote $out/cpython-embed.config for $exe ($version)"
