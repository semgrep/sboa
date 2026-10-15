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
"""Tests for ``sboa_bundle.py`` and ``_sboa_importer`` on a sample tree.

The sample covers: a package with subpackages, module docstrings, data files
(inside and outside packages), a pure wheel with ``*.dist-info`` (metadata and
entry points), a namespace package split across two bundles, a stub extension
module in a fake ``lib-dynload``, a dev override, and tracebacks.
"""
import hashlib
import shutil
import subprocess
import sys
import sysconfig
import zipfile
from pathlib import Path
from typing import Any
from typing import Dict
from typing import List
from typing import Optional
from typing import Tuple

import pytest
from conftest import IMPORTER
from conftest import make_wheel
from conftest import needs_builtin_extensions
from conftest import run_isolated
from conftest import run_tool
from conftest import STDLIB_DIR
from conftest import TOOL
from conftest import write_tree

TARGET = ["--python-version", "3.13.16", "--platform", "linux-gnu-x86_64"]

SAMPLE: Dict[str, "str | bytes"] = {
    "samplepkg/__init__.py": '''
        """Sample package docstring (kept at optimization 0)."""
        VALUE = 1
        ''',
    "samplepkg/sub/__init__.py": "",
    "samplepkg/sub/mod.py": """
        import json


        def boom():
            raise ValueError("boom from bundle")


        def table():
            return json.loads('{"a": 1}')
        """,
    "samplepkg/sub/res.json": '{"answer": 42}',
    "samplepkg/data/info.txt": "hello resource\n",
    "samplepkg/notes.md": "not selected by --data\n",
    "samplepkg/tests/test_x.py": "this is not python",
    "nsroot/part_a/__init__.py": "NAME = 'a'\n",
}

WHEEL_FILES = {
    "samplewheel/__init__.py": "from importlib.metadata import version\nVERSION = version('samplewheel')\n",
    "samplewheel/cacert.pem": "-----BEGIN CERT-----\n",
    "nsroot/part_b/__init__.py": "NAME = 'b'\n",
    "samplewheel-1.2.3.dist-info/METADATA": "Metadata-Version: 2.1\nName: SampleWheel\nVersion: 1.2.3\n",
    "samplewheel-1.2.3.dist-info/entry_points.txt": "[sample.plugins]\nfirst = samplewheel:VERSION\n",
    "samplewheel-1.2.3.dist-info/WHEEL": "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    "samplewheel-1.2.3.dist-info/RECORD": "",
}

STUB_EXT_C = r"""
#define PY_SSIZE_T_CLEAN
#include <Python.h>
static struct PyModuleDef def = {PyModuleDef_HEAD_INIT, "_sboa_stubext", NULL, 0, NULL};
PyMODINIT_FUNC PyInit__sboa_stubext(void) {
  PyObject *m = PyModule_Create(&def);
  if (m != NULL && PyModule_AddIntConstant(m, "ANSWER", 42) < 0) { Py_DECREF(m); return NULL; }
  return m;
}
"""


@pytest.fixture(scope="module")
def sample(tmp_path_factory: pytest.TempPathFactory) -> Dict[str, Path]:
    root = tmp_path_factory.mktemp("sample")
    src = root / "src"
    write_tree(src, SAMPLE)
    wheels = root / "wheels"
    make_wheel(wheels, "samplewheel-1.2.3-py3-none-any.whl", WHEEL_FILES)
    out = root / "out"
    run_tool(
        "bundle",
        "--name",
        "sample",
        "--package",
        f"samplepkg={src / 'samplepkg'}",
        "--data",
        "samplepkg/**/*.json",
        "--data",
        "samplepkg/data/*",
        "--exclude",
        "**/tests/**",
        # the generated-source checks below expect the ELF form, on any host
        "--target",
        "elf",
        "--out",
        str(out),
        "--mli",
    )
    run_tool(
        "bundle",
        "--name",
        "deps",
        "--package",
        f"nsroot={src / 'nsroot'}",
        "--wheels",
        str(wheels),
        "--out",
        str(out),
    ) if False else None
    # nsroot has no __init__.py, so it goes in as part of the wheel bundle instead.
    deps_src = root / "deps_src"
    write_tree(
        deps_src,
        {
            "nsroot/part_a/__init__.py": "NAME = 'a'\n",
            "nsroot/ns_data.txt": "ns data\n",
        },
    )
    run_tool("bundle", "--name", "deps", "--wheels", str(wheels), "--out", str(out))
    run_tool("bundle", "--name", "ns", "--site", str(deps_src), "--out", str(out))
    dynload = root / "lib-dynload"
    dynload.mkdir()
    c = root / "stub.c"
    c.write_text(STUB_EXT_C)
    subprocess.run(
        [
            "gcc",
            "-shared",
            "-fPIC",
            # macOS: Python symbols resolve from the loading process
            *(["-undefined", "dynamic_lookup"] if sys.platform == "darwin" else []),
            f"-I{sysconfig.get_paths()['include']}",
            str(c),
            "-o",
            str(
                dynload / ("_sboa_stubext" + sysconfig.get_config_var("EXT_SUFFIX"))
            ),
        ],
        check=True,
    )
    dev = root / "dev"
    write_tree(
        dev,
        {
            "samplepkg/__init__.py": "VALUE = 2\n",
            "samplepkg/sub/__init__.py": "",
            "samplepkg/sub/mod.py": "WHERE = 'dev'\n",
        },
    )
    stray = root / "stray"
    (stray / "samplepkg").mkdir(
        parents=True
    )  # a directory without __init__: must not shadow
    return {
        "out": out,
        "dynload": dynload,
        "dev": dev,
        "stray": stray,
        "src": src,
        "wheels": wheels,
    }


def bundles(sample: Dict[str, Path], stdlib_zip: Path) -> Any:
    out = sample["out"]
    return [
        ("sample", out / "sample_bundle.zip"),
        ("deps", out / "deps_bundle.zip"),
        ("ns", out / "ns_bundle.zip"),
        ("stdlib", stdlib_zip),
    ]


def test_bundle_layout_and_determinism(sample: Dict[str, Path], tmp_path: Path) -> None:
    z = sample["out"] / "sample_bundle.zip"
    with zipfile.ZipFile(z) as zf:
        names = zf.namelist()
        assert names == sorted(names)
        assert all(i.date_time == (1980, 1, 1, 0, 0, 0) for i in zf.infolist())
        assert "samplepkg/__init__.pyc" in names
        assert "samplepkg/sub/res.json" in names and "samplepkg/data/info.txt" in names
        assert "samplepkg/notes.md" not in names  # not matched by --data
        assert not any("tests" in n for n in names)  # --exclude
        assert not any(n.endswith(".py") for n in names)
        pyc = zf.read("samplepkg/sub/mod.pyc")
        assert int.from_bytes(pyc[4:8], "little") == 0b01  # unchecked hash
        assert zf.comment.startswith(b"sboa-bundle/1 name=sample magic=")
    # Rebuilding gives identical bytes.
    run_tool(
        "bundle",
        "--name",
        "sample",
        "--package",
        f"samplepkg={sample['src'] / 'samplepkg'}",
        "--data",
        "samplepkg/**/*.json",
        "--data",
        "samplepkg/data/*",
        "--exclude",
        "**/tests/**",
        "--out",
        str(tmp_path),
    )
    assert (tmp_path / "sample_bundle.zip").read_bytes() == z.read_bytes()
    with zipfile.ZipFile(sample["out"] / "deps_bundle.zip") as zf:
        names = zf.namelist()
        assert "samplewheel-1.2.3.dist-info/METADATA" in names
        assert "samplewheel-1.2.3.dist-info/entry_points.txt" in names
        assert "samplewheel-1.2.3.dist-info/RECORD" not in names
        assert "samplewheel/cacert.pem" in names


def test_generated_sources(sample: Dict[str, Path]) -> None:
    out = sample["out"]
    ml = (out / "sample_bundle.ml").read_text()
    assert (
        'Sboa.Bundle.of_incbin ~symbol:"sample_bundle" ~name:"sample" (incbin ())'
        in ml
    )
    assert "Sboa.Bundle.register ~priority:50 bundle" in ml
    assert '= "sboa_incbin_sample_bundle"' in ml
    assert (out / "sample_bundle.mli").read_text().count(
        "val bundle : Sboa.Bundle.t"
    ) == 1
    c = (out / "sample_bundle_blob.c").read_text()
    assert '.incbin \\"sample_bundle.zip\\"' in c and ".section .rodata" in c
    z = out / "sample_bundle.zip"
    assert (
        f"sample_bundle.zip: {z.stat().st_size} bytes, sha256 {hashlib.sha256(z.read_bytes()).hexdigest()}"
        in c
    )
    assert "extern const size_t sample_bundle_len;" in c
    assert "\\t.quad .Lsample_bundle_end - sample_bundle\\n" in c


@pytest.mark.parametrize(
    "target,expected",
    [
        ("elf", ["\\t.section .rodata\\n", "sample_bundle:\\n", "\\t.previous\\n"]),
        (
            "macho",
            [
                "\\t.section __TEXT,__const\\n",
                "\\t.globl _sample_bundle\\n",
                "_sample_bundle:\\n",
            ],
        ),
        (
            "coff",
            [
                '\\t.section .rdata,\\"dr\\"\\n',
                "\\t.globl sample_bundle\\n",
                "sample_bundle:\\n",
            ],
        ),
    ],
)
def test_incbin_targets(
    sample: Dict[str, Path], tmp_path: Path, target: str, expected: Any
) -> None:
    run_tool(
        "embed",
        "--zip",
        str(sample["out"] / "sample_bundle.zip"),
        "--name",
        "sample",
        "--target",
        target,
        "--out",
        str(tmp_path),
    )
    c = (tmp_path / "sample_bundle_blob.c").read_text()
    for e in expected:
        assert e in c


@pytest.mark.skipif(
    not sys.platform.startswith("linux")
    or shutil.which("gcc") is None
    or shutil.which("ocamlfind") is None
    and not Path("/usr/lib/ocaml/caml").is_dir(),
    reason="needs Linux (ELF), gcc and OCaml headers",
)
def test_elf_blob_compiles(sample: Dict[str, Path], tmp_path: Path) -> None:
    ocaml_where = (
        subprocess.run(
            ["ocamlfind", "ocamlc", "-where"], capture_output=True, text=True
        ).stdout.strip()
        if shutil.which("ocamlfind")
        else "/usr/lib/ocaml"
    )
    obj = tmp_path / "blob.o"
    subprocess.run(
        [
            "gcc",
            "-std=c99",
            "-Wall",
            "-Wextra",
            "-Werror",
            f"-I{ocaml_where}",
            "-c",
            "sample_bundle_blob.c",
            "-o",
            str(obj),
        ],
        cwd=sample["out"],
        check=True,
    )
    nm = subprocess.run(
        ["nm", str(obj)], capture_output=True, text=True, check=True
    ).stdout
    assert (
        " R sample_bundle\n" in nm
        and " R sample_bundle_len\n" in nm
        and " T sboa_incbin_sample_bundle\n" in nm
    )
    size = subprocess.run(
        ["size", "-A", str(obj)], capture_output=True, text=True
    ).stdout
    assert (
        str((sample["out"] / "sample_bundle.zip").stat().st_size) in size
        or ".rodata" in size
    )


@needs_builtin_extensions
def test_imports_resources_metadata(sample: Dict[str, Path], stdlib_zip: Path) -> None:
    r = run_isolated(
        """
        import samplepkg, samplepkg.sub.mod as mod
        RESULT["file"] = samplepkg.__file__
        RESULT["path"] = list(samplepkg.__path__)
        RESULT["mod_file"] = mod.__file__
        RESULT["doc"] = samplepkg.__doc__
        RESULT["json"] = mod.table()
        import csv
        RESULT["csv_origin"] = csv.__spec__.origin
        RESULT["is_pkg"] = [samplepkg.__spec__.loader.is_package("samplepkg"), mod.__loader__.is_package("samplepkg.sub.mod")]
        RESULT["source"] = mod.__loader__.get_source("samplepkg.sub.mod")
        RESULT["get_data"] = mod.__loader__.get_data("<sboa:sample>/samplepkg/data/info.txt").decode()
        try:
            mod.__loader__.get_data("<sboa:sample>/samplepkg/missing.txt")
        except FileNotFoundError as e:
            RESULT["get_data_missing"] = type(e).__name__

        import importlib.resources as ir
        root = ir.files("samplepkg")
        RESULT["res_text"] = (root / "data" / "info.txt").read_text()
        RESULT["res_json"] = (ir.files("samplepkg.sub") / "res.json").read_bytes().decode()
        RESULT["res_iter"] = sorted(p.name for p in root.iterdir())
        RESULT["res_is_dir"] = (root / "data").is_dir()
        with ir.as_file(root / "data" / "info.txt") as p:
            RESULT["as_file"] = open(p).read()
        RESULT["res_mod_anchor"] = (ir.files(mod) / "res.json").is_file()

        import importlib.metadata as md
        RESULT["version"] = md.version("samplewheel")
        RESULT["version_norm"] = md.version("SampleWheel")
        RESULT["dist_name"] = md.distribution("samplewheel").metadata["Name"]
        RESULT["eps"] = [(e.name, e.value) for e in md.entry_points(group="sample.plugins")]
        try:
            md.version("not-there")
        except md.PackageNotFoundError:
            RESULT["missing_dist"] = True
        import samplewheel
        RESULT["wheel_version_at_import"] = samplewheel.VERSION
        RESULT["pem"] = (ir.files("samplewheel") / "cacert.pem").read_text()

        import nsroot.part_a, nsroot.part_b
        RESULT["ns"] = [nsroot.part_a.NAME, nsroot.part_b.NAME, sorted(nsroot.__path__)]

        import tomllib
        RESULT["tomllib_file"] = tomllib.__file__
        """,
        bundles(sample, stdlib_zip),
    )
    assert r["file"] == "<sboa:sample>/samplepkg/__init__.py"
    assert r["path"] == ["<sboa:sample>/samplepkg"]
    assert r["mod_file"] == "<sboa:sample>/samplepkg/sub/mod.py"
    assert r["doc"] == "Sample package docstring (kept at optimization 0)."
    assert r["json"] == {"a": 1}
    assert r["csv_origin"] == "<sboa:stdlib>/csv.py"
    assert r["is_pkg"] == [True, False]
    assert r["source"] is None
    assert r["get_data"] == "hello resource\n"
    assert r["get_data_missing"] == "FileNotFoundError"
    assert r["res_text"] == "hello resource\n"
    assert r["res_json"] == '{"answer": 42}'
    assert r["res_iter"] == ["__init__.pyc", "data", "sub"]
    assert r["res_is_dir"] is True
    assert r["as_file"] == "hello resource\n"
    assert r["res_mod_anchor"] is True
    assert r["version"] == "1.2.3" and r["version_norm"] == "1.2.3"
    assert r["dist_name"] == "SampleWheel"
    assert r["eps"] == [["first", "samplewheel:VERSION"]]
    assert r["missing_dist"] is True
    assert r["wheel_version_at_import"] == "1.2.3"
    assert r["pem"].startswith("-----BEGIN CERT")
    assert r["ns"] == ["a", "b", ["<sboa:deps>/nsroot", "<sboa:ns>/nsroot"]]
    assert r["tomllib_file"] == "<sboa:stdlib>/tomllib/__init__.py"


def test_extension_module(sample: Dict[str, Path], stdlib_zip: Path) -> None:
    r = run_isolated(
        """
        import _sboa_stubext
        RESULT["answer"] = _sboa_stubext.ANSWER
        RESULT["file"] = _sboa_stubext.__file__
        RESULT["loader"] = type(_sboa_stubext.__loader__).__name__
        try:
            import _sboa_no_such_ext
        except ModuleNotFoundError:
            RESULT["missing"] = True
        """,
        bundles(sample, stdlib_zip),
        libdynload=sample["dynload"],
    )
    assert r["answer"] == 42
    assert (
        r["file"].startswith(str(sample["dynload"]))
        and r["loader"] == "ExtensionFileLoader"
    )
    assert r["missing"] is True


@needs_builtin_extensions
def test_dev_override(sample: Dict[str, Path], stdlib_zip: Path) -> None:
    r = run_isolated(
        """
        import samplepkg, samplepkg.sub.mod
        RESULT["value"] = samplepkg.VALUE
        RESULT["file"] = samplepkg.__file__
        RESULT["sub"] = samplepkg.sub.mod.WHERE
        import samplewheel  # not overridden: still from the bundle
        RESULT["wheel"] = samplewheel.__file__
        """,
        bundles(sample, stdlib_zip),
        dev=[sample["stray"], sample["dev"]],
    )
    assert r["value"] == 2 and r["sub"] == "dev"
    assert r["file"] == str(sample["dev"] / "samplepkg" / "__init__.py")
    assert r["wheel"] == "<sboa:deps>/samplewheel/__init__.py"
    # A bare directory in an override does not shadow the bundled package.
    r = run_isolated(
        "import samplepkg\nRESULT['value'] = samplepkg.VALUE\n",
        bundles(sample, stdlib_zip),
        dev=[sample["stray"]],
    )
    assert r["value"] == 1


@needs_builtin_extensions
def test_traceback(sample: Dict[str, Path], stdlib_zip: Path) -> None:
    r = run_isolated(
        """
        import traceback, inspect, linecache
        import samplepkg.sub.mod as mod
        try:
            mod.boom()
        except ValueError:
            RESULT["tb"] = traceback.format_exc()
        try:
            inspect.getsource(mod.boom)
        except OSError as e:
            RESULT["getsource"] = type(e).__name__
        """,
        bundles(sample, stdlib_zip),
    )
    assert 'File "<sboa:sample>/samplepkg/sub/mod.py", line 6, in boom' in r["tb"]
    assert "ValueError: boom from bundle" in r["tb"]
    assert r["getsource"] == "OSError"


def test_magic_mismatch(sample: Dict[str, Path], tmp_path: Path) -> None:
    bad = tmp_path / "bad.zip"
    with zipfile.ZipFile(sample["out"] / "sample_bundle.zip") as src, zipfile.ZipFile(
        bad, "w"
    ) as dst:
        for i in src.infolist():
            dst.writestr(i, src.read(i))
        dst.comment = b"sboa-bundle/1 name=sample magic=00000000"
    script = f"""
import sys
_m = type(sys)("_sboa_importer")
exec(compile(open({str(IMPORTER)!r}, "rb").read(), "<frozen _sboa_importer>", "exec"), _m.__dict__)
try:
    _m.install([("bad", open({str(bad)!r}, "rb").read())])
except _m.BundleError as e:
    print("BundleError:", e)
"""
    out = subprocess.run(
        [sys.executable, "-I", "-c", script], capture_output=True, text=True
    ).stdout
    assert "BundleError: bundle 'bad' was compiled for bytecode magic 00000000" in out


def test_refuses_native_code(tmp_path: Path) -> None:
    write_tree(
        tmp_path / "src",
        {
            "pkg/__init__.py": "",
            "pkg/_speedups.cpython-313-x86_64-linux-gnu.so": b"\x7fELF",
        },
    )
    r = run_tool(
        "bundle",
        "--name",
        "x",
        "--package",
        f"pkg={tmp_path / 'src' / 'pkg'}",
        "--out",
        str(tmp_path / "o"),
        check=False,
    )
    assert r.returncode == 1
    assert (
        "refusing native code in bundle 'x': pkg/_speedups.cpython-313-x86_64-linux-gnu.so"
        in r.stderr
    )
    # Same for a compiled wheel.
    make_wheel(
        tmp_path / "w",
        "fast-1.0-cp313-cp313-manylinux_2_17_x86_64.whl",
        {"fast/__init__.py": ""},
    )
    r = run_tool(
        "bundle",
        "--name",
        "x",
        "--wheels",
        str(tmp_path / "w"),
        "--out",
        str(tmp_path / "o"),
        check=False,
    )
    assert r.returncode == 1 and "only compiled wheels for fast" in r.stderr


def test_pure_wheel_selection_with_lock(tmp_path: Path) -> None:
    w = tmp_path / "w"
    pure = make_wheel(
        w,
        "dual-2.0-py3-none-any.whl",
        {
            "dual/__init__.py": "PURE = True\n",
            "dual-2.0.dist-info/METADATA": "Name: dual\nVersion: 2.0\n",
        },
    )
    comp = make_wheel(
        w,
        "dual-2.0-cp313-cp313-manylinux_2_17_x86_64.whl",
        {"dual/__init__.py": "", "dual/_c.cpython-313-x86_64-linux-gnu.so": "x"},
    )

    def h(p: Path) -> str:
        return "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest()

    lock = tmp_path / "uv.lock"
    lock.write_text(
        f"""version = 1
[[package]]
name = "app"
version = "0.1"
source = {{ virtual = "." }}
dependencies = [{{ name = "dual" }}]
[[package]]
name = "dual"
version = "2.0"
wheels = [
  {{ url = "https://example.invalid/{comp.name}", hash = "{h(comp)}" }},
  {{ url = "https://example.invalid/{pure.name}", hash = "{h(pure)}" }},
]
"""
    )
    run_tool(
        "bundle",
        "--name",
        "d",
        "--wheels",
        str(w),
        "--lock",
        str(lock),
        *TARGET,
        "--out",
        str(tmp_path / "o"),
    )
    with zipfile.ZipFile(tmp_path / "o" / "d_bundle.zip") as zf:
        assert "dual/__init__.pyc" in zf.namelist()
        assert not any(".so" in n for n in zf.namelist())
    # A wheel the lock does not list is rejected.
    pure.write_bytes(pure.read_bytes() + b"tampered")
    r = run_tool(
        "bundle",
        "--name",
        "d",
        "--wheels",
        str(w),
        "--lock",
        str(lock),
        *TARGET,
        "--out",
        str(tmp_path / "o"),
        check=False,
    )
    assert r.returncode == 1 and "sha256 not listed in the lock" in r.stderr


def test_marker_evaluation() -> None:
    sys.path.insert(0, str(TOOL.parent))
    try:
        import sboa_bundle as pb
    finally:
        sys.path.pop(0)
    env = pb.target_marker_env("3.13.16", "linux-gnu-x86_64")
    assert pb.eval_marker("sys_platform == 'win32'", env) is False
    assert pb.eval_marker("sys_platform != 'emscripten'", env) is True
    assert pb.eval_marker("platform_python_implementation != 'PyPy'", env) is True
    assert pb.eval_marker(
        "implementation_name != 'PyPy' and platform_python_implementation != 'PyPy'",
        env,
    )
    assert pb.eval_marker(
        "python_full_version < '3.11' or (sys_platform == 'linux' and python_version >= '3.10')",
        env,
    )
    assert pb.eval_marker("'linux' in sys_platform", env)
    assert (
        pb.eval_marker(
            "sys_platform == 'win32'", pb.target_marker_env("3.13", "windows-x86_64")
        )
        is True
    )


def test_freeze_table(tmp_path: Path) -> None:
    out = tmp_path / "frozen.c"
    run_tool(
        "freeze",
        "--module",
        f"_sboa_importer={IMPORTER}",
        "--package",
        f"encodings={STDLIB_DIR / 'encodings'}",
        "--out",
        str(out),
    )
    c = out.read_text()
    assert "const struct sboa_frozen_entry sboa_frozen_table[] = {" in c
    assert "#include" not in c  # no Python.h: compiles without CPython flags
    assert '{"_sboa_importer", sboa_frozen_' in c
    assert '{"encodings", ' in c and ", 1}," in c  # is_package flag
    assert '{"encodings.utf_8", ' in c
    assert c.rstrip().endswith("{0, 0, 0, 0}\n};") or "{0, 0, 0, 0}" in c


EMBED_MAIN_C = r"""
#define PY_SSIZE_T_CLEAN
#include <Python.h>
extern const struct _frozen sboa_frozen_table[];
int main(int argc, char **argv) {
  if (argc < 2) return 2;
  PyImport_FrozenModules = sboa_frozen_table;
  PyConfig config;
  PyConfig_InitIsolatedConfig(&config);
  config.module_search_paths_set = 1; /* empty sys.path */
  config.site_import = 0;
  config.write_bytecode = 0;
  config.install_signal_handlers = 0;
  config.use_frozen_modules = 1;
  config.pathconfig_warnings = 0;
  PyStatus st = Py_InitializeFromConfig(&config);
  PyConfig_Clear(&config);
  if (PyStatus_Exception(st)) Py_ExitStatusException(st);
  int rc = PyRun_SimpleString(argv[1]);
  if (Py_FinalizeEx() < 0) return 120;
  return rc == 0 ? 0 : 1;
}
"""


@needs_builtin_extensions
@pytest.mark.skipif(shutil.which("gcc") is None, reason="needs gcc")
def test_frozen_table_in_embedded_interpreter(tmp_path: Path, stdlib_zip: Path) -> None:
    """Link the frozen table into a real embedding host: start-up with empty sys.path
    succeeds (encodings is frozen) and the frozen importer serves the stdlib bundle."""
    frozen = tmp_path / "frozen.c"
    run_tool(
        "freeze",
        "--module",
        f"_sboa_importer={IMPORTER}",
        "--package",
        f"encodings={STDLIB_DIR / 'encodings'}",
        "--out",
        str(frozen),
    )
    (tmp_path / "main.c").write_text(EMBED_MAIN_C)
    inc = sysconfig.get_paths()["include"]
    libdir = str(Path(sys.base_prefix) / "lib")
    ldlib = f"python{sys.version_info[0]}.{sys.version_info[1]}"
    exe = tmp_path / "host"
    subprocess.run(
        [
            "gcc",
            "-std=c99",
            f"-I{inc}",
            "main.c",
            "frozen.c",
            f"-L{libdir}",
            f"-l{ldlib}",
            f"-Wl,-rpath,{libdir}",
            "-o",
            str(exe),
        ],
        cwd=tmp_path,
        check=True,
    )
    script = f"""
import sys, _sboa_importer
print("SYSPATH", sys.path)
print("IMPORTER_FILE", getattr(_sboa_importer, "__file__", None), _sboa_importer.__spec__.origin)
before = sorted(sys.modules)
with open({str(stdlib_zip)!r}, "rb") as f:
    _sboa_importer.install([("stdlib", memoryview(f.read()))], None, [])
import json, zipfile, importlib.metadata, importlib.resources, email.parser, encodings.cp1252
print("BEFORE", " ".join(before))
print("OK", json.__file__, encodings.cp1252.__spec__.origin)
"""
    r = subprocess.run(
        [str(exe), script], capture_output=True, text=True, env={"LC_ALL": "C.UTF-8"}
    )
    assert r.returncode == 0, r.stderr
    assert "OK <sboa:stdlib>/json/__init__.py frozen" in r.stdout, r.stdout
    before = r.stdout.split("BEFORE ", 1)[1].split("\n", 1)[0].split()
    # The importer's own import chain needs nothing outside builtins and frozen modules.
    assert "importlib" not in before and "zipfile" not in before, before


def test_check_seam(tmp_path: Path) -> None:
    write_tree(
        tmp_path / "src",
        {
            "app/__init__.py": "",
            "app/a.py": """
            import _fake_core
            from _fake_core import used_by_from


            def f():
                return _fake_core.used_attr(1) + getattr(_fake_core, "used_getattr")
            """,
            "app/b.py": """
            def g():
                import _fake_core as core
                return core.used_in_function
            """,
        },
    )
    run_tool(
        "bundle",
        "--name",
        "app",
        "--package",
        f"app={tmp_path / 'src' / 'app'}",
        "--out",
        str(tmp_path / "o"),
        "--zip-only",
    )
    exports = tmp_path / "exports.txt"
    exports.write_text("used_attr\nused_by_from\nused_getattr\nused_in_function\n")
    ok = run_tool(
        "check-seam",
        "--bundle",
        str(tmp_path / "o" / "app_bundle.zip"),
        "--module",
        "_fake_core",
        "--exports",
        str(exports),
        check=False,
    )
    assert ok.returncode == 0, ok.stdout + ok.stderr
    exports.write_text('["_fake_core.used_attr", "used_by_from", "unused_export"]')
    bad = run_tool(
        "check-seam",
        "--bundle",
        str(tmp_path / "o" / "app_bundle.zip"),
        "--module",
        "_fake_core",
        "--exports",
        str(exports),
        check=False,
    )
    assert bad.returncode == 1
    assert "_fake_core.used_getattr is used but not exported: app/a.py:7" in bad.stdout
    assert (
        "_fake_core.used_in_function is used but not exported: app/b.py:4" in bad.stdout
    )
    assert "_fake_core.unused_export is exported but never used" in bad.stdout
    allow = tmp_path / "allow.txt"
    allow.write_text("unused_export\nused_getattr\nused_in_function\n")
    ok = run_tool(
        "check-seam",
        "--bundle",
        str(tmp_path / "o" / "app_bundle.zip"),
        "--module",
        "_fake_core",
        "--exports",
        str(exports),
        "--allow",
        str(allow),
        check=False,
    )
    assert ok.returncode == 0, ok.stdout


def test_check_seam_via_reexport(tmp_path: Path) -> None:
    """A thin module imports the native module once; other modules import it from there."""
    write_tree(
        tmp_path / "src",
        {
            "app/__init__.py": "",
            "app/api.py": """
            try:
                import _fake_core as core
            except ImportError:
                core = None
            IN_BINARY = core.__name__ == "_fake_core"
            """,
            "app/user.py": """
            from app.api import core


            def f():
                return core.rpc(1)
            """,
        },
    )
    run_tool(
        "bundle",
        "--name",
        "app",
        "--package",
        f"app={tmp_path / 'src' / 'app'}",
        "--out",
        str(tmp_path / "o"),
        "--zip-only",
    )
    exports = tmp_path / "exports.txt"
    exports.write_text("rpc\n")
    args = [
        "check-seam",
        "--bundle",
        str(tmp_path / "o" / "app_bundle.zip"),
        "--module",
        "_fake_core",
        "--exports",
        str(exports),
    ]
    # without --via the use through app.api is invisible: the export looks unused
    bad = run_tool(*args, check=False)
    assert bad.returncode == 1
    assert "_fake_core.rpc is exported but never used" in bad.stdout
    ok = run_tool(*args, "--via", "app.api:core", check=False)
    assert ok.returncode == 0, ok.stdout + ok.stderr


@needs_builtin_extensions
@pytest.mark.parametrize("libdynload", [None, "/nonexistent/sboa/lib-dynload"])
def test_no_libdynload(
    sample: Dict[str, Path], stdlib_zip: Path, libdynload: Any
) -> None:
    """Linux/macOS ship no extension files: a missing or absent lib-dynload is fine."""
    r = run_isolated(
        """
        import samplepkg, csv
        RESULT["ok"] = (samplepkg.VALUE, csv.__spec__.origin)
        try:
            import _sboa_stubext
        except ModuleNotFoundError as e:
            RESULT["missing"] = e.name
        """,
        bundles(sample, stdlib_zip),
        libdynload=libdynload,
    )
    assert r["ok"] == [1, "<sboa:stdlib>/csv.py"]
    assert r["missing"] == "_sboa_stubext"


def _lock_for(wheels: Dict[str, Path], path: Path) -> None:
    def h(p: Path) -> str:
        return "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest()

    entries = ",\n".join(
        f'  {{ url = "https://example.invalid/{w.name}", hash = "{h(w)}" }}'
        for w in wheels.values()
    )
    path.write_text(
        f'version = 1\n[[package]]\nname = "dual"\nversion = "2.0"\nwheels = [\n{entries}\n]\n'
    )


def test_fetch_wheels_offline_and_exit_codes(tmp_path: Path) -> None:
    src = tmp_path / "src"
    pure = make_wheel(src, "dual-2.0-py3-none-any.whl", {"dual/__init__.py": ""})
    comp = make_wheel(
        src, "dual-2.0-cp313-cp313-manylinux_2_17_x86_64.whl", {"dual/__init__.py": ""}
    )
    lock = tmp_path / "uv.lock"
    _lock_for({"pure": pure, "comp": comp}, lock)
    req = tmp_path / "req.txt"
    req.write_text(
        "dual==2.0 \\\n    --hash=sha256:00\nnotneeded==1.0 ; sys_platform == 'win32'\n"
    )
    d = tmp_path / "wheels"
    d.mkdir()
    shutil.copy(pure, d / pure.name)
    base = [
        "fetch-wheels",
        "--lock",
        str(lock),
        "--requirements",
        str(req),
        "-d",
        str(d),
        *TARGET,
    ]
    # Present with the right hash: reused without network (the URL is unreachable),
    # with and without --offline.
    extras: List[List[str]] = [[], ["--offline"]]
    for extra in extras:
        r = run_tool(*base, *extra, check=False)
        assert r.returncode == 0, r.stderr
        assert r.stdout.split() == [pure.name]
        assert "notneeded (marker: sys_platform == 'win32')" in r.stderr
    # Tampered file: offline refuses, exit 1.
    (d / pure.name).write_bytes(b"tampered")
    r = run_tool(*base, "--offline", check=False)
    assert r.returncode == 1 and "sha256 does not match the lock" in r.stderr
    # Missing file offline: exit 1.
    (d / pure.name).unlink()
    r = run_tool(*base, "--offline", check=False)
    assert r.returncode == 1 and "missing (offline)" in r.stderr
    # Online, missing, unreachable URL: exit 1 with a clear message, no traceback.
    r = run_tool(*base, check=False)
    assert (
        r.returncode == 1
        and "download failed" in r.stderr
        and "Traceback" not in r.stderr
    )
    # Only a compiled wheel in the lock: exit 1, nothing fetched.
    _lock_for({"comp": comp}, lock)
    r = run_tool(*base, "--offline", check=False)
    assert r.returncode == 1 and "the lock has no py3-none-any wheel" in r.stderr
    # Usage error: exit 2.
    r = run_tool("fetch-wheels", "--lock", str(lock), check=False)
    assert r.returncode == 2


def test_fetch_wheels_lock_closure(tmp_path: Path) -> None:
    """Without ``--requirements`` the closure comes from the lock itself: the
    editable root's dependencies, extras, markers evaluated, no dev groups."""
    src = tmp_path / "src"
    whl = {
        n: make_wheel(src, f"{n}-1.0-py3-none-any.whl", {f"{n}/__init__.py": ""})
        for n in ("dual", "withextra", "extradep", "winonly", "devdep")
    }

    def pkg(name: str, deps: str = "", extra: str = "") -> str:
        h = hashlib.sha256(whl[name].read_bytes()).hexdigest()
        return (
            f'[[package]]\nname = "{name}"\nversion = "1.0"\n'
            f"dependencies = [{deps}]\n"
            f'wheels = [{{ url = "https://example.invalid/{whl[name].name}",'
            f' hash = "sha256:{h}" }}]\n{extra}'
        )

    lock = tmp_path / "uv.lock"
    lock.write_text(
        "version = 1\n"
        '[[package]]\nname = "app"\nversion = "0.1"\nsource = { editable = "." }\n'
        'dependencies = [{ name = "dual" }, { name = "withextra", extra = ["x"] },'
        ' { name = "winonly", marker = "sys_platform == \'win32\'" }]\n'
        '[package.dev-dependencies]\ndev = [{ name = "devdep" }]\n'
        + pkg("dual")
        + pkg(
            "withextra",
            extra='[package.optional-dependencies]\nx = [{ name = "extradep" }]\n',
        )
        + pkg("extradep")
        + pkg("winonly")
        + pkg("devdep")
    )
    d = tmp_path / "wheels"
    d.mkdir()
    for w in whl.values():
        shutil.copy(w, d / w.name)
    base = ["fetch-wheels", "--lock", str(lock), "-d", str(d), "--offline"]
    r = run_tool(
        *base,
        "--python-version",
        "3.13.16",
        "--platform",
        "linux-gnu-x86_64",
        check=False,
    )
    assert r.returncode == 0, r.stderr
    assert r.stdout.split() == [whl[n].name for n in ("dual", "extradep", "withextra")]
    r = run_tool(
        *base,
        "--python-version",
        "3.13.16",
        "--platform",
        "windows-x86_64",
        check=False,
    )
    assert "winonly-1.0-py3-none-any.whl" in r.stdout.split()
    r = run_tool(
        *base,
        "--python-version",
        "3.13",
        "--platform",
        "linux-gnu-x86_64",
        "--root",
        "nosuchpkg",
        check=False,
    )
    assert (
        r.returncode == 1 and "root package 'nosuchpkg' is not in the lock" in r.stderr
    )


def test_config_and_target_system(tmp_path: Path) -> None:
    """``--config`` supplies the interpreter and stdlib dir (the dune rule's
    only input); ``--target-system`` maps dune's %{system}."""
    cfg = tmp_path / "sboa.config"
    cfg.write_text(
        f'((version "3.13")\n (magic 3571)\n (stdlib_dir "{STDLIB_DIR}")\n'
        f' (python_exe "{sys.executable}")\n (runtime_files (("a" "b"))))\n'
    )
    run_tool(
        "--config",
        str(cfg),
        "embed",
        "--zip",
        str(TOOL),
        "--name",
        "t",
        "--target-system",
        "macosx",
        "--out",
        str(tmp_path / "m"),
    )
    assert "__TEXT,__const" in (tmp_path / "m" / "t_bundle_blob.c").read_text()
    frozen = tmp_path / "frozen.c"
    run_tool(
        "--config",
        str(cfg),
        "freeze",
        "--module",
        f"_sboa_importer={IMPORTER}",
        "--stdlib-package",
        "encodings",
        "--out",
        str(frozen),
    )
    assert '{"encodings.utf_8", ' in frozen.read_text()
    for system, needle in [
        ("mingw64", ".rdata"),
        ("linux", ".rodata"),
        ("freebsd", ".rodata"),
    ]:
        run_tool(
            "embed",
            "--zip",
            str(TOOL),
            "--name",
            "t",
            "--target-system",
            system,
            "--out",
            str(tmp_path / system),
        )
        assert needle in (tmp_path / system / "t_bundle_blob.c").read_text()


# ---------------------------------------------------------------------------
# Polish round (review items 11-20)
# ---------------------------------------------------------------------------


def _tool_module() -> Any:
    sys.path.insert(0, str(TOOL.parent))
    try:
        import sboa_bundle as pb
    finally:
        sys.path.pop(0)
    return pb


@needs_builtin_extensions
def test_namespace_package_resources(sample: Dict[str, Path], stdlib_zip: Path) -> None:
    """Item 11: importlib.resources.files() on a namespace package spanning bundles."""
    r = run_isolated(
        """
        import importlib.resources as ir, nsroot
        root = ir.files("nsroot")
        RESULT["names"] = sorted(p.name for p in root.iterdir())
        RESULT["data"] = (root / "ns_data.txt").read_text()
        RESULT["loader"] = type(nsroot.__spec__.loader).__name__
        RESULT["path"] = sorted(nsroot.__path__)
        import nsroot.part_b
        RESULT["sub"] = nsroot.part_b.NAME
        """,
        bundles(sample, stdlib_zip),
    )
    assert r["names"] == ["ns_data.txt", "part_a", "part_b"]
    assert r["data"] == "ns data\n"
    assert r["loader"] == "_NamespaceLoader"
    assert r["path"] == ["<sboa:deps>/nsroot", "<sboa:ns>/nsroot"]
    assert r["sub"] == "b"


@needs_builtin_extensions
def test_stdlib_dir_package_submodules_from_bundle(
    sample: Dict[str, Path], stdlib_zip: Path
) -> None:
    """Item 12: a package whose __path__ is under sys._stdlib_dir (frozen packages
    get that) has its submodules served from the bundles, not from disk."""
    r = run_isolated(
        """
        import encodings
        RESULT["parent_path"] = list(encodings.__path__)
        RESULT["stdlib_dir"] = sys._stdlib_dir
        import encodings.cp1250
        RESULT["origin"] = encodings.cp1250.__spec__.origin
        """,
        bundles(sample, stdlib_zip),
    )
    assert r["parent_path"][0].startswith(r["stdlib_dir"])
    assert r["origin"] == "<sboa:stdlib>/encodings/cp1250.py"


def _install_error(data: bytes, name: str = "b") -> str:
    script = f"""
import sys
_m = type(sys)("_sboa_importer")
exec(compile(open({str(IMPORTER)!r}, "rb").read(), "<frozen _sboa_importer>", "exec"), _m.__dict__)
import zlib  # builtin or not, as in conftest.PRELUDE
sys.path[:] = []
try:
    f = _m.install([({name!r}, {data!r})])
    import corruptpkg
    print("NO ERROR")
except _m.BundleError as e:
    print("BundleError:", e)
"""
    return subprocess.run(
        [sys.executable, "-I", "-S", "-c", script], capture_output=True, text=True
    ).stdout


def test_corrupt_bundles(tmp_path: Path) -> None:
    """Item 13: malformed bundles and names raise BundleError, not random errors."""
    write_tree(tmp_path / "src", {"corruptpkg/__init__.py": "X = 1\n" * 200})
    run_tool(
        "bundle",
        "--name",
        "b",
        "--package",
        f"corruptpkg={tmp_path / 'src' / 'corruptpkg'}",
        "--out",
        str(tmp_path / "o"),
        "--zip-only",
    )
    good = (tmp_path / "o" / "b_bundle.zip").read_bytes()
    assert "NO ERROR" in _install_error(good)
    assert "BundleError: bundle 'b': not a zip archive" in _install_error(b"garbage")
    assert "BundleError: bundle 'b': truncated central directory" in _install_error(
        good[:30] + good[good.rindex(b"PK\x05\x06") :]
    )
    # Corrupt deflate stream of the member.
    i = good.index(b"corruptpkg/__init__.pyc") + len("corruptpkg/__init__.pyc")
    bad = good[:i] + bytes(b ^ 0xFF for b in good[i : i + 40]) + good[i + 40 :]
    assert "is corrupt" in _install_error(bad) or "wrong size" in _install_error(bad)
    # Non-UTF-8 member name (same length, so offsets stay valid; general-purpose
    # flag bit 11 is set by zipfile, so the name must decode as UTF-8).
    bad_name = good.replace(
        b"corruptpkg/__init__.pyc", b"corruptpkg/__init__\xff\xfe\xfdc"
    )
    assert "is not UTF-8" in _install_error(bad_name)
    # Malformed magic in the comment.
    bad_magic = good.replace(b"magic=", b"magic=zz")[: len(good) + 2]
    out = _install_error(bad_magic)
    assert "BundleError" in out
    # Bundle names are restricted (they end up in <sboa:NAME> paths).
    assert "invalid bundle name 'a b>'" in _install_error(good, name="a b>")
    r = run_tool("bundle", "--name", 'x"y', "--out", str(tmp_path / "o2"), check=False)
    assert r.returncode == 2 and "invalid bundle name" in r.stderr


def _closure_lock(tmp_path: Path) -> Tuple[Path, Dict[str, Path], Path]:
    src = tmp_path / "src"
    whl = {
        n: make_wheel(src, f"{n}-1.0-py3-none-any.whl", {f"{n}/__init__.py": ""})
        for n in ("core", "oldpy", "winonly")
    }

    def h(n: str) -> str:
        return hashlib.sha256(whl[n].read_bytes()).hexdigest()

    pkgs = "".join(
        f'[[package]]\nname = "{n}"\nversion = "1.0"\n'
        f'wheels = [{{ url = "https://example.invalid/{whl[n].name}", hash = "sha256:{h(n)}" }}]\n'
        for n in whl
    )
    lock = tmp_path / "uv.lock"
    lock.write_text(
        "version = 1\n"
        '[[package]]\nname = "app"\nversion = "0.1"\nsource = { virtual = "." }\n'
        'dependencies = [{ name = "core" },'
        ' { name = "oldpy", marker = "python_full_version < \'3.12\'" },'
        ' { name = "winonly", marker = "sys_platform == \'win32\'" }]\n' + pkgs
    )
    d = tmp_path / "wheels"
    d.mkdir()
    for w in whl.values():
        shutil.copy(w, d / w.name)
    return lock, whl, d


def test_fetch_wheels_markers_follow_embedded_target(tmp_path: Path) -> None:
    """Item 14: markers are evaluated for the embedded interpreter, not the host."""
    lock, whl, d = _closure_lock(tmp_path)
    base = ["fetch-wheels", "--lock", str(lock), "-d", str(d), "--offline"]

    def fetched(*target: str) -> List[str]:
        r = run_tool(*base, *target, check=False)
        assert r.returncode == 0, r.stderr
        return sorted(r.stdout.split())

    assert fetched("--python-version", "3.13.16", "--platform", "linux-gnu-x86_64") == [
        whl["core"].name
    ]
    assert fetched(
        "--python-version", "3.11.9", "--platform", "linux-gnu-x86_64"
    ) == sorted([whl["core"].name, whl["oldpy"].name])
    assert fetched(
        "--python-version", "3.13.16", "--platform", "windows-x86_64"
    ) == sorted([whl["core"].name, whl["winonly"].name])
    cfg = tmp_path / "sboa.config"
    cfg.write_text(
        f'((version "3.11.2")\n (platform "windows-x86_64")\n (stdlib_dir "{STDLIB_DIR}")\n'
        f' (python_exe "{sys.executable}"))\n'
    )
    r = run_tool("--config", str(cfg), *base, check=False)
    assert r.returncode == 0, r.stderr
    assert sorted(r.stdout.split()) == sorted(w.name for w in whl.values())
    # Neither the config nor an explicit target: usage error (exit 2).
    r = run_tool(*base, check=False)
    assert r.returncode == 2 and "--config" in r.stderr
    r = run_tool(
        *base, "--python-version", "3.13", "--platform", "solaris-sparc", check=False
    )
    assert r.returncode == 2 and "unknown platform" in r.stderr


def test_fetch_wheels_prune(tmp_path: Path) -> None:
    """``--prune`` deletes the wheels the lock does not select, after a
    successful fetch only."""
    lock, whl, d = _closure_lock(tmp_path)
    stale = d / "stale-9.9-py3-none-any.whl"
    stale.write_bytes(b"not a wheel")
    base = ["fetch-wheels", "--lock", str(lock), "-d", str(d), "--offline", "--prune"]
    linux = ["--python-version", "3.13.16", "--platform", "linux-gnu-x86_64"]
    # A failed fetch (the closure needs a wheel that is missing) prunes nothing.
    (d / whl["core"].name).rename(tmp_path / "away.whl")
    r = run_tool(*base, *linux, check=False)
    assert r.returncode == 1 and "missing (offline)" in r.stderr
    assert sorted(p.name for p in d.glob("*.whl")) == sorted(
        [stale.name, whl["oldpy"].name, whl["winonly"].name]
    )
    (tmp_path / "away.whl").rename(d / whl["core"].name)
    r = run_tool(*base, *linux, check=False)
    assert r.returncode == 0, r.stderr
    assert r.stdout.split() == [whl["core"].name]
    assert "removing stale" in r.stderr
    assert [p.name for p in d.glob("*.whl")] == [whl["core"].name]


def test_runtime_files(tmp_path: Path) -> None:
    """``runtime-files`` stages the config's files for the matching layout
    only, and ``--check-install-list`` compares the bin layout with the dune
    install stanza."""
    src = tmp_path / "src"
    src.mkdir()
    (src / "python313.dll").write_bytes(b"dll")
    (src / "_ssl.pyd").write_bytes(b"pyd")
    cfg = tmp_path / "sboa.config"
    cfg.write_text(
        f'((version "3.13.16")\n (stdlib_dir "{STDLIB_DIR}")\n'
        f' (python_exe "{sys.executable}")\n (runtime_subdir "")\n'
        f' (runtime_files (("{src / "python313.dll"}" "python313.dll")'
        f' ("{src / "_ssl.pyd"}" "_ssl.pyd"))))\n'
    )
    cmd = ["--config", str(cfg), "runtime-files"]
    # The other layout: an empty directory, no check.
    run_tool(*cmd, "--layout", "libs", "--out", str(tmp_path / "libs"))
    assert list((tmp_path / "libs").iterdir()) == []
    dune = tmp_path / "dune"
    dune.write_text(
        "(install\n (files\n  (runtime_bin/python313.dll as python313.dll)"
        "\n  ; (runtime_bin/old.pyd as old.pyd)\n  (runtime_bin/_ssl.pyd as _ssl.pyd)))\n"
    )
    out = tmp_path / "bin"
    check = ["--layout", "bin", "--out", str(out), "--check-install-list", str(dune)]
    run_tool(*cmd, *check)
    assert sorted(p.name for p in out.iterdir()) == ["_ssl.pyd", "python313.dll"]
    dune.write_text("(install (files (runtime_bin/python313.dll as python313.dll)))\n")
    r = run_tool(*cmd, *check, check=False)
    assert r.returncode == 1 and "staged but not installed: _ssl.pyd" in r.stderr


def test_bundle_lock_checks_closure(tmp_path: Path) -> None:
    """Item 14: ``bundle --lock`` refuses a wheel set that is not the closure."""
    lock, whl, d = _closure_lock(tmp_path)
    out = str(tmp_path / "o")
    base = ["bundle", "--name", "d", "--lock", str(lock), "--out", out, "--zip-only"]
    linux = ["--python-version", "3.13.16", "--platform", "linux-gnu-x86_64"]
    r = run_tool(*base, "--wheels", str(d), *linux, check=False)
    assert r.returncode == 1
    assert "not in the closure: oldpy==1.0, winonly==1.0" in r.stderr
    r = run_tool(*base, "--wheels", str(d / whl["core"].name), *linux, check=False)
    assert r.returncode == 0, r.stderr
    r = run_tool(
        *base,
        "--wheels",
        str(d / whl["core"].name),
        "--python-version",
        "3.11",
        "--platform",
        "linux-gnu-x86_64",
        check=False,
    )
    assert r.returncode == 1 and "missing: oldpy==1.0" in r.stderr
    excl = tmp_path / "excludes"
    excl.write_text("# none of these\noldpy\n")
    r = run_tool(
        *base,
        "--wheels",
        str(d / whl["core"].name),
        "--python-version",
        "3.11",
        "--platform",
        "linux-gnu-x86_64",
        "--exclude-dist-file",
        str(excl),
        check=False,
    )
    assert r.returncode == 0, r.stderr


def test_lock_versions_and_requirement_shapes(tmp_path: Path) -> None:
    """Item 15: packages are keyed by (name, version); -e/URL lines fail."""
    pb = _tool_module()
    lock = tmp_path / "uv.lock"
    lock.write_text(
        "version = 1\n"
        '[[package]]\nname = "app"\nversion = "0.1"\nsource = { virtual = "." }\n'
        'dependencies = [{ name = "lib", version = "2.0" }]\n'
        '[[package]]\nname = "lib"\nversion = "1.0"\n'
        '[[package]]\nname = "lib"\nversion = "2.0"\n'
    )
    env = pb.target_marker_env("3.13", "linux-gnu-x86_64")
    assert pb.lock_closure(lock, None, env) == [("lib", "2.0", "")]
    lock.write_text(lock.read_text().replace(', version = "2.0"', ""))
    with pytest.raises(pb.ToolError, match="several versions"):
        pb.lock_closure(lock, None, env)
    for line in [
        "-e .",
        "--index-url https://x",
        "pkg @ https://example.invalid/p.whl",
    ]:
        req = tmp_path / "req.txt"
        req.write_text(line + "\n")
        r = run_tool(
            "fetch-wheels",
            "--lock",
            str(lock),
            "--requirements",
            str(req),
            "-d",
            str(tmp_path / "w"),
            "--offline",
            *TARGET,
            check=False,
        )
        assert r.returncode == 1 and "unsupported" in r.stderr, (line, r.stderr)


def test_pure_wheel_policy_gaps(tmp_path: Path) -> None:
    """Item 16: py3 tag required, Root-Is-Purelib honoured, .pth / symlinks /
    non-normalised names refused."""

    def bundle_wheel(
        fn: str, files: Dict[str, str], wheel_text: Optional[str] = None
    ) -> "subprocess.CompletedProcess[str]":
        d = tmp_path / fn
        p = make_wheel(d, fn, files)
        if wheel_text is not None:
            with zipfile.ZipFile(p, "a") as zf:
                zf.writestr("x-1.0.dist-info/WHEEL", wheel_text)
        return run_tool(
            "bundle",
            "--name",
            "w",
            "--wheels",
            str(p),
            "--out",
            str(tmp_path / "o"),
            "--zip-only",
            check=False,
        )

    r = bundle_wheel("x-1.0-py2-none-any.whl", {"x/__init__.py": ""})
    assert r.returncode == 1 and "only compiled wheels" in r.stderr
    assert (
        bundle_wheel("x-1.0-py2.py3-none-any.whl", {"x/__init__.py": ""}).returncode
        == 0
    )
    r = bundle_wheel(
        "x-1.0-py3-none-any.whl",
        {"x/__init__.py": ""},
        "Wheel-Version: 1.0\nRoot-Is-Purelib: false\n",
    )
    assert r.returncode == 1 and "Root-Is-Purelib: false" in r.stderr
    r = bundle_wheel(
        "x-1.0-py3-none-any.whl", {"x/__init__.py": "", "x-nspkg.pth": "import x"}
    )
    assert r.returncode == 1 and ".pth files run code" in r.stderr
    r = bundle_wheel(
        "x-1.0-py3-none-any.whl", {"x/__init__.py": "", "x/../../evil.py": ""}
    )
    assert r.returncode == 1 and "non-normalised member name" in r.stderr
    # Symlink member.
    p = make_wheel(tmp_path / "sym", "x-1.0-py3-none-any.whl", {"x/__init__.py": ""})
    with zipfile.ZipFile(p, "a") as zf:
        info = zipfile.ZipInfo("x/link.py")
        info.external_attr = 0o120777 << 16
        zf.writestr(info, "../etc/passwd")
    r = run_tool(
        "bundle",
        "--name",
        "w",
        "--wheels",
        str(p),
        "--out",
        str(tmp_path / "o"),
        "--zip-only",
        check=False,
    )
    assert r.returncode == 1 and "refusing symlink member" in r.stderr
    # Installed tree with a .pth, and a package tree with a symlinked module.
    site = tmp_path / "site"
    write_tree(site, {"y/__init__.py": "", "distutils-precedence.pth": "import os"})
    r = run_tool(
        "bundle",
        "--name",
        "w",
        "--site",
        str(site),
        "--out",
        str(tmp_path / "o"),
        "--zip-only",
        check=False,
    )
    assert r.returncode == 1 and ".pth files run code" in r.stderr
    pkg = tmp_path / "pkg" / "z"
    write_tree(pkg, {"__init__.py": "", "real.py": "A = 1\n"})
    (pkg / "alias.py").symlink_to(pkg / "real.py")
    r = run_tool(
        "bundle",
        "--name",
        "w",
        "--package",
        f"z={pkg}",
        "--out",
        str(tmp_path / "o"),
        "--zip-only",
        check=False,
    )
    assert r.returncode == 1 and "refusing symlink" in r.stderr


class _FakeResponse:
    def __init__(self, chunks: List[Any]) -> None:
        self._chunks = list(chunks)

    def __enter__(self) -> "_FakeResponse":
        return self

    def __exit__(self, *exc: Any) -> None:
        pass

    def read(self, n: int) -> bytes:
        item = self._chunks.pop(0) if self._chunks else b""
        if isinstance(item, BaseException):
            raise item
        return bytes(item)


def test_download_robustness(tmp_path: Path) -> None:
    """Item 17: timeout is passed, any failure is a ToolError, no .part survives."""
    pb = _tool_module()
    dest = tmp_path / "x-1.0-py3-none-any.whl"
    payload = b"wheel bytes"
    good = hashlib.sha256(payload).hexdigest()
    seen: Dict[str, Any] = {}

    def opener_ok(url: str, timeout: float) -> _FakeResponse:
        seen["timeout"] = timeout
        return _FakeResponse([payload])

    pb.download(
        "https://example.invalid/x.whl", dest, good, timeout=7.5, opener=opener_ok
    )
    assert dest.read_bytes() == payload and seen["timeout"] == 7.5
    dest.unlink()

    def opener_timeout(url: str, timeout: float) -> _FakeResponse:
        raise TimeoutError("timed out")

    def opener_midway(url: str, timeout: float) -> _FakeResponse:
        return _FakeResponse([b"partial", ConnectionResetError("reset")])

    def opener_weird(url: str, timeout: float) -> _FakeResponse:
        return _FakeResponse([ValueError("not an OSError")])

    for opener, needle in [
        (opener_timeout, "TimeoutError: timed out"),
        (opener_midway, "ConnectionResetError: reset"),
        (opener_weird, "ValueError"),
        (opener_ok, "does not match the lock's sha256"),
    ]:
        with pytest.raises(pb.ToolError, match=needle):
            pb.download("https://example.invalid/x.whl", dest, "0" * 64, opener=opener)
        assert not dest.exists()
        assert list(tmp_path.glob("*.part")) == []
    with pytest.raises(pb.ToolError, match="non-https"):
        pb.download("http://example.invalid/x.whl", dest, good, opener=opener_ok)


@pytest.mark.skipif(
    not sys.platform.startswith("linux") or shutil.which("gcc") is None,
    reason="needs Linux (the fixture's blob is ELF) and gcc",
)
def test_blob_length_computed_by_assembler(
    sample: Dict[str, Path], tmp_path: Path
) -> None:
    """Item 18: <sym>_len comes from the assembler and equals the zip size."""
    out = sample["out"]
    blob = (out / "sample_bundle_blob.c").read_text()
    asm = blob.split("__asm__(")[1].split(");")[0]
    (tmp_path / "blob.c").write_text(
        "#include <stddef.h>\n__asm__(" + asm + ");\n"
        "extern const unsigned char sample_bundle[];\nextern const size_t sample_bundle_len;\n"
        '#include <stdio.h>\nint main(void) { printf("%zu %c%c\\n", sample_bundle_len,'
        " sample_bundle[0], sample_bundle[1]); return 0; }\n"
    )
    exe = tmp_path / "blob"
    subprocess.run(
        ["gcc", "-std=c11", "blob.c", f"-Wa,-I{out}", "-o", str(exe)],
        cwd=tmp_path,
        check=True,
    )
    got = subprocess.run(
        [str(exe)], capture_output=True, text=True, check=True
    ).stdout.split()
    assert got == [str((out / "sample_bundle.zip").stat().st_size), "PK"]


def test_stdlib_shadow_refused(tmp_path: Path) -> None:
    """Item 20: third-party bundles may not ship stdlib top-level names."""
    for files in ({"typing.py": "X = 1\n"}, {"queue/__init__.py": ""}):
        p = make_wheel(tmp_path / "w", "shadow-1.0-py3-none-any.whl", files)
        base = [
            "bundle",
            "--name",
            "w",
            "--wheels",
            str(p),
            "--out",
            str(tmp_path / "o"),
            "--zip-only",
        ]
        r = run_tool(*base, check=False)
        assert (
            r.returncode == 1 and "would shadow the standard library module" in r.stderr
        )
        assert run_tool(*base, "--allow-stdlib-shadow", check=False).returncode == 0
        p.unlink()
    # Default priorities: stdlib first.
    pb = _tool_module()
    parser = pb.build_parser()
    std = parser.parse_args(["stdlib", "--out", "x"])
    bun = parser.parse_args(["bundle", "--name", "n", "--out", "x"])
    assert std.priority < bun.priority
