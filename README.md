WARNING: ALL SLOP RIGHT NOW

# sboa

sboa ("Sand Boa"; formerly `pyembed`) embeds CPython 3.13 in an OCaml
executable. It installs:

| What | |
|---|---|
| the `sboa` library | the bridge: GIL tokens, owned object handles with deferred release, fallible conversions, OCaml functions and classes exported as builtin Python modules, exception translation both ways, signal routing, atomic counters (`src/sboa.mli`) |
| the `sboa.ppx` deriver | `[@@deriving sboa]`: converters for OCaml types, records as Python classes (below) |
| the `sboa-bundle` tool | builds what an application ships with the library: the frozen-module table, the embedded standard library, Python bundles of packages or wheels, the runtime files; also describes a CPython installation (`sboa.config`) and prints its compiler and link flags |
| `lib/sboa/sboa.config` | the CPython sboa was built against |
| `lib/sboa/_sboa_importer.py` | the bundle importer, frozen into the application's frozen-module table |

Everything that has to match the CPython an application *ships* (the frozen
table, the stdlib bundle, the runtime files, linking libpython) is built by
the application with the tool, from a three-rule recipe (below).

Supported: Linux (glibc and musl) and macOS on x86_64 and arm64, Windows
x86_64 with the mingw-w64 OCaml port (gcc; MSVC is not supported). OCaml 5.3
or newer.

## Exporting OCaml to Python: a worked example

`[@@deriving sboa]` (the `sboa.ppx` deriver) gives an OCaml type a
converter, `Sboa.Export.def` registers a function with typed parameters
(no argument parsing by hand), and `Sboa.Export.stub` writes the `.pyi`.
This is `test/ppx/demo.ml`, `demo.py` and `demo.pyi`: `make test` runs
them and checks that this section shows them as they are.

```dune
(executable
 (name main)
 (libraries sboa)
 (preprocess (pps sboa.ppx))
 (link_flags (:include link.sexp)))
```

```ocaml
type run_result = { output : string; exit_code : int; log : string }
[@@deriving sboa]
(** What run did. *)

type run_error = { message : string; exit_code : int }
[@@deriving sboa] [@@sboa.exception]
(** Why run failed. *)

exception Run_error of run_error

let run argv verbose =
  match argv with
  | [] -> raise (Run_error { message = "nothing to run"; exit_code = 2 })
  | cmd :: _ ->
      let log = if verbose = Some true then "ran " ^ cmd else "" in
      { output = String.concat " " argv; exit_code = 0; log }

let () =
  let open Sboa.Export in
  def ~module_:"_demo" ~name:"run" ~doc:"Run argv."
    (pos "argv" Sboa.Conv.(list string)
    @-> kw_opt "verbose" Sboa.Conv.bool
    @-> returning run_result_conv)
    run;
  register_exception ~module_:"_demo" run_error_conv (function
    | Run_error e -> Some e
    | _ -> None)
```

In Python (`_demo` is a builtin module of the executable):

```python
import _demo

r = _demo.run(["echo", "hi"], verbose=True)
assert (r.output, r.exit_code, r.log) == ("echo hi", 0, "ran echo")
assert repr(r) == "RunResult(output='echo hi', exit_code=0, log='ran echo')"
assert r == _demo.RunResult("echo hi", 0, log="ran echo")
match r:
    case _demo.RunResult(output, 0, _):
        assert output == "echo hi"

try:
    _demo.run([])
except _demo.RunError as e:
    assert (e.message, e.exit_code) == ("nothing to run", 2)
    assert isinstance(e, _demo.OCamlError)
```

`Sboa.Export.stub "_demo"`, after the `OCamlError` and `Counter` classes
that every export module has:

```python
class RunResult:
    """What run did."""
    output: str
    exit_code: int
    log: str
    def __init__(self, output: str, exit_code: int, log: str) -> None: ...

class RunError(OCamlError):
    """Why run failed."""
    message: str
    exit_code: int
    def __init__(self, message: str, exit_code: int) -> None: ...

def run(argv: list[str], /, *, verbose: bool | None = None) -> RunResult:
    """Run argv."""
```

### What the ppx supports

For `type foo = ...`, `[@@deriving sboa]` defines `foo_conv : foo
Sboa.Conv.t` (`conv` for a type `t`); a type parameter becomes an argument,
`'a box` gives `box_conv : 'a Sboa.Conv.t -> 'a box Sboa.Conv.t`. In an
`.mli` it declares the same value.

| OCaml | Python |
|---|---|
| `int`, `float`, `bool` | `int`, `float` (an `int` is accepted), `bool` |
| `string` | `str` (UTF-8); `bytes` with `[@sboa.bytes]` |
| `bytes` | `bytes` |
| `unit` | `None` |
| `'a option` | `None` or the value |
| `'a list`, `'a array` | `list` (a `tuple` is accepted) |
| tuples of 2 to 4 elements | `tuple` (a `list` is accepted) |
| a record | an instance of its class: attributes named after the fields, a constructor taking them by position or keyword, a `repr` like `RunResult(output='', exit_code=0, log='')`, `__match_args__`; frozen, equality and hash by value. Any object with the attributes converts back. |
| a record with `[@@sboa.exception]` | an exception class, subclass of `OCamlError` (`args` is the field values); with `Export.register_exception` the OCaml exception escapes as it, and is re-raised as itself if it crosses back into OCaml |
| a variant | a constructor without arguments is its name, `"Empty"`; one with arguments a tuple, `("Circle", 1.5)`, `("Rect", p1, p2)` |
| a type variable `'a` | the converter argument |
| `t`, `foo`, `M.t`, `M.foo` (applied to arguments) | `conv`, `foo_conv`, `M.conv`, `M.foo_conv` (applied to their converters), e.g. `Sboa.Counter.conv` |
| `[@sboa.conv e]` on a type or a field | the converter `e`, e.g. `Sboa.Conv.object_` |

A record's class is named after the type in CamelCase (`run_result` ->
`RunResult`; a type `t` after its module), or `[@@sboa.name "Name"]`; its
docstring is the type's doc comment; `[@sboa.name "attr"]` renames a field
or a constructor. The class is created once and registered in the export
modules whose functions mention it (`Export.register_type` for others).
Not supported: recursive types, inline records, polymorphic variants,
GADTs, objects and functions as fields (`Sboa.Conv.func1`... by hand).

Typed exports (`src/sboa.mli`, `Export`): `pos name conv` (positional-only),
`kw name conv` (keyword-only), `kw_opt name conv` (keyword-only, `None` by
default, an `option` argument), `unit` (no argument), chained with `@->`
and ended by `returning conv`; `def ~detach:true` runs the function with
the GIL released. The text signature (`inspect.signature`) and the stub
follow: `run(argv, /, *, verbose=None)`.

The registry lives in the program, so the stub comes from the program: a
mode or a small executable that links the same modules and prints
`Sboa.Export.stub "_demo"`, run by a rule such as `(rule (with-stdout-to
_demo.pyi (run %{exe:print_stub.exe})))` (`sboa-bundle` runs under the
build CPython and never sees the OCaml registry, so it cannot write it).

## Where CPython comes from

sboa never downloads anything. Like `ocurl` with libcurl, it builds against
an installed CPython 3.13, found by `sboa-bundle discover` (which sboa's own
build runs first, and an application can run too) in this order:

1. `SBOA_PYTHON=<interpreter>` (a path, or a name looked up on `PATH`);
2. `SBOA_PREFIX=<installation prefix>` (absolute): its `bin/python3.13`,
   `bin/python3`, or `python.exe` on Windows;
3. `python3.13` on `PATH`;
4. `uv python find --system 3.13`, when `uv` is on `PATH`;
5. `python3` on `PATH`, if it is 3.13.

An interpreter named by 1 or 2 must do; 3 to 5 are tried in turn. It must be
CPython 3.13.x with a shared libpython (`--enable-shared`, a distribution's
`-dev`/`-devel` package, a framework build on macOS; always the case on
Windows), without free threading and without `Py_DEBUG`; each candidate
runs `sboa-bundle describe`, which checks it and writes `sboa.config`.
Otherwise the build stops, says why for each candidate and lists the five
ways to point at another one. `discover [--out sboa.config] [--cflags F]
[--link F] [--clibs F]` also writes the flag files of `flags` (below).

On a machine without one, either install the distribution's package (the
opam file declares it as a depext where the OS packages a 3.13:
`python3.13-dev` on Debian 13+ and Ubuntu 25.04+, `python3-dev` on Alpine,
`python3.13-devel` on Fedora, `python` on Arch, Homebrew's `python@3.13`), or
run

```bash
uv python install 3.13
```

Known to work besides: python-build-standalone (what uv installs), nixpkgs'
`python313`, Homebrew's framework build
(`SBOA_PREFIX=$(brew --prefix python@3.13)/Frameworks/Python.framework/Versions/3.13`),
the python.org Windows layout (`python.exe`, `python313.dll`, `include/`,
`libs/python313.lib`, `DLLs/`).

An installed sboa records the paths of the CPython it was built against:
after moving or removing that CPython, reinstall sboa (`opam reinstall
sboa`). Inside a dune workspace the discovery re-runs when `SBOA_PYTHON`,
`SBOA_PREFIX` or `UV_PYTHON_INSTALL_DIR` change or the installation under
`SBOA_PREFIX` is upgraded; after other changes (`PATH`), `dune clean`.

## `sboa.config`

Written by `sboa-bundle describe` (which `discover` runs). One sexp, a list
of `(field value)` pairs, UTF-8 with LF line ends; strings except
`runtime_files` (a list of `(source destination)` pairs). Paths are
absolute, with forward slashes; values containing `"`, `)`, a backslash or
a control character are refused. Readers must ignore unknown fields.

| Field | Meaning |
|---|---|
| `version` | the CPython version, e.g. `3.13.16` |
| `platform` | `linux-gnu-x86_64`, `linux-gnu-aarch64`, `linux-musl-x86_64`, `linux-musl-aarch64`, `macos-x86_64`, `macos-arm64` or `windows-x86_64`; the tool evaluates wheel markers for it |
| `install_fingerprint` | the interpreter's `sys.version` and libpython's size and mtime: an upgraded installation changes the config, and so rebuilds everything that depends on it |
| `incdir`, `stdlib_dir` | `sysconfig`'s `include` and `stdlib` paths |
| `libdir`, `lib_file` | the library linked by full path (`libpython3.13.so.1.0` or `.so`, `libpython3.13.dylib` or the framework's `Python`, or the import library `libs/python313.lib`) and its directory |
| `python_exe` | the interpreter (build time only: the tool runs under it) |
| `runtime_subdir` | the directory under `bin/` the runtime files install into: `libs` on Linux and macOS, empty on Windows |
| `runtime_files` | what must sit next to the executable for it to run without the CPython installation: libpython (under its SONAME; left out for macOS framework builds, whose absolute install name is always used) and the `lib-dynload` modules on Linux and macOS; `python313.dll`, `python3.dll`, the `vcruntime` DLLs and the `.pyd`/`.dll` files of `DLLs/` on Windows. Tk and CPython's test modules are left out. |

## Using sboa from dune

Dune rules run the tool as `%{bin:sboa-bundle}`. Every subcommand but
`discover` runs `sboa_bundle.py` under the `python_exe` of `--config C`
(bytecode is only valid for the interpreter that compiled it), or, without
`--config`, of the installed `sboa.config`: a build needs no other Python.

| Subcommand | |
|---|---|
| `discover [--out F] [--cflags F] [--link F] [--clibs F]` | find a CPython 3.13 as above and write its config (and flag files) |
| `describe --prefix P --out F` | write the config of the installation at P (`--python EXE` for a given interpreter) |
| `flags --config C --cflags\|--link\|--clibs` | print a dune `(:include)` sexp: `-I` of the headers; libpython by full path and the rpaths for an executable's `link_flags` (`-cclib`/`-ccopt`); the `sboa` library's `c_library_flags` (empty except the import library on Windows) |
| `exec --config C -- ARGS...` | run C's interpreter |
| `freeze`, `stdlib`, `bundle`, `embed`, `runtime-files`, `check-seam`, `fetch-wheels` | the recipe below; `sboa-bundle --help` and `sboa-bundle CMD --help` |

### The config

An application ships some CPython 3.13 and builds everything below from its
config. Either ship the one sboa was built against:

```dune
(rule
 (copy %{lib:sboa:sboa.config} cpython.config))
```

or find one the way sboa does (the config records absolute paths and depends
on the environment: no sandbox):

```dune
(rule
 (targets cpython.config)
 (deps (env_var SBOA_PYTHON) (env_var SBOA_PREFIX) (sandbox none))
 (action (run %{bin:sboa-bundle} discover --out %{targets})))
```

or describe the installation it ships, e.g. a directory target `cpython`
that a rule fills with `uv python install --install-dir`:

```dune
(rule
 (targets cpython.config)
 (deps (sandbox none))
 (action
  (run %{bin:sboa-bundle} describe --prefix %{dep:cpython} --out %{targets})))
```

The C stubs of sboa are compiled against sboa's CPython: the embedding ABI
is stable across the patch releases of 3.13, and the bytecode magic of the
frozen table and of every bundle is checked at start-up.

### The recipe

1. The frozen-module table: the bundle importer and the `encodings` package
   interpreter start-up needs. `--ml` adds a module whose initialization
   links the table; with `-linkall`, every executable linking the library
   gets it (instead of sboa's empty default).

```dune
(rule
 (targets frozen.c frozen.ml)
 (action
  (run %{bin:sboa-bundle} --config %{dep:cpython.config} freeze
   --module _sboa_importer=%{lib:sboa:_sboa_importer.py}
   --stdlib-package encodings --out frozen.c --ml frozen.ml)))

(library
 (name app_frozen)
 (modules frozen)
 (libraries sboa)
 (library_flags -linkall)
 (foreign_stubs (language c) (names frozen)))
```

2. The standard library, compiled to bytecode and embedded in the executable
   (`.incbin`), registered at priority 0: searched before every application
   bundle, so third-party code cannot shadow a stdlib module.

```dune
(rule
 (targets stdlib_bundle.zip stdlib_bundle_blob.c stdlib_bundle.ml stdlib_bundle.mli)
 (action
  (run %{bin:sboa-bundle} --config %{dep:cpython.config} stdlib
   --priority 0 --target-system %{system} --mli --out .)))

(library
 (name app_stdlib)
 (modules stdlib_bundle)
 (libraries sboa)
 (library_flags -linkall)
 (foreign_stubs
  (language c)
  (names stdlib_bundle_blob)
  (extra_deps stdlib_bundle.zip)))
```

3. The runtime files, installed next to the executables (libpython and
   extension modules under `bin/libs/` on Linux and macOS; DLLs next to the
   `.exe` on Windows). An empty directory target is an error, hence the
   `enabled_if`s; the directory targets need `(using directory-targets 0.1)`
   in the `dune-project`.

```dune
(rule
 (enabled_if (<> %{os_type} Win32))
 (targets (dir runtime_libs))
 (action
  (run %{bin:sboa-bundle} --config %{dep:cpython.config} runtime-files
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
  (run %{bin:sboa-bundle} --config %{dep:cpython.config} runtime-files
   --layout bin --out runtime_bin --check-install-list %{dep:dune})))

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

### Linking libpython

The `sboa` library carries no libpython link flags (on Windows only the
import library, which binds by DLL name): the executable links the CPython
it ships.

```dune
(rule
 (with-stdout-to link.sexp
  (run %{bin:sboa-bundle} --config %{dep:cpython.config} flags --link)))

(executable
 (name main)
 (libraries sboa app_frozen app_stdlib)
 (link_flags (:include link.sexp)))
```

`flags --link` links `lib_file` by full path (the executable records its
SONAME or install name) and adds two rpaths on Linux and macOS:
`$ORIGIN/libs` / `@loader_path/libs`, where the runtime files ship, and the
absolute `libdir`, so that binaries in `_build` run. Release builds that
must not carry the build machine's path write their own flags (the
`lib_file` and the first rpath). On Windows the DLLs live next to the
`.exe`.

### Application bundles

Python packages (or wheels, `--wheels`; `fetch-wheels` downloads the pure
wheels of a `uv.lock`) become a module that registers itself when linked:

```dune
(rule
 (targets app_bundle.ml app_bundle.zip app_bundle_blob.c)
 (deps (source_tree mypkg))
 (action
  (run %{bin:sboa-bundle} --config %{dep:cpython.config} bundle --name app
   --package mypkg=mypkg --out . --base app_bundle)))
```

(add `app_bundle` to the executable's `modules` and `app_bundle_blob` to its
`foreign_stubs`, with `(extra_deps app_bundle.zip)`; reference the module,
e.g. `let _ = App_bundle.bundle`, or link with `-linkall`).

`test/recipe/` is this recipe, built and run (as installed: `bin/` plus
`bin/libs/`) by `make test`.

## Building and testing

```bash
make             # dune build @install
make test        # alcotest suites (and the worked example), importer test, the recipe
make test-tools  # the tool's pytest suite (python3 -m pytest)
make fmt-check   # ocamlformat
```

`opam install . --deps-only --with-test` installs the OCaml dependencies
(and, where the OS packages one, CPython 3.13). opam builds have no network,
which is fine since sboa downloads nothing; the CPython is found as above,
e.g. `uv python install 3.13 && opam install sboa`.

### devenv

[devenv](https://devenv.sh) provides everything (OCaml, dune, ppxlib,
alcotest, ocamlformat, CPython 3.13 with pytest, `SBOA_PREFIX` set to nixpkgs'
`python313`):

```bash
devenv shell   # or `direnv allow` with the provided .envrc
devenv test    # build, test, test-tools, fmt-check (what CI runs)
```

## Licence

LGPL-2.1-only, see `LICENSE`.
