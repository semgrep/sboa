(lang dune 3.5)

(name sboa)

; runtime/dune uses directory targets (and so do applications' runtime-file
; stanzas, see README.md).

(using directory-targets 0.1)

(generate_opam_files true)

(license "LGPL-2.1-only")

(maintainers "Semgrep Inc. <support@semgrep.com>")

(authors "Semgrep Inc.")

(source
 (github semgrep/sboa))

(package
 (name sboa)
 (synopsis "Embed CPython in an OCaml executable")
 (description
  "sboa (Sand Boa) links a CPython 3.13 shared library into an OCaml program and exposes a small, explicit bridge: a GIL token, owned Python object handles with deferred reference release, fallible typed conversions, OCaml functions and classes exported as builtin Python modules, and exception translation in both directions. sboa.stdlib compiles the standard library into the executable and sboa.frozen holds the frozen bundle importer. sboa never downloads CPython: an installed CPython 3.13 with a shared libpython must be provided at build time (SBOA_PREFIX=<installation prefix>, SBOA_PYTHON=<interpreter>, or python3.13 on PATH).")
 (depends
  (ocaml
   (>= 5.3))
  (alcotest :with-test)))
