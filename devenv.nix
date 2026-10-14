{ pkgs, ... }:

let
  ocamlPackages = pkgs.ocaml-ng.ocamlPackages_5_3;
  python = pkgs.python313;
in
{
  # OCaml >= 5.3, dune, alcotest, ocamlformat; CPython 3.13 (nixpkgs builds it
  # with a shared libpython) is what sboa builds against.
  languages.ocaml = {
    enable = true;
    packages = ocamlPackages;
  };

  packages = [
    ocamlPackages.dune_3
    ocamlPackages.alcotest
    ocamlPackages.findlib
    pkgs.ocamlformat_0_29_0
    (python.withPackages (ps: [ ps.pytest ]))
    pkgs.git
    pkgs.gnumake
  ];

  # The CPython for toolchain/find_python.sh (see README.md).
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
