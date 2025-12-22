let
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs {};
  hcloud = pkgs.callPackage nix/hcloud.nix {};

  isMacOS = builtins.match ".*-darwin" pkgs.stdenv.hostPlatform.system != null;
in pkgs.mkShell rec {
  name = "dart";

  buildInputs = with pkgs; [    
    pkgs.dart
    pkgs.openssl
    # pkgs.hcloud
    hcloud
    yq
  ] ++ (if !isMacOS then [
    pkgs.openssh
  ] else []);

  shellHook = ''

  '';
}
