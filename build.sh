#!/usr/bin/env nix-shell
#!nix-shell -i bash
set -e

if [[ "build-macos build-linux release-macos list-identities create-keychain-profile notarytool-log" == *"$1"* ]]; then
  CMD="$1"
fi

for i in "$@"; do
  case $i in
    --env=*)
    ENV="${i#*=}"
    shift
    source $ENV
    ;;
    --log-id=*)
    LOG_ID="${i#*=}"
    shift
    ;;
    *)
    REST="$@"
    ;;
  esac
done

checkVar() {
  if [ -z "$1" ]; then
    echo "Missing env-var $2" >&2
    exit 1
  fi
}

# Main body
if [ "$CMD" = "build-macos" ]; then
  dart pub get --enforce-lockfile
  dart compile exe --verbosity error --target-os macos -o bin/nix-infra bin/nix_infra.dart
  dart compile exe --verbosity error --target-os macos -o bin/nix-infra-machine-mcp bin/nix_infra_machine_mcp.dart
  dart compile exe --verbosity error --target-os macos -o bin/nix-infra-cluster-mcp bin/nix_infra_cluster_mcp.dart
  dart compile exe --verbosity error --target-os macos -o bin/nix-infra-dev-mcp bin/nix_infra_dev_mcp.dart
fi

if [ "$CMD" = "build-linux" ]; then
  # nix-shell -p podman qemu edk2
  [ -d "$(pwd)/bin/linux" ] && rm -rf "$(pwd)/bin/linux"
  mkdir -p "$(pwd)/bin/linux"
  ./build-linux.sh "$(pwd)/bin/linux"
  exit 0
fi

if [ "$CMD" = "release-macos" ]; then
  # https://scriptingosx.com/2021/07/notarize-a-command-line-tool-with-notarytool/
  checkVar "$DEV_CERTIFICATE" DEV_CERTIFICATE 
  checkVar "$DEV_APP_CERTIFICATE" DEV_APP_CERTIFICATE
  checkVar "$DEV_IDENTIFIER" DEV_IDENTIFIER
  checkVar "$DEV_CREDENTIAL_PROFILE" DEV_CREDENTIAL_PROFILE

  # Check if xcode-select is pointing to Nix
  XCODE_PATH=$(which xcode-select)
  if [ $? -eq 0 ] && echo "$XCODE_PATH" | grep -q '/nix/store'; then
    echo "ERROR: xcode-select is pointing to a Nix path: $XCODE_PATH" >&2
    echo "" >&2
    echo "The notarytool requires native macOS SDKs, not Nix versions." >&2
    echo "Please exit your nix-shell and run this script in a normal terminal." >&2
    echo "" >&2
    echo "If you're not in a nix-shell, reset xcode-select with:" >&2
    echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
    echo "  # or" >&2
    echo "  sudo xcode-select --switch /Library/Developer/CommandLineTools" >&2
    exit 1
  fi

  binaries="nix-infra nix-infra-machine-mcp nix-infra-cluster-mcp nix-infra-dev-mcp"
  
  echo "******************************************************"
  echo "Releasing: $binaries"
  echo "******************************************************"
  echo

  # Check that binaries exist
  for target in $binaries; do
    if [ ! -f "bin/$target" ]; then
      echo "You have not yet built $target, please run '$0 build-macos' and retry the release." >&2
      exit 1
    fi
  done

  PKG="bin/nix-infra-installer"
  VERSION=$(grep -E '^version: ' pubspec.yaml | awk '{print $2}')

  # Clean up previous build artifacts
  [ -d "$PKG" ] && rm -rf "$PKG"
  [ -f "$PKG.pkg" ] && rm -f "$PKG.pkg"

  mkdir "$PKG"

  # Sign and stage all binaries
  for target in $binaries; do
    cp "bin/$target" "$PKG/"

    # Sign the application with hardened runtime
    # https://lessons.livecode.com/m/4071/l/1122100-codesigning-and-notarizing-your-lc-standalone-for-distribution-outside-the-mac-appstore
    codesign --deep --force --verify --verbose --timestamp --options runtime \
      --sign "$DEV_APP_CERTIFICATE" \
      --entitlements "bin/entitlements.plist" \
      "$PKG/$target"
  done

  # Create single package containing all binaries
  pkgbuild --root "$PKG" \
        --identifier "$DEV_IDENTIFIER" \
        --version "$VERSION" \
        --install-location "/usr/local/bin" \
        --sign "$DEV_CERTIFICATE" \
        "$PKG.pkg"

  # Notarize
  xcrun notarytool submit "$PKG.pkg" \
    --keychain-profile "$DEV_CREDENTIAL_PROFILE" \
    --wait

  # Staple the notarization ticket
  xcrun stapler staple "$PKG.pkg"
fi

if [ "$CMD" = "list-identities" ]; then
  security find-identity -p basic -v
fi

if [ "$CMD" = "notarytool-log" ]; then
  xcrun notarytool log "$LOG_ID" --keychain-profile "$DEV_CREDENTIAL_PROFILE"
fi

if [ "$CMD" = "create-keychain-profile" ]; then
  xcrun notarytool store-credentials
  # Profile name: nix-infra.urbantalk.se
  # Path to App Store Connect API private key: [skip]
  # Developer Apple ID: [your-email@exampl.com]
  # Developer Team ID: [see Developer ID Application in list-identities]
fi