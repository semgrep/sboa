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
"""Tests for ``sboa_bundle.py describe``, ``flags`` and ``exec``: the
runtime-file listings (on fake installation trees, so the Windows layout is
covered everywhere) and real runs against the interpreter running the tests."""

import importlib.util
import subprocess
import sys
import sysconfig
from pathlib import Path
from types import ModuleType

import pytest

SBOA_DIR = Path(__file__).resolve().parents[2]
TOOL = SBOA_DIR / "tools" / "sboa_bundle.py"


def load(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(path.stem, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


describe = load(TOOL)


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
    with pytest.raises(describe.ToolError):
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
        with pytest.raises(describe.ToolError):
            describe.check_value("x", bad)
    # a CR (CRLF command output), and Cygwin's rendering of one in a file name
    for bad in ["C:/x/_opam\r/cpython", "C:/x/_opam\uf00d/cpython"]:
        with pytest.raises(describe.ToolError, match="control character"):
            describe.check_value("prefix", bad)


def test_link_flags() -> None:
    cfg = {"lib_file": "/p/lib/libpython3.13.so.1.0", "libdir": "/p/lib"}
    linux = describe.link_items({**cfg, "platform": "linux-gnu-x86_64"})
    assert linux == [
        ("lib", "/p/lib/libpython3.13.so.1.0"),
        ("opt", "'-Wl,-rpath,$ORIGIN/libs'"),
        ("opt", "-Wl,-rpath,/p/lib"),
    ]
    macos = describe.link_items({**cfg, "platform": "macos-arm64"})
    assert macos[1] == ("opt", "-Wl,-rpath,@loader_path/libs")
    win = {"lib_file": "C:/p/libs/python313.lib", "platform": "windows-x86_64"}
    assert describe.link_items(win) == [("lib", "C:/p/libs/python313.lib")]


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
    cfg_file = tmp_path / "out" / "sboa.config"
    r = subprocess.run(
        [
            sys.executable,
            "-I",
            str(TOOL),
            "describe",
            "--prefix",
            sys.base_prefix,
            "--out",
            str(cfg_file),
        ],
        capture_output=True,
        text=True,
    )
    assert r.returncode == 0, r.stderr
    cfg = describe.read_sboa_config(cfg_file)
    assert cfg["version"].startswith("3.13.")
    assert Path(cfg["incdir"], "Python.h").is_file()
    assert Path(cfg["lib_file"]).exists()
    assert Path(cfg["python_exe"]).is_file()
    assert cfg["runtime_subdir"] == "libs"
    entries = describe.runtime_entries(cfg)
    assert entries and all(Path(src).is_file() for src, _ in entries)
    staged = tmp_path / "staged"
    assert describe.stage(cfg, "libs", str(staged))
    for _, dest in entries:
        assert (staged / dest).is_file()
    assert not describe.stage(cfg, "bin", str(tmp_path / "empty"))

    def tool(*args: str) -> str:
        r = subprocess.run(
            [sys.executable, "-I", str(TOOL), *args], capture_output=True, text=True
        )
        assert r.returncode == 0, r.stderr
        return r.stdout

    assert tool("flags", "--config", str(cfg_file), "--cflags") == (
        f'("-I{cfg["incdir"]}")\n'
    )
    assert tool("flags", "--config", str(cfg_file), "--clibs") == "()\n"
    link = tool("--config", str(cfg_file), "flags", "--link")
    assert link.startswith(f'("-cclib" "{cfg["lib_file"]}" "-ccopt" ')
    out = tool(
        "exec", "--config", str(cfg_file), "--", "-c", "import sys; print(sys.prefix)"
    )
    assert out.strip() == sys.base_prefix


def test_describe_refuses_a_prefix_without_python(tmp_path: Path) -> None:
    r = subprocess.run(
        [
            sys.executable,
            "-I",
            str(TOOL),
            "describe",
            "--prefix",
            str(tmp_path),
            "--out",
            str(tmp_path / "c"),
        ],
        capture_output=True,
        text=True,
    )
    assert r.returncode == 1
    assert "has no bin/python3.13, bin/python3 or python.exe" in r.stderr
