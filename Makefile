# Standalone build of the pyembed package. Never invoke dune at the
# monorepo root; this Makefile wraps `dune build --root .` for this package.
#
# The CPython prefix comes from the cpython-embed opam package
# ($OPAM_SWITCH_PREFIX/lib/cpython-embed/cpython-embed.config) or, for
# development, from PYEMBED_PREFIX (an install tree with include/python3.X,
# lib/libpython3.X.so and lib/python3.X/). See probe.sh.
#
# `build` and `test` only touch src/ and test/: runtime/dune (the runtime-file
# install stanzas) needs cpython-embed installed in the switch, so it is only
# built by `install`.

DUNE ?= dune
DUNE_ARGS ?=

.PHONY: build
build:
	$(DUNE) build --root . @src/all @test/all $(DUNE_ARGS)

# The tests find the stdlib and the interpreter through probe.sh (installed
# cpython-embed by default; PYEMBED_PREFIX / PYEMBED_PYTHON override).
.PHONY: test
test:
	$(DUNE) build --root . @test/runtest --force $(DUNE_ARGS)

# Library + runtime files (bin/libs/...); requires cpython-embed.
.PHONY: install
install:
	$(DUNE) build --root . @install $(DUNE_ARGS)

.PHONY: fmt
fmt:
	$(DUNE) build --root . @src/fmt @test/fmt --auto-promote $(DUNE_ARGS) || true

.PHONY: clean
clean:
	$(DUNE) clean --root .
