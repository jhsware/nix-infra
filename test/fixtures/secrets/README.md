# Secret file fixtures

Fixtures for `test/secret_codec_test.dart`, made with real OpenSSL 3 and
LibreSSL by `make_fixtures.sh`:

```sh
sh test/fixtures/secrets/make_fixtures.sh
```
The committed files were made on 2026-11-10 with OpenSSL 3.4.0
(`/opt/homebrew/bin/openssl`) and LibreSSL 3.3.6 (`/usr/bin/openssl`).
Re-running the script makes new salts, so the encrypted files change but the
plaintexts stay the same.


All values are dummy values. The password of every encrypted file is
`fixture-pass-1` (passed as `-pass env:FIXTURE_PASS`). In the table, `\n`
is a newline; a value has no trailing newline unless `\n` is shown at the
end. The test file holds the same values.

| File | Made with | Expected plaintext |
|------|-----------|--------------------|
| `legacy_b64_single` | `printf ... \| openssl enc -pbkdf2 -pass env:FIXTURE_PASS -a` (OpenSSL 3; no cipher, so base64 only, the command nix-infra used) | `dummy-value-1` |
| `legacy_b64_netrc` | same as above (OpenSSL 3) | `machine github.com\nlogin dummy-user\npassword ghp_000000000000000000000000000000000000\n` (`ghp_` + 36 x `0`) |
| `legacy_b64_long` | same as above (LibreSSL); the base64 has a line break | `dummy-long-value-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789-end` |
| `openssl3_pbkdf2` | `openssl enc -aes-256-cbc -pbkdf2 -pass env:FIXTURE_PASS -a` (OpenSSL 3) | `dummy-openssl3-pbkdf2` |
| `openssl3_bytestokey_sha256` | `openssl enc -aes-256-cbc -md sha256 -pass env:FIXTURE_PASS -a` (OpenSSL 3, EVP_BytesToKey) | `dummy-openssl3-sha256` |
| `libressl_pbkdf2` | `openssl enc -aes-256-cbc -pbkdf2 -pass env:FIXTURE_PASS -a` (LibreSSL) | `dummy-libressl-line-1\ndummy-libressl-line-2\n` |
| `openssl_bytestokey_md5` | `openssl enc -aes-256-cbc -md md5 -pass env:FIXTURE_PASS -a` (OpenSSL 3, EVP_BytesToKey) | `dummy-openssl-md5` |
| `openssl_other_cipher` | `openssl enc -aes-128-cbc -pbkdf2 -pass env:FIXTURE_PASS -a` (OpenSSL 3); the codec cannot open it | `dummy-aes128-value` |
