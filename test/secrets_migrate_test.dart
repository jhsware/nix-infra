import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nix_infra/secret_codec.dart';
import 'package:nix_infra/secrets.dart';
import 'package:test/test.dart';

const _fixtureDir = 'test/fixtures/secrets';
const _fixturePass = 'fixture-pass-1';

/// Legacy fixtures that open with [_fixturePass] (see
/// test/fixtures/secrets/README.md), with their format.
const _legacyFixtures = {
  'legacy_b64_single': SecretFileFormat.legacyBase64,
  'legacy_b64_netrc': SecretFileFormat.legacyBase64,
  'legacy_b64_long': SecretFileFormat.legacyBase64,
  'openssl3_pbkdf2': SecretFileFormat.opensslSalted,
  'openssl3_bytestokey_sha256': SecretFileFormat.opensslSalted,
  'libressl_pbkdf2': SecretFileFormat.opensslSalted,
  'openssl_bytestokey_md5': SecretFileFormat.opensslSalted,
};

const _base64Fixtures = [
  'legacy_b64_single',
  'legacy_b64_netrc',
  'legacy_b64_long',
];

const _githubNetrc =
    'machine api.github.com\n'
    'login x-access-token\n'
    'password ghp_000000000000000000000000000000000000\n';

final _oldMtime = DateTime.utc(2024, 1, 2, 3, 4, 5);

int _mode(String path) => FileStat.statSync(path).mode & 0x1ff;

void main() {
  late Directory project;
  late Directory secretsDir;
  late void Function(String) originalSink;

  setUp(() {
    project = Directory.systemTemp.createTempSync('secrets_migrate_test_');
    secretsDir = Directory('${project.path}/secrets')..createSync();
    originalSink = secretWarningSink;
    secretWarningSink = (_) {};
    resetLegacySecretWarning();
  });

  tearDown(() {
    secretWarningSink = originalSink;
    resetLegacySecretWarning();
    project.deleteSync(recursive: true);
  });

  File fileOf(String name) => File('${secretsDir.path}/$name');

  void copyFixture(String name) {
    File('$_fixtureDir/$name').copySync(fileOf(name).path);
    fileOf(name).setLastModifiedSync(_oldMtime);
  }

  void writeLegacyBase64(String name, String value) {
    fileOf(name).writeAsStringSync('${base64.encode(utf8.encode(value))}\n');
    fileOf(name).setLastModifiedSync(_oldMtime);
  }

  List<String> tmpFiles() => secretsDir
      .listSync()
      .map((e) => e.uri.pathSegments.last)
      .where((n) => n.startsWith('.tmp-'))
      .toList();

  Future<Map<String, String>> readAll(
    Iterable<String> names,
    String key,
  ) async => {for (final n in names) n: await readSecret(project, key, n)};

  group('migrateSecret', () {
    test(
      'converts each legacy fixture to v2 with a new key; values are kept',
      () async {
        final newKey = generateFilesKey();
        for (final name in _legacyFixtures.keys) {
          copyFixture(name);
        }
        writeLegacyBase64('legacy_github_netrc', _githubNetrc);
        final names = [..._legacyFixtures.keys, 'legacy_github_netrc'];
        final before = await readAll(names, _fixturePass);

        for (final name in names) {
          final result = await migrateSecret(
            project,
            name,
            oldKey: _fixturePass,
            newKey: newKey,
          );
          expect(result.status, MigrateStatus.converted, reason: '$result');
          expect(
            result.format,
            _legacyFixtures[name] ?? SecretFileFormat.legacyBase64,
          );

          final bytes = fileOf(name).readAsBytesSync();
          expect(detectSecretFormat(bytes), SecretFileFormat.v2, reason: name);
          final header = parseSecretV2Header(bytes);
          expect(header.kdf, SecretKdf.hkdfSha256);
          expect(header.created, _oldMtime, reason: 'created = old mtime');
          expect(_mode(fileOf(name).path), 0x100, reason: '$name mode 400');
        }

        expect(
          parseSecretV2Header(
            fileOf('legacy_github_netrc').readAsBytesSync(),
          ).kind,
          kSecretKindGithubNetrc,
        );
        expect(
          parseSecretV2Header(
            fileOf('legacy_b64_netrc').readAsBytesSync(),
          ).kind,
          kSecretKindText,
        );
        expect(await readAll(names, newKey), before);
        expect(tmpFiles(), isEmpty);
      },
    );

    test('same key: legacy base64 files become v2 with the same key', () async {
      final key = generateFilesKey();
      for (final name in _base64Fixtures) {
        copyFixture(name);
      }
      final before = await readAll(_base64Fixtures, key);

      for (final name in _base64Fixtures) {
        final result = await migrateSecret(
          project,
          name,
          oldKey: key,
          newKey: key,
        );
        expect(result.status, MigrateStatus.converted, reason: '$result');
      }
      expect(await readAll(_base64Fixtures, key), before);
      for (final name in _base64Fixtures) {
        expect(
          detectSecretFormat(fileOf(name).readAsBytesSync()),
          SecretFileFormat.v2,
        );
        expect(_mode(fileOf(name).path), 0x100);
      }
      expect(tmpFiles(), isEmpty);
    });

    test(
      'same key: an OpenSSL file becomes v2 with the same password',
      () async {
        copyFixture('openssl3_pbkdf2');
        final before = await readSecret(
          project,
          _fixturePass,
          'openssl3_pbkdf2',
        );

        final result = await migrateSecret(
          project,
          'openssl3_pbkdf2',
          oldKey: _fixturePass,
          newKey: _fixturePass,
        );
        expect(result.status, MigrateStatus.converted, reason: '$result');

        final bytes = fileOf('openssl3_pbkdf2').readAsBytesSync();
        expect(parseSecretV2Header(bytes).kdf, SecretKdf.pbkdf2HmacSha256);
        expect(
          await readSecret(project, _fixturePass, 'openssl3_pbkdf2'),
          before,
        );
        expect(tmpFiles(), isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('v2 files are not changed without a new key', () async {
      final key = generateFilesKey();
      await saveSecret(project, key, 'v2-file', 'value');
      final bytes = fileOf('v2-file').readAsBytesSync();
      final modified = fileOf('v2-file').lastModifiedSync();

      final result = await migrateSecret(
        project,
        'v2-file',
        oldKey: key,
        newKey: key,
      );
      expect(result.status, MigrateStatus.skipped);
      expect(result.format, SecretFileFormat.v2);
      expect(fileOf('v2-file').readAsBytesSync(), bytes);
      expect(fileOf('v2-file').lastModifiedSync(), modified);
    });

    test('with a new key every file opens with the new key only; '
        'kind and created are kept', () async {
      final oldKey = generateFilesKey();
      final newKey = generateFilesKey();
      await saveSecret(project, oldKey, 'v2-text', 'l1\r\nl2\r\n');
      await saveSecret(project, oldKey, 'v2-netrc', _githubNetrc);
      for (final name in _base64Fixtures) {
        copyFixture(name);
      }
      final names = ['v2-text', 'v2-netrc', ..._base64Fixtures];
      final before = await readAll(names, oldKey);
      final headersBefore = {
        for (final n in ['v2-text', 'v2-netrc'])
          n: parseSecretV2Header(fileOf(n).readAsBytesSync()),
      };

      for (final name in names) {
        final result = await migrateSecret(
          project,
          name,
          oldKey: oldKey,
          newKey: newKey,
        );
        expect(result.status, MigrateStatus.converted, reason: '$result');
      }

      expect(await readAll(names, newKey), before);
      for (final name in names) {
        final bytes = fileOf(name).readAsBytesSync();
        expect(parseSecretV2Header(bytes).keyId, filesKeyId(newKey));
        await expectLater(
          readSecret(project, oldKey, name),
          throwsA(isA<SecretKeyMismatch>()),
          reason: name,
        );
        expect(_mode(fileOf(name).path), 0x100);
      }
      for (final entry in headersBefore.entries) {
        final after = parseSecretV2Header(fileOf(entry.key).readAsBytesSync());
        expect(after.kind, entry.value.kind);
        expect(after.created, entry.value.created);
      }
      expect(tmpFiles(), isEmpty);
    });

    test('a rerun skips files that the new key already opens', () async {
      final oldKey = generateFilesKey();
      final newKey = generateFilesKey();
      await saveSecret(project, oldKey, 'a', 'value-a');
      await saveSecret(project, oldKey, 'b', 'value-b');
      copyFixture('legacy_b64_single');

      // A first run that stopped after one file.
      expect(
        (await migrateSecret(
          project,
          'a',
          oldKey: oldKey,
          newKey: newKey,
        )).status,
        MigrateStatus.converted,
      );
      final aBytes = fileOf('a').readAsBytesSync();

      final rerun = {
        for (final n in ['a', 'b', 'legacy_b64_single'])
          n: await migrateSecret(project, n, oldKey: oldKey, newKey: newKey),
      };
      expect(rerun['a']!.status, MigrateStatus.skipped);
      expect(rerun['b']!.status, MigrateStatus.converted);
      expect(rerun['legacy_b64_single']!.status, MigrateStatus.converted);
      expect(fileOf('a').readAsBytesSync(), aBytes);

      // A third run changes nothing.
      for (final n in ['a', 'b']) {
        final bytes = fileOf(n).readAsBytesSync();
        final result = await migrateSecret(
          project,
          n,
          oldKey: oldKey,
          newKey: newKey,
        );
        expect(result.status, MigrateStatus.skipped);
        expect(fileOf(n).readAsBytesSync(), bytes);
      }
      expect(await readSecret(project, newKey, 'a'), 'value-a');
      expect(await readSecret(project, newKey, 'b'), 'value-b');
    });

    test(
      'a file that cannot be read is reported failed and not changed',
      () async {
        copyFixture('openssl_other_cipher');
        fileOf('junk').writeAsStringSync('not base64 !!\n');
        final newKey = generateFilesKey();

        for (final name in ['openssl_other_cipher', 'junk']) {
          final bytes = fileOf(name).readAsBytesSync();
          final result = await migrateSecret(
            project,
            name,
            oldKey: _fixturePass,
            newKey: newKey,
          );
          expect(result.status, MigrateStatus.failed, reason: name);
          expect(result.reason, isNotNull);
          expect(result.reason, isNot(contains('dummy')));
          expect(fileOf(name).readAsBytesSync(), bytes, reason: name);
        }
        expect(tmpFiles(), isEmpty);
      },
    );

    test('a wrong old key fails and leaves the file unchanged', () async {
      final key = generateFilesKey();
      await saveSecret(project, key, 'v2-file', 'value');
      final bytes = fileOf('v2-file').readAsBytesSync();

      final result = await migrateSecret(
        project,
        'v2-file',
        oldKey: generateFilesKey(),
        newKey: generateFilesKey(),
      );
      expect(result.status, MigrateStatus.failed);
      expect(fileOf('v2-file').readAsBytesSync(), bytes);
      expect(tmpFiles(), isEmpty);
    });

    test(
      'a symbolic link and a missing name fail and change nothing',
      () async {
        copyFixture('legacy_b64_single');
        final target = fileOf('legacy_b64_single').readAsBytesSync();
        Link(
          '${secretsDir.path}/linked',
        ).createSync(fileOf('legacy_b64_single').path);
        final key = generateFilesKey();

        final link = await migrateSecret(
          project,
          'linked',
          oldKey: key,
          newKey: key,
        );
        expect(link.status, MigrateStatus.failed);
        expect(link.reason, contains('symbolic link'));
        expect(
          FileSystemEntity.isLinkSync('${secretsDir.path}/linked'),
          isTrue,
        );
        expect(fileOf('legacy_b64_single').readAsBytesSync(), target);

        final missing = await migrateSecret(
          project,
          'missing',
          oldKey: key,
          newKey: key,
        );
        expect(missing.status, MigrateStatus.failed);
        expect(missing.reason, 'not found');
      },
    );
  });

  group('secrets list', () {
    test('buildSecretListRow for each format', () async {
      final created = DateTime.utc(2025, 6, 7, 8, 9, 10);
      final modified = DateTime.utc(2025, 6, 8);
      final v2 = await encryptSecretV2(
        plaintext: _githubNetrc,
        key: generateFilesKey(),
        kind: kSecretKindGithubNetrc,
        created: created,
      );

      final v2Row = buildSecretListRow('a', bytes: v2, modified: modified);
      expect(v2Row.format, 'v2');
      expect(v2Row.kind, kSecretKindGithubNetrc);
      expect(v2Row.created, created);
      expect(v2Row.modified, modified);
      expect(v2Row.isLink, isFalse);

      Uint8List fixture(String name) =>
          File('$_fixtureDir/$name').readAsBytesSync();
      final openssl = buildSecretListRow(
        'b',
        bytes: fixture('openssl3_pbkdf2'),
      );
      expect(openssl.format, 'openssl');
      expect(openssl.kind, isNull);
      expect(openssl.created, isNull);

      expect(
        buildSecretListRow('c', bytes: fixture('legacy_b64_single')).format,
        'plain',
      );
      expect(
        buildSecretListRow('d', bytes: ascii.encode('not base64 !!\n')).format,
        'unknown',
      );
      expect(
        buildSecretListRow('e').format,
        'unknown',
        reason: 'unreadable file',
      );

      final badHeader = buildSecretListRow(
        'f',
        bytes: ascii.encode('$kSecretV2Magic\nkind: text\n---\nAAAA\n'),
      );
      expect(badHeader.format, 'v2');
      expect(badHeader.kind, '(bad header)');

      final link = buildSecretListRow('g', isLink: true);
      expect(link.format, 'link');
      expect(link.isLink, isTrue);
    });

    test('listSecretFiles skips dot names and folders, lists links', () async {
      copyFixture('legacy_b64_single');
      copyFixture('openssl3_pbkdf2');
      await saveSecret(project, generateFilesKey(), 'v2-file', 'value');
      fileOf('.tmp-0123456789abcdef').writeAsStringSync('partial');
      fileOf('.hidden').writeAsStringSync('x');
      Directory('${secretsDir.path}/subdir').createSync();
      Link(
        '${secretsDir.path}/linked',
      ).createSync('${secretsDir.path}/does-not-exist');

      final rows = listSecretFiles(project);
      expect(rows.map((r) => r.name), [
        'legacy_b64_single',
        'linked',
        'openssl3_pbkdf2',
        'v2-file',
      ]);
      expect(rows.map((r) => r.format), ['plain', 'link', 'openssl', 'v2']);
      expect(rows[0].modified, _oldMtime);
      expect(rows[1].modified, isNull);
      expect(rows[3].kind, kSecretKindText);
    });

    test('listSecretFiles of a project without secrets is empty', () {
      secretsDir.deleteSync();
      expect(listSecretFiles(project), isEmpty);
    });

    test('formatSecretListRows prints aligned columns', () {
      final lines = formatSecretListRows([
        SecretListRow(
          name: 'a-long-secret-name',
          format: 'v2',
          kind: 'github-netrc',
          created: DateTime.utc(2025, 1, 2, 3, 4, 5),
          modified: DateTime.utc(2025, 1, 2, 3, 4, 6),
          secretFormat: SecretFileFormat.v2,
        ),
        SecretListRow(
          name: 'b',
          format: 'plain',
          modified: DateTime.utc(2024, 1, 2),
          secretFormat: SecretFileFormat.legacyBase64,
        ),
      ]);
      expect(lines, hasLength(3));
      expect(lines[0], startsWith('NAME'));
      final formatColumn = lines[0].indexOf('FORMAT');
      expect(lines[1].indexOf('v2'), formatColumn);
      expect(lines[2].indexOf('plain'), formatColumn);
      expect(lines[1], contains('2025-01-02T03:04:05Z'));
      expect(lines[2], contains('2024-01-02T00:00:00Z'));
      final kindColumn = lines[0].indexOf('KIND');
      expect(lines[2].substring(kindColumn, kindColumn + 1), '-');
    });
  });
}
