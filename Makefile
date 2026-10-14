# Build and test sboa. The CPython 3.13 it builds against is found by
# toolchain/find_python.sh: SBOA_PYTHON=<interpreter>, SBOA_PREFIX=<prefix>,
# or python3.13 / python3 on PATH (see README.md).

DUNE ?= dune
PYTHON ?= python3

.PHONY: all
all:
	$(DUNE) build @install

# The alcotest suites, the importer test and the runtime-file smoke test.
.PHONY: test
test:
	$(DUNE) test --force

# The bundle tool's tests (pytest, under a CPython 3.13).
.PHONY: test-tools
test-tools:
	$(PYTHON) -m pytest tools/tests -q

.PHONY: fmt
fmt:
	$(DUNE) build @fmt --auto-promote

.PHONY: fmt-check
fmt-check:
	$(DUNE) build @fmt

.PHONY: doc
doc:
	$(DUNE) build @doc

.PHONY: clean
clean:
	$(DUNE) clean
