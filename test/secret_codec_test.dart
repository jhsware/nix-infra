import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:nix_infra/secret_codec.dart';
import 'package:test/test.dart';

// Error policy (documented in lib/secret_codec.dart):
// - a file that is not a valid secret file, or a v2 header that breaks the
//   reader limits -> SecretFormatUnknown;
// - wrong key, modified file, OpenSSL file that cannot be opened, missing
//   key -> SecretDecryptFailed;
// - v2 key_id or key type differs from the given key -> SecretKeyMismatch.

const _password = 'test-password-not-a-secret';
const _fixturePass = 'fixture-pass-1';
const _fixtureDir = 'test/fixtures/secrets';
const _testIterations = 100000;
final _created = DateTime.utc(2026, 11, 10, 12, 0, 0);

/// Expected plaintext of every fixture (see test/fixtures/secrets/README.md).
const _legacyFixtures = {
  'legacy_b64_single': 'dummy-value-1',
  'legacy_b64_netrc':
      'machine github.com\n'
      'login dummy-user\n'
      'password ghp_000000000000000000000000000000000000\n',
  'legacy_b64_long':
      'dummy-long-value-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789-end',
};

const _opensslFixtures = {
  'openssl3_pbkdf2': 'dummy-openssl3-pbkdf2',
  'openssl3_bytestokey_sha256': 'dummy-openssl3-sha256',
  'libressl_pbkdf2': 'dummy-libressl-line-1\ndummy-libressl-line-2\n',
  'openssl_bytestokey_md5': 'dummy-openssl-md5',
};

const _otherCipherFixture = 'openssl_other_cipher';

Uint8List _fixture(String name) {
  final file = File('$_fixtureDir/$name');
  if (!file.existsSync()) {
    fail('Missing fixture $name: run sh $_fixtureDir/make_fixtures.sh');
  }
  return file.readAsBytesSync();
}

Future<Uint8List> _encrypt(
  String plaintext, {
  required String key,
  String kind = kSecretKindText,
}) => encryptSecretV2(
  plaintext: plaintext,
  key: key,
  kind: kind,
  created: _created,
  iterations: _testIterations,
);

String _text(Uint8List bytes) => utf8.decode(bytes);

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Replaces the header line that starts with `<field>: `.
String _replaceField(String file, String field, String newLine) {
  final lines = file.split('\n');
  final index = lines.indexWhere((l) => l.startsWith('$field: '));
  expect(index, isNonNegative, reason: 'field $field not found');
  lines[index] = newLine;
  return lines.join('\n');
}

String _fieldLine(String file, String field) =>
    file.split('\n').firstWhere((l) => l.startsWith('$field: '));

/// Splits a v2 file into its header (with `---\n`) and decoded payload.
(String, Uint8List) _splitV2(Uint8List file) {
  final text = _text(file);
  final index = text.indexOf('\n---\n') + 5;
  final header = text.substring(0, index);
  final payload = base64.decode(text.substring(index).replaceAll('\n', ''));
  return (header, payload);
}

Uint8List _joinV2(String header, List<int> payload) =>
    _bytes('$header${base64.encode(payload)}\n');

Future<Object> _caught(Future<Object?> Function() action) async {
  try {
    await action();
  } catch (e) {
    return e;
  }
  fail('Expected an exception');
}

void main() {
  group('files key', () {
    test('generateFilesKey has the documented form', () {
      final key = generateFilesKey();
      expect(key, matches(RegExp(r'^nisk1_[A-Za-z0-9_-]{43}$')));
      expect(isGeneratedFilesKey(key), isTrue);
      expect(generateFilesKey(), isNot(key));
    });

    test('isGeneratedFilesKey refuses other text', () {
      final key = generateFilesKey();
      expect(isGeneratedFilesKey(_password), isFalse);
      expect(isGeneratedFilesKey('nisk1_short'), isFalse);
      expect(isGeneratedFilesKey('${key}A'), isFalse);
      expect(isGeneratedFilesKey('nisk2_${key.substring(6)}'), isFalse);
      expect(isGeneratedFilesKey('nisk1_${'+' * 43}'), isFalse);
      // 'B' sets an unused bit in the last character: not canonical.
      expect(isGeneratedFilesKey('nisk1_${'A' * 42}B'), isFalse);
      expect(isGeneratedFilesKey('nisk1_${'A' * 42}E'), isTrue);
    });

    test('filesKeyId is SHA-256(label || key bytes), 8 hex', () {
      final keyBytes = List<int>.generate(32, (i) => i);
      final key = 'nisk1_${base64Url.encode(keyBytes).replaceAll('=', '')}';
      final expected = crypto.sha256
          .convert([...utf8.encode('nix-infra-secret/key-id'), ...keyBytes])
          .toString()
          .substring(0, 8);
      expect(filesKeyId(key), expected);
      expect(filesKeyId(key), matches(RegExp(r'^[0-9a-f]{8}$')));
    });

    test('filesKeyId refuses a password without echoing it', () {
      expect(
        () => filesKeyId(_password),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'toString',
            isNot(contains(_password)),
          ),
        ),
      );
    });
  });

  group('v2 round trip', () {
    const plaintexts = [
      'single line',
      'line 1\nline 2\nline 3',
      'trailing newline\n',
      'åäö – 日本語 – 🔑',
      '',
    ];

    test('with a generated files key', () async {
      final key = generateFilesKey();
      for (final plaintext in plaintexts) {
        final file = await _encrypt(plaintext, key: key);
        final secret = await decryptSecret(file, key: key);
        expect(secret.plaintext, plaintext);
        expect(secret.format, SecretFileFormat.v2);
        expect(secret.kind, kSecretKindText);
        expect(secret.created, _created);
      }
    });

    test('with a password', () async {
      for (final plaintext in plaintexts.take(4)) {
        final file = await _encrypt(
          plaintext,
          key: _password,
          kind: kSecretKindGithubNetrc,
        );
        final secret = await decryptSecret(file, key: _password);
        expect(secret.plaintext, plaintext);
        expect(secret.kind, kSecretKindGithubNetrc);
      }
    });

    test(
      'key_id only for a generated key, iterations only for a password',
      () async {
        final key = generateFilesKey();
        final hkdf = parseSecretV2Header(await _encrypt('x', key: key));
        expect(hkdf.kdf, SecretKdf.hkdfSha256);
        expect(hkdf.keyId, filesKeyId(key));
        expect(hkdf.iterations, isNull);

        final pbkdf2 = parseSecretV2Header(await _encrypt('x', key: _password));
        expect(pbkdf2.kdf, SecretKdf.pbkdf2HmacSha256);
        expect(pbkdf2.keyId, isNull);
        expect(pbkdf2.iterations, _testIterations);
      },
    );

    test(
      'header layout, created in UTC seconds, 64-character body lines',
      () async {
        final key = generateFilesKey();
        final file = _text(
          await encryptSecretV2(
            plaintext: 'x' * 200,
            key: key,
            kind: kSecretKindText,
            created: DateTime.utc(2026, 11, 10, 12, 0, 0, 999),
          ),
        );
        final lines = file.split('\n');
        expect(lines[0], 'nix-infra-secret/v2');
        expect(lines[1], 'kind: text');
        expect(lines[2], 'created: 2026-11-10T12:00:00Z');
        expect(lines[3], 'kdf: hkdf-sha256');
        expect(lines[4], startsWith('salt: '));
        expect(lines[5], 'cipher: aes-256-gcm');
        expect(lines[6], startsWith('nonce: '));
        expect(lines[7], 'key_id: ${filesKeyId(key)}');
        expect(lines[8], '---');
        expect(file, endsWith('\n'));
        final body = lines.sublist(9, lines.length - 1);
        expect(body.length, greaterThan(1));
        for (final line in body.take(body.length - 1)) {
          expect(line.length, 64);
        }
        expect(body.last.length, inInclusiveRange(1, 64));

        final pbkdf2Lines = _text(
          await _encrypt('x', key: _password),
        ).split('\n');
        expect(pbkdf2Lines[3], 'kdf: pbkdf2-hmac-sha256');
        expect(pbkdf2Lines[4], 'iterations: $_testIterations');
        expect(pbkdf2Lines[5], startsWith('salt: '));
      },
    );

    test('new salt and nonce for every encryption', () async {
      final key = generateFilesKey();
      final a = parseSecretV2Header(await _encrypt('same', key: key));
      final b = parseSecretV2Header(await _encrypt('same', key: key));
      expect(a.salt, isNot(b.salt));
      expect(a.nonce, isNot(b.nonce));
    });

    test('a file follows the documented spec (HKDF, AAD = header)', () async {
      final key = generateFilesKey();
      final file = await _encrypt('spec value', key: key);
      final (headerWithDashes, payload) = _splitV2(file);
      final aad = utf8.encode(
        headerWithDashes.substring(0, headerWithDashes.length - 4),
      );
      final header = parseSecretV2Header(file);
      final keyBytes = base64Url.decode('${key.substring(6)}=');
      final fileKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(
            secretKey: SecretKey(keyBytes),
            nonce: header.salt,
            info: utf8.encode('nix-infra-secret/v2'),
          );
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          payload.sublist(0, payload.length - 16),
          nonce: header.nonce,
          mac: Mac(payload.sublist(payload.length - 16)),
        ),
        secretKey: fileKey,
        aad: aad,
      );
      expect(utf8.decode(clear), 'spec value');
    });

    test('a file follows the documented spec (PBKDF2)', () async {
      final file = await _encrypt('spec value', key: _password);
      final (headerWithDashes, payload) = _splitV2(file);
      final header = parseSecretV2Header(file);
      final fileKey =
          await Pbkdf2(
            macAlgorithm: Hmac.sha256(),
            iterations: _testIterations,
            bits: 256,
          ).deriveKey(
            secretKey: SecretKey(utf8.encode(_password)),
            nonce: header.salt,
          );
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          payload.sublist(0, payload.length - 16),
          nonce: header.nonce,
          mac: Mac(payload.sublist(payload.length - 16)),
        ),
        secretKey: fileKey,
        aad: utf8.encode(
          headerWithDashes.substring(0, headerWithDashes.length - 4),
        ),
      );
      expect(utf8.decode(clear), 'spec value');
    });

    test('encryptSecretV2 refuses bad arguments', () async {
      await expectLater(_encrypt('x', key: ''), throwsA(isA<ArgumentError>()));
      await expectLater(
        _encrypt('x', key: 'nisk1_not-a-valid-key'),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        _encrypt('x', key: _password, kind: 'Bad Kind'),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        encryptSecretV2(
          plaintext: 'x',
          key: _password,
          kind: kSecretKindText,
          created: _created,
          iterations: 99999,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('v2 tamper and wrong key', () {
    late String key;
    late Uint8List file;

    setUpAll(() async {
      key = generateFilesKey();
      file = await _encrypt('tamper target value', key: key);
    });

    test('the untouched file decrypts', () async {
      expect(
        (await decryptSecret(file, key: key)).plaintext,
        'tamper target value',
      );
    });

    test('a change of any header byte fails', () async {
      final (header, _) = _splitV2(file);
      final headerLength = header.length - 4;
      for (var i = 0; i < headerLength; i++) {
        final copy = Uint8List.fromList(file);
        copy[i] ^= 0x01;
        await expectLater(
          decryptSecret(copy, key: key),
          throwsA(isA<SecretCodecException>()),
          reason: 'header byte $i',
        );
      }
    });

    test('a change of the ciphertext or the tag fails', () async {
      final (header, payload) = _splitV2(file);
      for (final index in [
        0,
        payload.length - 17,
        payload.length - 16,
        payload.length - 1,
      ]) {
        final copy = Uint8List.fromList(payload);
        copy[index] ^= 0x80;
        await expectLater(
          decryptSecret(_joinV2(header, copy), key: key),
          throwsA(isA<SecretDecryptFailed>()),
          reason: 'payload byte $index',
        );
      }
      // Truncated tag.
      await expectLater(
        decryptSecret(
          _joinV2(header, payload.sublist(0, payload.length - 1)),
          key: key,
        ),
        throwsA(isA<SecretDecryptFailed>()),
      );
    });

    test('a changed kind, salt or nonce fails', () async {
      final other = _text(await _encrypt('tamper target value', key: key));
      final text = _text(file);
      for (final field in ['salt', 'nonce']) {
        final swapped = _replaceField(text, field, _fieldLine(other, field));
        await expectLater(
          decryptSecret(_bytes(swapped), key: key),
          throwsA(isA<SecretDecryptFailed>()),
          reason: field,
        );
      }
      final otherKind = _replaceField(text, 'kind', 'kind: github-netrc');
      await expectLater(
        decryptSecret(_bytes(otherKind), key: key),
        throwsA(isA<SecretDecryptFailed>()),
      );
    });

    test('another generated key gives SecretKeyMismatch', () async {
      await expectLater(
        decryptSecret(file, key: generateFilesKey()),
        throwsA(isA<SecretKeyMismatch>()),
      );
    });

    test('a password on an hkdf file gives SecretKeyMismatch', () async {
      await expectLater(
        decryptSecret(file, key: _password),
        throwsA(isA<SecretKeyMismatch>()),
      );
    });

    test('a forged key_id that matches the key still fails', () async {
      final otherKey = generateFilesKey();
      final forged = _replaceField(
        _text(file),
        'key_id',
        'key_id: ${filesKeyId(otherKey)}',
      );
      await expectLater(
        decryptSecret(_bytes(forged), key: otherKey),
        throwsA(isA<SecretDecryptFailed>()),
      );
    });

    test('no key fails', () async {
      await expectLater(
        decryptSecret(file),
        throwsA(isA<SecretDecryptFailed>()),
      );
    });

    test('a wrong password fails', () async {
      final pbkdf2File = await _encrypt('x', key: _password);
      await expectLater(
        decryptSecret(pbkdf2File, key: 'another-password'),
        throwsA(isA<SecretDecryptFailed>()),
      );
    });

    test(
      'key type is checked before the PBKDF2 derivation',
      () async {
        // 10000000 iterations would take far longer than the timeout.
        final pbkdf2File = _text(await _encrypt('x', key: _password));
        final slow = _replaceField(
          pbkdf2File,
          'iterations',
          'iterations: 10000000',
        );
        await expectLater(
          decryptSecret(_bytes(slow), key: generateFilesKey()),
          throwsA(isA<SecretKeyMismatch>()),
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });

  group('v2 reader limits (SecretFormatUnknown)', () {
    late String pbkdf2File;
    late String hkdfFile;

    setUpAll(() async {
      pbkdf2File = _text(await _encrypt('x', key: _password));
      hkdfFile = _text(await _encrypt('x', key: generateFilesKey()));
    });

    Future<void> expectRefused(String file, {String? reason}) => expectLater(
      decryptSecret(_bytes(file), key: _password),
      throwsA(isA<SecretFormatUnknown>()),
      reason: reason,
    );

    test('iterations out of range', () async {
      await expectRefused(
        _replaceField(pbkdf2File, 'iterations', 'iterations: 99999'),
      );
      await expectRefused(
        _replaceField(pbkdf2File, 'iterations', 'iterations: 10000001'),
      );
      await expectRefused(
        _replaceField(pbkdf2File, 'iterations', 'iterations: 0100000'),
      );
    });

    test('unknown kdf or cipher', () async {
      await expectRefused(_replaceField(pbkdf2File, 'kdf', 'kdf: scrypt'));
      await expectRefused(
        _replaceField(pbkdf2File, 'cipher', 'cipher: aes-128-gcm'),
      );
    });

    test('missing, duplicate and unknown fields', () async {
      for (final field in [
        'kind',
        'created',
        'kdf',
        'iterations',
        'salt',
        'cipher',
        'nonce',
      ]) {
        final lines = pbkdf2File.split('\n')
          ..removeWhere((l) => l.startsWith('$field: '));
        await expectRefused(lines.join('\n'), reason: 'missing $field');
      }
      final hkdfLines = hkdfFile.split('\n')
        ..removeWhere((l) => l.startsWith('key_id: '));
      await expectRefused(hkdfLines.join('\n'), reason: 'missing key_id');

      final duplicate = pbkdf2File.replaceFirst(
        'kind: text\n',
        'kind: text\nkind: text\n',
      );
      await expectRefused(duplicate, reason: 'duplicate');

      final unknown = pbkdf2File.replaceFirst(
        'kind: text\n',
        'kind: text\ncomment: hello\n',
      );
      await expectRefused(unknown, reason: 'unknown field');
    });

    test('kdf-specific fields', () async {
      await expectRefused(
        pbkdf2File.replaceFirst('---\n', 'key_id: 0123abcd\n---\n'),
        reason: 'key_id with pbkdf2',
      );
      await expectRefused(
        hkdfFile.replaceFirst('---\n', 'iterations: 100000\n---\n'),
        reason: 'iterations with hkdf',
      );
      await expectRefused(
        _replaceField(hkdfFile, 'key_id', 'key_id: 0123ABCD'),
        reason: 'uppercase key_id',
      );
    });

    test('salt not 16 bytes, nonce not 12 bytes', () async {
      await expectRefused(
        _replaceField(
          pbkdf2File,
          'salt',
          'salt: ${base64.encode(List.filled(15, 1))}',
        ),
      );
      await expectRefused(
        _replaceField(
          pbkdf2File,
          'nonce',
          'nonce: ${base64.encode(List.filled(16, 1))}',
        ),
      );
      await expectRefused(
        _replaceField(pbkdf2File, 'salt', 'salt: not base64!'),
      );
    });

    test('invalid created', () async {
      await expectRefused(
        _replaceField(pbkdf2File, 'created', 'created: 2026-13-01T00:00:00Z'),
      );
      await expectRefused(
        _replaceField(
          pbkdf2File,
          'created',
          'created: 2026-11-10T12:00:00+01:00',
        ),
      );
    });

    test('header longer than 4 KiB', () async {
      final long = pbkdf2File.replaceFirst(
        'kind: text\n',
        'kind: text\n${'x: y\n' * 1000}',
      );
      final error = await _caught(
        () => decryptSecret(_bytes(long), key: _password),
      );
      expect(error, isA<SecretFormatUnknown>());
      expect(error.toString(), contains('4096'));
    });

    test('no --- line, empty or invalid body', () async {
      await expectRefused(pbkdf2File.replaceFirst('\n---\n', '\n'));
      final headerOnly = pbkdf2File.substring(
        0,
        pbkdf2File.indexOf('\n---\n') + 5,
      );
      await expectRefused(headerOnly, reason: 'empty body');
      await expectRefused('$headerOnly!!!!\n', reason: 'invalid body');
    });

    test('parseSecretV2Header applies the same limits', () {
      expect(
        () => parseSecretV2Header(
          _bytes(_replaceField(pbkdf2File, 'kdf', 'kdf: scrypt')),
        ),
        throwsA(isA<SecretFormatUnknown>()),
      );
      expect(
        () => parseSecretV2Header(_bytes('not a v2 file')),
        throwsA(isA<SecretFormatUnknown>()),
      );
    });
  });

  group('detection', () {
    test('v2', () async {
      expect(
        detectSecretFormat(await _encrypt('x', key: generateFilesKey())),
        SecretFileFormat.v2,
      );
    });

    test('legacy fixtures are legacyBase64', () {
      for (final name in _legacyFixtures.keys) {
        expect(
          detectSecretFormat(_fixture(name)),
          SecretFileFormat.legacyBase64,
          reason: name,
        );
      }
    });

    test('OpenSSL fixtures are opensslSalted', () {
      for (final name in [..._opensslFixtures.keys, _otherCipherFixture]) {
        expect(
          detectSecretFormat(_fixture(name)),
          SecretFileFormat.opensslSalted,
          reason: name,
        );
      }
    });

    test('a file that is not base64 is unknown', () {
      expect(
        detectSecretFormat(_bytes('hello world!\n')),
        SecretFileFormat.unknown,
      );
      expect(
        detectSecretFormat(_bytes('nix-infra-secret/v3\nkind: text\n')),
        SecretFileFormat.unknown,
      );
    });

    test('a random binary file is unknown', () {
      final random = Random(42);
      final bytes = Uint8List.fromList(
        List.generate(256, (_) => random.nextInt(256)),
      );
      expect(detectSecretFormat(bytes), SecretFileFormat.unknown);
    });

    test('base64 that does not decode to UTF-8 is unknown', () async {
      final file = _bytes('${base64.encode([0xff, 0xfe, 0x00, 0x80])}\n');
      expect(detectSecretFormat(file), SecretFileFormat.unknown);
      await expectLater(
        decryptSecret(file, key: _password),
        throwsA(isA<SecretFormatUnknown>()),
      );
    });
  });

  group('legacy fixtures', () {
    test('legacy base64 files decode without a key', () async {
      for (final entry in _legacyFixtures.entries) {
        final secret = await decryptSecret(_fixture(entry.key));
        expect(secret.plaintext, entry.value, reason: entry.key);
        expect(secret.format, SecretFileFormat.legacyBase64);
        expect(secret.kind, isNull);
        expect(secret.created, isNull);
      }
    });

    test('the long fixture has line breaks in its base64', () {
      final lines = _text(_fixture('legacy_b64_long')).trim().split('\n');
      expect(lines.length, greaterThan(1));
    });

    test('OpenSSL files decrypt with the password', () async {
      for (final entry in _opensslFixtures.entries) {
        final secret = await decryptSecret(
          _fixture(entry.key),
          key: _fixturePass,
        );
        expect(secret.plaintext, entry.value, reason: entry.key);
        expect(secret.format, SecretFileFormat.opensslSalted);
      }
    });

    test('an OpenSSL file with a wrong password fails', () async {
      for (final name in _opensslFixtures.keys) {
        await expectLater(
          decryptSecret(_fixture(name), key: 'wrong-password'),
          throwsA(isA<SecretDecryptFailed>()),
          reason: name,
        );
      }
    });

    test('an OpenSSL file without a key fails', () async {
      await expectLater(
        decryptSecret(_fixture('openssl3_pbkdf2')),
        throwsA(isA<SecretDecryptFailed>()),
      );
    });

    test('another OpenSSL cipher gives the "cannot open" error', () async {
      final error = await _caught(
        () => decryptSecret(_fixture(_otherCipherFixture), key: _fixturePass),
      );
      expect(error, isA<SecretDecryptFailed>());
      expect(error.toString(), contains('cannot open'));
      expect(error.toString(), contains('openssl enc -d'));
    });
  });

  group('messages', () {
    test(
      'no exception contains the key, the password or the plaintext',
      () async {
        const plaintext = 'very-recognisable-plaintext';
        final key = generateFilesKey();
        final hkdfFile = await _encrypt(plaintext, key: key);
        final pbkdf2File = await _encrypt(plaintext, key: _password);
        final (header, payload) = _splitV2(hkdfFile);
        final tampered = Uint8List.fromList(payload)..[0] ^= 0x80;
        final otherKey = generateFilesKey();

        final errors = [
          await _caught(() => decryptSecret(hkdfFile, key: otherKey)),
          await _caught(() => decryptSecret(hkdfFile, key: _password)),
          await _caught(() => decryptSecret(pbkdf2File, key: key)),
          await _caught(
            () => decryptSecret(pbkdf2File, key: 'wrong-$_password'),
          ),
          await _caught(
            () => decryptSecret(_joinV2(header, tampered), key: key),
          ),
          await _caught(() => decryptSecret(_bytes('$plaintext!'))),
          await _caught(() => _encrypt(plaintext, key: 'nisk1_$_password')),
          await _caught(() async => filesKeyId(_password)),
        ];
        for (final error in errors) {
          final text = error.toString();
          for (final secret in [
            key,
            otherKey,
            key.substring(6),
            _password,
            plaintext,
            base64.encode(utf8.encode(plaintext)),
          ]) {
            expect(text, isNot(contains(secret)), reason: text);
          }
        }
      },
    );

    test('DecryptedSecret.toString does not contain the plaintext', () async {
      final key = generateFilesKey();
      final secret = await decryptSecret(
        await _encrypt('very-recognisable-plaintext', key: key),
        key: key,
      );
      expect(secret.toString(), isNot(contains('recognisable')));
    });
  });
}
