{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      package = import ./default.nix { inherit pkgs; };
    in
    {
      packages.${system} = {
        default = package;
        whisper-dict = package;
      };

      apps.${system}.default = {
        type = "app";
        program = "${package}/bin/whisper-dict";
        meta = package.meta;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.zig ] ++ package.runtimeDeps;
      };

      homeManagerModules.whisper-dict = import ./nix/home-manager-module.nix { inherit self; };
      homeManagerModules.default = self.homeManagerModules.whisper-dict;
    };
}
