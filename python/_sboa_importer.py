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
"""Import Python modules from in-memory bundles (the ``sboa`` bootstrap importer).

A *bundle* is a zip archive produced by ``tools/sboa_bundle.py``: unchecked-hash
``.pyc`` files compiled at optimization level 0, data files, and trimmed
``*.dist-info`` directories.  The host hands every bundle to :func:`install` as a
``(name, buffer)`` pair, in search order; the buffer is typically a ``memoryview``
over bytes that live in the executable's read-only data, so nothing is read from
the filesystem.

What :func:`install` sets up:

* one :class:`SboaFinder` on ``sys.meta_path`` (right after the frozen importer)
  that resolves, in order: ``dev_overrides`` directories (through the standard
  ``PathFinder``, the editable-install equivalent), regular and package modules from
  the bundles, ``lib-dynload`` extension modules by name (``ExtensionFileLoader``),
  and implicit namespace packages (directories without ``__init__``) spanning
  bundles;
* a loader per bundle giving modules ``__file__ = "<sboa:NAME>/pkg/mod.py"``,
  ``__path__ = ["<sboa:NAME>/pkg"]``, ``get_data``, ``get_code``,
  ``get_source`` (always ``None``: bytecode only) and a ``TraversableResources``
  reader backed by ``zipfile.Path`` so ``importlib.resources.files(pkg)`` works;
* ``find_distributions`` on the finder, so ``importlib.metadata.version()`` and
  ``entry_points()`` see every ``*.dist-info`` directory in the bundles.

Bootstrap constraints.  This module is frozen into the executable and runs before
any filesystem or bundle importer exists, so at install time it may only use
builtin modules (``sys``, ``marshal``, ``_imp``, ``_thread``) and
modules that CPython itself freezes (``_frozen_importlib``,
``_frozen_importlib_external``, ``os``).  In particular it must not import
``importlib`` (not frozen), ``zipfile``, ``io`` wrappers beyond the frozen ``io``,
or ``struct``: bundle central directories are parsed by hand below.  ``zipfile``,
``importlib.resources.abc`` and ``importlib.metadata`` are imported lazily, the
first time a resource or a distribution is requested; by then the stdlib bundle is
reachable through this very importer.  The module has no ``__file__`` of its own
and does not need one.
"""
import _frozen_importlib as _bootstrap  # type: ignore[import-not-found]
import _frozen_importlib_external as _bootstrap_external  # type: ignore[import-not-found]
import _imp
import _thread
import marshal
import os
import sys

TYPE_CHECKING = False
if TYPE_CHECKING:
    from collections.abc import Iterable
    from collections.abc import Iterator
    from collections.abc import Sequence
    from types import CodeType
    from types import ModuleType
    from typing import Any
    from typing import Optional
    from typing import Union

    Buffer = Union[bytes, bytearray, memoryview]

__all__ = ["install", "uninstall", "SboaFinder", "BundleError"]

_PREFIX = "<sboa:"
_EOCD_SIG = b"PK\x05\x06"
_CDIR_SIG = b"PK\x01\x02"
_LOCAL_SIG = b"PK\x03\x04"
_STORED = 0
_DEFLATED = 8
# .pyc header (PEP 552): magic (4) | flags (4) | 8 bytes (hash or mtime+size).
_PYC_HEADER_SIZE = 16


class BundleError(ImportError):
    """A bundle is malformed or was compiled for another interpreter."""


def _u16(buf: "memoryview", off: int) -> int:
    return int.from_bytes(buf[off : off + 2], "little")


def _u32(buf: "memoryview", off: int) -> int:
    return int.from_bytes(buf[off : off + 4], "little")


class _Entry:
    __slots__ = ("method", "csize", "usize", "header_off")

    def __init__(self, method: int, csize: int, usize: int, header_off: int) -> None:
        self.method = method
        self.csize = csize
        self.usize = usize
        self.header_off = header_off


class _Bundle:
    """One zip bundle: a parsed central directory plus lazily-built helpers."""

    def __init__(self, name: str, data: "Buffer") -> None:
        self.name = name
        self.prefix = _PREFIX + name + ">/"
        self.data = memoryview(data).cast("B")
        self.entries: "dict[str, _Entry]" = {}
        self.comment = b""
        self._parse()
        # module name -> (arcname of the .pyc, is_package)
        self.modules: "dict[str, tuple[str, bool]]" = {}
        # directories that exist implicitly (dotted form), for namespace packages
        self.dirs: "set[str]" = set()
        self.dist_infos: "list[str]" = []
        self._index()
        self._lock = _thread.allocate_lock()
        self._zipfile: "Any" = None
        self.loader = _BundleLoader(self)

    def _parse(self) -> None:
        buf = self.data
        n = len(buf)
        # End of central directory: 22 bytes + up to 65535 bytes of comment.
        start = max(0, n - 22 - 0xFFFF)
        tail = bytes(buf[start:])
        pos = tail.rfind(_EOCD_SIG)
        if pos < 0:
            raise BundleError(f"bundle {self.name!r}: not a zip archive")
        eocd = start + pos
        count = _u16(buf, eocd + 10)
        cd_size = _u32(buf, eocd + 12)
        cd_off = _u32(buf, eocd + 16)
        clen = _u16(buf, eocd + 20)
        self.comment = bytes(buf[eocd + 22 : eocd + 22 + clen])
        if cd_off == 0xFFFFFFFF or count == 0xFFFF:
            raise BundleError(f"bundle {self.name!r}: zip64 archives are not supported")
        if cd_off + cd_size > eocd:
            raise BundleError(f"bundle {self.name!r}: truncated central directory")
        off = cd_off
        end = cd_off + cd_size
        for _ in range(count):
            if off + 46 > end or bytes(buf[off : off + 4]) != _CDIR_SIG:
                raise BundleError(f"bundle {self.name!r}: bad central directory")
            method = _u16(buf, off + 10)
            csize = _u32(buf, off + 20)
            usize = _u32(buf, off + 24)
            nlen = _u16(buf, off + 28)
            elen = _u16(buf, off + 30)
            klen = _u16(buf, off + 32)
            hoff = _u32(buf, off + 42)
            if off + 46 + nlen + elen + klen > end:
                raise BundleError(f"bundle {self.name!r}: bad central directory")
            raw_name = bytes(buf[off + 46 : off + 46 + nlen])
            try:
                name = raw_name.decode("utf-8")
            except UnicodeDecodeError:
                raise BundleError(
                    f"bundle {self.name!r}: member name {raw_name!r} is not UTF-8"
                ) from None
            if hoff + 30 > cd_off:
                raise BundleError(f"bundle {self.name!r}: {name}: bad header offset")
            if not name.endswith("/"):
                self.entries[name] = _Entry(method, csize, usize, hoff)
            off += 46 + nlen + elen + klen

    def _index(self) -> None:
        for arc in self.entries:
            parts = arc.split("/")
            for i in range(1, len(parts)):
                self.dirs.add(".".join(parts[:i]))
            if len(parts) == 2 and parts[0].endswith(".dist-info"):
                if parts[0] not in self.dist_infos:
                    self.dist_infos.append(parts[0])
            if not arc.endswith(".pyc"):
                continue
            stem = arc[:-4]
            if stem.endswith("/__init__"):
                self.modules[stem[:-9].replace("/", ".")] = (arc, True)
            elif stem != "__init__":
                self.modules[stem.replace("/", ".")] = (arc, False)
        self.dist_infos.sort()

    def read(self, arc: str) -> bytes:
        """Return the uncompressed bytes of member ``arc`` (KeyError if absent)."""
        e = self.entries[arc]
        buf = self.data
        h = e.header_off
        if bytes(buf[h : h + 4]) != _LOCAL_SIG:
            raise BundleError(f"bundle {self.name!r}: bad local header for {arc}")
        start = h + 30 + _u16(buf, h + 26) + _u16(buf, h + 28)
        if start + e.csize > len(buf):
            raise BundleError(f"bundle {self.name!r}: {arc} is truncated")
        raw = buf[start : start + e.csize]
        if e.method == _STORED:
            data = bytes(raw)
        elif e.method == _DEFLATED:
            # zlib is imported on first use, not at install time: CPython
            # builds that do not compile it into libpython (nix, Homebrew)
            # keep it in lib-dynload, which only this importer's finder
            # reaches once installed.
            import zlib

            try:
                data = zlib.decompress(raw, -15, e.usize)
            except zlib.error as exc:
                raise BundleError(
                    f"bundle {self.name!r}: {arc} is corrupt: {exc}"
                ) from None
        else:
            data = b""
        if e.method in (_STORED, _DEFLATED):
            if len(data) != e.usize:
                raise BundleError(f"bundle {self.name!r}: {arc} has the wrong size")
            return data
        raise BundleError(
            f"bundle {self.name!r}: unsupported compression {e.method} for {arc}"
        )

    def zipfile(self) -> "Any":
        """A ``zipfile.ZipFile`` over the bundle, built on first use."""
        with self._lock:
            if self._zipfile is None:
                import io
                import zipfile

                zf = zipfile.ZipFile(io.BytesIO(self.data))
                # zipfile.Path.__str__ joins this with member names; make those
                # strings match the modules' __file__.
                zf.filename = self.prefix[:-1]
                self._zipfile = zf
            return self._zipfile

    def arc_of_path(self, path: str) -> "Optional[str]":
        if path.startswith(self.prefix):
            return path[len(self.prefix) :]
        return None


class _BundleLoader:
    """Loader for modules stored in one bundle."""

    def __init__(self, bundle: _Bundle) -> None:
        self._bundle = bundle

    def __repr__(self) -> str:
        return f"<sboa loader {self._bundle.name!r}>"

    def _lookup(self, fullname: str) -> "tuple[str, bool]":
        try:
            return self._bundle.modules[fullname]
        except KeyError:
            raise ImportError(
                f"{fullname!r} is not in bundle {self._bundle.name!r}", name=fullname
            ) from None

    # -- Loader -----------------------------------------------------------
    def create_module(self, spec: "Any") -> None:
        return None

    def exec_module(self, module: "ModuleType") -> None:
        spec = module.__spec__
        name = spec.name if spec is not None else module.__name__
        exec(self.get_code(name), module.__dict__)

    # -- InspectLoader ----------------------------------------------------
    def get_code(self, fullname: str) -> "CodeType":
        arc, _ = self._lookup(fullname)
        data = self._bundle.read(arc)
        if len(data) < _PYC_HEADER_SIZE or data[:4] != _bootstrap_external.MAGIC_NUMBER:
            raise BundleError(
                f"{self._bundle.prefix}{arc}: bytecode magic {data[:4]!r} does not "
                f"match this interpreter ({_bootstrap_external.MAGIC_NUMBER!r})",
                name=fullname,
            )
        try:
            code: "CodeType" = marshal.loads(memoryview(data)[_PYC_HEADER_SIZE:])
        except (EOFError, ValueError, TypeError) as exc:
            raise BundleError(
                f"{self._bundle.prefix}{arc}: corrupt bytecode: {exc}", name=fullname
            ) from None
        return code

    def get_source(self, fullname: str) -> None:
        self._lookup(fullname)
        return None

    def is_package(self, fullname: str) -> bool:
        return self._lookup(fullname)[1]

    # -- ExecutionLoader / ResourceLoader ----------------------------------
    def get_filename(self, fullname: str) -> str:
        arc, _ = self._lookup(fullname)
        return self._bundle.prefix + arc[:-1]

    def get_data(self, path: str) -> bytes:
        arc = self._bundle.arc_of_path(path)
        if arc is None:
            arc = path
        try:
            return self._bundle.read(arc)
        except KeyError:
            raise FileNotFoundError(2, "No such file in bundle", path) from None

    # -- importlib.resources ----------------------------------------------
    def get_resource_reader(self, fullname: str) -> "Any":
        arc, is_pkg = self._lookup(fullname)
        at = arc.rpartition("/")[0]
        return _make_reader(self._bundle, at + "/" if at else "")


# The TraversableResources subclass, created on first use (its base class lives in
# the stdlib bundle, which is not importable when this module is executed).
_READER_CLASS: "list[Any]" = []


class _NamespaceLoader:
    """Loader for an implicit namespace package spanning bundle directories.

    CPython's ``NamespaceLoader`` only reads ``_NamespacePath`` objects of real
    directories (``importlib.resources.files()`` raises ``ValueError`` otherwise);
    this one answers ``get_resource_reader`` with a ``MultiplexedPath`` over the
    bundles' ``zipfile.Path`` directories.
    """

    def __init__(self, fullname: str, bundles: "Sequence[_Bundle]") -> None:
        self._name = fullname
        self._bundles = list(bundles)

    def __repr__(self) -> str:
        return f"<sboa namespace loader {self._name!r}>"

    def create_module(self, spec: "Any") -> None:
        return None

    def exec_module(self, module: "ModuleType") -> None:
        pass

    def is_package(self, fullname: str) -> bool:
        return True

    def get_source(self, fullname: str) -> None:
        return None

    def get_code(self, fullname: str) -> "CodeType":
        return compile("", f"<sboa namespace {fullname}>", "exec")

    def get_resource_reader(self, fullname: str) -> "Any":
        from importlib.resources.abc import TraversableResources
        from importlib.resources.readers import MultiplexedPath  # type: ignore[import-not-found]
        import zipfile

        at = self._name.replace(".", "/") + "/"
        paths = [zipfile.Path(b.zipfile(), at) for b in self._bundles]

        class _NamespaceReader(TraversableResources):
            def files(self) -> "Any":
                return MultiplexedPath(*paths)

        return _NamespaceReader()


def _make_reader(bundle: _Bundle, at: str) -> "Any":
    if not _READER_CLASS:
        from importlib.resources.abc import TraversableResources

        class _Reader(TraversableResources):
            def __init__(self, bundle: _Bundle, at: str) -> None:
                self._bundle = bundle
                self._at = at

            def files(self) -> "Any":
                import zipfile

                return zipfile.Path(self._bundle.zipfile(), self._at)

        _READER_CLASS.append(_Reader)
    return _READER_CLASS[0](bundle, at)


class SboaFinder:
    """``sys.meta_path`` finder over bundles, ``lib-dynload`` and dev overrides."""

    def __init__(
        self,
        bundles: "Sequence[_Bundle]",
        libdynload_dir: "Optional[str]",
        dev_overrides: "Sequence[str]",
    ) -> None:
        self.bundles = list(bundles)
        self._by_name = {b.name: b for b in self.bundles}
        self.libdynload_dir = libdynload_dir
        self.dev_overrides = [os.fspath(d) for d in dev_overrides]
        self._suffixes = list(_imp.extension_suffixes())
        self._dynload_files: "Optional[frozenset[str]]" = None
        stdlib_dir = getattr(sys, "_stdlib_dir", None)
        self._stdlib_dir: "Optional[str]" = (
            stdlib_dir.rstrip(os.sep)
            if isinstance(stdlib_dir, str) and stdlib_dir
            else None
        )

    def __repr__(self) -> str:
        return f"<SboaFinder bundles={[b.name for b in self.bundles]}>"

    # -- helpers ------------------------------------------------------------
    def _bundles_for(
        self, path: "Optional[Sequence[str]]"
    ) -> "Optional[list[_Bundle]]":
        """Bundles to search for a module whose parent has ``__path__ == path``.

        ``None`` means the parent lives outside the bundles (dev override or an
        explicit ``sys.path`` entry): leave it to ``PathFinder``.  An empty path
        (frozen packages such as ``encodings`` have ``__path__ == []``) searches
        every bundle by full name.
        """
        if not path:
            return self.bundles
        found: "list[_Bundle]" = []
        for entry in path:
            if not isinstance(entry, str):
                continue
            if entry.startswith(_PREFIX):
                b = self._by_name.get(entry[len(_PREFIX) :].partition(">")[0])
                if b is not None and b not in found:
                    found.append(b)
            elif self._stdlib_dir and (
                entry == self._stdlib_dir or entry.startswith(self._stdlib_dir + os.sep)
            ):
                # A frozen stdlib package (encodings, ...) gets a filesystem
                # __path__ under sys._stdlib_dir when that is known.  The
                # directory need not exist; its submodules live in the bundles.
                return self.bundles
        return found or None

    def _dynload(self, fullname: str) -> "Optional[str]":
        if self.libdynload_dir is None:
            return None
        if self._dynload_files is None:
            try:
                self._dynload_files = frozenset(os.listdir(self.libdynload_dir))
            except OSError:
                self._dynload_files = frozenset()
        for suffix in self._suffixes:
            if fullname + suffix in self._dynload_files:
                return os.path.join(self.libdynload_dir, fullname + suffix)
        return None

    # -- MetaPathFinder -----------------------------------------------------
    def find_spec(
        self,
        fullname: str,
        path: "Optional[Sequence[str]]" = None,
        target: "Optional[ModuleType]" = None,
    ) -> "Any":
        if path is None and self.dev_overrides:
            spec = _bootstrap_external.PathFinder.find_spec(
                fullname, self.dev_overrides
            )
            # Only real modules win; a stray directory (namespace portion) does not
            # shadow the bundled package.
            if spec is not None and spec.loader is not None:
                return spec
        bundles = self._bundles_for(path)
        if bundles is None:
            return None
        for b in bundles:
            hit = b.modules.get(fullname)
            if hit is not None:
                arc, is_pkg = hit
                origin = b.prefix + arc[:-1]
                spec = _bootstrap.ModuleSpec(
                    fullname, b.loader, origin=origin, is_package=is_pkg
                )
                spec.has_location = True
                spec.cached = b.prefix + arc
                if is_pkg:
                    spec.submodule_search_locations = [
                        b.prefix + arc.rpartition("/")[0]
                    ]
                return spec
        if path is None:
            filename = self._dynload(fullname)
            if filename is not None:
                loader = _bootstrap_external.ExtensionFileLoader(fullname, filename)
                return _bootstrap_external.spec_from_file_location(
                    fullname, filename, loader=loader
                )
        locations = [
            b.prefix + fullname.replace(".", "/") for b in bundles if fullname in b.dirs
        ]
        if locations:
            portions = [b for b in bundles if fullname in b.dirs]
            loader = _NamespaceLoader(fullname, portions)
            spec = _bootstrap.ModuleSpec(fullname, loader, is_package=True)
            spec.submodule_search_locations = locations
            return spec
        return None

    def invalidate_caches(self) -> None:
        self._dynload_files = None

    # -- importlib.metadata DistributionFinder ------------------------------
    def find_distributions(self, context: "Any" = None) -> "Iterator[Any]":
        import importlib.metadata as md

        name = getattr(context, "name", None) if context is not None else None
        wanted = _normalize_dist(name) if name else None
        for b in self.bundles:
            for d in b.dist_infos:
                project = d[: -len(".dist-info")].rpartition("-")[0]
                if wanted is None or _normalize_dist(project) == wanted:
                    import zipfile

                    root: "Any" = zipfile.Path(b.zipfile(), d + "/")
                    yield md.PathDistribution(root)


_NAME_CHARS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"
)


def _valid_bundle_name(name: object) -> bool:
    """Bundle names appear in ``<sboa:NAME>`` paths: ``[A-Za-z0-9_.-]+``."""
    return isinstance(name, str) and name != "" and all(c in _NAME_CHARS for c in name)


def _normalize_dist(name: str) -> str:
    """PEP 503 normalization with ``_`` (``importlib.metadata.Prepared.normalize``)."""
    out: "list[str]" = []
    sep = False
    for ch in name.lower():
        if ch in "-_.":
            sep = True
            continue
        if sep and out:
            out.append("_")
        sep = False
        out.append(ch)
    return "".join(out)


def install(
    bundles: "Iterable[tuple[str, Buffer]]",
    libdynload_dir: "Optional[str]" = None,
    dev_overrides: "Iterable[str]" = (),
) -> SboaFinder:
    """Install the bundle importer on ``sys.meta_path`` and return it.

    ``bundles`` are ``(name, buffer)`` pairs in search order (first wins).  Each
    bundle's zip comment must carry the bytecode magic of the running interpreter
    (``BundleError`` otherwise).  ``libdynload_dir`` is the directory holding the
    stdlib extension modules (``_ssl.cpython-313-x86_64-linux-gnu.so``, ...).
    ``None``, or a directory that does not exist or cannot be listed, simply
    disables extension lookup: that is the normal case on Linux and macOS, where
    every extension module is built into libpython and only Windows ships
    ``.pyd`` files.  No error is raised; unknown names fall through to
    ``ModuleNotFoundError`` as usual.  ``dev_overrides`` directories are searched
    first through ``PathFinder`` (sources, editable-install style).  Calling
    ``install`` again replaces the previous finder.
    """
    parsed = []
    seen = set()
    for name, data in bundles:
        if not _valid_bundle_name(name):
            raise BundleError(
                f"invalid bundle name {name!r} (allowed: [A-Za-z0-9_.-]+)"
            )
        if name in seen:
            raise BundleError(f"duplicate bundle name {name!r}")
        seen.add(name)
        b = _Bundle(name, data)
        _check_magic(b)
        parsed.append(b)
    finder = SboaFinder(parsed, libdynload_dir, list(dev_overrides))
    uninstall()
    pos = len(sys.meta_path)
    for i, f in enumerate(sys.meta_path):
        if f is _bootstrap_external.PathFinder:
            pos = i
            break
    sys.meta_path.insert(pos, finder)
    return finder


def uninstall() -> None:
    """Remove any finder installed by :func:`install` from ``sys.meta_path``."""
    sys.meta_path[:] = [f for f in sys.meta_path if not isinstance(f, SboaFinder)]


def _check_magic(b: _Bundle) -> None:
    # Comment format written by sboa_bundle.py: "sboa-bundle/1 name=N magic=HEX".
    fields = dict(
        kv.split("=", 1)
        for kv in b.comment.decode("ascii", "replace").split()
        if "=" in kv
    )
    magic = fields.get("magic")
    if magic is None:
        raise BundleError(f"bundle {b.name!r} has no sboa header (zip comment)")
    try:
        found = bytes.fromhex(magic)
    except ValueError:
        raise BundleError(f"bundle {b.name!r}: malformed magic {magic!r}") from None
    if found != _bootstrap_external.MAGIC_NUMBER:
        raise BundleError(
            f"bundle {b.name!r} was compiled for bytecode magic {magic}, this "
            f"interpreter has {_bootstrap_external.MAGIC_NUMBER.hex()}"
        )
