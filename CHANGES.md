# Changes

## unreleased

- First release as a standalone repository (formerly `pyembed` inside the
  Semgrep monorepo). sboa no longer downloads CPython: it builds against an
  installed CPython 3.13 (`SBOA_PREFIX`, `SBOA_PYTHON`, or `python3.13` on
  `PATH`) and describes it in `sboa.config`, including the runtime files an
  application ships on every platform. `sboa.config`, `probe.sh` and
  `sboa_bundle.py` are installed into `lib/sboa/`.
- `sboa_bundle.py runtime-files` replaces `gen_runtime_files.py` (one tool,
  one reader of `sboa.config`); `fetch-wheels --prune` deletes the wheels the
  lock no longer selects; the unused `--stored` and `--python` flags are gone
  (`--config` names the interpreter).
