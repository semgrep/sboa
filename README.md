# pyembed

Embed CPython in an OCaml executable: a dune virtual library (`pyembed`) with
two implementations, `pyembed.cpython` (the bridge, linked against a shared
libpython) and `pyembed.disabled` (every primitive raises
`Pyembed.Not_available`), plus `pyembed.stdlib` (the CPython standard library
compiled into the executable), `pyembed.frozen` (the frozen importer table) and
the bundle tool `tools/pyembed_bundle.py`. Nothing here is specific to an
application.

## Where CPython comes from: `toolchain/`

| File | Purpose |
|---|---|
| `toolchain/pbs.json` | The manifest: python-build-standalone release, CPython version, archive flavour (`install_only_stripped`) and, per target triple, the archive file name, its sha256 and the platform id written to the config. |
| `toolchain/fetch.sh` | `fetch.sh TARGET MANIFEST OUT_DIR [WORKSPACE_ROOT]`: maps the OCaml target (`%{ocaml-config:target}`) to a manifest entry, downloads the archive into the cache unless a file with the right sha256 is already there, checks the sha256, unpacks it into `OUT_DIR/prefix` and writes `OUT_DIR/cpython-embed.config`. POSIX sh with curl or wget, sha256sum or shasum, tar and sed. |
| `toolchain/dune` | The rule running `fetch.sh` (targets `cpython-embed.config` and the directory `prefix`). Every rule that needs CPython depends on `toolchain/cpython-embed.config`. |
| `toolchain/cache/` | Downloaded archives (git-ignored), reused across builds and `dune clean`. |

`make cpython-embed` builds only this rule (the only step that needs the
network, and only while the archive is not cached). Inputs:

- `PYEMBED_ARCHIVE_DIR=<absolute dir>`: look for (and download into) the
  archive in `<dir>` instead of `toolchain/cache/`. With the archive already
  there the build is offline. A private copy of the archive is sha256-checked
  and unpacked, so a shared directory is safe.
- `PYEMBED_PREFIX=<absolute prefix>`: use an installed CPython of the same
  minor version (shared libpython, no free threading, no `Py_DEBUG`, and a
  libpython whose `Py_GetVersion` is the interpreter's; Homebrew's
  `python@3.13` is
  `$(brew --prefix python@3.13)/Frameworks/Python.framework/Versions/3.13`)
  instead of the archive: nothing is downloaded or copied, the config points
  into the prefix (its logical path, so an `opt/` symlink survives upgrades),
  its `runtime_files` is empty, and executables find libpython through the
  absolute rpath `probe.sh` adds. Such builds keep C extension modules in
  their own `lib-dynload`: it is recorded as `external_libdynload_dir` and
  compiled into `pyembed.toolchain`, whose `libdynload_dir ()` is the value an
  application passes as `Pyembed.Config.libdynload_dir` (the fallback when no
  `libs/python3.X/lib-dynload` sits next to the executable). The rule tracks
  the prefix's `bin/python3*` and `lib/libpython3*`, so an upgraded install
  re-runs it. Unix layouts only. `PYEMBED_PREFIX` is read by `fetch.sh` only;
  everything else reads the config.
- `CPYTHON_EMBED_MAGIC`: bytecode magic number, when the interpreter cannot run
  on the build machine.

Supported targets: x86_64 and aarch64 Linux (glibc and musl), x86_64 and arm64
macOS, x86_64 Windows (mingw OCaml; the archive is the MSVC build, which keeps
its own layout). Moving to another CPython release means editing `pbs.json`
only (and the hard-coded Windows DLL list in `runtime/runtime_files.dune.inc`
if the set of extension modules changes; the Windows build fails, naming the
files, until the list matches what the archive stages).

## `cpython-embed.config`

One sexp, a list of `(field value)` pairs; strings except `magic` (int) and
`runtime_files` (list of `(src dest)`). Paths are absolute, with forward
slashes. Consumers must ignore unknown fields.

| Field | Meaning |
|---|---|
| `version` | CPython version, e.g. `3.13.16` |
| `platform` | `linux-gnu-x86_64`, `linux-gnu-aarch64`, `linux-musl-x86_64`, `linux-musl-aarch64`, `macos-x86_64`, `macos-arm64` or `windows-x86_64`; the bundle tool evaluates wheel markers for it |
| `magic` | importlib bytecode magic as an int (3571 for 3.13) |
| `release`, `archive_sha256` | the python-build-standalone release and the archive's sha256 (downloaded archive only): a manifest change always changes the config, so every rule depending on it re-runs |
| `install_fingerprint` | `PYEMBED_PREFIX` only: the interpreter's `sys.version` and libpython's size and mtime, for the same reason |
| `external_libdynload_dir` | `PYEMBED_PREFIX` only: the external CPython's `lib-dynload` (empty otherwise) |
| `prefix`, `incdir`, `libdir`, `stdlib_dir`, `libdynload_dir`, `python_exe` | paths into the CPython tree |
| `lib_name` | `python3.13` (`python313` on Windows) |
| `lib_file` | the library to link by full path: `libpython3.13.so.1.0`, `libpython3.13.dylib` or `libs/python313.lib` |
| `runtime_subdir` | directory under `bin/` the runtime files install into: `libs` on Linux and macOS, empty on Windows |
| `runtime_libdynload` | extension-module directory relative to `bin/<runtime_subdir>/` (empty when there is none) |
| `runtime_files` | the files that must sit next to the executable: libpython on Linux and macOS; the DLLs and `.pyd` files (without Tk and the test modules) on Windows |

Paths containing `"`, `)` or a backslash are refused by `fetch.sh` (the
readers do not unescape them). `probe.sh` turns the config into compiler and
linker flags (`$PYEMBED_CONFIG` overrides it); `runtime/` installs `runtime_files`
(`bin/libs/` or next to the `.exe`) together with `THIRD_PARTY_NOTICES.txt`.

## Building and testing

```bash
make -C OSS/libs/pyembed build     # libraries, stdlib bundle, frozen table, tests
make -C OSS/libs/pyembed test      # pyembed.disabled, importer and pyembed suites
make -C OSS/libs/pyembed install   # + runtime files (bin/libs/ or the DLLs)
```

The Makefile wraps `dune build --root .`; inside a larger dune workspace the
same rules run from there, with their own `_build` but the same archive cache.
An opam package of pyembed would need the archive as an `extra-source` (pointed
to by `PYEMBED_ARCHIVE_DIR`) or an installed CPython (`PYEMBED_PREFIX`), since
opam builds have no network.
