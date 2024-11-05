let
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs {};
  isMacOS = builtins.match ".*-darwin" pkgs.stdenv.hostPlatform.system != null;
in pkgs.mkShell rec {
  name = "dart";

  buildInputs = with pkgs; [    
    pkgs.dart
    pkgs.openssl
  ] ++ (if !isMacOS then [
    pkgs.openssh
  ] else []);

  shellHook = ''

  '';
}
