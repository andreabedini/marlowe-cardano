{ pkgs
, marlowe-playground
, marlowe-dashboard
, web-ghc
, plutus-pab
, marlowe-pab
, docs
, vmCompileTests
, inputs
}:
let
  inherit (pkgs.stdenv) isDarwin;
  testing = import (pkgs.path + "/nixos/lib/testing-python.nix") { inherit (pkgs) system; };
  makeTest = testing.makeTest;
  tests = pkgs.recurseIntoAttrs {
    marlowe-playground-server = pkgs.callPackage ./vm-tests/marlowe-playground.nix { inherit makeTest marlowe-playground; };
    web-ghc = pkgs.callPackage ./vm-tests/web-ghc.nix { inherit makeTest web-ghc inputs; };
    pab = pkgs.callPackage ./vm-tests/pab.nix { inherit makeTest plutus-pab marlowe-pab marlowe-dashboard; };
    all = pkgs.callPackage ./vm-tests/all.nix { inherit makeTest marlowe-playground marlowe-dashboard web-ghc plutus-pab marlowe-pab docs vmCompileTests inputs; };
  };
in
if isDarwin then { } else tests
