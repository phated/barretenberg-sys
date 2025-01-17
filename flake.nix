{
  description = "Build barretenberg-sys";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.11";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    barretenberg = {
      url = "github:AztecProtocol/barretenberg";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs =
    { self, nixpkgs, crane, flake-utils, rust-overlay, barretenberg, ... }:
    flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          rust-overlay.overlays.default
          barretenberg.overlays.default
        ];
      };

      rustToolchain = pkgs.rust-bin.stable."1.66.0".default;

      craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

      environment = {
        # rust-bindgen needs to know the location of libclang
        LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
      };

      commonArgs = {
        pname = "barretenberg-sys";
        # x-release-please-start-version
        version = "0.0.0";
        # x-release-please-end

        # As per https://discourse.nixos.org/t/gcc11stdenv-and-clang/17734/7 since it seems that aarch64-linux uses
        # gcc9 instead of gcc11 for the C++ stdlib, while all other targets we support provide the correct libstdc++
        stdenv = with pkgs;
          if (stdenv.targetPlatform.isGnu && stdenv.targetPlatform.isAarch64) then
            overrideCC llvmPackages.stdenv (llvmPackages.clang.override { gccForLibs = gcc11.cc; })
          else
            llvmPackages.stdenv;

        src = craneLib.cleanCargoSource ./.;

        doCheck = false;

        nativeBuildInputs = [
          # This provides the pkg-config tool to find barretenberg & other native libraries
          pkgs.pkg-config
          # This provides the `lld` linker to cargo
          pkgs.llvmPackages.bintools
        ];

        buildInputs = [
          pkgs.llvmPackages.openmp
          pkgs.barretenberg
        ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
          # Need libiconv on Darwin. See https://github.com/ipetkov/crane/issues/156
          pkgs.libiconv
        ];
      } // environment;

      # Build *just* the cargo dependencies, so we can reuse all of that work between runs
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      barretenberg-sys = craneLib.buildPackage (commonArgs // {
        inherit cargoArtifacts;
      });
    in
    rec {
      checks = {
        cargo-clippy = craneLib.cargoClippy (commonArgs // {
          inherit cargoArtifacts;

          cargoClippyExtraArgs = "--all-targets -- -D warnings";

          doCheck = true;
        });

        cargo-test = craneLib.cargoTest (commonArgs // {
          inherit cargoArtifacts;

          cargoTestExtraArgs = "--workspace -- --test-threads=1";

          doCheck = true;
        });
      };

      packages.default = barretenberg-sys;

      # llvmPackages should be aligned to selection from libbarretenberg
      # better if we get rid of llvm targets and override them from input
      devShells.default = pkgs.mkShell.override { stdenv = pkgs.llvmPackages.stdenv; } ({
        inputsFrom = builtins.attrValues self.checks;

        buildInputs = packages.default.buildInputs;
        nativeBuildInputs = with pkgs; packages.default.nativeBuildInputs ++ [
          which
          starship
          git
          cargo
          rustc
        ];

        shellHook = ''
          eval "$(starship init bash)"
        '';

      } // environment);
    });
}
