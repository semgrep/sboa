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
"""Integration test: bundle a real uv project and import it from the bundles.

Driven by a JSON config named by ``SBOA_IT_CONFIG`` (skipped when unset) so this
package stays free of any knowledge of the project under test::

  {
    "project": "path/to/uv/project",          # holds uv.lock (relative to the config)
    "packages": {"name": "src/name", ...},    # relative to project
    "data": ["glob", ...], "exclude": ["glob", ...],
    "exclude_dists": ["dist", ...],           # removed from the third-party closure
    "import": "pkg.module",                   # must import from the bundles
    "expect_unpatched_failure": {"module": "pkg.mod", "contains": ["text", ...]},
    "patches": [{"file": "name/x.py", "old": "...", "new": "..."}],  # scratch copy only
    "patch_excludes": ["glob", ...]           # extra --exclude for the patched bundle
  }

Steps: ``uv export`` -> ``fetch-wheels`` (pure-wheel policy, cached in
``SBOA_WHEEL_CACHE``, default ``/tmp/sboa-wheels``) -> ``bundle`` the closure
with ``--lock`` -> ``bundle`` the project sources -> import with ``sys.path = []``
and the interpreter's ``lib-dynload``.  The unpatched sources are expected to fail
where configured; a scratch copy with the patches applied must import.  Sizes and
timings are printed (``pytest -s``).
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from typing import Dict
from typing import List

import pytest
from conftest import IMPORTER
from conftest import LIBDYNLOAD_DIR
from conftest import run_tool
from conftest import STDLIB_DIR

CONFIG = os.environ.get("SBOA_IT_CONFIG")


def host_platform() -> str:
    """sboa platform name of the interpreter running the test (which is
    the embedded interpreter: the test imports from bundles compiled by it)."""
    import platform

    machine = platform.machine().lower()
    arch = {"amd64": "x86_64", "arm64": "aarch64"}.get(machine, machine)
    if sys.platform == "darwin":
        return "macos-arm64" if arch == "aarch64" else "macos-x86_64"
    if sys.platform == "win32":
        return "windows-x86_64"
    libc = "gnu" if platform.libc_ver()[0] == "glibc" else "musl"
    return f"linux-{libc}-{arch}"


TARGET = ["--python-version", sys.version.split()[0], "--platform", host_platform()]
UV = shutil.which("uv") or str(Path.home() / ".local/bin/uv")

pytestmark = pytest.mark.skipif(CONFIG is None, reason="SBOA_IT_CONFIG not set")

IMPORT_SCRIPT = r"""
import json, sys, time
t0 = time.perf_counter()
_m = type(sys)("_sboa_importer")
with open(sys.argv[1], "rb") as f:
    exec(compile(f.read(), "<frozen _sboa_importer>", "exec"), _m.__dict__)
sys.modules["_sboa_importer"] = _m
sys.path[:] = []
sys.path_importer_cache.clear()
bundles = []
for name, path in json.loads(sys.argv[2]):
    with open(path, "rb") as f:
        bundles.append((name, memoryview(f.read())))
_m.install(bundles, sys.argv[3], [])
t1 = time.perf_counter()
try:
    __import__(sys.argv[4])
except BaseException:
    import traceback
    traceback.print_exc()
    sys.exit(3)
t2 = time.perf_counter()
fs = sorted(n for n, m in list(sys.modules.items())
            if isinstance(getattr(m, "__file__", None), str) and not m.__file__.startswith("<sboa:"))
print(json.dumps({"install_ms": (t1 - t0) * 1e3, "import_ms": (t2 - t1) * 1e3,
                  "modules": len(sys.modules), "filesystem_modules": fs}))
"""


def load_config() -> Dict[str, Any]:
    assert CONFIG is not None
    cfg: Dict[str, Any] = json.loads(Path(CONFIG).read_text())
    cfg["project"] = (Path(CONFIG).parent / cfg["project"]).resolve()
    return cfg


def bundle_sources(
    cfg: Dict[str, Any], src_root: Path, out: Path, extra_excludes: List[str]
) -> Path:
    args = ["bundle", "--name", "app", "--out", str(out), "--zip-only"]
    for name, rel in cfg["packages"].items():
        args += ["--package", f"{name}={src_root / rel}"]
    for g in cfg.get("data", []):
        args += ["--data", g]
    for g in cfg.get("exclude", []) + extra_excludes:
        args += ["--exclude", g]
    run_tool(*args)
    return out / "app_bundle.zip"


def run_import(zips: List[Any], module: str) -> "subprocess.CompletedProcess[str]":
    env = {k: v for k, v in os.environ.items() if not k.startswith("PYTHON")}
    return subprocess.run(
        [
            sys.executable,
            "-I",
            "-S",
            "-c",
            IMPORT_SCRIPT,
            str(IMPORTER),
            json.dumps([(n, str(p)) for n, p in zips]),
            str(LIBDYNLOAD_DIR),
            module,
        ],
        capture_output=True,
        text=True,
        env=env,
    )


def test_uv_project(tmp_path: Path) -> None:
    cfg = load_config()
    project: Path = cfg["project"]
    req = tmp_path / "requirements.txt"
    with req.open("w") as f:
        subprocess.run(
            [
                UV,
                "export",
                "--frozen",
                "--no-dev",
                "--no-emit-project",
                "--format",
                "requirements-txt",
            ],
            cwd=project,
            stdout=f,
            check=True,
        )
    cache = Path(os.environ.get("SBOA_WHEEL_CACHE", "/tmp/sboa-wheels"))
    fetch = [
        "fetch-wheels",
        "--lock",
        str(project / "uv.lock"),
        "--requirements",
        str(req),
        "--out",
        str(cache),
        *TARGET,
    ]
    excludes: List[str] = []
    for d in cfg.get("exclude_dists", []):
        excludes += ["--exclude-dist", d]
    fetch += excludes
    r = run_tool(*fetch, check=False)
    if r.returncode != 0:
        pytest.skip(f"cannot fetch wheels: {r.stderr[-500:]}")
    wanted = set(r.stdout.split())
    wheels = tmp_path / "wheels"
    wheels.mkdir()
    for w in wanted:
        os.link(cache / w, wheels / w) if os.stat(cache).st_dev == os.stat(
            tmp_path
        ).st_dev else shutil.copy(cache / w, wheels / w)
    print(f"\nclosure: {len(wanted)} pure wheels; skipped: {r.stderr.strip()}")

    out = tmp_path / "out"
    run_tool(
        "bundle",
        "--name",
        "deps",
        "--wheels",
        str(wheels),
        "--lock",
        str(project / "uv.lock"),
        *TARGET,
        *excludes,
        "--out",
        str(out),
        "--zip-only",
    )
    run_tool("stdlib", "--stdlib-dir", str(STDLIB_DIR), "--out", str(out), "--zip-only")
    deps, std = out / "deps_bundle.zip", out / "stdlib_bundle.zip"

    # 1. Unpatched sources: the configured failure must show up.
    app = bundle_sources(cfg, project, out / "unpatched", [])
    exp = cfg.get("expect_unpatched_failure")
    if exp:
        r2 = run_import([("app", app), ("deps", deps), ("stdlib", std)], exp["module"])
        print(
            f"unpatched import {exp['module']} -> rc={r2.returncode}\n{r2.stderr[-1500:]}"
        )
        assert r2.returncode == 3
        for text in exp["contains"]:
            assert text in r2.stderr

    # 2. Scratch copy with the patches applied: the import must succeed.
    scratch = tmp_path / "scratch"
    for rel in cfg["packages"].values():
        shutil.copytree(project / rel, scratch / rel)
    for p in cfg.get("patches", []):
        target = scratch / p["file"]
        text = target.read_text()
        assert p["old"] in text, f"patch no longer applies to {p['file']}: {p['old']!r}"
        target.write_text(text.replace(p["old"], p["new"], 1))
    app2 = bundle_sources(cfg, scratch, out / "patched", cfg.get("patch_excludes", []))
    zips = [("stdlib", std), ("app", app2), ("deps", deps)]  # production order
    timings = []
    for _ in range(5):
        t = time.perf_counter()
        r3 = run_import(zips, cfg["import"])
        wall = (time.perf_counter() - t) * 1e3
        assert r3.returncode == 0, r3.stderr[-3000:]
        res = json.loads(r3.stdout.strip().splitlines()[-1])
        res["process_ms"] = wall
        timings.append(res)
    best = min(timings, key=lambda x: x["import_ms"])
    print(
        f"sizes: app={app2.stat().st_size} deps={deps.stat().st_size} stdlib={std.stat().st_size} bytes"
    )
    print(
        "import {}: best of 5: install {:.1f} ms, import {:.0f} ms, process {:.0f} ms, {} modules; all import_ms={}".format(
            cfg["import"],
            best["install_ms"],
            best["import_ms"],
            best["process_ms"],
            best["modules"],
            [round(t["import_ms"]) for t in timings],
        )
    )
    print("modules with a filesystem __file__:", best["filesystem_modules"])
