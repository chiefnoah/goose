{
  description = "Goose compiler and language servers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ];
      eachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = eachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          packages = pkgs.callPackage ./nix/packages.nix {
            version = "0-unstable-${self.shortRev or "dirty"}";
          };
        in {
          inherit (packages) default goose goose-lsp goose-lsp-cpp;
        });

      checks = eachSystem (system: {
        inherit (self.packages.${system}) goose goose-lsp goose-lsp-cpp;
      });

      devShells = eachSystem (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              cmake
              git
              ninja
              clang
              python3
            ];
          };
        });
    };
}
