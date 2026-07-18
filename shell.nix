# Dev shell providing kcov for real line coverage (see scripts/coverage.sh).
#
#   nix-shell --run ./scripts/coverage.sh
#
# or drop into the shell and run it manually:
#
#   nix-shell
#   ./scripts/coverage.sh
{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  name = "restsift-coverage";

  buildInputs = [
    pkgs.kcov
  ];
}
