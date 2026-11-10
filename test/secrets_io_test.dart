import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nix_infra/cluster_node.dart';
import 'package:nix_infra/secret_codec.dart';
import 'package:nix_infra/secrets.dart';
import 'package:process_run/shell.dart';
import 'package:test/test.dart';

const _fixtureDir = 'test/fixtures/secrets';
const _fixturePass = 'fixture-pass-1';
const _password = 'test-password-not-a-secret';

const _netrcValue = 'machine api.github.com\n'
    'login x-access-token\n'
    'password ghp_000000000000000000000000000000000000\n';

/// The values that `openssl enc -d` + process_run `outText` returned for
/// the fixtures (see test/fixtures/secrets/README.md): lines joined with
/// '\n', no final line break.
const _legacyFixturesOutText = {
  'legacy_b64_single': 'dummy-value-1',
  'legacy_b64_netrc': 'machine github.com\n'
      'login dummy-user\n'
      'password ghp_000000000000000000000000000000000000',
  'legacy_b64_long':
      'dummy-long-value-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789-end',
};

/// Legacy base64 files made in the test, with the outText value.
const _legacyMadeOutText = {
  'legacy_crlf': ('crlf-line-1\r\ncrlf-line-2\r\n', 'crlf-line-1\ncrlf-line-2'),
  'legacy_trailing_newline': ('one-line-value\n', 'one-line-value'),
  'legacy_blank_lines': ('a\n\nb\n\n', 'a\n\nb\n'),
};

/// Writes [value] as `openssl enc -a` would: base64 in lines of 64
/// characters, each followed by a newline.
void _writeLegacyBase64(File file, String value) {
  final encoded = base64.encode(utf8.encode(value));
  final out = StringBuffer();
  for (var i = 0; i < encoded.length; i += 64) {
    final end = i + 64 < encoded.length ? i + 64 : encoded.length;
    out.write('${encoded.substring(i, end)}\n');
  }
  file.writeAsStringSync(out.toString());
}

int _mode(String path) => FileStat.statSync(path).mode & 0x1ff;

bool _hasOpenssl() {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  late Directory project;
  late Directory secretsDir;
  late List<String> warnings;
  late void Function(String) originalSink;

  setUp(() {
    project = Directory.systemTemp.createTempSync('secrets_io_test_');
    secretsDir = Directory('${project.path}/secrets');
    warnings = [];
    originalSink = secretWarningSink;
    secretWarningSink = warnings.add;
    resetLegacySecretWarning();
  });

  tearDown(() {
    secretWarningSink = originalSink;
    resetLegacySecretWarning();
    // Files are mode 400; the folder is writable so they can be deleted.
    project.deleteSync(recursive: true);
  });

  void copyFixture(String name, {String? as}) {
    secretsDir.createSync(recursive: true);
    File('$_fixtureDir/$name').copySync('${secretsDir.path}/${as ?? name}');
  }

  List<String> tmpFiles() => secretsDir
      .listSync()
      .map((e) => e.uri.pathSegments.last)
      .where((n) => n.startsWith('.tmp-'))
      .toList();

  group('saveSecret', () {
    test('writes a v2 file with a generated key and reads it back', () async {
      final key = generateFilesKey();
      await saveSecret(project, key, 'db-password', 'value-1');

      final file = File('${secretsDir.path}/db-password');
      final bytes = file.readAsBytesSync();
      expect(utf8.decode(bytes), startsWith('$kSecretV2Magic\n'));
      expect(parseSecretV2Header(bytes).kdf, SecretKdf.hkdfSha256);
      expect(parseSecretV2Header(bytes).kind, kSecretKindText);
      expect(_mode(file.path), 0x100, reason: 'file mode 400');
      expect(_mode(secretsDir.path), 0x1c0, reason: 'folder mode 700');
      expect(tmpFiles(), isEmpty);

      expect(await readSecret(project, key, 'db-password'), 'value-1');
    });

    test('writes a v2 file with a password and reads it back', () async {
      await saveSecret(project, _password, 'api-key', 'value-2');

      final bytes = File('${secretsDir.path}/api-key').readAsBytesSync();
      expect(utf8.decode(bytes), startsWith('$kSecretV2Magic\n'));
      expect(parseSecretV2Header(bytes).kdf, SecretKdf.pbkdf2HmacSha256);
      expect(await readSecret(project, _password, 'api-key'), 'value-2');
      expect(tmpFiles(), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('refuses an existing name unless overwrite is true', () async {
      final key = generateFilesKey();
      await saveSecret(project, key, 'name-1', 'first');

      await expectLater(saveSecret(project, key, 'name-1', 'second'),
          throwsA(isA<SecretExists>()));
      expect(await readSecret(project, key, 'name-1'), 'first');
      expect(tmpFiles(), isEmpty);

      await saveSecret(project, key, 'name-1', 'second', overwrite: true);
      expect(await readSecret(project, key, 'name-1'), 'second');
      expect(_mode('${secretsDir.path}/name-1'), 0x100);
      expect(tmpFiles(), isEmpty);
    });

    test('stores a GitHub netrc value with kind github-netrc', () async {
      final key = generateFilesKey();
      await saveSecret(project, key, 'github-netrc', _netrcValue);
      await saveSecret(project, key, 'other-netrc',
          'machine github.com\nlogin someone\npassword x\n');

      Uint8List bytes(String name) =>
          File('${secretsDir.path}/$name').readAsBytesSync();
      expect(parseSecretV2Header(bytes('github-netrc')).kind,
          kSecretKindGithubNetrc);
      expect(parseSecretV2Header(bytes('other-netrc')).kind, kSecretKindText);
    });

    test('refuses names with "/" or a leading "."', () async {
      final key = generateFilesKey();
      await expectLater(
          saveSecret(project, key, '../x', 'v'), throwsArgumentError);
      await expectLater(
          saveSecret(project, key, '.hidden', 'v'), throwsArgumentError);
      await expectLater(readSecret(project, key, 'a/b'), throwsArgumentError);
    });
  });

  group('detectSecretKind', () {
    test('only a single api.github.com x-access-token entry is github-netrc',
        () {
      expect(detectSecretKind(_netrcValue), kSecretKindGithubNetrc);
      expect(
          detectSecretKind(
              'machine api.github.com login x-access-token password p'),
          kSecretKindGithubNetrc);
      expect(detectSecretKind('machine api.github.com login other password p'),
          kSecretKindText);
      expect(detectSecretKind('machine api.github.com login x-access-token'),
          kSecretKindText);
      expect(detectSecretKind('plain value'), kSecretKindText);
    });
  });

  group('readSecret returns the outText value', () {
    test('legacy base64 fixtures', () async {
      for (final entry in _legacyFixturesOutText.entries) {
        copyFixture(entry.key);
        expect(await readSecret(project, _fixturePass, entry.key), entry.value,
            reason: entry.key);
      }
    });

    test('legacy base64 with CRLF, trailing newline and blank lines', () async {
      secretsDir.createSync(recursive: true);
      for (final entry in _legacyMadeOutText.entries) {
        _writeLegacyBase64(
            File('${secretsDir.path}/${entry.key}'), entry.value.$1);
        expect(
            await readSecret(project, _fixturePass, entry.key), entry.value.$2,
            reason: entry.key);
      }
    });

    test('legacy OpenSSL fixture with a trailing newline', () async {
      copyFixture('libressl_pbkdf2');
      copyFixture('openssl3_pbkdf2');
      expect(await readSecret(project, _fixturePass, 'libressl_pbkdf2'),
          'dummy-libressl-line-1\ndummy-libressl-line-2');
      expect(await readSecret(project, _fixturePass, 'openssl3_pbkdf2'),
          'dummy-openssl3-pbkdf2');
    });

    test('v2 values with CRLF and a trailing newline', () async {
      final key = generateFilesKey();
      await saveSecret(project, key, 'crlf', 'l1\r\nl2\r\n');
      await saveSecret(project, key, 'netrc', _netrcValue);
      expect(await readSecret(project, key, 'crlf'), 'l1\nl2');
      expect(await readSecret(project, key, 'netrc'),
          _netrcValue.substring(0, _netrcValue.length - 1));
    });

    test('same string as `openssl enc -d` + process_run outText', () async {
      secretsDir.createSync(recursive: true);
      final names = <String>[];
      for (final name in _legacyFixturesOutText.keys) {
        copyFixture(name);
        names.add(name);
      }
      for (final entry in _legacyMadeOutText.entries) {
        _writeLegacyBase64(
            File('${secretsDir.path}/${entry.key}'), entry.value.$1);
        names.add(entry.key);
      }

      // The command earlier nix-infra versions ran in readSecret.
      final shell = Shell(
        environment: {'SECRETS_PASS': _fixturePass},
        runInShell: true,
        verbose: false,
      );
      for (final name in names) {
        final res = await shell.run(
            'openssl enc -pbkdf2 -pass env:SECRETS_PASS -d -a -in "${secretsDir.path}/$name"');
        expect(await readSecret(project, _fixturePass, name), res.outText,
            reason: name);
      }
    }, skip: _hasOpenssl() ? false : 'openssl not found');
  });

  group('readSecret errors', () {
    test('missing name throws SecretNotFound', () async {
      secretsDir.createSync(recursive: true);
      await expectLater(readSecret(project, generateFilesKey(), 'missing'),
          throwsA(isA<SecretNotFound>()));
    });

    test('damaged v2 file throws SecretDecryptFailed', () async {
      final key = generateFilesKey();
      await saveSecret(project, key, 'good', 'value');
      final text = File('${secretsDir.path}/good').readAsStringSync();
      final bodyStart = text.indexOf('---\n') + 4;
      final damagedChar = text[bodyStart] == 'A' ? 'B' : 'A';
      File('${secretsDir.path}/damaged').writeAsStringSync(
          text.replaceRange(bodyStart, bodyStart + 1, damagedChar));

      await expectLater(readSecret(project, key, 'damaged'),
          throwsA(isA<SecretDecryptFailed>()));
    });

    test('v2 file of another generated key throws SecretKeyMismatch', () async {
      await saveSecret(project, generateFilesKey(), 'other', 'value');
      await expectLater(readSecret(project, generateFilesKey(), 'other'),
          throwsA(isA<SecretKeyMismatch>()));
    });

    test('unknown format throws SecretFormatUnknown', () async {
      secretsDir.createSync(recursive: true);
      File('${secretsDir.path}/junk').writeAsStringSync('not base64 !!\n');
      await expectLater(readSecret(project, _fixturePass, 'junk'),
          throwsA(isA<SecretFormatUnknown>()));
    });
  });

  group('legacy base64 warning', () {
    test('is printed once and lists the names, without values', () async {
      copyFixture('legacy_b64_single');
      copyFixture('legacy_b64_netrc');
      copyFixture('openssl3_pbkdf2');
      final key = _fixturePass;

      await readSecret(project, key, 'openssl3_pbkdf2');
      expect(warnings, isEmpty);

      await readSecret(project, key, 'legacy_b64_single');
      await readSecret(project, key, 'legacy_b64_netrc');
      await readSecret(project, key, 'legacy_b64_single');

      expect(warnings, hasLength(1));
      expect(warnings.single, contains('not encrypted'));
      expect(warnings.single, contains('nix-infra secrets migrate'));
      expect(warnings.single, contains('legacy_b64_single'));
      expect(warnings.single, contains('legacy_b64_netrc'));
      expect(warnings.single, isNot(contains('openssl3_pbkdf2')));
      expect(warnings.single, isNot(contains('dummy')));
    });
  });

  group('loadSecretForDeploy', () {
    Future<(String?, List<String>)> load(String key, String name) async {
      final printed = <String>[];
      final value = await runZoned(
        () => loadSecretForDeploy(project, key, name, nodeName: 'worker001'),
        zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => printed.add(line)),
      );
      return (value, printed);
    }

    test('missing secret returns null and prints the warning', () async {
      secretsDir.createSync(recursive: true);
      final (value, printed) = await load(generateFilesKey(), 'missing');
      expect(value, isNull);
      expect(printed.join('\n'),
          contains("WARNING! Secret 'missing' not found in secrets directory"));
      expect(printed.join('\n'), contains('nix-infra store-secret'));
    });

    test('damaged secret prints an error and throws', () async {
      final key = generateFilesKey();
      await saveSecret(project, key, 'damaged', 'secret-value-123');
      final file = File('${secretsDir.path}/damaged');
      final text = file.readAsStringSync();
      final bodyStart = text.indexOf('---\n') + 4;
      final damagedChar = text[bodyStart] == 'A' ? 'B' : 'A';
      file.deleteSync();
      file.writeAsStringSync(
          text.replaceRange(bodyStart, bodyStart + 1, damagedChar));

      final printed = <String>[];
      await expectLater(
        runZoned(
          () => loadSecretForDeploy(project, key, 'damaged',
              nodeName: 'worker001'),
          zoneSpecification: ZoneSpecification(
              print: (self, parent, zone, line) => printed.add(line)),
        ),
        throwsA(isA<SecretDecryptFailed>()),
      );
      expect(printed.join('\n'),
          contains("ERROR! Secret 'damaged' could not be read: "));
      expect(printed.join('\n'), isNot(contains('secret-value-123')));
    });

    test('readable secret is returned', () async {
      final key = generateFilesKey();
      await saveSecret(project, key, 'ok', 'v\n');
      final (value, printed) = await load(key, 'ok');
      expect(value, 'v');
      expect(printed, isEmpty);
    });
  });

  group('buildNetrcDecryptCommands', () {
    test('writes a line break after each decrypted entry', () {
      final cmds = buildNetrcDecryptCommands(['github-netrc', 'gitlab-netrc']);
      expect(
          cmds.split('\n'),
          equals([
            'systemd-creds decrypt /root/secrets/github-netrc - >> /run/keys/combined-netrc && echo >> /run/keys/combined-netrc',
            'systemd-creds decrypt /root/secrets/gitlab-netrc - >> /run/keys/combined-netrc && echo >> /run/keys/combined-netrc',
          ]));
    });
  });
}
