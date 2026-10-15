#!/bin/sh
# find_python.sh OUT_DIR
#
# Finds the CPython 3.13 that sboa builds against and runs describe.py with
# it, which writes OUT_DIR/sboa.config.
# Run by the rule in ./dune. sboa never downloads CPython: it must already be
# installed. The interpreter is, in order:
#
#   1. $SBOA_PYTHON, an interpreter (a path, or a name looked up on PATH);
#   2. the interpreter of the installed CPython at $SBOA_PREFIX:
#      bin/python3.13 or bin/python3 (Linux, macOS), python.exe (Windows);
#   3. python3.13, then python3, on PATH.
#
# describe.py checks that it is CPython 3.13 with a shared libpython,
# without free threading and without Py_DEBUG. POSIX sh only.
set -eu

die() {
  echo "find_python.sh: $*" >&2
  echo "find_python.sh: point sboa at a CPython 3.13 with SBOA_PYTHON=<interpreter>," \
    "SBOA_PREFIX=<installation prefix>, or a python3.13 on PATH" >&2
  exit 1
}

[ $# -eq 1 ] || {
  echo "usage: $0 OUT_DIR" >&2
  exit 2
}
out=$1
here=$(dirname "$0")

is_absolute() {
  case "$1" in
    /* | [A-Za-z]:/* | [A-Za-z]:\\*) return 0 ;;
    *) return 1 ;;
  esac
}

prefix=
python=
if [ -n "${SBOA_PYTHON:-}" ]; then
  if is_absolute "$SBOA_PYTHON"; then
    python=$SBOA_PYTHON
  else
    python=$(command -v "$SBOA_PYTHON" 2>/dev/null) ||
      die "SBOA_PYTHON=$SBOA_PYTHON: not found on PATH"
  fi
  [ -f "$python" ] || die "SBOA_PYTHON: no file $python"
elif [ -n "${SBOA_PREFIX:-}" ]; then
  # Absolute: the rule runs inside dune's build directory.
  is_absolute "$SBOA_PREFIX" ||
    die "SBOA_PREFIX must be an absolute path, got '$SBOA_PREFIX'"
  [ -d "$SBOA_PREFIX" ] || die "SBOA_PREFIX: no directory $SBOA_PREFIX"
  prefix=$SBOA_PREFIX
  for c in bin/python3.13 bin/python3 python.exe; do
    if [ -f "$prefix/$c" ]; then
      python=$prefix/$c
      break
    fi
  done
  [ -n "$python" ] ||
    die "SBOA_PREFIX=$prefix has no bin/python3.13, bin/python3 or python.exe"
else
  for c in python3.13 python3; do
    if python=$(command -v "$c" 2>/dev/null); then
      break
    fi
    python=
  done
  [ -n "$python" ] ||
    die "no python3.13 or python3 on PATH, and neither SBOA_PYTHON nor SBOA_PREFIX is set"
fi

# -I: ignore PYTHON* variables and the user site; -B: write no bytecode.
if [ -n "$prefix" ]; then
  exec "$python" -I -B "$here/describe.py" --python "$python" --prefix "$prefix" --out "$out"
else
  exec "$python" -I -B "$here/describe.py" --python "$python" --out "$out"
fi
