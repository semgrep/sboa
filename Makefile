# Build and test sboa. The CPython 3.13 it builds against is found by
# `sboa-bundle discover` (SBOA_PYTHON, SBOA_PREFIX, python3.13 on PATH,
# `uv python find 3.13`, python3 if it is 3.13; see README.md).

DUNE ?= dune
PYTHON ?= python3

.PHONY: all
all:
	$(DUNE) build @install

# The alcotest suites, the importer test and the application recipe.
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
