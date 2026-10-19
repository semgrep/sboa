(lang dune 3.5)

(name sboa)

; test/recipe uses directory targets (and so do applications' runtime-file
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
  "sboa (Sand Boa) links a CPython 3.13 shared library into an OCaml program and exposes a small, explicit bridge: a GIL token, owned Python object handles with deferred reference release, fallible typed conversions, OCaml functions and classes exported as builtin Python modules, exception translation in both directions, and a deriver (sboa.ppx) for converters and typed exports. The sboa-bundle tool builds what an application ships with it: the frozen-module table, the embedded standard library and application bundles, the runtime files. sboa never downloads CPython: it finds an installed CPython 3.13 with a shared libpython at build time (SBOA_PYTHON, SBOA_PREFIX, python3.13 on PATH, `uv python find 3.13`, or a python3 that is 3.13).")
 (depends
  (ocaml
   (>= 5.3))
  (ppxlib
   (>= 0.36))
  (alcotest :with-test)))
