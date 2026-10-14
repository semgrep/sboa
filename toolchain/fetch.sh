#!/bin/sh
# fetch.sh TARGET MANIFEST OUT_DIR [WORKSPACE_ROOT]
#
# Provides the CPython that pyembed embeds, for the OCaml target TARGET
# (dune's %{ocaml-config:target}: x86_64-pc-linux-gnu,
# x86_64-alpine-linux-musl, aarch64-apple-darwin24.0.0, x86_64-w64-mingw32...),
# and describes it in OUT_DIR/cpython-embed.config and
# OUT_DIR/pyembed_toolchain_data.ml. Run by the rule in ./dune; nothing here
# is specific to an application.
#
# Two modes:
#
# 1. Default: the python-build-standalone archive that MANIFEST (pbs.json)
#    pins for TARGET. The archive is looked up in, or downloaded into, a cache
#    directory; a private copy of it is checked against the manifest's sha256
#    and only that copy is unpacked (a cached file with the wrong sha256 is
#    reported and downloaded again). The cache directory is
#    $PYEMBED_ARCHIVE_DIR if set (an absolute path; offline builds: put the
#    archive there), else toolchain/cache/ in the source tree (git-ignored,
#    kept across `dune clean`, cached by CI), found through dune's
#    DUNE_SOURCEROOT and WORKSPACE_ROOT (%{workspace_root}); run by hand
#    (no WORKSPACE_ROOT), cache/ next to this script. The files the build
#    needs are staged under OUT_DIR/prefix (unix; Windows keeps the archive's
#    layout):
#
#      include/python3.13/        C headers
#      lib/libpython3.13.so.1.0   shared library (.dylib on macOS)
#      lib/python3.13/            stdlib sources, empty lib-dynload/
#      bin/python3.13             interpreter (build time only)
#      LICENSE.txt                PSF licence
#
# 2. PYEMBED_PREFIX=<absolute prefix of an installed CPython 3.13>: nothing
#    is downloaded or copied; the config points into that prefix (a Homebrew
#    formula builds against brew's python@3.13, which is
#    $(brew --prefix python@3.13)/Frameworks/Python.framework/Versions/3.13;
#    any CPython 3.13 built with a shared libpython, without free threading
#    or Py_DEBUG, works). The directories are asked of its interpreter
#    (sysconfig). runtime_files is empty: the executables find libpython
#    through the absolute rpath to the prefix's libdir that probe.sh adds, and
#    the prefix's lib-dynload (C extension modules that such builds do not
#    compile into libpython) is recorded as external_libdynload_dir, which
#    pyembed.toolchain bakes into the executable as the fallback extension
#    directory. Unix layouts only. OUT_DIR/prefix only holds EXTERNAL, a note
#    naming the prefix (dune rejects empty directory targets).
#
# cpython-embed.config is one sexp, a list of (field value) pairs, with
# absolute forward-slash paths; see ../README.md for the fields. It also
# identifies what it describes (mode 1: release and archive_sha256; mode 2:
# install_fingerprint), so that a manifest bump or a changed external install
# changes the file and dune re-runs every rule that depends on it.
#
# POSIX sh and standard tools only: curl or wget (GNU or busybox), sha256sum or
# shasum, tar, sed, tr, find. CPYTHON_EMBED_MAGIC overrides the bytecode magic
# number (only needed when the interpreter cannot run on the build machine).
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

is_absolute() {
  case "$1" in
    /* | [A-Za-z]:/* | [A-Za-z]:\\*) return 0 ;;
    *) return 1 ;;
  esac
}
for v in PYEMBED_ARCHIVE_DIR PYEMBED_PREFIX; do
  eval "val=\${$v:-}"
  # shellcheck disable=SC2154 # set by the eval
  if [ -n "$val" ] && ! is_absolute "$val"; then
    die "$v must be an absolute path (it is resolved inside dune's build directory), got '$val'"
  fi
done

# The hash tool, checked up front (a failure inside $(...) would only end
# the subshell). Hashing stdin keeps the file name out of the output: GNU
# sha256sum escapes names containing a backslash with a leading '\'.
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum <"$1" | sed 's/[^0-9a-f].*//'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 <"$1" | sed 's/[^0-9a-f].*//'; }
else
  die "need sha256sum or shasum"
fi
sha256_checked() { # sha256_checked FILE: the hash, or die
  h=$(sha256_of "$1")
  [ -n "$h" ] || die "could not compute the sha256 of $1"
  printf '%s' "$h"
}

mkdir -p "$out"

# Absolute path with forward slashes: Cygwin paths become C:/... (what
# mingw gcc, dune and CPython expect on Windows). abspath_logical keeps
# symlinks (a Homebrew opt/ path stays valid across upgrades).
abspath() {
  p=$(cd "$1" && pwd -P)
  if command -v cygpath >/dev/null 2>&1; then
    p=$(cygpath -m "$p")
  fi
  printf '%s' "$p"
}
abspath_logical() {
  p=$(cd "$1" && pwd)
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
release=$(field "$flat" release)
if [ -z "$platform" ] || [ -z "$file" ] || [ -z "$sha" ] || [ -z "$url_base" ] ||
   [ -z "$version" ] || [ -z "$release" ]; then
  die "incomplete entry for $key in $manifest"
fi
case "$url_base" in
  https://*) ;;
  *) die "url_base must be an https:// URL, got '$url_base'" ;;
esac
pyver=$(printf '%s' "$version" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/')
pyver_nodot=$(printf '%s' "$pyver" | tr -d .)

case "$platform" in
  linux-*) kind=elf ;;
  macos-*) kind=macho ;;
  windows-*) kind=windows ;;
  *) die "unknown platform '$platform' in $manifest" ;;
esac

rm -rf "$out/prefix" "$out/cpython-embed.config" "$out/pyembed_toolchain_data.ml"
mkdir -p "$out/prefix"

# Values go into a sexp and an OCaml string literal, read by sed-based
# readers: refuse the characters none of them escapes.
check_value() { # check_value NAME VALUE
  case "$2" in
    *'"'* | *')'* | *\\*)
      die "$1 contains '\"', ')' or a backslash, which the config cannot carry: $2" ;;
  esac
}

write_config() { # write_config IDENTITY RUNTIME_FILES (the rest are globals)
  for v in prefix:"$final" incdir:"$incdir" libdir:"$libdir" lib_file:"$lib_file" \
    stdlib_dir:"$stdlib_dir" libdynload_dir:"$libdynload_dir" python_exe:"$python_exe" \
    external_libdynload_dir:"$external_libdynload_dir"; do
    check_value "${v%%:*}" "${v#*:}"
  done
  cat >"$out/cpython-embed.config" <<CONFIG
((version "$version")
 (platform "$platform")
 (magic $magic)
$1
 (prefix "$final")
 (incdir "$incdir")
 (libdir "$libdir")
 (lib_name "$lib_name")
 (lib_file "$lib_file")
 (stdlib_dir "$stdlib_dir")
 (libdynload_dir "$libdynload_dir")
 (external_libdynload_dir "$external_libdynload_dir")
 (python_exe "$python_exe")
 (runtime_subdir "$runtime_subdir")
 (runtime_libdynload "$runtime_libdynload")
 (runtime_files ($2
 )))
CONFIG
  # Read by pyembed.toolchain (toolchain/pyembed_toolchain.ml).
  if [ -n "$external_libdynload_dir" ]; then
    ext="Some \"$external_libdynload_dir\""
  else
    ext=None
  fi
  cat >"$out/pyembed_toolchain_data.ml" <<ML
(* Generated by toolchain/fetch.sh from cpython-embed.config. *)
let version = "$version"
let platform = "$platform"
let external_libdynload_dir = $ext
let default_libdynload_rel = "libs/python$pyver/lib-dynload"
ML
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
  [ -d "$PYEMBED_PREFIX" ] || die "PYEMBED_PREFIX: no directory $PYEMBED_PREFIX"
  final=$(abspath_logical "$PYEMBED_PREFIX")
  python_exe=$final/bin/python$pyver
  [ -x "$python_exe" ] || die "no $python_exe (CPython $pyver is required)"
  query() { code=$1; shift; "$python_exe" -I -B -c "$code" "$@"; }
  ext_version=$(query 'import platform; print(platform.python_version())')
  case "$ext_version" in
    "$pyver".*) ;;
    *) die "CPython $pyver is required, $python_exe is $ext_version" ;;
  esac
  version=$ext_version
  flags=$(query 'import sysconfig as s; print(s.get_config_var("Py_ENABLE_SHARED") or 0, s.get_config_var("Py_GIL_DISABLED") or 0, s.get_config_var("Py_DEBUG") or 0)')
  case "$flags" in
    "1 0 0") ;;
    *) die "$python_exe must be built with a shared libpython, without free threading and without Py_DEBUG (Py_ENABLE_SHARED Py_GIL_DISABLED Py_DEBUG = $flags)" ;;
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
  # The library must be this interpreter's: same version string, and not a
  # debug build (which exports _Py_NegativeRefcount) next to a release one.
  lib_check=$(query 'import ctypes, sys
lib = ctypes.CDLL(sys.argv[1])
f = lib.Py_GetVersion
f.restype = ctypes.c_char_p
print("same" if f().decode() == sys.version else "version", "debug" if hasattr(lib, "_Py_NegativeRefcount") else "release")' "$lib_file") ||
    die "cannot load $lib_file with $python_exe"
  [ "$lib_check" = "same release" ] ||
    die "$lib_file is not the library of $python_exe ($lib_check: Py_GetVersion must match and Py_DEBUG must be off)"
  lib_name=python$pyver
  libdynload_dir=$stdlib_dir/lib-dynload
  external_libdynload_dir=
  [ ! -d "$libdynload_dir" ] || external_libdynload_dir=$libdynload_dir
  runtime_subdir=libs
  runtime_libdynload=
  magic=$(magic_of "$python_exe")
  fingerprint=$(query 'import os, sys; st = os.stat(sys.argv[1]); v = sys.version.translate({10: 32, 34: 39, 40: 91, 41: 93, 92: 47}); print(v, st.st_size, st.st_mtime_ns)' "$lib_file")
  check_value install_fingerprint "$fingerprint"
  write_config " (install_fingerprint \"$fingerprint\")" ""
  echo "$final" >"$out/prefix/EXTERNAL"
  echo "fetch.sh: $out/cpython-embed.config for $python_exe ($version, $platform)"
  exit 0
fi

# --- mode 1: the pinned archive ----------------------------------------------
if [ -n "${PYEMBED_ARCHIVE_DIR:-}" ]; then
  cache=$PYEMBED_ARCHIVE_DIR
elif [ -n "$wsroot" ]; then
  # The rule runs in <build context>/<dir>; the cache lives in <source>/<dir>.
  [ -n "${DUNE_SOURCEROOT:-}" ] ||
    die "DUNE_SOURCEROOT is not set (not run by dune?): set PYEMBED_ARCHIVE_DIR"
  src_root=$DUNE_SOURCEROOT
  if command -v cygpath >/dev/null 2>&1; then
    src_root=$(cygpath -u "$src_root")
  fi
  ws=$(cd "$wsroot" && pwd -P)
  here=$(cd "$out" && pwd -P)
  rel=${here#"$ws"}
  [ "$rel" != "$here" ] ||
    die "cannot locate the source directory: $here is not under the workspace root $ws; set PYEMBED_ARCHIVE_DIR"
  cache=$src_root$rel/cache
else
  cache=$(cd "$(dirname "$0")" && pwd -P)/cache
fi
mkdir -p "$cache" || die "cannot create the archive directory $cache"
archive=$cache/$file

work=$out/prefix.unpack
mine=$work/archive.tar.gz # the private, verified copy that gets unpacked
part=$archive.part.$$
cleanup() { rm -rf "$work" "$part"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
rm -rf "$work"
mkdir -p "$work"

# Partial downloads of killed builds (the trap cannot run on SIGKILL).
find "$cache" -name "$file.part.*" -mmin +60 -exec rm -f {} + 2>/dev/null || true

have=
if [ -f "$archive" ]; then
  cp "$archive" "$mine"
  got=$(sha256_checked "$mine")
  if [ "$got" = "$sha" ]; then
    have=1
    echo "fetch.sh: using $archive"
  else
    echo "fetch.sh: $archive has sha256 $got, expected $sha: downloading it again" >&2
    rm -f "$mine"
  fi
fi

if [ -z "$have" ]; then
  # '+' must be percent-encoded in the release asset URL.
  url=$url_base/$(printf '%s' "$file" | sed 's/+/%2B/g')
  fail_msg="download failed: $url (no usable $file in $cache; to build offline, put that file in a directory and set PYEMBED_ARCHIVE_DIR to its absolute path)"
  echo "fetch.sh: downloading $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' \
      --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
      -o "$mine" "$url" || die "$fail_msg"
  elif command -v wget >/dev/null 2>&1; then
    if wget --version >/dev/null 2>&1; then # GNU wget
      wget -q --https-only --timeout=60 --tries=3 -O "$mine" "$url" || die "$fail_msg"
    else # busybox wget: -T is its only timeout option, no protocol filter
      wget -q -T 60 -O "$mine" "$url" || die "$fail_msg"
    fi
  else
    die "need curl or wget to download $url (or put $file in a directory and set PYEMBED_ARCHIVE_DIR)"
  fi
  got=$(sha256_checked "$mine")
  [ "$got" = "$sha" ] || die "sha256 mismatch for $url: got $got, expected $sha"
  # Keep it for the next build (best effort: the cache may be read-only).
  if cp "$mine" "$part" 2>/dev/null && mv -f "$part" "$archive"; then
    :
  else
    echo "fetch.sh: warning: could not store the archive in $cache" >&2
  fi
fi

tar -xzf "$mine" -C "$work"
rm -f "$mine"
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
external_libdynload_dir=
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
write_config " (release \"$release\")
 (archive_sha256 \"$sha\")" "$runtime"
echo "fetch.sh: CPython $version ($platform) in $final"
