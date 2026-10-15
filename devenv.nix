{ pkgs, ... }:

let
  # 5.4 (>= 5.3, what sboa supports): the 5.3 set is not in the binary
  # cache for aarch64-darwin, and building it there fails its test suite.
  ocamlPackages = pkgs.ocaml-ng.ocamlPackages_5_4;
  python = pkgs.python313;
in
{
  # OCaml 5.4, dune, alcotest, ocamlformat; CPython 3.13 (nixpkgs builds it
  # with a shared libpython) is what sboa builds against.
  languages.ocaml = {
    enable = true;
    packages = ocamlPackages;
  };

  packages = [
    ocamlPackages.dune_3
    ocamlPackages.alcotest
    ocamlPackages.dune-configurator
    ocamlPackages.findlib
    pkgs.ocamlformat_0_29_0
    (python.withPackages (ps: [ ps.pytest ]))
    pkgs.git
    pkgs.gnumake
  ];

  # The CPython sboa builds against (config/discover.ml; see README.md).
  env.SBOA_PREFIX = "${python}";

  enterShell = ''
    echo "sboa dev shell: OCaml $(ocamlfind ocamlopt -version), dune $(dune --version), $(python3 --version)"
    echo "SBOA_PREFIX=$SBOA_PREFIX"
  '';

  enterTest = ''
    set -e
    make
    make test
    python3 -m pytest tools/tests -q
    make fmt-check
  '';
}
