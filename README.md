WARNING: ALL SLOP RIGHT NOW

# sboa

sboa ("Sand Boa"; formerly `pyembed`) embeds CPython 3.13 in an OCaml
executable. It is a dune virtual library (`sboa`) with two implementations:

| Library | What |
|---|---|
| `sboa` | the bridge: GIL tokens, owned object handles with deferred release, fallible conversions, OCaml functions and classes exported as builtin Python modules, exception translation both ways, signal routing, atomic counters (`src/sboa.mli`) |
| `sboa.cpython` | the implementation linked against a shared libpython |
| `sboa.disabled` | the implementation for executables that must not carry Python: every primitive raises `Sboa.Not_available` |
| `sboa.stdlib` | the standard library of the CPython built against, compiled to bytecode and embedded in the executable (registered at priority 0) |
| `sboa.frozen` | the frozen-module table: the bundle importer (`python/_sboa_importer.py`) and the `encodings` package interpreter start-up needs |
| `sboa.toolchain` | facts about the CPython an executable was built against (version, platform, its `lib-dynload` directory) |

plus the build-time tools `sboa_bundle.py` (Python bundles, the frozen table,
the seam check, the wheel fetch, the runtime files an application ships next
to its executable) and `probe.sh` (C and link flags, the build-time
interpreter). Nothing here is specific to an application.

Supported: Linux (glibc and musl) and macOS on x86_64 and arm64, Windows
x86_64 with the mingw-w64 OCaml port (gcc; MSVC is not supported). OCaml 5.3
or newer.

## Where CPython comes from

sboa never downloads anything. It builds against an installed CPython 3.13,
found by `toolchain/find_python.sh` in this order:

1. `SBOA_PYTHON=<interpreter>` (a path, or a name looked up on `PATH`);
2. `SBOA_PREFIX=<installation prefix>` (absolute): its `bin/python3.13`,
   `bin/python3`, or `python.exe` on Windows;
3. `python3.13`, then `python3`, on `PATH`.

The CPython must be 3.13.x, built with a shared libpython (`--enable-shared`;
always the case on Windows), without free threading and without `Py_DEBUG`;
otherwise the build stops and says how to point at another one. Known to work:
[python-build-standalone](https://github.com/astral-sh/python-build-standalone)
`install_only` archives, Debian/Ubuntu/Fedora packages with their `-dev`
headers, Homebrew's `python@3.13`
(`SBOA_PREFIX=$(brew --prefix python@3.13)/Frameworks/Python.framework/Versions/3.13`),
nixpkgs' `python313`, and the python.org Windows layout (`python.exe`,
`python313.dll`, `include/`, `libs/python313.lib`, `DLLs/`).

`toolchain/describe.py`, run under that interpreter (standard library only:
`sys` and `sysconfig` plus the installation's layout), writes
`toolchain/sboa.config` and the data module of `sboa.toolchain`. The rule
tracks `SBOA_PREFIX`, `SBOA_PYTHON`, `SBOA_MAGIC` and, under `SBOA_PREFIX`,
`bin/python3*` and `lib/libpython3*`; the config records the interpreter's
`sys.version` and libpython's size and mtime, so upgrading the installation
rebuilds everything that depends on it. An installed sboa (opam) records the
paths of the CPython it was built against: after moving or replacing that
CPython, reinstall sboa (`opam reinstall sboa`).

## `sboa.config`

One sexp, a list of `(field value)` pairs; strings except `magic` (an int) and
`runtime_files` (a list of `(source destination)` pairs). Paths are absolute,
with forward slashes; values containing `"`, `)` or a backslash are refused.
Consumers must ignore unknown fields.

| Field | Meaning |
|---|---|
| `version` | the CPython version, e.g. `3.13.16` |
| `platform` | `linux-gnu-x86_64`, `linux-gnu-aarch64`, `linux-musl-x86_64`, `linux-musl-aarch64`, `macos-x86_64`, `macos-arm64` or `windows-x86_64`; the bundle tool evaluates wheel markers for it |
| `magic` | importlib bytecode magic as an int (3571 for 3.13); `SBOA_MAGIC` overrides it |
| `install_fingerprint` | the interpreter's `sys.version` and libpython's size and mtime |
| `prefix` | the installation prefix (`SBOA_PREFIX` as given, so a Homebrew `opt/` path survives upgrades; else `sys.base_prefix`) |
| `incdir`, `stdlib_dir` | `sysconfig`'s `include` and `stdlib` paths |
| `libdir`, `lib_file`, `lib_name` | the library linked by full path (`libpython3.13.so.1.0` or `.so`, `libpython3.13.dylib`, or the import library `libs/python313.lib`), its directory, and `python3.13` / `python313` |
| `libdynload_dir` | the extension-module directory (`<stdlib>/lib-dynload`, `DLLs/` on Windows) |
| `external_libdynload_dir` | `libdynload_dir` when it holds extension modules that ship (empty for python-build-standalone, whose modules are compiled into libpython, and on Windows); compiled into `sboa.toolchain` as the fallback for executables run without their runtime files |
| `python_exe` | the interpreter (build time only) |
| `runtime_subdir` | the directory under `bin/` the runtime files install into: `libs` on Linux and macOS, empty on Windows |
| `runtime_libdynload` | the extension-module directory relative to `bin/<runtime_subdir>/` |
| `runtime_files` | what must sit next to the executable for it to run without the CPython installation: libpython (under its SONAME; left out for macOS framework builds, whose absolute install name is always used) and the `lib-dynload` modules on Linux and macOS; `python313.dll`, `python3.dll`, the `vcruntime` DLLs and the `.pyd`/`.dll` files of `DLLs/` on Windows. Tk and CPython's test modules are left out. |

Executables linked with `sboa.cpython` get two rpaths on Linux and macOS:
`$ORIGIN/libs` / `@loader_path/libs` (where the runtime files ship) and the
absolute `libdir` (so test binaries in `_build` run). Release builds that must
not carry the build machine's path set `SBOA_NO_LIBDIR_RPATH=1` when building
sboa. On Windows the DLLs live next to the `.exe`.

## Using sboa from dune

An installed sboa puts `sboa.config`, `probe.sh` and `sboa_bundle.py` in
`lib/sboa/`; dune rules reference them as
`%{lib:sboa:...}` (which also makes them dependencies). `SBOA_CONFIG`
overrides the config `probe.sh` reads.

Link `sboa` and one implementation, and usually the stdlib and the frozen
importer:

```dune
(executable
 (name main)
 (libraries sboa sboa.cpython sboa.stdlib sboa.frozen))
```

Bundle application code (a Python package directory, or wheels with
`--wheels`) into a module that registers itself when linked:

```dune
(rule
 (targets app_bundle.ml app_bundle.zip app_bundle_blob.c)
 (deps (source_tree mypkg))
 (action
  (run sh %{lib:sboa:probe.sh} --exec-python -I %{lib:sboa:sboa_bundle.py}
   --config %{lib:sboa:sboa.config} bundle --name app
   --package mypkg=mypkg --out . --base app_bundle)))
```

(add `app_bundle` to the executable's `modules` and `app_bundle_blob` to its
`foreign_stubs`, with `(extra_deps app_bundle.zip)`; the module registers the
bundle when it is linked, so reference it, e.g. `let _ = App_bundle.bundle`,
or link with `-linkall`). `probe.sh
--exec-python` runs the interpreter of the config, so no other Python is
needed at build time.

Install the runtime files next to the executables (libpython and extension
modules under `bin/libs/` on Linux and macOS; DLLs next to the `.exe` on
Windows):

```dune
(rule
 (enabled_if (<> %{os_type} Win32))
 (targets (dir runtime_libs))
 (action
  (run sh %{lib:sboa:probe.sh} --exec-python -I %{lib:sboa:sboa_bundle.py}
   --config %{lib:sboa:sboa.config} runtime-files
   --layout libs --out runtime_libs)))

(install
 (enabled_if (<> %{os_type} Win32))
 (package app)
 (section bin)
 (dirs (runtime_libs as libs)))

(rule
 (enabled_if (= %{os_type} Win32))
 (targets (dir runtime_bin))
 (action
  (run sh %{lib:sboa:probe.sh} --exec-python -I %{lib:sboa:sboa_bundle.py}
   --config %{lib:sboa:sboa.config} runtime-files
   --layout bin --out runtime_bin
   --check-install-list %{dep:dune})))

(install
 (enabled_if (= %{os_type} Win32))
 (package app)
 (section bin)
 (files
  (runtime_bin/python313.dll as python313.dll)
  (runtime_bin/python3.dll as python3.dll)
  ; ... one entry per file: dune's install stanza takes no globs over a
  ; directory target; --check-install-list fails the build when the list
  ; and the staged files differ
  (runtime_bin/vcruntime140.dll as vcruntime140.dll)))
```

The directory targets need `(using directory-targets 0.1)` in the consumer's
`dune-project`; an empty directory target is an error, hence the
`enabled_if`s.

Executables built with `-noautolink` must pass the link flags themselves: the
stub archives `-lsboa_cpython_stubs`, `-lsboa_frozen_stubs`,
`-lsboa_stdlib_stubs`, then `lib_file` from the config and the two rpaths
above.

## Building and testing

```bash
export SBOA_PREFIX=/path/to/cpython-3.13
make             # dune build @install
make test        # alcotest suites, importer test, runtime-file staging
make test-tools  # the bundle tool's pytest suite (python3 -m pytest)
make fmt-check   # ocamlformat
```

`opam install . --deps-only --with-test` installs the OCaml dependencies.
sboa builds as an opam package the same way: opam builds have no network,
which is fine since sboa downloads nothing, but the CPython must be installed
beforehand and named on the `opam install` command line, e.g.
`SBOA_PREFIX=$HOME/cpython opam install sboa`.

### devenv

[devenv](https://devenv.sh) provides everything (OCaml, dune, alcotest,
ocamlformat, CPython 3.13 with pytest, `SBOA_PREFIX` set to nixpkgs'
`python313`):

```bash
devenv shell   # or `direnv allow` with the provided .envrc
devenv test    # build, test, test-tools, fmt-check (what CI runs)
```

## Licence

LGPL-2.1-only, see `LICENSE`.
