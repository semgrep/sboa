#
# Copyright (c) 2026 Semgrep Inc.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public License
# version 2.1 as published by the Free Software Foundation.
#
# This library is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the file
# LICENSE for more details.
#
"""Describe the CPython that sboa builds against.

Run by ``find_python.sh`` under the interpreter it found, as
``python -I -B describe.py --python PATH [--prefix DIR] --out DIR``. Writes
``DIR/sboa.config`` (one sexp, a list of ``(field value)`` pairs; see the
README for the fields) and ``DIR/sboa_toolchain_data.ml`` (compiled into
``sboa.toolchain``). Everything is asked of the running interpreter
(``sys``, ``sysconfig``) and of the installation's layout, so any CPython 3.13
built with a shared libpython works: python-build-standalone, distribution
packages, Homebrew's framework build, nix, the python.org Windows installer.

``runtime_files`` lists what an application must install next to its
executable for it to run without the CPython installation: libpython and the
C extension modules of ``lib-dynload`` (under ``bin/libs/``) on Linux and
macOS; ``python3XY.dll``, ``python3.dll``, the ``vcruntime`` DLLs and the
contents of ``DLLs/`` (next to the ``.exe``) on Windows. Tk and CPython's
test extension modules are left out.

Standard library only; must run under the interpreter it describes.
"""
import argparse
import ctypes
import importlib.util
import os
import platform
import sys
import sysconfig
from typing import List
from typing import Optional
from typing import Tuple

PYVER = "3.13"

# Extension modules and DLLs never shipped (Tk, CPython's own test modules).
EXCLUDED_PREFIXES = ("_tkinter.", "_test", "xxlimited", "_ctypes_test", "_xxtest")
EXCLUDED_DLL_PREFIXES = ("tcl", "tk")


class DescribeError(Exception):
    pass


def slashes(path: str) -> str:
    """Forward slashes: what gcc (mingw), dune and CPython accept everywhere."""
    return path.replace("\\", "/")


def check_value(name: str, value: str) -> str:
    # The readers of sboa.config (probe.sh's sed, the OCaml string literal)
    # do not unescape anything.
    if any(c in value for c in '")\\\n'):
        raise DescribeError(
            f"{name} contains '\"', ')', a backslash or a newline, which"
            f" sboa.config cannot carry: {value!r}"
        )
    # A control character in a path is a CRLF command output captured without
    # stripping the CR (`opam var` on Windows); Cygwin shows such a character
    # in a file name as U+F000 + its code.
    if any(ord(c) < 0x20 or ord(c) == 0x7F or 0xF000 <= ord(c) <= 0xF0FF for c in value):
        raise DescribeError(
            f"{name} contains a control character (a carriage return from a"
            f" CRLF command output?): {value!r}"
        )
    return value


def excluded(name: str) -> bool:
    lower = name.lower()
    if lower.startswith(EXCLUDED_PREFIXES):
        return True
    return lower.endswith(".dll") and lower.startswith(EXCLUDED_DLL_PREFIXES)


def platform_id(kind: str) -> str:
    machine = platform.machine().lower()
    arch = {"amd64": "x86_64", "x86_64": "x86_64", "arm64": "aarch64"}.get(
        machine, machine
    )
    if kind == "windows":
        if arch != "x86_64":
            raise DescribeError(f"unsupported Windows architecture {machine}")
        return "windows-x86_64"
    if kind == "macho":
        return "macos-arm64" if arch == "aarch64" else "macos-x86_64"
    soabi = sysconfig.get_config_var("SOABI") or ""
    multiarch = sysconfig.get_config_var("MULTIARCH") or ""
    libc = "musl" if "musl" in soabi or "musl" in multiarch else "gnu"
    if libc == "gnu" and platform.libc_ver()[0] not in ("glibc", ""):
        libc = "musl"
    return f"linux-{libc}-{arch}"


def unix_runtime_files(
    lib_file: str, soname: str, ship_lib: bool, libdynload_dir: str
) -> List[Tuple[str, str]]:
    """(absolute source, destination under bin/libs/) on Linux and macOS."""
    files: List[Tuple[str, str]] = []
    if ship_lib:
        files.append((slashes(os.path.realpath(lib_file)), soname))
    if os.path.isdir(libdynload_dir):
        for name in sorted(os.listdir(libdynload_dir)):
            path = os.path.join(libdynload_dir, name)
            if (name.endswith(".so") or name.endswith(".dylib")) and not excluded(
                name
            ):
                if os.path.isfile(path):
                    files.append(
                        (slashes(path), f"python{PYVER}/lib-dynload/{name}")
                    )
    return files


def windows_runtime_files(prefix: str) -> List[Tuple[str, str]]:
    """(absolute source, destination next to the .exe) on Windows: the DLLs
    of the installation's root and the contents of DLLs/."""
    nodot = PYVER.replace(".", "")
    files: List[Tuple[str, str]] = []
    for name in (f"python{nodot}.dll", "python3.dll"):
        path = os.path.join(prefix, name)
        if not os.path.isfile(path):
            raise DescribeError(f"no {path}")
        files.append((slashes(path), name))
    for name in sorted(os.listdir(prefix)):
        if name.lower().startswith("vcruntime") and name.lower().endswith(".dll"):
            files.append((slashes(os.path.join(prefix, name)), name))
    dlls = os.path.join(prefix, "DLLs")
    if os.path.isdir(dlls):
        for name in sorted(os.listdir(dlls)):
            lower = name.lower()
            if (lower.endswith(".pyd") or lower.endswith(".dll")) and not excluded(
                name
            ):
                files.append((slashes(os.path.join(dlls, name)), name))
    return files


def find_unix_lib(kind: str, prefix: str) -> Tuple[str, str, bool]:
    """(library to link by full path, its runtime file name, whether the
    library can be shipped next to the executable)."""
    if kind == "macho":
        names = [f"libpython{PYVER}.dylib"]
    else:
        names = [f"libpython{PYVER}.so.1.0", f"libpython{PYVER}.so"]
    instsoname = sysconfig.get_config_var("INSTSONAME") or ""
    if instsoname and "/" not in instsoname and instsoname not in names:
        names.insert(0, instsoname)
    # LIBDIR is baked in at the CPython build (wrong for a relocated tree such
    # as python-build-standalone's): look in PREFIX/lib first.
    dirs = [os.path.join(prefix, "lib")]
    libdir = sysconfig.get_config_var("LIBDIR")
    if libdir and libdir not in dirs:
        dirs.append(libdir)
    candidates = [(d, name) for d in dirs for name in names]
    framework = sysconfig.get_config_var("PYTHONFRAMEWORK")
    if kind == "macho" and framework:
        # <prefix> is Python.framework/Versions/3.13, whose library is
        # <prefix>/Python (lib/libpython3.13.dylib, when present, links to it).
        candidates.append((prefix, framework))
    for d, name in candidates:
        path = os.path.join(d, name)
        if not os.path.exists(path):
            continue
        if kind == "macho":
            # A framework build has an absolute install name: a copy next to
            # the executable would never be loaded.
            return path, name, not framework
        soname = instsoname if instsoname and "/" not in instsoname else name
        return path, soname, True
    raise DescribeError(
        f"no {' or '.join(names)} in {' or '.join(dirs)}: the CPython must be"
        " built with a shared libpython (--enable-shared)"
    )


def check_interpreter() -> None:
    if sys.implementation.name != "cpython":
        raise DescribeError(f"{sys.executable} is not CPython")
    if f"{sys.version_info[0]}.{sys.version_info[1]}" != PYVER:
        raise DescribeError(
            f"CPython {PYVER} is required, {sys.executable} is"
            f" {platform.python_version()}"
        )
    if sysconfig.get_config_var("Py_GIL_DISABLED"):
        raise DescribeError(f"{sys.executable} is a free-threaded build")
    if hasattr(sys, "gettotalrefcount") or sysconfig.get_config_var("Py_DEBUG"):
        raise DescribeError(f"{sys.executable} is a debug (Py_DEBUG) build")
    # A macOS framework build (python.org, Homebrew) has a shared library
    # (the framework's) without Py_ENABLE_SHARED.
    if (
        os.name != "nt"
        and not sysconfig.get_config_var("Py_ENABLE_SHARED")
        and not sysconfig.get_config_var("PYTHONFRAMEWORK")
    ):
        raise DescribeError(
            f"{sys.executable} is built without a shared libpython"
            " (Py_ENABLE_SHARED is off)"
        )


def check_library(lib_file: str) -> None:
    """The library must be this interpreter's: same version string, and not
    a debug build (which exports _Py_NegativeRefcount)."""
    try:
        lib = ctypes.CDLL(lib_file)
        f = lib.Py_GetVersion
        f.restype = ctypes.c_char_p
        same = f().decode() == sys.version
        debug = hasattr(lib, "_Py_NegativeRefcount")
    except (OSError, AttributeError) as e:
        raise DescribeError(f"cannot load {lib_file}: {e}") from e
    if not same or debug:
        raise DescribeError(
            f"{lib_file} is not the library of {sys.executable}"
            " (Py_GetVersion must match and Py_DEBUG must be off)"
        )


def magic() -> int:
    env = os.environ.get("SBOA_MAGIC")
    if env:
        return int(env)
    return int.from_bytes(importlib.util.MAGIC_NUMBER[:2], "little")


def describe(python: str, prefix: Optional[str]) -> List[Tuple[str, str]]:
    """The config fields, in order (values already rendered)."""
    check_interpreter()
    if sys.platform == "win32":
        kind = "windows"
    elif sys.platform == "darwin":
        kind = "macho"
    else:
        kind = "elf"
    # The prefix as given (a Homebrew opt/ path stays valid across upgrades).
    prefix = os.path.abspath(prefix) if prefix else sys.base_prefix
    incdir = sysconfig.get_path("include")
    stdlib_dir = sysconfig.get_path("stdlib")
    if kind == "windows":
        nodot = PYVER.replace(".", "")
        lib_name = f"python{nodot}"
        libdir = os.path.join(prefix, "libs")
        lib_file = os.path.join(libdir, f"python{nodot}.lib")
        if not os.path.isfile(lib_file):
            raise DescribeError(f"no import library {lib_file}")
        libdynload_dir = os.path.join(prefix, "DLLs")
        external_libdynload_dir = ""
        runtime_subdir = ""
        runtime_libdynload = ""
        runtime = windows_runtime_files(prefix)
    else:
        lib_name = f"python{PYVER}"
        lib_file, soname, ship_lib = find_unix_lib(kind, prefix)
        libdir = os.path.dirname(lib_file)
        check_library(lib_file)
        libdynload_dir = os.path.join(stdlib_dir, "lib-dynload")
        runtime = unix_runtime_files(lib_file, soname, ship_lib, libdynload_dir)
        has_ext = any("/lib-dynload/" in dest for _, dest in runtime)
        # Where the extension modules are when nothing was installed next to
        # the executable (a build run from the build tree, a package that
        # does not ship them): compiled into sboa.toolchain.
        external_libdynload_dir = libdynload_dir if has_ext else ""
        runtime_subdir = "libs"
        runtime_libdynload = f"python{PYVER}/lib-dynload"
    if not os.path.isfile(os.path.join(incdir, "Python.h")):
        raise DescribeError(f"no {incdir}/Python.h (the CPython headers)")
    st = os.stat(lib_file)
    fingerprint = (
        sys.version.translate({10: 32, 34: 39, 40: 91, 41: 93, 92: 47})
        + f" {st.st_size} {st.st_mtime_ns}"
    )

    def q(name: str, value: str) -> Tuple[str, str]:
        return (name, '"' + check_value(name, value) + '"')

    def p(name: str, value: str) -> Tuple[str, str]:
        return q(name, slashes(value))

    files = "".join(
        f'\n  ("{check_value("runtime_files", s)}"'
        f' "{check_value("runtime_files", d)}")'
        for s, d in runtime
    )
    return [
        q("version", platform.python_version()),
        q("platform", platform_id(kind)),
        ("magic", str(magic())),
        q("install_fingerprint", fingerprint),
        p("prefix", prefix),
        p("incdir", incdir),
        p("libdir", libdir),
        q("lib_name", lib_name),
        p("lib_file", lib_file),
        p("stdlib_dir", stdlib_dir),
        p("libdynload_dir", libdynload_dir),
        p("external_libdynload_dir", external_libdynload_dir),
        p("python_exe", python),
        q("runtime_subdir", runtime_subdir),
        q("runtime_libdynload", runtime_libdynload),
        ("runtime_files", f"({files}\n )"),
    ]


def ocaml_data(fields: List[Tuple[str, str]]) -> str:
    d = dict(fields)
    ext = d["external_libdynload_dir"]
    ext_ml = "None" if ext == '""' else f"Some {ext}"
    return (
        "(* Generated by toolchain/describe.py from sboa.config. *)\n"
        f"let version = {d['version']}\n"
        f"let platform = {d['platform']}\n"
        f"let external_libdynload_dir = {ext_ml}\n"
        f'let default_libdynload_rel = "libs/python{PYVER}/lib-dynload"\n'
    )


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--python", required=True, help="the interpreter, as found")
    ap.add_argument("--prefix", help="the installation prefix (SBOA_PREFIX)")
    ap.add_argument("--out", required=True, help="output directory")
    args = ap.parse_args(argv)
    try:
        fields = describe(args.python, args.prefix)
    except DescribeError as e:
        print(f"describe.py: {e}", file=sys.stderr)
        print(
            "describe.py: point sboa at a CPython 3.13 with"
            " SBOA_PYTHON=<interpreter>, SBOA_PREFIX=<installation prefix>,"
            " or a python3.13 on PATH",
            file=sys.stderr,
        )
        return 1
    os.makedirs(args.out, exist_ok=True)
    body = "\n ".join(f"({k} {v})" for k, v in fields)
    # UTF-8 whatever the locale (the readers assume it; a non-ASCII path
    # under the Windows code page would fail here, far from its cause)
    with open(
        os.path.join(args.out, "sboa.config"), "w", encoding="utf-8", newline="\n"
    ) as f:
        f.write(f"({body})\n")
    with open(
        os.path.join(args.out, "sboa_toolchain_data.ml"),
        "w",
        encoding="utf-8",
        newline="\n",
    ) as f:
        f.write(ocaml_data(fields))
    d = {k: v.strip('"') for k, v in fields}
    print(
        f"describe.py: {args.out}/sboa.config for {args.python}"
        f" ({d['version']}, {d['platform']})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
