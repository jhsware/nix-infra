#!/usr/bin/env nix-shell
#!nix-shell -i /bin/bash

if [[ "release list-identities create-keychain-profile" == *"$1"* ]]; then
  CMD="$1"
fi

for i in "$@"; do
  case $i in
    --env=*)
    ENV="${i#*=}"
    shift
    source $ENV
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
if [ -z "$CMD" ]; then
  dart pub get --enforce-lockfile
  dart compile exe --verbosity error --target-os macos -o bin/nix-infra bin/nix_infra.dart
fi

if [ "$CMD" = "release" ]; then
  # https://scriptingosx.com/2021/07/notarize-a-command-line-tool-with-notarytool/
  checkVar $DEV_CERTIFICATE DEV_CERTIFICATE 

  # [ -f "bin/nix-infra" ] && rm -f bin/nix-infra
  # [ -f "bin/nix-infra.zip" ] && rm -f bin/nix-infra.zip

  # dart pub get --enforce-lockfile
  # dart compile exe --verbosity error --target-os macos -o bin/nix-infra bin/nix_infra.dart

  # Sign the application
  codesign -vvvv --force --prefix=se.urbantalk. -R="notarized" --check-notarization --sign "$DEV_CERTIFICATE" bin/nix-infra

  # Create a ZIP archive for notarization
  zip -r bin/nix-infra.zip bin/nix-infra

  # Submit for notarization
  xcrun notarytool submit bin/nix-infra.zip \
    --apple-id "$DEV_EMAIL" \
    --password "$DEV_PASSWORD" \
    --team-id "$DEV_TEAM_ID" \
    --keychain-profile "$DEV_CREDENTIAL_PROFILE" \
    --wait

  # Staple the notarization ticket
  # https://stackoverflow.com/questions/58817903/how-to-download-notarized-files-from-apple
  xcrun stapler staple bin/nix-infra.zip
  echo "Check if app is notarized"
  spctl --assess ./bin/nix-infra


  # Check notarization status
  echo "Waiting for notarization to complete..."
  echo "Complete by running ./build.sh finish --env=$ENV"
fi

if [ "$CMD" = "list-identities" ]; then
  security find-identity -p basic -v
fi

if [ "$CMD" = "create-keychain-profile" ]; then
  xcrun notarytool store-credentials
  # Profile name: nix-infra.urbantalk.se
  # Path to App Store Connect API private key: [skip]
  # Developer Apple ID: [your-email@exampl.com]
  # Developer Team ID: [see Developer ID Application in list-identities]
fi