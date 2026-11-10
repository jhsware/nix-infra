#!/bin/sh
# Makes the secret file fixtures for test/secret_codec_test.dart with real
# OpenSSL 3 and LibreSSL. DUMMY VALUES ONLY, dummy password fixture-pass-1.
#
#   sh test/fixtures/secrets/make_fixtures.sh
#
# Override the binaries with OPENSSL3=/path/to/openssl and
# LIBRESSL=/path/to/openssl. The expected plaintext of every file is listed
# in README.md next to this script. Re-running the script makes new salts,
# so the encrypted files change; the plaintexts stay the same.
set -eu

cd "$(dirname "$0")"

FIXTURE_PASS='fixture-pass-1'
export FIXTURE_PASS

if [ -z "${OPENSSL3:-}" ]; then
  for candidate in /opt/homebrew/bin/openssl /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" version | grep -q '^OpenSSL 3'; then
      OPENSSL3="$candidate"
      break
    fi
  done
fi
if [ -z "${OPENSSL3:-}" ]; then
  echo "OpenSSL 3 not found; set OPENSSL3=/path/to/openssl" >&2
  exit 1
fi

LIBRESSL="${LIBRESSL:-/usr/bin/openssl}"
if ! "$LIBRESSL" version | grep -q '^LibreSSL'; then
  echo "LibreSSL not found at $LIBRESSL; set LIBRESSL=/path/to/openssl" >&2
  exit 1
fi

echo "OpenSSL 3: $OPENSSL3 ($("$OPENSSL3" version))"
echo "LibreSSL:  $LIBRESSL ($("$LIBRESSL" version))"

# Legacy nix-infra files: the exact command nix-infra used. Without a cipher,
# openssl enc only encodes base64.
printf 'dummy-value-1' \
  | "$OPENSSL3" enc -pbkdf2 -pass env:FIXTURE_PASS -a > legacy_b64_single
printf 'machine github.com\nlogin dummy-user\npassword ghp_000000000000000000000000000000000000\n' \
  | "$OPENSSL3" enc -pbkdf2 -pass env:FIXTURE_PASS -a > legacy_b64_netrc
printf 'dummy-long-value-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789-end' \
  | "$LIBRESSL" enc -pbkdf2 -pass env:FIXTURE_PASS -a > legacy_b64_long

# OpenSSL files made by hand with a cipher.
printf 'dummy-openssl3-pbkdf2' \
  | "$OPENSSL3" enc -aes-256-cbc -pbkdf2 -pass env:FIXTURE_PASS -a > openssl3_pbkdf2
printf 'dummy-openssl3-sha256' \
  | "$OPENSSL3" enc -aes-256-cbc -md sha256 -pass env:FIXTURE_PASS -a > openssl3_bytestokey_sha256
printf 'dummy-libressl-line-1\ndummy-libressl-line-2\n' \
  | "$LIBRESSL" enc -aes-256-cbc -pbkdf2 -pass env:FIXTURE_PASS -a > libressl_pbkdf2
printf 'dummy-openssl-md5' \
  | "$OPENSSL3" enc -aes-256-cbc -md md5 -pass env:FIXTURE_PASS -a > openssl_bytestokey_md5

# A cipher the codec does not support: must give the "cannot open" error.
printf 'dummy-aes128-value' \
  | "$OPENSSL3" enc -aes-128-cbc -pbkdf2 -pass env:FIXTURE_PASS -a > openssl_other_cipher

# Check: the legacy files decode with plain base64, the others decrypt.
for f in legacy_b64_single legacy_b64_netrc legacy_b64_long; do
  "$OPENSSL3" enc -pbkdf2 -pass env:FIXTURE_PASS -d -a -in "$f" > /dev/null
done
"$OPENSSL3" enc -d -aes-256-cbc -pbkdf2 -pass env:FIXTURE_PASS -a -in openssl3_pbkdf2 > /dev/null
"$OPENSSL3" enc -d -aes-256-cbc -md sha256 -pass env:FIXTURE_PASS -a -in openssl3_bytestokey_sha256 > /dev/null
"$LIBRESSL" enc -d -aes-256-cbc -pbkdf2 -pass env:FIXTURE_PASS -a -in libressl_pbkdf2 > /dev/null
"$OPENSSL3" enc -d -aes-256-cbc -md md5 -pass env:FIXTURE_PASS -a -in openssl_bytestokey_md5 > /dev/null
"$OPENSSL3" enc -d -aes-128-cbc -pbkdf2 -pass env:FIXTURE_PASS -a -in openssl_other_cipher > /dev/null

echo "Fixtures written to $(pwd)"
