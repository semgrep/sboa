#!/usr/bin/env python3
"""Build-time tool for ``sboa``: Python bundles, the frozen table, the seam check,
the runtime files.

Run it with the embedded interpreter (the bytecode it writes is only valid for the
interpreter that compiled it; with ``--config`` the tool re-executes itself under
the config's ``python_exe``).  Standard library only.

Subcommands::

  bundle        compile packages / wheels into a deterministic zip of unchecked-hash
                .pyc files (+ data files and trimmed *.dist-info) and emit the C/OCaml
                sources that embed it with ``.incbin``
  stdlib        same, for the interpreter's standard library (with the exclusion list)
  embed         emit the C/OCaml embedding sources for an existing bundle zip
  freeze        marshal modules into ``sboa_frozen_table[]`` (C; the layout of
                ``struct _frozen``), optionally with an OCaml module linking it
  check-seam    diff the attributes a bundle's bytecode uses on a module against the
                names the native side exports
  fetch-wheels  download the pure-Python wheels of a ``uv.lock`` closure
                (network: outside opam builds; in dune, a ``(sandbox none)`` rule)
  runtime-files stage the files an application ships next to its executable
                (``runtime_files`` of ``sboa.config``) into a directory target
  describe      write the ``sboa.config`` of a CPython 3.13 installation
  flags         print the C flags or link flags of a config as a dune sexp
  exec          run the interpreter of a config

The installed ``sboa-bundle`` executable runs this script under the CPython sboa
was built against; ``--config`` (the CPython an application ships) then decides
which interpreter does the work.

Determinism: every zip has sorted member names, a fixed 1980-01-01 timestamp, fixed
permissions and no directory entries; ``.pyc`` files use the PEP 552
unchecked-hash header (no mtime) and optimization level 0 (``-OO`` would strip the
docstrings click uses for help).  ``marshal`` output depends on string hashes for
set constants, so the tool re-executes itself with ``PYTHONHASHSEED=0``.

Generated-file contract (see ``docs/single-binary/notes/u3.md``): for ``--name N``
the base name is ``N_bundle`` and the tool writes ``N_bundle.zip``,
``N_bundle_blob.c`` (defines ``const unsigned char N_bundle[]``,
``const size_t N_bundle_len`` and the OCaml primitive ``sboa_incbin_N_bundle``)
and ``N_bundle.ml``.
"""
import argparse
import dis
import hashlib
import importlib.util
import json
import marshal
import os
import re
import shutil
import subprocess
import sys
import tomllib
import types
import urllib.request
import zipfile
from dataclasses import dataclass
from dataclasses import field
from pathlib import Path
from typing import Any
from typing import Dict
from typing import Iterator
from typing import List
from typing import Optional
from typing import Sequence
from typing import Set
from typing import Tuple
from typing import Union

FORMAT_VERSION = 1
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)
NATIVE_SUFFIXES = (".so", ".pyd", ".dylib", ".dll")
# Excluded from the stdlib bundle (SINGLE_BINARY_PLAN.md §3.3): test suites, GUI and
# packaging-time code, plus build artefacts that live under lib/python3.X.
STDLIB_EXCLUDED_TOP = frozenset(
    {
        "test",
        "idlelib",
        "tkinter",
        "turtledemo",
        "ensurepip",
        "lib2to3",
        "pydoc_data",
        "site-packages",
        "lib-dynload",
        "__phello__",
    }
)
STDLIB_EXCLUDED_ANYWHERE = frozenset({"tests", "idle_test", "__pycache__"})
# Files kept from each *.dist-info directory.  importlib.metadata needs METADATA
# (version(), requires()) and entry_points.txt (entry_points()); licences ship with
# the code they cover.
DIST_INFO_KEEP = re.compile(
    r"^(METADATA|entry_points\.txt|top_level\.txt|"
    r"(LICEN[CS]E|COPYING|NOTICE|AUTHORS)[^/]*|licenses/.*)$"
)


class ToolError(Exception):
    """A user-facing build error (printed without a traceback); exit code 1."""

    exit_code = 1


class UsageError(ToolError):
    """A missing or inconsistent command-line option; exit code 2 (as argparse)."""

    exit_code = 2


BUNDLE_NAME_RE = re.compile(r"[A-Za-z0-9_.\-]+")


def validate_bundle_name(name: str) -> str:
    """Bundle names end up in ``<sboa:NAME>`` paths, zip comments and OCaml
    string literals: restrict them to ``[A-Za-z0-9_.-]+``."""
    if not BUNDLE_NAME_RE.fullmatch(name):
        raise UsageError(f"invalid bundle name {name!r} (allowed: [A-Za-z0-9_.-]+)")
    return name


# ---------------------------------------------------------------------------
# Globs and small helpers
# ---------------------------------------------------------------------------


def glob_to_regex(pattern: str) -> "re.Pattern[str]":
    """Translate a ``/``-separated glob (``*``, ``?``, ``**``) to a regex.

    ``**/`` matches zero or more directories, a trailing ``/**`` everything below,
    ``*`` and ``?`` never cross ``/``.
    """
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


class Globs:
    def __init__(self, patterns: Sequence[str]) -> None:
        self.regexes = [glob_to_regex(p) for p in patterns]

    def match(self, path: str) -> bool:
        return any(r.match(path) for r in self.regexes)


def normalize_dist(name: str) -> str:
    """PEP 503 normalization."""
    return re.sub(r"[-_.]+", "-", name).lower()


def is_native(name: str) -> bool:
    base = name.rsplit("/", 1)[-1]
    return base.endswith(NATIVE_SUFFIXES) or ".so." in base


def c_ident(s: str) -> str:
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", s):
        raise ToolError(f"{s!r} is not a valid C identifier")
    return s


# ---------------------------------------------------------------------------
# Compilation
# ---------------------------------------------------------------------------


def compile_pyc(source: bytes, filename: str) -> bytes:
    """Compile ``source`` to an unchecked-hash .pyc image (PEP 552, flags=0b01)."""
    code = compile(source, filename, "exec", dont_inherit=True, optimize=0)
    header = (
        importlib.util.MAGIC_NUMBER
        + (0b01).to_bytes(4, "little")
        + importlib.util.source_hash(source)
    )
    return header + marshal.dumps(code)


# ---------------------------------------------------------------------------
# Bundle contents
# ---------------------------------------------------------------------------


@dataclass
class Member:
    data: bytes
    origin: str  # where it came from, for error messages


def check_member_name(arc: str, origin: str) -> None:
    """Refuse archive names that are not normalised relative POSIX paths."""
    parts = arc.split("/")
    if (
        not arc
        or arc.startswith("/")
        or "\\" in arc
        or any(p in ("", ".", "..") for p in parts)
    ):
        raise ToolError(f"refusing non-normalised member name {arc!r} (from {origin})")


STDLIB_TOP_NAMES = frozenset(sys.stdlib_module_names)


@dataclass
class BundleContents:
    name: str
    members: Dict[str, Member] = field(default_factory=dict)
    allow_stdlib_shadow: bool = False

    def __post_init__(self) -> None:
        validate_bundle_name(self.name)

    def add(self, arc: str, data: bytes, origin: str) -> None:
        check_member_name(arc, origin)
        parts = arc.split("/")
        if len(parts) == 1 and arc.endswith(".pth"):
            raise ToolError(
                f"refusing {arc} (from {origin}): .pth files run code at site "
                "initialisation, which the embedded interpreter never performs"
            )
        if not self.allow_stdlib_shadow:
            top = parts[0]
            if len(parts) == 1:
                top = top[:-4] if top.endswith(".pyc") else ""
            if top in STDLIB_TOP_NAMES:
                raise ToolError(
                    f"refusing {arc} (from {origin}) in bundle {self.name!r}: it "
                    f"would shadow the standard library module {top!r} "
                    "(pass --allow-stdlib-shadow if that is intended)"
                )
        if is_native(arc):
            raise ToolError(
                f"refusing native code in bundle {self.name!r}: {arc} (from {origin}). "
                "Bundles carry bytecode only; use a pure-Python wheel, drop the "
                "dependency, or link the extension into the binary."
            )
        prev = self.members.get(arc)
        if prev is not None:
            raise ToolError(
                f"duplicate member {arc} in bundle {self.name!r}: "
                f"{prev.origin} and {origin}"
            )
        self.members[arc] = Member(data, origin)

    def add_source(self, arc_py: str, source: bytes, origin: str) -> None:
        """Compile ``arc_py`` (a ``.py`` arcname) and add the ``.pyc``."""
        filename = f"<sboa:{self.name}>/{arc_py}"
        try:
            pyc = compile_pyc(source, filename)
        except SyntaxError as e:
            raise ToolError(f"{origin}:{e.lineno}: syntax error: {e.msg}") from None
        self.add(arc_py[:-3] + ".pyc", pyc, origin)


def walk_tree(root: Path) -> Iterator[Tuple[str, Path]]:
    """Yield ``(relative posix path, path)`` for files under ``root``, sorted."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(
            d for d in dirnames if d != "__pycache__" and not d.startswith(".")
        )
        for fn in sorted(filenames):
            p = Path(dirpath) / fn
            yield p.relative_to(root).as_posix(), p


def refuse_symlink(p: Path) -> None:
    if p.is_symlink():
        raise ToolError(
            f"refusing symlink {p} -> {os.readlink(p)}: bundle a regular file instead"
        )


def add_package(
    contents: BundleContents,
    name: str,
    src: Path,
    data: Globs,
    exclude: Globs,
) -> None:
    """Add a source package directory (or a single ``.py`` module) as ``name``."""
    if src.is_file():
        arc = name.replace(".", "/") + ".py"
        if not exclude.match(arc):
            contents.add_source(arc, src.read_bytes(), str(src))
        return
    if not (src / "__init__.py").is_file():
        raise ToolError(f"--package {name}={src}: not a package (no __init__.py)")
    prefix = name.replace(".", "/")
    for rel, p in walk_tree(src):
        arc = f"{prefix}/{rel}"
        if exclude.match(arc) or rel.endswith((".pyc", ".pyo")):
            continue
        if rel.endswith(".py") or is_native(rel) or data.match(arc):
            refuse_symlink(p)
        if rel.endswith(".py"):
            contents.add_source(arc, p.read_bytes(), str(p))
        elif is_native(rel):
            contents.add(arc, b"", str(p))  # raises
        elif data.match(arc):
            contents.add(arc, p.read_bytes(), str(p))


def keep_dist_info_file(rel_in_dist_info: str) -> bool:
    return bool(DIST_INFO_KEEP.match(rel_in_dist_info))


# Third-party files that are never read at run time: C sources/headers shipped next
# to optional accelerators, Cython sources, type stubs and markers.
WHEEL_NEVER_RUNTIME = Globs(
    ["**/*.c", "**/*.h", "**/*.cpp", "**/*.pyx", "**/*.pxd", "**/*.pyi", "**/py.typed"]
)


def add_wheel_member(
    contents: BundleContents, arc: str, data: bytes, origin: str, exclude: Globs
) -> None:
    parts = arc.split("/")
    if parts[0].endswith(".dist-info"):
        if keep_dist_info_file("/".join(parts[1:])) and not exclude.match(arc):
            contents.add(arc, data, origin)
        return
    if (
        exclude.match(arc)
        or WHEEL_NEVER_RUNTIME.match(arc)
        or arc.endswith((".pyc", ".pyo"))
    ):
        return
    if "__pycache__" in parts:
        return
    if arc.endswith(".py"):
        contents.add_source(arc, data, origin)
    else:
        contents.add(arc, data, origin)


WHEEL_RE = re.compile(
    r"^(?P<dist>[^-]+)-(?P<ver>[^-]+)(?:-(?P<build>\d[^-]*))?"
    r"-(?P<py>[^-]+)-(?P<abi>[^-]+)-(?P<plat>[^-]+)\.whl$"
)


@dataclass(frozen=True)
class WheelName:
    path: Path
    dist: str  # normalized
    version: str
    tags: Tuple[str, str, str]

    @property
    def pure(self) -> bool:
        py, abi, plat = self.tags
        pys = py.split(".")
        return (
            abi == "none"
            and plat == "any"
            and all(t.startswith("py") for t in pys)
            and any(t.startswith("py3") for t in pys)
        )


def parse_wheel_name(p: Path) -> WheelName:
    m = WHEEL_RE.match(p.name)
    if m is None:
        raise ToolError(f"not a wheel file name: {p.name}")
    return WheelName(
        p, normalize_dist(m["dist"]), m["ver"], (m["py"], m["abi"], m["plat"])
    )


@dataclass
class LockPackage:
    name: str
    version: str
    wheels: List[Dict[str, object]]


def lock_closure(
    path: Path, root: Optional[str], env: Dict[str, str]
) -> List[Tuple[str, str, str]]:
    """The runtime dependency closure of a ``uv.lock`` root package.

    Starts from ``root`` (default: the lock's only package with an ``editable`` or
    ``virtual`` source, i.e. the project itself), follows ``dependencies`` and the
    ``optional-dependencies`` of requested extras (never ``dev-dependencies``), and
    keeps an edge only if its marker holds in ``env``. This is what
    ``uv export --frozen --no-dev --no-emit-project`` lists, with markers already
    evaluated. Returns sorted ``(normalized name, version, "")`` triples.
    """
    with path.open("rb") as f:
        lock = tomllib.load(f)
    by_name: Dict[str, Dict[str, Dict[str, Any]]] = {}
    for p in lock.get("package", []):
        by_name.setdefault(normalize_dist(p["name"]), {})[str(p.get("version", ""))] = p

    def resolve(name: str, version: Optional[str], what: str) -> Tuple[str, str]:
        versions = by_name.get(name)
        if not versions:
            raise ToolError(f"{path}: {what} {name!r} is not in the lock")
        if version is None:
            if len(versions) != 1:
                raise ToolError(
                    f"{path}: {what} {name!r} is locked at several versions "
                    f"({sorted(versions)}) and the edge does not say which"
                )
            version = next(iter(versions))
        if version not in versions:
            raise ToolError(f"{path}: {what} {name}=={version} is not in the lock")
        return name, version

    if root is None:
        roots = [
            (n, v)
            for n, vs in by_name.items()
            for v, p in vs.items()
            if "editable" in p.get("source", {}) or "virtual" in p.get("source", {})
        ]
        if len(roots) != 1:
            raise ToolError(
                f"{path}: cannot pick the root package ({roots}); pass --root"
            )
        root_key = roots[0]
    else:
        root_key = resolve(normalize_dist(root), None, "root package")
    seen: Set[Tuple[str, str]] = set()
    todo: List[Tuple[Tuple[str, str], Tuple[str, ...]]] = [(root_key, ())]
    done: Set[Tuple[Tuple[str, str], Tuple[str, ...]]] = set()
    while todo:
        key, extras = todo.pop()
        if (key, extras) in done:
            continue
        done.add((key, extras))
        seen.add(key)
        pkg = by_name[key[0]][key[1]]
        edges = list(pkg.get("dependencies", []))
        for e in extras:
            edges += pkg.get("optional-dependencies", {}).get(e, [])
        for dep in edges:
            marker = dep.get("marker", "")
            if marker and not eval_marker(marker, env):
                continue
            dep_key = resolve(
                normalize_dist(dep["name"]),
                str(dep["version"]) if "version" in dep else None,
                "dependency",
            )
            todo.append((dep_key, tuple(sorted(dep.get("extra", [])))))
    seen.discard(root_key)
    names = [n for n, _ in seen]
    dups = sorted({n for n in names if names.count(n) > 1})
    if dups:
        raise ToolError(f"{path}: several versions of {dups} in one closure")
    return sorted((n, v, "") for n, v in seen)


Lock = Dict[str, List[LockPackage]]


def read_lock(path: Path) -> Lock:
    """Read a ``uv.lock`` (TOML) into normalized name -> packages (one per locked
    version: forked resolutions can lock several versions of one name)."""
    with path.open("rb") as f:
        lock = tomllib.load(f)
    out: Lock = {}
    for pkg in lock.get("package", []):
        name = normalize_dist(pkg["name"])
        out.setdefault(name, []).append(
            LockPackage(name, str(pkg.get("version", "")), list(pkg.get("wheels", [])))
        )
    return out


def lock_get(lock: Lock, name: str, version: str) -> Optional[LockPackage]:
    for pkg in lock.get(name, []):
        if pkg.version == version:
            return pkg
    return None


def lock_wheel_filename(w: Dict[str, object]) -> str:
    url = str(w.get("url", w.get("path", w.get("filename", ""))))
    return url.rsplit("/", 1)[-1].split("#", 1)[0]


def lock_pure_wheel(pkg: LockPackage) -> Optional[Dict[str, object]]:
    for w in pkg.wheels:
        if parse_wheel_name(Path(lock_wheel_filename(w))).pure:
            return w
    return None


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def select_wheels(
    wheel_paths: Sequence[Path],
    lock: Optional["Lock"],
    exclude_dists: Set[str],
) -> List[WheelName]:
    """Pick one wheel per distribution, pure ones first.

    ``wheel_paths`` are ``.whl`` files or directories holding them.

    With a lock, every wheel must be one the lock lists (by sha256) and a
    compiled wheel is refused when the lock offers a ``py3-none-any`` one.
    """
    by_dist: Dict[str, List[WheelName]] = {}
    files: Set[Path] = set()
    for wp in wheel_paths:
        files.update(wp.glob("*.whl") if wp.is_dir() else [wp])
    for p in sorted(files):
        w = parse_wheel_name(p)
        if w.dist in exclude_dists:
            continue
        by_dist.setdefault(w.dist, []).append(w)
    chosen: List[WheelName] = []
    for dist in sorted(by_dist):
        cands = by_dist[dist]
        pure = [w for w in cands if w.pure]
        if not pure:
            hint = ""
            offered = [
                lock_wheel_filename(pw)
                for pkg in (lock or {}).get(dist, [])
                for pw in [lock_pure_wheel(pkg)]
                if pw is not None
            ]
            if offered:
                hint = f" (the lock offers {', '.join(offered)})"
            raise ToolError(
                f"only compiled wheels for {dist}: "
                + ", ".join(w.path.name for w in cands)
                + hint
                + "; bundles carry no native code"
            )
        if len({w.version for w in pure}) > 1:
            raise ToolError(
                f"several versions of {dist}: {[w.path.name for w in pure]}"
            )
        w = pure[0]
        if lock is not None:
            pkgs = lock.get(dist)
            if not pkgs:
                raise ToolError(f"{w.path.name}: {dist} is not in the lock")
            digest = "sha256:" + sha256_file(w.path)
            owners = [
                pkg
                for pkg in pkgs
                if any(lw.get("hash") == digest for lw in pkg.wheels)
            ]
            if not owners:
                raise ToolError(
                    f"{w.path.name}: sha256 not listed in the lock for {dist}"
                )
            w = WheelName(w.path, w.dist, owners[0].version, w.tags)
        chosen.append(w)
    return chosen


def add_wheel(contents: BundleContents, w: WheelName, exclude: Globs) -> None:
    with zipfile.ZipFile(w.path) as zf:
        for info in sorted(zf.infolist(), key=lambda i: i.filename):
            if info.is_dir():
                continue
            arc = info.filename
            origin = f"{w.path.name}:{info.filename}"
            check_member_name(arc, origin)
            if (info.external_attr >> 16) & 0o170000 == 0o120000:
                raise ToolError(f"refusing symlink member {origin}")
            parts = arc.split("/")
            if len(parts) > 2 and parts[0].endswith(".data"):
                if parts[1] in ("purelib", "platlib"):
                    arc = "/".join(parts[2:])
                else:
                    continue  # scripts, headers, data: not importable
            elif parts[0].endswith(".dist-info") and parts[-1] == "WHEEL":
                text = zf.read(info).decode("utf-8", "replace")
                if re.search(r"(?mi)^Root-Is-Purelib:\s*false\s*$", text):
                    raise ToolError(f"{w.path.name}: WHEEL says Root-Is-Purelib: false")
            add_wheel_member(
                contents, arc, zf.read(info), f"{w.path.name}:{info.filename}", exclude
            )


def read_record(dist_info: Path) -> List[str]:
    rec = dist_info / "RECORD"
    if not rec.is_file():
        return []
    import csv

    with rec.open(newline="") as f:
        return [row[0] for row in csv.reader(f) if row]


def add_site(
    contents: BundleContents, site: Path, exclude: Globs, exclude_dists: Set[str]
) -> None:
    """Add an installed tree (``pip/uv install --target``), minus excluded dists."""
    dropped: Set[str] = set()
    for di in sorted(site.glob("*.dist-info")):
        project = normalize_dist(di.name[: -len(".dist-info")].rpartition("-")[0])
        if project in exclude_dists:
            dropped.update(
                os.path.normpath(r).replace(os.sep, "/") for r in read_record(di)
            )
            dropped.update(f"{di.name}/{rel}" for rel, _ in walk_tree(di))
    for rel, p in walk_tree(site):
        top = rel.split("/", 1)[0]
        if rel in dropped or top == "bin":
            continue
        refuse_symlink(p)
        add_wheel_member(contents, rel, p.read_bytes(), str(p), exclude)


# ---------------------------------------------------------------------------
# Zip, C and OCaml emission
# ---------------------------------------------------------------------------


def write_zip(contents: BundleContents, out: Path) -> None:
    if len(contents.members) >= 0xFFFF:
        raise ToolError("too many members for a non-zip64 bundle")
    comment = (
        f"sboa-bundle/{FORMAT_VERSION} name={contents.name} "
        f"magic={importlib.util.MAGIC_NUMBER.hex()}"
    ).encode("ascii")
    method = zipfile.ZIP_DEFLATED
    tmp = out.with_suffix(out.suffix + ".tmp")
    with zipfile.ZipFile(tmp, "w") as zf:
        for arc in sorted(contents.members):
            info = zipfile.ZipInfo(arc, date_time=ZIP_EPOCH)
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = method
            zf.writestr(
                info, contents.members[arc].data, compress_type=method, compresslevel=9
            )
        zf.comment = comment
    os.replace(tmp, out)


ASM_TARGETS = ("elf", "macho", "coff")


def default_target() -> str:
    if sys.platform == "darwin":
        return "macho"
    if sys.platform in ("win32", "cygwin"):
        return "coff"
    return "elf"


def target_of_system(system: str) -> str:
    """Map dune's ``%{system}`` (``linux``, ``macosx``, ``mingw64``, ``win64``,
    ``cygwin``, ``freebsd``, ...) to an object format."""
    if system in ("macosx", "darwin"):
        return "macho"
    if system.startswith(("mingw", "win", "cygwin")):
        return "coff"
    return "elf"


def resolve_target(args: argparse.Namespace) -> str:
    if args.target_system:
        return target_of_system(args.target_system)
    return str(args.target)


def asm_lines(target: str, symbol: str, incbin_path: str) -> List[str]:
    """Assembler for the blob, per object format.

    - ELF (GNU as / clang): ``.section .rodata``, ``.type``/``.size`` for tools,
      ``.previous`` returns to the compiler's section.
    - Mach-O (clang): C symbols carry a leading ``_``; ``__TEXT,__const`` is the
      read-only constant section (``.const``).
    - COFF via mingw-w64 GNU as: ``.rdata`` with flags ``dr`` (data, read-only).
      x86_64 and aarch64 Windows do not prefix C symbols with ``_`` (only i386
      does), so the label is the bare name.  COFF has no section stack, so the
      block ends with ``.text``.
    """
    path = incbin_path.replace("\\", "/").replace('"', '\\"')
    # The length is computed by the assembler from the bytes it actually
    # included (end label - start), never written as a literal that a stale
    # object could disagree with.  ``.L``/``L`` labels are assembler-local (on
    # Mach-O they also do not start a new atom, so the difference is a constant).
    if target == "elf":
        end = f".L{symbol}_end"
        return [
            "\t.section .rodata",
            f"\t.globl {symbol}",
            f"\t.type {symbol}, @object",
            "\t.p2align 4",
            f"{symbol}:",
            f'\t.incbin "{path}"',
            f"{end}:",
            f"\t.size {symbol}, {end} - {symbol}",
            "\t.byte 0",
            "\t.p2align 3",
            f"\t.globl {symbol}_len",
            f"\t.type {symbol}_len, @object",
            f"\t.size {symbol}_len, 8",
            f"{symbol}_len:",
            f"\t.quad {end} - {symbol}",
            "\t.previous",
        ]
    if target == "macho":
        label = "_" + symbol
        end = f"L{symbol}_end"
        return [
            "\t.section __TEXT,__const",
            f"\t.globl {label}",
            "\t.p2align 4",
            f"{label}:",
            f'\t.incbin "{path}"',
            f"{end}:",
            "\t.byte 0",
            "\t.p2align 3",
            f"\t.globl {label}_len",
            f"{label}_len:",
            f"\t.quad {end} - {label}",
            "\t.text",
        ]
    if target == "coff":
        end = f".L{symbol}_end"
        return [
            '\t.section .rdata,"dr"',
            f"\t.globl {symbol}",
            "\t.p2align 4",
            f"{symbol}:",
            f'\t.incbin "{path}"',
            f"{end}:",
            "\t.byte 0",
            "\t.p2align 3",
            f"\t.globl {symbol}_len",
            f"{symbol}_len:",
            f"\t.quad {end} - {symbol}",
            "\t.text",
        ]
    raise ToolError(f"unknown --target {target}")


def c_string_body(s: str) -> str:
    """Escape ``s`` for the inside of a C string literal."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\t", "\\t")


def emit_c(
    out: Path,
    symbol: str,
    name: str,
    incbin_path: str,
    size: int,
    sha256: str,
    target: str,
) -> None:
    asm = "\n".join(
        '  "' + c_string_body(line) + '\\n"'
        for line in asm_lines(target, symbol, incbin_path)
    )
    out.write_text(
        f"""/* Generated by sboa_bundle.py; do not edit.
 *
 * Embeds bundle {name!r} ({incbin_path}: {size} bytes, sha256 {sha256})
 * in read-only data with the
 * assembler's .incbin directive (object format: {target}).  dune compiles foreign
 * stubs from the library's build directory, where the zip is generated, so the
 * relative path resolves.  The sha256 above changes this file whenever the zip
 * changes, so compiler caches (ccache keys on the preprocessed source, not on
 * .incbin inputs) cannot serve a stale object.  {symbol}_len is computed by the
 * assembler from the included bytes.  Exposes the bytes to C as {symbol}/{symbol}_len and to
 * OCaml as the primitive sboa_incbin_{symbol} (a read-only external Bigarray;
 * see https://ocaml.org/manual/intfc.html#s:C-Bigarrays).  Writing to it faults.
 */
#include <stddef.h>
#include <caml/mlvalues.h>
#include <caml/bigarray.h>

__asm__(
{asm}
);

extern const unsigned char {symbol}[];
extern const size_t {symbol}_len;
_Static_assert(sizeof(size_t) == 8, "{symbol}_len is emitted as .quad");

value sboa_incbin_{symbol}(value unit);
value sboa_incbin_{symbol}(value unit)
{{
  (void)unit;
  return caml_ba_alloc_dims(CAML_BA_CHAR | CAML_BA_C_LAYOUT | CAML_BA_EXTERNAL, 1,
                            (void *){symbol}, (intnat){symbol}_len);
}}
"""
    )


def emit_ml(out: Path, symbol: str, name: str, priority: int, mli: bool) -> None:
    out.write_text(
        f"""(** Embedded Python bundle [{name}] (generated by sboa_bundle.py; do not edit).

    Linking this module registers the bundle with [Sboa] at priority {priority}
    (lower is searched first). The bytes live in the executable's read-only data
    (symbol [{symbol}], see [{symbol}_blob.c]). *)

external incbin :
  unit -> (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
  = "sboa_incbin_{symbol}"

let bundle = Sboa.Bundle.of_incbin ~symbol:"{symbol}" ~name:"{name}" (incbin ())
let () = Sboa.Bundle.register ~priority:{priority} bundle
"""
    )
    if mli:
        out.with_suffix(".mli").write_text(
            f"""(** Embedded Python bundle [{name}] (generated by sboa_bundle.py; do not edit).
    Registered with [Sboa.Bundle.register] when linked. *)

val bundle : Sboa.Bundle.t
(** The bundle [{name}], backed by the read-only symbol [{symbol}]. *)
"""
        )


def emit_embedding(
    zip_path: Path,
    name: str,
    base: str,
    out_dir: Path,
    priority: int,
    target: str,
    incbin_path: Optional[str],
    mli: bool,
) -> None:
    validate_bundle_name(name)
    symbol = c_ident(base)
    size = zip_path.stat().st_size
    emit_c(
        out_dir / f"{base}_blob.c",
        symbol,
        name,
        incbin_path or zip_path.name,
        size,
        sha256_file(zip_path),
        target,
    )
    emit_ml(out_dir / f"{base}.ml", symbol, name, priority, mli)


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------


def parse_kv(s: str, flag: str) -> Tuple[str, Path]:
    if "=" not in s:
        raise ToolError(f"{flag} expects NAME=PATH, got {s!r}")
    k, v = s.split("=", 1)
    return k, Path(v)


def add_embed_args(p: argparse.ArgumentParser, default_priority: int) -> None:
    p.add_argument("--out", type=Path, required=True, help="output directory")
    p.add_argument(
        "--base", help="base name of outputs and C symbol (default NAME_bundle)"
    )
    p.add_argument(
        "--priority",
        type=int,
        default=default_priority,
        help="search priority; lower first (default %(default)s)",
    )
    p.add_argument(
        "--target",
        choices=ASM_TARGETS,
        default=default_target(),
        help="object format for the .incbin blob (default: host, %(default)s)",
    )
    p.add_argument(
        "--target-system",
        metavar="SYSTEM",
        help="pick --target from dune's %%{system} (macosx -> macho, mingw*/win*/cygwin"
        " -> coff, anything else -> elf); overrides --target",
    )
    p.add_argument(
        "--incbin-path",
        help="path written in the .incbin directive (default: the zip's file name)",
    )
    p.add_argument("--mli", action="store_true", help="also write BASE.mli")
    p.add_argument("--zip-only", action="store_true", help="only write the zip")


def finish_bundle(contents: BundleContents, args: argparse.Namespace) -> None:
    base = args.base or f"{contents.name}_bundle"
    args.out.mkdir(parents=True, exist_ok=True)
    zip_path = args.out / f"{base}.zip"
    write_zip(contents, zip_path)
    if not args.zip_only:
        emit_embedding(
            zip_path,
            contents.name,
            base,
            args.out,
            args.priority,
            resolve_target(args),
            args.incbin_path,
            args.mli,
        )
    n_pyc = sum(1 for a in contents.members if a.endswith(".pyc"))
    print(
        f"{zip_path}: {n_pyc} modules, {len(contents.members) - n_pyc} other files, "
        f"{zip_path.stat().st_size} bytes",
        file=sys.stderr,
    )


def read_exclude_dists(args: argparse.Namespace) -> Set[str]:
    names = list(args.exclude_dist)
    for f in args.exclude_dist_file:
        for line in f.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                names.append(line)
    return {normalize_dist(d) for d in names}


def check_closure(
    args: argparse.Namespace, chosen: Sequence[WheelName], exclude_dists: Set[str]
) -> None:
    """With ``--lock``, the wheels must be exactly the lock's closure for the
    embedded interpreter, minus the excluded distributions."""
    env = target_marker_env_from_args(args)
    want = {
        (n, v)
        for n, v, _ in lock_closure(args.lock, args.root, env)
        if n not in exclude_dists
    }
    have = {(w.dist, w.version) for w in chosen}
    missing = sorted(want - have)
    extra = sorted(have - want)
    if missing or extra:
        raise ToolError(
            "the wheels do not match the lock closure"
            + (
                f"; missing: {', '.join(f'{n}=={v}' for n, v in missing)}"
                if missing
                else ""
            )
            + (
                f"; not in the closure: {', '.join(f'{n}=={v}' for n, v in extra)}"
                if extra
                else ""
            )
            + " (run fetch-wheels again, or --exclude-dist)"
        )


def cmd_bundle(args: argparse.Namespace) -> None:
    contents = BundleContents(args.name, allow_stdlib_shadow=args.allow_stdlib_shadow)
    data = Globs(args.data)
    exclude = Globs(args.exclude)
    exclude_dists = read_exclude_dists(args)
    for spec in args.package:
        name, path = parse_kv(spec, "--package")
        add_package(contents, name, path, data, exclude)
    lock = read_lock(args.lock) if args.lock else None
    if args.wheels:
        chosen = select_wheels(args.wheels, lock, exclude_dists)
        if lock is not None:
            check_closure(args, chosen, exclude_dists)
        for w in chosen:
            add_wheel(contents, w, exclude)
    for site in args.site:
        add_site(contents, site, exclude, exclude_dists)
    finish_bundle(contents, args)


def stdlib_member_excluded(rel: str) -> bool:
    parts = rel.split("/")
    if parts[0] in STDLIB_EXCLUDED_TOP or parts[0].startswith("config-"):
        return True
    return any(p in STDLIB_EXCLUDED_ANYWHERE for p in parts[:-1])


def cmd_stdlib(args: argparse.Namespace) -> None:
    contents = BundleContents(args.name, allow_stdlib_shadow=True)
    exclude = Globs(args.exclude)
    root = args.stdlib_dir
    if root is None:
        if args.config is None:
            raise ToolError("stdlib needs --stdlib-dir or --config")
        root = Path(config_str(read_sboa_config(args.config), "stdlib_dir"))
    if not (root / "os.py").is_file():
        raise ToolError(f"{root}: not a stdlib directory (no os.py)")
    for rel, p in walk_tree(root):
        if stdlib_member_excluded(rel) or exclude.match(rel) or not rel.endswith(".py"):
            continue
        contents.add_source(rel, p.read_bytes(), str(p))
    finish_bundle(contents, args)


def cmd_embed(args: argparse.Namespace) -> None:
    validate_bundle_name(args.name)
    base = args.base or f"{args.name}_bundle"
    args.out.mkdir(parents=True, exist_ok=True)
    emit_embedding(
        args.zip,
        args.name,
        base,
        args.out,
        args.priority,
        resolve_target(args),
        args.incbin_path or os.path.relpath(args.zip, args.out),
        args.mli,
    )


def frozen_entries(args: argparse.Namespace) -> List[Tuple[str, bytes, bool]]:
    entries: Dict[str, Tuple[bytes, bool]] = {}

    def add(modname: str, path: Path, is_pkg: bool) -> None:
        code = compile(
            path.read_bytes(),
            f"<frozen {modname}>",
            "exec",
            dont_inherit=True,
            optimize=0,
        )
        if modname in entries:
            raise ToolError(f"module {modname} frozen twice")
        entries[modname] = (marshal.dumps(code), is_pkg)

    for spec in args.module:
        name, path = parse_kv(spec, "--module")
        add(name, path, False)
    packages = [parse_kv(spec, "--package") for spec in args.package]
    if args.stdlib_package:
        stdlib_dir = args.stdlib_dir
        if stdlib_dir is None:
            if args.config is None:
                raise ToolError(
                    "--stdlib-package needs --stdlib-dir or --config"
                )
            stdlib_dir = Path(config_str(read_sboa_config(args.config), "stdlib_dir"))
        packages += [(n, stdlib_dir / n.replace(".", "/")) for n in args.stdlib_package]
    for name, path in packages:
        if not (path / "__init__.py").is_file():
            raise ToolError(f"freeze: {path} is not a package directory")
        for rel, p in walk_tree(path):
            if not rel.endswith(".py"):
                continue
            stem = rel[:-3]
            if stem == "__init__":
                add(name, p, True)
            elif stem.endswith("/__init__"):
                add(name + "." + stem[:-9].replace("/", "."), p, True)
            else:
                add(name + "." + stem.replace("/", "."), p, False)
    return [(n, entries[n][0], entries[n][1]) for n in sorted(entries)]


def c_bytes(data: bytes) -> str:
    rows = []
    for i in range(0, len(data), 20):
        rows.append("  " + ",".join(str(b) for b in data[i : i + 20]) + ",")
    return "\n".join(rows)


def cmd_freeze(args: argparse.Namespace) -> None:
    entries = frozen_entries(args)
    parts = [
        f"""/* Generated by sboa_bundle.py freeze; do not edit.
 *
 * PyImport_FrozenModules table for CPython {sys.version_info.major}.{sys.version_info.minor} (marshal format
 * {marshal.version}, bytecode magic {importlib.util.MAGIC_NUMBER.hex()}).  Layout follows
 * Include/cpython/import.h: struct _frozen {{ name; code; size; is_package; }} with
 * size > 0 and is_package a separate flag (3.11+; the old negative-size
 * convention is gone).  The host points PyImport_FrozenModules at
 * sboa_frozen_table before Py_InitializeFromConfig; CPython consults this
 * table after its bootstrap modules and before its own frozen stdlib, once
 * it has checked sboa_frozen_magic against its own.
 *
 * The struct is spelled out here so that this file needs no Python.h (and
 * no CPython C flags) to compile.
 */
struct sboa_frozen_entry {{
  const char *name;
  const unsigned char *code;
  int size;
  int is_package;
}};

const unsigned char sboa_frozen_magic[4] = {{{",".join(str(b) for b in importlib.util.MAGIC_NUMBER)}}};
"""
    ]
    for i, (name, code, _pkg) in enumerate(entries):
        parts.append(
            f"/* {name} */\nstatic const unsigned char sboa_frozen_{i}[] = {{\n{c_bytes(code)}\n}};\n"
        )
    parts.append("const struct sboa_frozen_entry sboa_frozen_table[] = {")
    for i, (name, _code, pkg) in enumerate(entries):
        parts.append(
            f'  {{"{name}", sboa_frozen_{i}, (int)sizeof(sboa_frozen_{i}), {1 if pkg else 0}}},'
        )
    parts.append("  {0, 0, 0, 0}\n};\n")
    if args.ml is not None:
        # The table's strong symbols override sboa's weak empty ones, but
        # nothing references them strongly, so a static linker would never
        # pull this object out of a library archive. The OCaml module calls
        # this primitive at initialization: linked with -linkall, it brings
        # the object, and the table, into every executable.
        parts.append(
            "#include <caml/mlvalues.h>\n\n"
            "value sboa_frozen_anchor(value unit)\n{\n"
            "  (void)unit;\n  return Val_unit;\n}\n"
        )
        args.ml.parent.mkdir(parents=True, exist_ok=True)
        args.ml.write_text(
            "(* Generated by sboa_bundle.py freeze; do not edit. Evaluating this"
            " module\n   links the frozen-module table (see the C file). *)\n\n"
            'external anchor : unit -> unit = "sboa_frozen_anchor"\n\n'
            "let () = anchor ()\n"
        )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(parts))
    total = sum(len(c) for _, c, _ in entries)
    print(
        f"{args.out}: {len(entries)} frozen modules, {total} bytes of marshalled code",
        file=sys.stderr,
    )


# --- check-seam -------------------------------------------------------------

LOAD_NAME_OPS = frozenset(
    {
        "LOAD_NAME",
        "LOAD_GLOBAL",
        "LOAD_FAST",
        "LOAD_DEREF",
        "LOAD_FAST_CHECK",
        "LOAD_FAST_LOAD_FAST",
        "LOAD_FROM_DICT_OR_GLOBALS",
        "LOAD_FROM_DICT_OR_DEREF",
    }
)
STORE_OPS = frozenset({"STORE_NAME", "STORE_GLOBAL", "STORE_FAST", "STORE_DEREF"})


def lineno(ins: dis.Instruction) -> str:
    pos = ins.positions
    return str(pos.lineno) if pos is not None and pos.lineno is not None else "?"


def iter_code(code: types.CodeType) -> Iterator[types.CodeType]:
    yield code
    for c in code.co_consts:
        if isinstance(c, types.CodeType):
            yield from iter_code(c)


@dataclass
class SeamUse:
    names: Dict[str, Set[str]] = field(default_factory=dict)  # attr -> {file:line}
    star: Set[str] = field(default_factory=set)
    dynamic: Set[str] = field(default_factory=set)

    def add(self, attr: str, where: str) -> None:
        self.names.setdefault(attr, set()).add(where)


def scan_code_for_module(
    code: types.CodeType,
    module: str,
    where: str,
    use: SeamUse,
    via: Sequence[Tuple[str, str]] = (),
) -> None:
    """Record attributes of ``module`` referenced by ``code`` (all nested code).

    Recognised: ``import M [as A]`` followed by ``A.x``, ``from M import x``,
    ``getattr(A, "x")``; ``from M import *`` and ``getattr(A, non_constant)`` are
    reported as unverifiable. ``via`` lists re-exports ``(R, N)``: ``from R
    import N [as A]`` binds ``A`` to the module like ``import M as A`` does (a
    thin module that imports M once and that the rest of the program imports
    it from). Dunder attributes (``__name__``...) are not seam names.
    """
    codes = list(iter_code(code))
    aliases: Set[str] = set()
    first, _, rest = module.partition(".")
    for c in codes:
        ins = list(dis.get_instructions(c))
        for i, x in enumerate(ins):
            for reexport, name in via:
                if (
                    x.opname == "IMPORT_NAME"
                    and x.argval == reexport
                    and i + 2 < len(ins)
                    and ins[i + 1].opname == "IMPORT_FROM"
                    and ins[i + 1].argval == name
                    and ins[i + 2].opname in STORE_OPS
                ):
                    aliases.add(ins[i + 2].argval)
            if x.opname == "IMPORT_NAME" and x.argval == module:
                j = i + 1
                if j < len(ins) and ins[j].opname in STORE_OPS and not rest:
                    aliases.add(ins[j].argval)
                elif j < len(ins) and ins[j].opname == "IMPORT_FROM":
                    # ``import a.b as c`` compiles to IMPORT_NAME a.b; IMPORT_FROM b; STORE c
                    if (
                        rest
                        and ins[j].argval == module.rsplit(".", 1)[1]
                        and j + 1 < len(ins)
                        and ins[j + 1].opname in STORE_OPS
                    ):
                        aliases.add(ins[j + 1].argval)
                    else:
                        while j < len(ins) and ins[j].opname == "IMPORT_FROM":
                            use.add(
                                ins[j].argval,
                                f"{where}:{lineno(ins[j])}",
                            )
                            j += 2  # IMPORT_FROM, STORE_*
                elif (
                    j < len(ins)
                    and ins[j].opname == "CALL_INTRINSIC_1"
                    and "IMPORT_STAR" in str(ins[j].argrepr)
                ):
                    use.star.add(where)
    if not aliases:
        return
    for c in codes:
        ins = list(dis.get_instructions(c))
        for i, x in enumerate(ins):
            if x.opname in LOAD_NAME_OPS and x.argval in aliases and i + 1 < len(ins):
                nxt = ins[i + 1]
                line = f"{where}:{lineno(x)}"
                if nxt.opname == "LOAD_ATTR":
                    if not (nxt.argval.startswith("__") and nxt.argval.endswith("__")):
                        use.add(nxt.argval, line)
                elif (
                    i >= 1
                    and ins[i - 1].opname == "LOAD_GLOBAL"
                    and ins[i - 1].argval == "getattr"
                ):
                    if nxt.opname == "LOAD_CONST" and isinstance(nxt.argval, str):
                        use.add(nxt.argval, line)
                    else:
                        use.dynamic.add(line)


def read_exports(spec: str, module: str) -> Set[str]:
    p = Path(spec)
    if p.is_file() and os.access(p, os.X_OK) and not p.suffix in (".txt", ".json"):
        text = subprocess.run(
            [str(p)], check=True, capture_output=True, text=True
        ).stdout
    else:
        text = p.read_text()
    names: Set[str] = set()
    stripped = text.lstrip()
    if stripped.startswith(("[", "{")):
        obj = json.loads(text)
        if isinstance(obj, dict):
            obj = obj.get(module, obj.get("exports", []))
        for e in obj:
            names.add(e["name"] if isinstance(e, dict) else str(e))
    else:
        for line in text.splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                names.add(line)
    prefix = module + "."
    out = set()
    for n in names:
        if n.startswith(prefix):
            out.add(n[len(prefix) :])
        elif "." not in n:
            out.add(n)
    return out


def read_allow(path: Optional[Path]) -> Set[str]:
    if path is None:
        return set()
    return {l.split("#", 1)[0].strip() for l in path.read_text().splitlines()} - {""}


def cmd_check_seam(args: argparse.Namespace) -> int:
    use = SeamUse()
    via: List[Tuple[str, str]] = []
    for spec in args.via:
        reexport, sep, name = spec.partition(":")
        if not sep or not reexport or not name:
            raise ToolError(f"--via expects MODULE:NAME, got {spec!r}")
        via.append((reexport, name))
    with zipfile.ZipFile(args.bundle) as zf:
        for arc in sorted(zf.namelist()):
            if not arc.endswith(".pyc"):
                continue
            data = zf.read(arc)
            if data[:4] != importlib.util.MAGIC_NUMBER:
                raise ToolError(
                    f"{arc}: compiled for another interpreter; run with the bundle's python"
                )
            scan_code_for_module(
                marshal.loads(data[16:]), args.module, arc[:-1], use, via
            )
    exports = read_exports(args.exports, args.module)
    allow = read_allow(args.allow)
    missing = sorted(set(use.names) - exports - allow)
    unused = sorted(exports - set(use.names) - allow)
    ok = True
    for n in missing:
        ok = False
        print(
            f"error: {args.module}.{n} is used but not exported: "
            + ", ".join(sorted(use.names[n]))
        )
    for n in unused:
        ok = False
        print(
            f"error: {args.module}.{n} is exported but never used from Python (allow-list it if intended)"
        )
    for w in sorted(use.star):
        ok = False
        print(f"error: {w}: 'from {args.module} import *' cannot be checked")
    for w in sorted(use.dynamic):
        print(f"warning: {w}: dynamic getattr on {args.module} not checked")
    print(
        f"check-seam: {len(use.names)} names used, {len(exports)} exported, {len(allow)} allow-listed: {'OK' if ok else 'FAILED'}",
        file=sys.stderr,
    )
    return 0 if ok else 1


# --- fetch-wheels -------------------------------------------------------------


# sboa platform names (sboa.config ``platform``) ->
# (sys.platform, platform.system(), platform.machine()).
TARGET_PLATFORMS: Dict[str, Tuple[str, str, str]] = {
    "linux-gnu-x86_64": ("linux", "Linux", "x86_64"),
    "linux-gnu-aarch64": ("linux", "Linux", "aarch64"),
    "linux-musl-x86_64": ("linux", "Linux", "x86_64"),
    "linux-musl-aarch64": ("linux", "Linux", "aarch64"),
    "macos-x86_64": ("darwin", "Darwin", "x86_64"),
    "macos-arm64": ("darwin", "Darwin", "arm64"),
    "windows-x86_64": ("win32", "Windows", "AMD64"),
}


def target_marker_env(python_version: str, platform: str) -> Dict[str, str]:
    """PEP 508 marker variables of the *embedded* interpreter (CPython
    ``python_version`` X.Y[.Z] on sboa ``platform``), independent of the
    interpreter running this tool."""
    if platform not in TARGET_PLATFORMS:
        raise UsageError(
            f"unknown platform {platform!r} (known: {', '.join(sorted(TARGET_PLATFORMS))})"
        )
    m = re.fullmatch(r"(\d+)\.(\d+)(?:\.\d+)?", python_version)
    if m is None:
        raise UsageError(f"bad --python-version {python_version!r} (expected X.Y[.Z])")
    sys_platform, system, machine = TARGET_PLATFORMS[platform]
    return {
        "python_version": f"{m[1]}.{m[2]}",
        "python_full_version": python_version,
        "implementation_name": "cpython",
        "implementation_version": python_version,
        "platform_python_implementation": "CPython",
        "sys_platform": sys_platform,
        "os_name": "nt" if sys_platform == "win32" else "posix",
        "platform_system": system,
        "platform_machine": machine,
        "platform_release": "",
        "platform_version": "",
        "extra": "",
    }


def target_marker_env_from_args(args: argparse.Namespace) -> Dict[str, str]:
    """Marker environment from ``--python-version``/``--platform`` or else from the
    global ``--config``; one of them is required."""
    version, platform = args.python_version, args.platform
    if (version is None) != (platform is None):
        raise UsageError("--python-version and --platform go together")
    if version is None:
        if args.config is None:
            raise UsageError(
                "markers are evaluated for the embedded interpreter: pass "
                "--config FILE, or --python-version and --platform"
            )
        cfg = read_sboa_config(args.config)
        if "version" not in cfg or "platform" not in cfg:
            raise ToolError(f"{args.config}: no version/platform fields")
        version, platform = config_str(cfg, "version"), config_str(cfg, "platform")
    return target_marker_env(version, platform)


MARKER_TOKEN = re.compile(
    r"\s*(?:(?P<str>'[^']*'|\"[^\"]*\")|(?P<op>===|==|!=|<=|>=|~=|<|>|\(|\))|(?P<word>[A-Za-z_][A-Za-z0-9_.]*))"
)


class _MarkerParser:
    """Recursive-descent evaluator for PEP 508 markers (``packaging`` is not stdlib)."""

    def __init__(self, marker: str, env: Dict[str, str]) -> None:
        self.marker = marker
        self.env = env
        self.toks: List[Tuple[str, str]] = []
        self.pos = 0
        text = marker.strip()
        at = 0
        while at < len(text):
            m = MARKER_TOKEN.match(text, at)
            if m is None or m.end() == at:
                raise ToolError(f"cannot parse marker {marker!r}")
            at = m.end()
            kind = m.lastgroup or ""
            self.toks.append((kind, m.group(kind)))

    def peek(self) -> Tuple[str, str]:
        return self.toks[self.pos] if self.pos < len(self.toks) else ("", "")

    def take(self) -> Tuple[str, str]:
        tok = self.peek()
        if tok == ("", ""):
            raise ToolError(f"truncated marker {self.marker!r}")
        self.pos += 1
        return tok

    def value(self) -> str:
        kind, t = self.take()
        if kind == "str":
            return t[1:-1]
        if kind == "word" and t in self.env:
            return self.env[t]
        raise ToolError(f"unknown marker variable {t!r} in {self.marker!r}")

    @staticmethod
    def compare(lhs: str, op: str, rhs: str) -> bool:
        if op == "in":
            return lhs in rhs
        if op == "not in":
            return lhs not in rhs
        numeric = re.fullmatch(r"[\d.]+", lhs) and re.fullmatch(r"[\d.]+", rhs)
        if op in ("==", "!=", "===") and not numeric:
            return (lhs == rhs) == (op != "!=")
        a = tuple(int(x) for x in re.findall(r"\d+", lhs))
        b = tuple(int(x) for x in re.findall(r"\d+", rhs))
        if op in ("==", "==="):
            return a == b
        if op == "!=":
            return a != b
        if op == "<":
            return a < b
        if op == "<=":
            return a <= b
        if op == ">":
            return a > b
        if op == ">=":
            return a >= b
        if op == "~=":
            return a >= b and a[: len(b) - 1] == b[: len(b) - 1]
        raise ToolError(f"unknown marker operator {op!r}")

    def atom(self) -> bool:
        if self.peek() == ("op", "("):
            self.take()
            r = self.disj()
            self.take()
            return r
        lhs = self.value()
        _, op = self.take()
        if op == "not":
            self.take()
            op = "not in"
        return self.compare(lhs, op, self.value())

    def conj(self) -> bool:
        r = self.atom()
        while self.peek() == ("word", "and"):
            self.take()
            r = self.atom() and r
        return r

    def disj(self) -> bool:
        r = self.conj()
        while self.peek() == ("word", "or"):
            self.take()
            r = self.conj() or r
        return r


def eval_marker(marker: str, env: Dict[str, str]) -> bool:
    """Evaluate a PEP 508 environment marker against ``env``."""
    p = _MarkerParser(marker, env)
    r = p.disj()
    if p.pos != len(p.toks):
        raise ToolError(f"trailing tokens in marker {marker!r}")
    return r


DOWNLOAD_TIMEOUT = 60.0


def download(
    url: str,
    dest: Path,
    sha256: str,
    timeout: float = DOWNLOAD_TIMEOUT,
    opener: Optional[Any] = None,
) -> None:
    """Fetch ``url`` to ``dest`` atomically, checking ``sha256``.

    ``timeout`` bounds every socket operation; any failure (network, timeout,
    HTTP error, disk) becomes a :class:`ToolError` and the ``.part`` file is
    always removed.  ``opener`` defaults to ``urllib.request.urlopen`` (tests
    inject a fake).
    """
    if not url.startswith("https://"):
        raise ToolError(f"{dest.name}: refusing non-https URL {url!r}")
    open_url = opener or urllib.request.urlopen
    tmp = dest.with_name(dest.name + ".part")
    try:
        try:
            with open_url(url, timeout=timeout) as r, tmp.open("wb") as f:
                while chunk := r.read(1 << 20):
                    f.write(chunk)
        except Exception as e:  # URLError, TimeoutError, http.client errors, OSError
            raise ToolError(
                f"{dest.name}: download failed: {type(e).__name__}: {e}"
            ) from None
        if sha256_file(tmp) != sha256:
            raise ToolError(
                f"{dest.name}: downloaded file does not match the lock's sha256"
            )
        os.replace(tmp, dest)
    finally:
        tmp.unlink(missing_ok=True)


def fetch_requirements(
    args: argparse.Namespace, env: Dict[str, str]
) -> List[Tuple[str, str, str]]:
    """``(normalized name, version, marker)`` for every requirement to fetch: the
    lines of ``--requirements`` (a ``uv export`` output), or else the lock's own
    closure from ``--root`` (see :func:`lock_closure`)."""
    if args.requirements is None:
        return lock_closure(args.lock, args.root, env)
    out: List[Tuple[str, str, str]] = []
    for raw in args.requirements.read_text().splitlines():
        line = raw.split("#", 1)[0].strip().rstrip("\\").strip()
        if not line or line.startswith("--hash"):
            continue
        if line.startswith("-"):
            raise ToolError(
                f"unsupported requirements line {raw!r}: only NAME==VERSION pins "
                "(and --hash continuations) are accepted; editable/option lines "
                "are not bundleable"
            )
        req, _, marker = line.partition(";")
        if "@" in req or "://" in req:
            raise ToolError(f"unsupported direct-URL requirement {raw!r}")
        m = re.match(
            r"^([A-Za-z0-9_.\-]+)(?:\[[^\]]*\])?\s*==\s*([^\s;]+)", req.strip()
        )
        if m is None:
            raise ToolError(
                f"unsupported requirement line {raw!r} (expected NAME==VERSION)"
            )
        out.append((normalize_dist(m[1]), m[2], marker))
    return out


def cmd_fetch_wheels(args: argparse.Namespace) -> None:
    """Exit codes: 0 all wheels present and verified (stdout lists their file
    names); 1 any error (``sboa-bundle: error: ...`` on stderr): no pure wheel in
    the lock for a required distribution, requirement not in the lock, hash
    mismatch, missing file with ``--offline``, download failure, unparsable
    requirement or marker; 2 command-line usage error (argparse)."""
    lock = read_lock(args.lock)
    env = target_marker_env_from_args(args)
    excluded = read_exclude_dists(args)
    args.out.mkdir(parents=True, exist_ok=True)
    # Recorded for `bundle --exclude-dist-file DIR/.excludes` (closure check).
    (args.out / ".excludes").write_text("".join(f"{d}\n" for d in sorted(excluded)))
    skipped: List[str] = []
    selected: Set[str] = set()
    for dist, version, marker in fetch_requirements(args, env):
        if marker.strip() and not eval_marker(marker, env):
            skipped.append(f"{dist} (marker: {marker.strip()})")
            continue
        if dist in excluded:
            skipped.append(f"{dist} (excluded)")
            continue
        pkg = lock_get(lock, dist, version)
        if pkg is None:
            raise ToolError(f"{dist}=={version} is not in {args.lock}")
        w = lock_pure_wheel(pkg)
        if w is None:
            raise ToolError(
                f"{dist}=={version}: the lock has no py3-none-any wheel; exclude it or replace it"
            )
        fn = lock_wheel_filename(w)
        if not parse_wheel_name(Path(fn)).pure:  # defensive: lock_pure_wheel chose it
            raise ToolError(f"{fn}: not a pure (py3-none-any) wheel")
        algo, _, want = str(w.get("hash", "")).partition(":")
        if algo != "sha256" or not want:
            raise ToolError(f"{fn}: the lock has no sha256 for this wheel")
        dest = args.out / fn
        selected.add(fn)
        if dest.is_file():
            if sha256_file(dest) == want:
                print(fn)  # reused, verified
                continue
            if args.offline:
                raise ToolError(
                    f"{dest}: sha256 does not match the lock (offline: not re-fetched)"
                )
            print(f"warning: {dest}: sha256 mismatch, re-downloading", file=sys.stderr)
        elif args.offline:
            raise ToolError(f"{dest}: missing (offline)")
        download(str(w.get("url", "")), dest, want, timeout=args.timeout)
        print(fn)
    for s in skipped:
        print(f"skipped: {s}", file=sys.stderr)
    if args.prune:
        # Only after a complete fetch: a stale wheel would fail the bundle's
        # closure check, but a failed fetch must leave the cache alone.
        for p in sorted(args.out.glob("*.whl")):
            if p.name not in selected:
                print(f"removing stale {p}", file=sys.stderr)
                p.unlink()


# ---------------------------------------------------------------------------
# runtime-files: the files an application ships next to its executable
# ---------------------------------------------------------------------------

# ``sboa.config`` lists, in ``runtime_files``, the files that must sit next to
# the final executable: the shared library and the extension modules.
# ``runtime-files --layout libs|bin --out DIR`` copies them into DIR (modes
# preserved) when the platform's layout matches, and creates an empty DIR
# otherwise. Run as the action of a dune rule with ``(targets (dir DIR))`` it
# lets a dune project install the files without any platform knowledge:
#
#   libs  Linux/macOS: runtime_subdir is ``libs``; the files land in bin/libs/.
#   bin   Windows: runtime_subdir is empty; DLLs and .pyd land in bin/, next to
#         the .exe, which is where the Windows loader looks.
#
# (dune cannot read external files in an ``install`` stanza, ``install`` has no
# ``:include``, and a generated dune file cannot be ``include``d, so the names
# cannot flow into the stanza; whole directories can.)
#
# The Windows ``install`` stanza therefore names every file by hand. With
# ``--check-install-list FILE`` (the dune file holding that stanza) the staged
# ``bin`` layout must be exactly the ``(runtime_bin/NAME as NAME)`` entries of
# FILE, otherwise the build fails: a CPython upgrade that adds, drops or
# renames a DLL or extension module is caught here instead of as a missing
# file at run time.


def runtime_entries(cfg: "Dict[str, Sexp]") -> List[Tuple[str, str]]:
    """(absolute source, destination relative to bin/<subdir>/)."""
    files = cfg.get("runtime_files")
    if not isinstance(files, list):
        raise ToolError("config field 'runtime_files' missing or not a list")
    out: List[Tuple[str, str]] = []
    for item in files:
        if not (isinstance(item, list) and len(item) == 2):
            raise ToolError(f"malformed runtime_files entry: {item!r}")
        src, dest = item
        if not (isinstance(src, str) and isinstance(dest, str)):
            raise ToolError(f"malformed runtime_files entry: {item!r}")
        if not os.path.isabs(src):
            raise ToolError(f"runtime file {src!r} is not an absolute path")
        if os.path.isabs(dest) or ".." in dest.replace("\\", "/").split("/"):
            raise ToolError(f"runtime file destination {dest!r} escapes the directory")
        out.append((src, dest))
    return out


def stage(cfg: "Dict[str, Sexp]", layout: str, out_dir: str) -> bool:
    """Copy the runtime files into [out_dir]/<dest> if the config's layout is
    [layout] ("libs": runtime_subdir is non-empty; "bin": it is empty), else
    just create the empty [out_dir]. Returns whether anything was staged."""
    os.makedirs(out_dir, exist_ok=True)
    if ("libs" if config_str(cfg, "runtime_subdir") else "bin") != layout:
        return False
    for src, dest in runtime_entries(cfg):
        out = os.path.join(out_dir, dest)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        shutil.copyfile(src, out)
        shutil.copymode(src, out)
    return True


_INSTALL_ENTRY = re.compile(r"\(\s*runtime_bin/([^\s()]+)\s+as\s+([^\s()]+)\s*\)")


def install_list(path: str) -> List[str]:
    """The NAMEs of the ``(runtime_bin/NAME as NAME)`` entries of a dune file
    (``;`` comments ignored)."""
    with open(path, encoding="utf-8") as f:
        text = "\n".join(line.split(";", 1)[0] for line in f.read().splitlines())
    names: List[str] = []
    for src, dest in _INSTALL_ENTRY.findall(text):
        if src != dest:
            raise ToolError(f"{path}: runtime_bin/{src} is installed as {dest}")
        names.append(src)
    return names


def check_install_list(out_dir: str, list_file: str) -> None:
    """Fail unless the files staged in [out_dir] are exactly the install
    list of [list_file]."""
    staged = set()
    for dirpath, _dirs, files in os.walk(out_dir):
        for name in files:
            rel = os.path.relpath(os.path.join(dirpath, name), out_dir)
            staged.add(rel.replace(os.sep, "/"))
    listed = set(install_list(list_file))
    if staged == listed:
        return
    lines = [
        f"the runtime files staged in {out_dir} differ from the install list"
        f" in {list_file}:"
    ]
    for name in sorted(staged - listed):
        lines.append(f"  staged but not installed: {name}")
    for name in sorted(listed - staged):
        lines.append(f"  installed but not staged: {name}")
    lines.append(
        "Update the (runtime_bin/NAME as NAME) entries of the Windows install"
        " stanza."
    )
    raise ToolError("\n".join(lines))


def cmd_runtime_files(args: argparse.Namespace) -> None:
    if args.config is None:
        raise UsageError("runtime-files needs --config")
    cfg = read_sboa_config(args.config)
    staged_here = stage(cfg, args.layout, str(args.out))
    if args.check_install_list and args.layout == "bin" and staged_here:
        check_install_list(str(args.out), str(args.check_install_list))


# ---------------------------------------------------------------------------
# describe, flags, exec: the CPython a config names
# ---------------------------------------------------------------------------

# ``describe`` writes ``sboa.config`` (one sexp, a list of ``(field value)``
# pairs; see the README for the fields) for a CPython 3.13 installation.
# Everything is asked of that installation's interpreter (``sys``,
# ``sysconfig``) and of its layout, so any CPython 3.13 with a shared
# libpython works: python-build-standalone (uv), distribution packages,
# Homebrew's framework build, nix, the python.org Windows layout. It must run
# under the interpreter it describes, and re-runs itself under it when needed.
#
# ``runtime_files`` lists what an application must install next to its
# executable for it to run without the CPython installation: libpython and the
# C extension modules of ``lib-dynload`` (under ``bin/libs/``) on Linux and
# macOS; ``python3XY.dll``, ``python3.dll``, the ``vcruntime`` DLLs and the
# contents of ``DLLs/`` (next to the ``.exe``) on Windows. Tk and CPython's
# test extension modules are left out.
#
# ``flags`` turns a config into dune ``(:include)`` files, ``exec`` runs its
# interpreter.

PYVER = "3.13"

# Extension modules and DLLs never shipped (Tk, CPython's own test modules).
EXCLUDED_PREFIXES = ("_tkinter.", "_test", "xxlimited", "_ctypes_test", "_xxtest")
EXCLUDED_DLL_PREFIXES = ("tcl", "tk")


def slashes(path: str) -> str:
    """Forward slashes: what gcc (mingw), dune and CPython accept everywhere."""
    return path.replace("\\", "/")


def check_value(name: str, value: str) -> str:
    # The readers of sboa.config (dune's (:include) of the flags, OCaml
    # string literals) do not unescape anything.
    if any(c in value for c in '")\\\n'):
        raise ToolError(
            f"{name} contains '\"', ')', a backslash or a newline, which"
            f" sboa.config cannot carry: {value!r}"
        )
    # A control character in a path is a CRLF command output captured without
    # stripping the CR (`opam var` on Windows); Cygwin shows such a character
    # in a file name as U+F000 + its code.
    if any(ord(c) < 0x20 or ord(c) == 0x7F or 0xF000 <= ord(c) <= 0xF0FF for c in value):
        raise ToolError(
            f"{name} contains a control character (a carriage return from a"
            f" CRLF command output?): {value!r}"
        )
    return value


def excluded_runtime_file(name: str) -> bool:
    lower = name.lower()
    if lower.startswith(EXCLUDED_PREFIXES):
        return True
    return lower.endswith(".dll") and lower.startswith(EXCLUDED_DLL_PREFIXES)


def host_platform_id(kind: str) -> str:
    import platform

    machine = platform.machine().lower()
    arch = {"amd64": "x86_64", "x86_64": "x86_64", "arm64": "aarch64"}.get(
        machine, machine
    )
    if kind == "windows":
        if arch != "x86_64":
            raise ToolError(f"unsupported Windows architecture {machine}")
        return "windows-x86_64"
    if kind == "macho":
        return "macos-arm64" if arch == "aarch64" else "macos-x86_64"
    import sysconfig

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
            if (
                name.endswith((".so", ".dylib"))
                and not excluded_runtime_file(name)
                and os.path.isfile(path)
            ):
                files.append((slashes(path), f"python{PYVER}/lib-dynload/{name}"))
    return files


def windows_runtime_files(prefix: str) -> List[Tuple[str, str]]:
    """(absolute source, destination next to the .exe) on Windows: the DLLs
    of the installation's root and the contents of DLLs/."""
    nodot = PYVER.replace(".", "")
    files: List[Tuple[str, str]] = []
    for name in (f"python{nodot}.dll", "python3.dll"):
        path = os.path.join(prefix, name)
        if not os.path.isfile(path):
            raise ToolError(f"no {path}")
        files.append((slashes(path), name))
    for name in sorted(os.listdir(prefix)):
        if name.lower().startswith("vcruntime") and name.lower().endswith(".dll"):
            files.append((slashes(os.path.join(prefix, name)), name))
    dlls = os.path.join(prefix, "DLLs")
    if os.path.isdir(dlls):
        for name in sorted(os.listdir(dlls)):
            if name.lower().endswith((".pyd", ".dll")) and not excluded_runtime_file(
                name
            ):
                files.append((slashes(os.path.join(dlls, name)), name))
    return files


def find_unix_lib(kind: str, prefix: str) -> Tuple[str, str, bool]:
    """(library to link by full path, its runtime file name, whether the
    library can be shipped next to the executable)."""
    import sysconfig

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
    raise ToolError(
        f"{sys.executable} is a static build: no {' or '.join(names)} in"
        f" {' or '.join(dirs)} (the CPython must come with a shared libpython:"
        " --enable-shared, or a distribution's -dev/-devel package)"
    )


def check_interpreter() -> None:
    import platform
    import sysconfig

    if sys.implementation.name != "cpython":
        raise ToolError(f"{sys.executable} is not CPython")
    if f"{sys.version_info[0]}.{sys.version_info[1]}" != PYVER:
        raise ToolError(
            f"CPython {PYVER} is required, {sys.executable} is"
            f" {platform.python_version()}"
        )
    if sysconfig.get_config_var("Py_GIL_DISABLED"):
        raise ToolError(f"{sys.executable} is a free-threaded build")
    if hasattr(sys, "gettotalrefcount") or sysconfig.get_config_var("Py_DEBUG"):
        raise ToolError(f"{sys.executable} is a debug (Py_DEBUG) build")


def check_library(lib_file: str) -> None:
    """The library must be this interpreter's: same version string, and not
    a debug build (which exports _Py_NegativeRefcount)."""
    import ctypes

    try:
        lib = ctypes.CDLL(lib_file)
        f = lib.Py_GetVersion
        f.restype = ctypes.c_char_p
        same = f().decode() == sys.version
        debug = hasattr(lib, "_Py_NegativeRefcount")
    except (OSError, AttributeError) as e:
        raise ToolError(f"cannot load {lib_file}: {e}") from e
    if not same or debug:
        raise ToolError(
            f"{lib_file} is not the library of {sys.executable}"
            " (Py_GetVersion must match and Py_DEBUG must be off)"
        )


def describe_fields(python: str, prefix: Optional[str]) -> List[Tuple[str, str]]:
    """The config fields of the running interpreter, in order (values
    already rendered)."""
    import platform
    import sysconfig

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
        libdir = os.path.join(prefix, "libs")
        lib_file = os.path.join(libdir, f"python{nodot}.lib")
        if not os.path.isfile(lib_file):
            raise ToolError(f"no import library {lib_file}")
        runtime_subdir = ""
        runtime = windows_runtime_files(prefix)
    else:
        lib_file, soname, ship_lib = find_unix_lib(kind, prefix)
        libdir = os.path.dirname(lib_file)
        check_library(lib_file)
        libdynload_dir = os.path.join(stdlib_dir, "lib-dynload")
        runtime = unix_runtime_files(lib_file, soname, ship_lib, libdynload_dir)
        runtime_subdir = "libs"
    if not os.path.isfile(os.path.join(incdir, "Python.h")):
        raise ToolError(f"no {incdir}/Python.h (the CPython headers)")
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
        q("platform", host_platform_id(kind)),
        q("install_fingerprint", fingerprint),
        p("incdir", incdir),
        p("libdir", libdir),
        p("lib_file", lib_file),
        p("stdlib_dir", stdlib_dir),
        p("python_exe", python),
        q("runtime_subdir", runtime_subdir),
        ("runtime_files", f"({files}\n )"),
    ]


def prefix_interpreter(prefix: str) -> str:
    for c in ("bin/python3.13", "bin/python3", "python.exe"):
        path = os.path.join(prefix, c)
        if os.path.isfile(path):
            return path
    raise ToolError(f"{prefix} has no bin/python3.13, bin/python3 or python.exe")


def cmd_describe(args: argparse.Namespace) -> int:
    prefix = None if args.prefix is None else os.path.abspath(args.prefix)
    if prefix is not None and not os.path.isdir(prefix):
        raise ToolError(f"no directory {prefix}")
    if args.python is not None:
        python = args.python
    elif prefix is not None:
        python = prefix_interpreter(prefix)
    else:
        python = sys.executable
    python = slashes(os.path.abspath(python))
    if os.path.realpath(python) != os.path.realpath(sys.executable):
        # -I: ignore PYTHON* variables and the user site; -B: no bytecode.
        cmd = [python, "-I", "-B", os.path.abspath(__file__), "describe"]
        cmd += ["--python", python, "--out", str(args.out)]
        if prefix is not None:
            cmd += ["--prefix", prefix]
        try:
            return subprocess.run(cmd).returncode
        except OSError as e:
            raise ToolError(f"cannot run {python}: {e}") from e
    fields = describe_fields(python, prefix)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    body = "\n ".join(f"({k} {v})" for k, v in fields)
    # UTF-8 and LF whatever the locale and platform (the readers assume it;
    # a non-ASCII path under the Windows code page would fail here, far from
    # its cause).
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"({body})\n")
    d = {k: v.strip('"') for k, v in fields}
    print(
        f"sboa-bundle: {out} for {python} ({d['version']}, {d['platform']})",
        file=sys.stderr,
    )
    return 0


def installed_config() -> Path:
    """The ``sboa.config`` next to this script: the installed one
    (``lib/sboa/``), or the one sboa's build writes next to the script in a
    dune workspace."""
    return Path(os.path.realpath(__file__)).parent / "sboa.config"


def need_config(args: argparse.Namespace, cmd: str) -> Dict[str, "Sexp"]:
    """``--config``, else the installed config (what the launcher runs the
    script under)."""
    if args.config is not None:
        return read_sboa_config(args.config)
    default = installed_config()
    if not default.is_file():
        raise UsageError(f"{cmd} needs --config (there is no {default})")
    return read_sboa_config(default)


def dune_sexp(items: Sequence[str]) -> str:
    """A dune list of quoted atoms (config values carry no '"' or '\\')."""
    return "(" + " ".join(f'"{check_value("flag", s)}"' for s in items) + ")\n"


def link_items(cfg: Dict[str, "Sexp"]) -> List[Tuple[str, str]]:
    """(kind, flag): ``lib`` for libpython by full path (the executable
    records its SONAME / install name), ``opt`` for the rpaths: where the
    runtime files ship (bin/libs/), then libdir (binaries in _build)."""
    items = [("lib", config_str(cfg, "lib_file"))]
    plat = config_str(cfg, "platform")
    if plat.startswith("windows"):
        return items  # DLLs live next to the .exe
    if plat.startswith("macos"):
        items.append(("opt", "-Wl,-rpath,@loader_path/libs"))
    else:
        # ocamlopt hands the linker command to the shell: quote $ORIGIN.
        items.append(("opt", "'-Wl,-rpath,$ORIGIN/libs'"))
    items.append(("opt", f"-Wl,-rpath,{config_str(cfg, 'libdir')}"))
    return items


def cmd_flags(args: argparse.Namespace) -> None:
    cfg = need_config(args, "flags")
    if args.what == "cflags":
        flags = [f"-I{config_str(cfg, 'incdir')}"]
    elif args.what == "clibs":
        # A Windows DLL (the bytecode stub library) cannot have undefined
        # symbols: there, the library links the import library, which binds
        # by DLL name (python313.dll next to the .exe), not by path.
        # Elsewhere the application links libpython (--link).
        plat = config_str(cfg, "platform")
        flags = [config_str(cfg, "lib_file")] if plat.startswith("windows") else []
    else:
        flags = []
        for kind, f in link_items(cfg):
            flags += ["-cclib" if kind == "lib" else "-ccopt", f]
    text = dune_sexp(flags)
    if args.out is None:
        sys.stdout.write(text)
    else:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)


def cmd_exec(args: argparse.Namespace) -> int:
    python = config_str(need_config(args, "exec"), "python_exe")
    rest = list(args.args)
    if rest[:1] == ["--"]:
        rest = rest[1:]
    sys.stdout.flush()
    if os.name == "posix":
        try:
            os.execv(python, [python, *rest])
        except OSError as e:
            raise ToolError(f"cannot run {python}: {e}") from e
    try:
        return subprocess.run([python, *rest]).returncode
    except OSError as e:
        raise ToolError(f"cannot run {python}: {e}") from e


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def add_target_args(p: argparse.ArgumentParser) -> None:
    p.add_argument(
        "--exclude-dist-file",
        action="append",
        default=[],
        type=Path,
        metavar="FILE",
        help="file of distribution names to leave out (one per line, # comments)",
    )
    p.add_argument(
        "--python-version",
        help="embedded CPython version for markers (default: the --config's)",
    )
    p.add_argument(
        "--platform",
        help="embedded sboa platform for markers, e.g. linux-gnu-x86_64"
        " (default: the --config's)",
    )
    p.add_argument(
        "--root",
        help="lock package whose runtime closure to use (default: the lock's"
        " editable/virtual project package)",
    )


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="sboa-bundle",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "--config",
        type=Path,
        help="sboa.config: run under its python_exe, evaluate wheel markers for"
        " its interpreter, default stdlib --stdlib-dir to its stdlib_dir",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("bundle", help="bundle packages and wheels")
    b.add_argument("--name", required=True)
    b.add_argument(
        "--package",
        action="append",
        default=[],
        metavar="NAME=DIR",
        help="source package directory (or NAME=FILE.py)",
    )
    b.add_argument(
        "--wheels",
        action="append",
        default=[],
        type=Path,
        metavar="PATH",
        help=".whl file or directory of .whl files (repeatable)",
    )
    b.add_argument(
        "--site",
        action="append",
        default=[],
        type=Path,
        metavar="DIR",
        help="installed tree (pip/uv --target)",
    )
    b.add_argument(
        "--lock",
        type=Path,
        help="uv.lock: verify wheel hashes, enforce the pure-wheel policy",
    )
    b.add_argument(
        "--data",
        action="append",
        default=[],
        metavar="GLOB",
        help="non-.py files of --package trees to include (arcname glob)",
    )
    b.add_argument(
        "--exclude",
        action="append",
        default=[],
        metavar="GLOB",
        help="arcname glob to leave out",
    )
    b.add_argument(
        "--exclude-dist",
        action="append",
        default=[],
        metavar="NAME",
        help="distribution to leave out",
    )
    add_target_args(b)
    b.add_argument(
        "--allow-stdlib-shadow",
        action="store_true",
        help="accept top-level names that are standard library modules",
    )
    add_embed_args(b, 50)
    b.set_defaults(func=cmd_bundle)

    s = sub.add_parser("stdlib", help="bundle the standard library")
    s.add_argument(
        "--stdlib-dir",
        type=Path,
        help="stdlib directory (default: stdlib_dir from --config)",
    )
    s.add_argument("--name", default="stdlib")
    s.add_argument("--exclude", action="append", default=[], metavar="GLOB")
    add_embed_args(s, 0)
    s.set_defaults(func=cmd_stdlib)

    e = sub.add_parser("embed", help="emit embedding sources for an existing zip")
    e.add_argument("--zip", type=Path, required=True)
    e.add_argument("--name", required=True)
    add_embed_args(e, 50)
    e.set_defaults(func=cmd_embed)

    f = sub.add_parser("freeze", help="write the PyImport_FrozenModules table")
    f.add_argument("--module", action="append", default=[], metavar="NAME=FILE")
    f.add_argument("--package", action="append", default=[], metavar="NAME=DIR")
    f.add_argument(
        "--stdlib-package",
        action="append",
        default=[],
        metavar="NAME",
        help="freeze stdlib package NAME from --stdlib-dir / the config's stdlib_dir",
    )
    f.add_argument("--stdlib-dir", type=Path)
    f.add_argument("--out", type=Path, required=True)
    f.add_argument(
        "--ml",
        type=Path,
        metavar="FILE",
        help="also write an OCaml module whose initialization links the table"
        " (for a -linkall library; see the README)",
    )
    f.set_defaults(func=cmd_freeze)

    c = sub.add_parser("check-seam", help="check bytecode references against exports")
    c.add_argument("--bundle", type=Path, required=True)
    c.add_argument("--module", required=True)
    c.add_argument(
        "--exports",
        required=True,
        help="file (lines or JSON) or executable printing it",
    )
    c.add_argument("--allow", type=Path, help="names allowed to be exported-but-unused")
    c.add_argument(
        "--via",
        action="append",
        default=[],
        metavar="MODULE:NAME",
        help="`from MODULE import NAME` also binds the checked module "
        "(a re-exporting module; repeatable)",
    )
    c.set_defaults(func=cmd_check_seam)

    w = sub.add_parser(
        "fetch-wheels", help="download the pure wheels of a uv.lock closure"
    )
    w.add_argument("--lock", type=Path, required=True)
    w.add_argument(
        "--requirements",
        type=Path,
        help="uv export --format requirements-txt output (default: the closure of"
        " --root computed from the lock itself)",
    )
    w.add_argument("--exclude-dist", action="append", default=[], metavar="NAME")
    add_target_args(w)
    w.add_argument(
        "--timeout",
        type=float,
        default=DOWNLOAD_TIMEOUT,
        help="seconds per network operation (default %(default)s)",
    )
    w.add_argument("-d", "--out", type=Path, required=True, help="wheel directory")
    w.add_argument(
        "--offline",
        action="store_true",
        help="never download: every wheel must already be in -d with the lock's sha256",
    )
    w.add_argument(
        "--prune",
        action="store_true",
        help="after a successful fetch, delete the *.whl files of -d that the"
        " lock does not select (a stale wheel fails the bundle's closure check)",
    )
    w.set_defaults(func=cmd_fetch_wheels)

    r = sub.add_parser(
        "runtime-files",
        help="stage the runtime files of --config into a directory (dune target)",
    )
    r.add_argument("--layout", choices=["libs", "bin"], required=True)
    r.add_argument("--out", type=Path, required=True, help="directory to populate")
    r.add_argument(
        "--check-install-list",
        type=Path,
        metavar="FILE",
        help="with --layout bin: the dune file whose (runtime_bin/NAME as NAME)"
        " entries must be exactly the staged files",
    )
    r.set_defaults(func=cmd_runtime_files)

    d = sub.add_parser(
        "describe",
        help="write the sboa.config of a CPython 3.13 installation",
    )
    d.add_argument(
        "--prefix",
        help="installation prefix (its bin/python3.13, bin/python3 or python.exe;"
        " default: the interpreter's sys.base_prefix)",
    )
    d.add_argument(
        "--python", help="the interpreter (default: the --prefix's, else this one)"
    )
    d.add_argument("--out", type=Path, required=True, help="the config file to write")
    d.set_defaults(func=cmd_describe)

    fl = sub.add_parser(
        "flags",
        help="print C or link flags of --config (default: the installed"
        " sboa.config) as a dune (:include) sexp",
    )
    config_arg(fl)
    what = fl.add_mutually_exclusive_group(required=True)
    what.add_argument(
        "--cflags",
        dest="what",
        action="store_const",
        const="cflags",
        help="-I of the CPython headers (foreign_stubs flags)",
    )
    what.add_argument(
        "--link",
        dest="what",
        action="store_const",
        const="link",
        help="libpython by full path and the rpaths, for an executable's"
        " link_flags (-cclib/-ccopt)",
    )
    what.add_argument(
        "--clibs",
        dest="what",
        action="store_const",
        const="clibs",
        help="the sboa library's c_library_flags: empty, except the import"
        " library on Windows",
    )
    fl.add_argument("--out", type=Path, help="write to this file (default: stdout)")
    fl.set_defaults(func=cmd_flags)

    x = sub.add_parser(
        "exec",
        help="run the interpreter of --config (default: the installed"
        " sboa.config): exec [--config C] -- ARGS...",
    )
    config_arg(x)
    x.add_argument("args", nargs=argparse.REMAINDER)
    x.set_defaults(func=cmd_exec)
    return ap


def config_arg(p: argparse.ArgumentParser) -> None:
    """``--config`` after the subcommand too (SUPPRESS: an absent one leaves the
    global option's value alone)."""
    p.add_argument(
        "--config", type=Path, default=argparse.SUPPRESS, help="sboa.config"
    )


# ---------------------------------------------------------------------------
# sboa.config
# ---------------------------------------------------------------------------

Sexp = Union[str, List["Sexp"]]

_SEXP_TOKEN = re.compile(
    r'\s+|(?P<lp>\()|(?P<rp>\))|"(?P<str>(?:[^"\\]|\\.)*)"|(?P<atom>[^\s()"]+)'
)


def parse_sexp(text: str) -> Sexp:
    """Parse one sexp made of lists, atoms and double-quoted strings."""
    stack: List[List[Sexp]] = [[]]
    pos = 0
    while pos < len(text):
        m = _SEXP_TOKEN.match(text, pos)
        if m is None:
            raise ToolError(f"cannot parse sexp at offset {pos}")
        pos = m.end()
        if m.group("lp"):
            stack.append([])
        elif m.group("rp"):
            if len(stack) < 2:
                raise ToolError("unbalanced ')'")
            done = stack.pop()
            stack[-1].append(done)
        elif m.group("str") is not None:
            stack[-1].append(re.sub(r"\\(.)", r"\1", m.group("str")))
        elif m.group("atom"):
            stack[-1].append(m.group("atom"))
    if len(stack) != 1 or len(stack[0]) != 1:
        raise ToolError("expected exactly one complete sexp")
    return stack[0][0]


def read_sboa_config(path: Path) -> Dict[str, Sexp]:
    """Read ``sboa.config``: a list of ``(field value)`` pairs, the value a
    string (or atom) except ``runtime_files``, a list of ``(source dest)``
    pairs. Unknown fields are kept as they are."""
    top = parse_sexp(path.read_text(encoding="utf-8"))
    if not isinstance(top, list):
        raise ToolError(f"{path}: must be a list of (field value) pairs")
    cfg: Dict[str, Sexp] = {}
    for entry in top:
        if not (
            isinstance(entry, list) and len(entry) == 2 and isinstance(entry[0], str)
        ):
            raise ToolError(f"{path}: malformed entry: {entry!r}")
        cfg.setdefault(entry[0], entry[1])
    return cfg


def config_str(cfg: Dict[str, Sexp], key: str) -> str:
    v = cfg.get(key)
    if not isinstance(v, str):
        raise ToolError(f"sboa.config: field '{key}' missing or not a string")
    return v


def reexec_if_needed(argv: Sequence[str]) -> None:
    """Re-run under ``--config``'s interpreter and/or with ``PYTHONHASHSEED=0``
    (deterministic marshal)."""
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--config", type=Path)
    known, _ = ap.parse_known_args(argv)
    target = sys.executable
    if known.config is not None:
        target = config_str(read_sboa_config(known.config), "python_exe")
    rest = list(argv)
    same = os.path.realpath(target) == os.path.realpath(sys.executable)
    if (
        same
        and os.environ.get("PYTHONHASHSEED") == "0"
        and sys.flags.hash_randomization == 0
    ):
        return
    if os.environ.get("_SBOA_BUNDLE_REEXEC") == "1":
        raise ToolError("re-execution did not take effect")
    env = {k: v for k, v in os.environ.items() if not k.startswith("PYTHON")}
    env.update(
        PYTHONHASHSEED="0", PYTHONDONTWRITEBYTECODE="1", _SBOA_BUNDLE_REEXEC="1"
    )
    cmd = [target, "-s", "-P", os.path.abspath(__file__), *rest]
    sys.exit(subprocess.run(cmd, env=env).returncode)


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        args = build_parser().parse_args(argv)
        # describe re-runs itself under the interpreter it describes; flags
        # and exec only read the config.
        if args.func not in (cmd_describe, cmd_flags, cmd_exec):
            reexec_if_needed(argv)
        rc = args.func(args)
        return int(rc or 0)
    except ToolError as e:
        print(f"sboa-bundle: error: {e}", file=sys.stderr)
        return e.exit_code


if __name__ == "__main__":
    sys.exit(main())
