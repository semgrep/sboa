# Changes

## unreleased

- sboa builds curl-style: `config/discover.ml` (dune-configurator) finds the
  CPython 3.13 (`SBOA_PYTHON`, `SBOA_PREFIX`, `python3.13` on `PATH`,
  `uv python find 3.13`, `python3` if it is 3.13) and writes `sboa.config`;
  the opam file declares the CPython 3.13 dev package as a depext where an
  OS has one. `toolchain/find_python.sh`, `toolchain/describe.py` and
  `probe.sh` are gone (with `SBOA_CONFIG` and `SBOA_NO_LIBDIR_RPATH`): the
  tool's new `describe`, `flags` and `exec` subcommands cover them.
- The `sboa` library no longer links libpython (except the import library
  on Windows): the application links the CPython it ships
  (`sboa-bundle flags --link`).
- `sboa.stdlib` and `sboa.frozen` are gone: an application builds its stdlib
  bundle and frozen table against the CPython it ships, with the recipe of
  the README (`freeze --ml` writes the module that links the table). The
  installed `sboa-bundle` executable runs the tool under sboa's CPython;
  `_sboa_importer.py` is installed into `lib/sboa/`.
- `sboa.config` loses the fields nothing read (`magic` and `SBOA_MAGIC`,
  `prefix`, `lib_name`, `libdynload_dir`, `runtime_libdynload`). `freeze`
  output no longer includes `Python.h`.

- First release as a standalone repository (formerly `pyembed` inside the
  Semgrep monorepo). sboa no longer downloads CPython: it builds against an
  installed CPython 3.13 (`SBOA_PREFIX`, `SBOA_PYTHON`, or `python3.13` on
  `PATH`) and describes it in `sboa.config`, including the runtime files an
  application ships on every platform. `sboa.config`, `probe.sh` and
  `sboa_bundle.py` are installed into `lib/sboa/`.
- `sboa` is a plain library linked against libpython: the virtual library,
  `sboa.cpython`, `sboa.disabled` and `Sboa.Not_available` are gone (test
  runners link the real thing; the stub archive is `libsboa_stubs`).
  `sboa.toolchain` and the `external_libdynload_dir` field are gone: the
  bundle importer always looks for extension modules next to the executable.
  `Config.t` keeps `extra_sys_path` and `dev_overrides` only (the program
  name is the executable, `sys.argv` starts as `[executable]`, signals are
  always routed).
- `sboa_bundle.py runtime-files` replaces `gen_runtime_files.py` (one tool,
  one reader of `sboa.config`); `fetch-wheels --prune` deletes the wheels the
  lock no longer selects; the unused `--stored` and `--python` flags are gone
  (`--config` names the interpreter).
