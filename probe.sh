#!/bin/sh
# probe.sh: derive C compiler and linker flags for libpython.
#
# Usage:
#   probe.sh CFLAGS_SEXP LINK_SEXP   write dune (:include) files
#   probe.sh --print-libdir          print the directory holding libpython
#   probe.sh --print-stdlib          print the stdlib directory
#   probe.sh --print-python          print the matching interpreter (build time)
#   probe.sh --exec-python ARGS...   run that interpreter (build-time tools in
#                                    dune rules; no other Python is needed);
#                                    $PYEMBED_PYTHON overrides it
#
# Sources, in order of precedence:
#   1. $PYEMBED_PREFIX: a CPython install tree (include/pythonX.Y/Python.h,
#      lib/libpythonX.Y.so|.dylib, lib/pythonX.Y/). For development and tests.
#   2. $PYEMBED_CONFIG, or $OPAM_SWITCH_PREFIX/lib/cpython-embed/cpython-embed.config:
#      the sexp written by the cpython-embed opam package, with at least the
#      fields (incdir ..) (libdir ..) and either (lib_file ..) (the shared
#      library or import library, linked by full path; preferred) or
#      (lib_name ..) (linked as -l<lib_name>); optionally (stdlib_dir ..).
#
# Executables get two rpaths at link time: $ORIGIN/libs (Linux) or
# @loader_path/libs (macOS), where the runtime library ships next to the
# installed binary, and the absolute libdir, so binaries in _build (tests)
# and ldd resolve it too. Windows needs neither: DLLs live next to the exe.
set -eu

die() { echo "probe.sh: $*" >&2; exit 1; }

# sexp_field FILE KEY: print the atom following "(KEY" (quoted or bare).
sexp_field() {
  sed -n "s/^.*($2[[:space:]][[:space:]]*\"\{0,1\}\([^\")]*\)\"\{0,1\}).*$/\1/p" "$1" | head -n 1
}

incdir=""; libdir=""; lib_name=""; lib_file=""; stdlib_dir=""; python_exe=""
if [ -n "${PYEMBED_PREFIX:-}" ]; then
  prefix=$PYEMBED_PREFIX
  for d in "$prefix"/include/python3.*; do
    [ -d "$d" ] && incdir=$d && break
  done
  [ -n "$incdir" ] || die "no include/python3.* under $prefix"
  lib_name=$(basename "$incdir")      # e.g. python3.13
  libdir=$prefix/lib
  stdlib_dir=$libdir/$lib_name
  python_exe=$prefix/bin/$lib_name
else
  config=${PYEMBED_CONFIG:-${OPAM_SWITCH_PREFIX:-/nonexistent}/lib/cpython-embed/cpython-embed.config}
  [ -f "$config" ] ||
    die "set PYEMBED_PREFIX or install cpython-embed (looked for $config)"
  # Windows opam prefixes contain backslashes, which are escape characters in
  # dune sexps; gcc/mingw and CPython accept forward slashes, so normalise.
  slashes() { printf '%s' "$1" | sed 's#\\#/#g'; }
  incdir=$(slashes "$(sexp_field "$config" incdir)")
  libdir=$(slashes "$(sexp_field "$config" libdir)")
  lib_name=$(sexp_field "$config" lib_name)
  lib_file=$(slashes "$(sexp_field "$config" lib_file)")
  stdlib_dir=$(slashes "$(sexp_field "$config" stdlib_dir)")
  python_exe=$(slashes "$(sexp_field "$config" python_exe)")
  [ -n "$incdir" ] && [ -n "$libdir" ] && [ -n "$lib_name$lib_file" ] ||
    die "incomplete config $config"
  case $lib_name in lib*) lib_name=${lib_name#lib} ;; esac
  lib_name=${lib_name%%.so*}; lib_name=${lib_name%.dylib}; lib_name=${lib_name%.dll}
fi

case "${1:-}" in
  --print-libdir) echo "$libdir"; exit 0 ;;
  --print-stdlib) echo "$stdlib_dir"; exit 0 ;;
  --print-python) echo "$python_exe"; exit 0 ;;
  --exec-python)
    shift
    python_exe=${PYEMBED_PYTHON:-$python_exe}
    [ -n "$python_exe" ] || die "no python_exe (config or PYEMBED_PREFIX)"
    exec "$python_exe" "$@" ;;
esac

[ $# -eq 2 ] || die "usage: probe.sh CFLAGS_SEXP LINK_SEXP"
[ -f "$incdir/Python.h" ] || die "$incdir/Python.h not found"

# shellcheck disable=SC2016 # $ORIGIN is for the dynamic linker, not the shell
case $(uname -s) in
  Darwin) rpath='-Wl,-rpath,@loader_path/libs' ;;
  MINGW*|MSYS*|CYGWIN*) rpath='' ;;            # DLLs live next to the exe
  *) rpath='-Wl,-rpath,$ORIGIN/libs' ;;
esac

# Atoms are quoted (dune sexp syntax); paths must not contain '"' or '\'.
printf '("-I%s")\n' "$incdir" > "$1"
if [ -n "$lib_file" ]; then
  # By full path: the executable records the library's SONAME/install name.
  link="\"$lib_file\""
else
  link="\"-L$libdir\" \"-l$lib_name\""
fi
[ -z "$rpath" ] || link="$link \"$rpath\""
# The absolute libdir rpath lets _build binaries (tests) and ldd find the
# library; it is searched after libs/. Release builds that must not carry a
# build-machine path set PYEMBED_NO_LIBDIR_RPATH=1 (or strip it when
# bundling).
if [ -n "$rpath" ] && [ -z "${PYEMBED_NO_LIBDIR_RPATH:-}" ]; then
  link="$link \"-Wl,-rpath,$libdir\""
fi
printf '(%s)\n' "$link" > "$2"
