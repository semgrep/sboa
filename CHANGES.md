# Changes

## unreleased

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
