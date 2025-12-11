#!/usr/bin/env nix-shell
#!nix-shell -i bash
set -e

if [[ "build-macos build-linux release list-identities create-keychain-profile notarytool-log" == *"$1"* ]]; then
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
    echo "Missing env-var $2"
    exit 1
  fi
}

# Main body
if [ "$CMD" = "build-macos" ]; then
  dart pub get --enforce-lockfile
  dart compile exe --verbosity error --target-os macos -o bin/nix-infra bin/nix_infra.dart
  dart compile exe --verbosity error --target-os macos -o bin/nix-infra-machine-mcp bin/nix_infra_machine_mcp.dart
  dart compile exe --verbosity error --target-os macos -o bin/nix-infra-cluster-mcp bin/nix_infra_cluster_mcp.dart
fi

if [ "$CMD" = "build-linux" ]; then
  # nix-shell -p podman qemu edk2
  [ -d "$(pwd)/bin/linux" ] && rm -rf "$(pwd)/bin/linux"
  mkdir -p "$(pwd)/bin/linux"
  ./build-linux.sh "$(pwd)/bin/linux"
  exit 0
fi

if [ "$CMD" = "release" ]; then
  # https://scriptingosx.com/2021/07/notarize-a-command-line-tool-with-notarytool/
  checkVar "$DEV_CERTIFICATE" DEV_CERTIFICATE 
  checkVar "$DEV_APP_CERTIFICATE" DEV_APP_CERTIFICATE
  checkVar "$DEV_IDENTIFIER" DEV_IDENTIFIER
  checkVar "$DEV_CREDENTIAL_PROFILE" DEV_CREDENTIAL_PROFILE

  binaries="nix-infra nix-infra-machine-mcp nix-infra-cluster-mcp"
  
  echo "******************************************************"
  echo "Releasing: $binaries"
  echo "******************************************************"
  echo

  for target in $binaries; do
    PKG="bin/$target-installer"
    VERSION=$(grep -E '^version: ' pubspec.yaml | awk '{print $2}')

    [ -f "bin/$target" ] && rm -f "bin/$target"
    [ -f "bin/$target.zip" ] && rm -f "bin/$target.zip"
    [ -d "bin/$target-installer" ] && rm -rf "bin/$target-installer"

    mkdir "$PKG"
    cp "bin/$target" "$PKG/"

    # Sign the application with hardened runtime
    # https://lessons.livecode.com/m/4071/l/1122100-codesigning-and-notarizing-your-lc-standalone-for-distribution-outside-the-mac-appstore
    codesign --deep --force --verify --verbose --timestamp --options runtime \
      --sign "$DEV_APP_CERTIFICATE" \
      --entitlements "bin/entitlements.plist" \
      "$PKG/$target"

    # Create package
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
    # https://stackoverflow.com/questions/58817903/how-to-download-notarized-files-from-apple
    xcrun stapler staple "$PKG.pkg"
  done
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