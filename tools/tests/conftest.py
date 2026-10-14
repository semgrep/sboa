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
"""Shared fixtures for the pyembed bundler/importer tests.

Every test that installs the importer does so in a fresh subprocess (``run_isolated``)
running the same interpreter as pytest with ``-I -S`` and ``sys.path = []``, so the
only way to import anything not already loaded is through ``_pyembed_importer``.
"""
import json
import os
import subprocess
import sys
import textwrap
from pathlib import Path
from typing import Any
from typing import Dict
from typing import List
from typing import Sequence

import pytest

PYEMBED_DIR = Path(__file__).resolve().parents[2]
TOOL = PYEMBED_DIR / "tools" / "pyembed_bundle.py"
IMPORTER = PYEMBED_DIR / "python" / "_pyembed_importer.py"
STDLIB_DIR = Path(
    os.environ.get(
        "PYEMBED_STDLIB_DIR",
        Path(sys.base_prefix)
        / "lib"
        / f"python{sys.version_info[0]}.{sys.version_info[1]}",
    )
)
LIBDYNLOAD_DIR = STDLIB_DIR / "lib-dynload"


def run_tool(*args: str, check: bool = True) -> "subprocess.CompletedProcess[str]":
    """Run ``pyembed_bundle.py`` under the current interpreter."""
    r = subprocess.run(
        [sys.executable, "-I", str(TOOL), *args], capture_output=True, text=True
    )
    if check and r.returncode != 0:
        raise AssertionError(f"tool failed ({r.returncode}):\n{r.stdout}\n{r.stderr}")
    return r


PRELUDE = """
import json, sys, time
_t0 = time.perf_counter()
# Load the importer the way the frozen table does: a code object executed in a
# module that has no __file__.
_pyembed_importer = type(sys)("_pyembed_importer")
with open({importer!r}, "rb") as _f:
    exec(compile(_f.read(), "<frozen _pyembed_importer>", "exec"), _pyembed_importer.__dict__)
sys.modules["_pyembed_importer"] = _pyembed_importer
# From here on nothing comes from the filesystem except dev overrides and lib-dynload.
sys.path[:] = []
sys.path_importer_cache.clear()
_bundles = []
for _name, _path in {bundles!r}:
    with open(_path, "rb") as _f:
        _bundles.append((_name, memoryview(_f.read())))
FINDER = _pyembed_importer.install(_bundles, {libdynload!r}, {dev!r})
RESULT = {{}}
"""

EPILOGUE = """
print("@@RESULT@@" + json.dumps(RESULT, default=str))
"""


def run_isolated(
    script: str,
    bundles: Sequence[Any],
    libdynload: Any = None,
    dev: Sequence[Any] = (),
    env: "Dict[str, str] | None" = None,
) -> Dict[str, Any]:
    """Run ``script`` with the importer installed; return its ``RESULT`` dict."""
    src = (
        PRELUDE.format(
            importer=str(IMPORTER),
            bundles=[(n, str(p)) for n, p in bundles],
            libdynload=None if libdynload is None else str(libdynload),
            dev=[str(d) for d in dev],
        )
        + textwrap.dedent(script)
        + EPILOGUE
    )
    full_env = {k: v for k, v in os.environ.items() if not k.startswith("PYTHON")}
    full_env.update(env or {})
    r = subprocess.run(
        [sys.executable, "-I", "-S", "-c", src],
        capture_output=True,
        text=True,
        env=full_env,
    )
    out = r.stdout
    if "@@RESULT@@" not in out:
        raise AssertionError(f"script failed ({r.returncode}):\n{out}\n{r.stderr}")
    return json.loads(out.split("@@RESULT@@", 1)[1])  # type: ignore[no-any-return]


@pytest.fixture(scope="session")
def stdlib_zip(tmp_path_factory: pytest.TempPathFactory) -> Path:
    out = tmp_path_factory.mktemp("stdlib")
    run_tool("stdlib", "--stdlib-dir", str(STDLIB_DIR), "--out", str(out), "--zip-only")
    return out / "stdlib_bundle.zip"


def write_tree(root: Path, files: Dict[str, "str | bytes"]) -> None:
    for rel, content in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            p.write_bytes(content)
        else:
            p.write_text(textwrap.dedent(content))


def make_wheel(out_dir: Path, filename: str, files: Dict[str, str]) -> Path:
    import zipfile

    out_dir.mkdir(parents=True, exist_ok=True)
    p = out_dir / filename
    with zipfile.ZipFile(p, "w") as zf:
        for rel in sorted(files):
            zf.writestr(rel, textwrap.dedent(files[rel]))
    return p


def args_list(*pairs: List[str]) -> List[str]:
    return [a for pair in pairs for a in pair]
