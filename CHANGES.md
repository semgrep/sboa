# Changes

## unreleased

- First release as a standalone repository (formerly `pyembed` inside the
  Semgrep monorepo). sboa no longer downloads CPython: it builds against an
  installed CPython 3.13 (`SBOA_PREFIX`, `SBOA_PYTHON`, or `python3.13` on
  `PATH`) and describes it in `sboa.config`, including the runtime files an
  application ships on every platform. `sboa.config`, `probe.sh`,
  `sboa_bundle.py` and `gen_runtime_files.py` are installed into `lib/sboa/`.
