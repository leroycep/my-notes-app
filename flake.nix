{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.05";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:arqv/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    nix-zig-builder.url = "github:leroycep/nix-zig-builder";
    nix-zig-builder.inputs.nixpkgs.follows = "nixpkgs";

    apple_pie = {
      url = "github:Luukdegram/apple_pie";
      flake = false;
    };
    sqlite-zig = {
      url = "github:leroycep/sqlite-zig/sqlite-v3.37.0";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig-overlay,
    nix-zig-builder,
    apple_pie,
    sqlite-zig,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
      zig = zig-overlay.packages.${system}.master.latest;
      zig-builder = nix-zig-builder.packages.${system}.zig-builder;
      zigPackages = pkgs.lib.concatStringsSep "\n" [
        "apple_pie=${apple_pie}/src/apple_pie.zig"
        "sqlite3=${sqlite-zig}/src/sqlite3.zig"
      ];
      sqlite3Src = "${sqlite-zig}/src/sqlite3.c";
    in rec {
      packages.default = packages.my-notes-app;
      packages.my-notes-app = derivation {
        name = "my-notes-app-server";
        src = ./.;
        inherit system;
        inherit zig zigPackages sqlite3Src;

        builder = "${zig-builder}/bin/zig-builder";
        args = ["install"];
      };

      devShell = pkgs.mkShell {
        name = "my-notes-app-devshell";

        nativeBuildInputs = [
          zig pkgs.entr
        ];

        inherit zigPackages sqlite3Src;
      };

      formatter = pkgs.alejandra;
    });
}
