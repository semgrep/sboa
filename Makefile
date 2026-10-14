# Standalone build of the pyembed package. Never invoke dune at the
# monorepo root; this Makefile wraps `dune build --root .` for this package.
#
# The CPython comes from toolchain/ (see toolchain/fetch.sh): the dune rule
# there downloads the python-build-standalone archive pinned in
# toolchain/pbs.json for the OCaml target into toolchain/cache/ (once; set
# PYEMBED_ARCHIVE_DIR to a directory holding the archive to build offline),
# checks its sha256 and writes toolchain/cpython-embed.config in _build.
# PYEMBED_PREFIX=<installed CPython 3.13 prefix> uses that CPython instead
# (no download). See probe.sh for the other overrides.

DUNE ?= dune
DUNE_ARGS ?=

# The CPython toolchain alone (the only step that may need the network).
.PHONY: cpython-embed
cpython-embed:
	$(DUNE) build --root . toolchain/cpython-embed.config $(DUNE_ARGS)

.PHONY: build
build: cpython-embed
	$(DUNE) build --root . @src/all @stdlib/all @frozen/all @test/all $(DUNE_ARGS)

# The tests find the stdlib and the interpreter through probe.sh
# (toolchain/cpython-embed.config; PYEMBED_PREFIX / PYEMBED_PYTHON override).
.PHONY: test
test: cpython-embed
	$(DUNE) build --root . @test/runtest --force $(DUNE_ARGS)

# Library + runtime files (bin/libs/... or the DLLs on Windows).
.PHONY: install
install: cpython-embed
	$(DUNE) build --root . @install $(DUNE_ARGS)

.PHONY: fmt
fmt:
	$(DUNE) build --root . @src/fmt @test/fmt --auto-promote $(DUNE_ARGS) || true

.PHONY: clean
clean:
	$(DUNE) clean --root .
