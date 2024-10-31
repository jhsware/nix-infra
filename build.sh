#!/usr/bin/env nix-shell
#!nix-shell -i /bin/bash
dart pub get
dart compile exe --verbosity error --target-os macos -o bin/nix-infra bin/nix_infra.dart