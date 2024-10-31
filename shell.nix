let
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs {};

in pkgs.mkShell rec {
  name = "dart";

  buildInputs = with pkgs; [    
    pkgs.dart
    pkgs.openssl
    pkgs.openssh
  ];

  shellHook = ''

  '';
}
