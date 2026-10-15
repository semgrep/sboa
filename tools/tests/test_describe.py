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
"""Tests for toolchain/describe.py: the runtime-file listings (on fake
installation trees, so the Windows layout is covered everywhere) and a real
run against the interpreter running the tests."""
import importlib.util
import subprocess
import sys
import sysconfig
from pathlib import Path
from types import ModuleType

import pytest

SBOA_DIR = Path(__file__).resolve().parents[2]
DESCRIBE = SBOA_DIR / "toolchain" / "describe.py"
TOOL = SBOA_DIR / "tools" / "sboa_bundle.py"


def load(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(path.stem, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


describe = load(DESCRIBE)


def touch(root: Path, *names: str) -> None:
    for name in names:
        p = root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")


def test_windows_runtime_files(tmp_path: Path) -> None:
    touch(
        tmp_path,
        "python.exe",
        "python313.dll",
        "python3.dll",
        "vcruntime140.dll",
        "vcruntime140_1.dll",
        "DLLs/_ssl.pyd",
        "DLLs/libcrypto-3-x64.dll",
        "DLLs/_tkinter.pyd",
        "DLLs/tcl86t.dll",
        "DLLs/tk86t.dll",
        "DLLs/_testcapi.pyd",
        "DLLs/_ctypes_test.pyd",
        "DLLs/xxlimited.pyd",
        "DLLs/py.ico",
    )
    files = describe.windows_runtime_files(str(tmp_path))
    dests = [d for _, d in files]
    assert dests == [
        "python313.dll",
        "python3.dll",
        "vcruntime140.dll",
        "vcruntime140_1.dll",
        "_ssl.pyd",
        "libcrypto-3-x64.dll",
    ]
    for src, _ in files:
        assert "\\" not in src and Path(src).is_file()


def test_windows_runtime_files_needs_the_dll(tmp_path: Path) -> None:
    touch(tmp_path, "python.exe", "python3.dll")
    with pytest.raises(describe.DescribeError):
        describe.windows_runtime_files(str(tmp_path))


def test_unix_runtime_files(tmp_path: Path) -> None:
    touch(
        tmp_path,
        "lib/libpython3.13.so.1.0",
        "lib/python3.13/lib-dynload/math.cpython-313-x86_64-linux-gnu.so",
        "lib/python3.13/lib-dynload/_tkinter.cpython-313-x86_64-linux-gnu.so",
        "lib/python3.13/lib-dynload/_testcapi.cpython-313-x86_64-linux-gnu.so",
        "lib/python3.13/lib-dynload/README",
    )
    lib = str(tmp_path / "lib" / "libpython3.13.so.1.0")
    dyn = str(tmp_path / "lib" / "python3.13" / "lib-dynload")
    files = describe.unix_runtime_files(lib, "libpython3.13.so.1.0", True, dyn)
    assert [d for _, d in files] == [
        "libpython3.13.so.1.0",
        "python3.13/lib-dynload/math.cpython-313-x86_64-linux-gnu.so",
    ]
    files = describe.unix_runtime_files(lib, "libpython3.13.so.1.0", False, dyn)
    assert [d for _, d in files] == [
        "python3.13/lib-dynload/math.cpython-313-x86_64-linux-gnu.so",
    ]


def test_check_value() -> None:
    assert describe.check_value("x", "/a/b c") == "/a/b c"
    for bad in ['a"b', "a)b", "a\\b"]:
        with pytest.raises(describe.DescribeError):
            describe.check_value("x", bad)
    # a CR (CRLF command output), and Cygwin's rendering of one in a file name
    for bad in ["C:/x/_opam\r/cpython", "C:/x/_opam\uf00d/cpython"]:
        with pytest.raises(describe.DescribeError, match="control character"):
            describe.check_value("prefix", bad)


def shared_cpython_313() -> bool:
    return (
        sys.version_info[:2] == (3, 13)
        and sys.platform != "win32"
        and bool(sysconfig.get_config_var("Py_ENABLE_SHARED"))
        and not sysconfig.get_config_var("Py_GIL_DISABLED")
    )


@pytest.mark.skipif(
    not shared_cpython_313(), reason="needs a CPython 3.13 with a shared libpython"
)
def test_describe_this_interpreter(tmp_path: Path) -> None:
    out = tmp_path / "out"
    r = subprocess.run(
        [
            sys.executable,
            "-I",
            "-B",
            str(DESCRIBE),
            "--python",
            sys.executable,
            "--prefix",
            sys.base_prefix,
            "--out",
            str(out),
        ],
        capture_output=True,
        text=True,
    )
    assert r.returncode == 0, r.stderr
    gen = load(TOOL)
    cfg = gen.read_sboa_config(out / "sboa.config")
    assert cfg["version"].startswith("3.13.")
    assert int(cfg["magic"]) == int.from_bytes(
        importlib.util.MAGIC_NUMBER[:2], "little"
    )
    assert Path(cfg["incdir"], "Python.h").is_file()
    assert Path(cfg["lib_file"]).exists()
    assert cfg["runtime_subdir"] == "libs"
    entries = gen.runtime_entries(cfg)
    assert entries and all(Path(src).is_file() for src, _ in entries)
    staged = tmp_path / "staged"
    assert gen.stage(cfg, "libs", str(staged))
    for _, dest in entries:
        assert (staged / dest).is_file()
    assert not gen.stage(cfg, "bin", str(tmp_path / "empty"))
