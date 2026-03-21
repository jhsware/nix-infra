import 'package:test/test.dart';
import 'package:nix_infra/helpers.dart';

void main() {
  group('substitute() - secrets pattern recognition', () {
    test('regular secrets are collected in expectedSecrets', () {
      final expectedSecrets = <String>[];
      final input = 'netrc-file = [%%secrets/github-netrc%%]';

      final result = substitute(input, {},
          expectedSecrets: expectedSecrets);

      expect(result, equals('netrc-file = github-netrc'));
      expect(expectedSecrets, equals(['github-netrc']));
    });

    test('multiple secrets are all collected', () {
      final expectedSecrets = <String>[];
      final input = '''
        secret1 = [%%secrets/db-password%%]
        secret2 = [%%secrets/api-key%%]
      ''';

      substitute(input, {},
          expectedSecrets: expectedSecrets);

      expect(expectedSecrets, containsAll(['db-password', 'api-key']));
    });

    test('regular substitutions still work unchanged', () {
      final expectedSecrets = <String>[];
      final input = 'hostname = [%%nodeName%%], ip = [%%nodeIp%%]';

      final result = substitute(input, {
        'nodeName': 'worker001',
        'nodeIp': '10.0.0.1',
      },
          expectedSecrets: expectedSecrets);

      expect(result, equals('hostname = worker001, ip = 10.0.0.1'));
      expect(expectedSecrets, isEmpty);
    });

    test('unrecognized placeholders are left unchanged', () {
      final input = 'value = [%%unknown/path%%]';

      final result = substitute(input, {});

      expect(result, equals('value = [%%unknown/path%%]'));
    });

    test('works without optional lists (backward compatible)', () {
      final input = 'secret = [%%secrets/foo%%]';

      // Should not throw when lists are null
      final result = substitute(input, {});

      expect(result, equals('secret = foo'));
    });
  });

  group('substitute() - secrets.netrc pattern recognition', () {
    test('netrc secrets are collected in both expectedSecrets and expectedNetrcSecrets', () {
      final expectedSecrets = <String>[];
      final expectedNetrcSecrets = <String>[];
      final input = 'cred = [%%secrets.netrc/github-netrc%%]';

      final result = substitute(input, {},
          expectedSecrets: expectedSecrets,
          expectedNetrcSecrets: expectedNetrcSecrets);

      expect(result, equals('cred = github-netrc'));
      expect(expectedSecrets, equals(['github-netrc']));
      expect(expectedNetrcSecrets, equals(['github-netrc']));
    });

    test('multiple netrc secrets are all collected', () {
      final expectedSecrets = <String>[];
      final expectedNetrcSecrets = <String>[];
      final input = '''
        cred1 = [%%secrets.netrc/github-netrc%%]
        cred2 = [%%secrets.netrc/gitlab-netrc%%]
      ''';

      substitute(input, {},
          expectedSecrets: expectedSecrets,
          expectedNetrcSecrets: expectedNetrcSecrets);

      expect(expectedSecrets, containsAll(['github-netrc', 'gitlab-netrc']));
      expect(expectedNetrcSecrets, containsAll(['github-netrc', 'gitlab-netrc']));
    });

    test('mixed secrets and netrc secrets are separated correctly', () {
      final expectedSecrets = <String>[];
      final expectedNetrcSecrets = <String>[];
      final input = '''
        regular = [%%secrets/api-key%%]
        netrc = [%%secrets.netrc/github-netrc%%]
      ''';

      substitute(input, {},
          expectedSecrets: expectedSecrets,
          expectedNetrcSecrets: expectedNetrcSecrets);

      expect(expectedSecrets, containsAll(['api-key', 'github-netrc']));
      expect(expectedNetrcSecrets, equals(['github-netrc']));
    });

    test('netrc secrets work without optional lists (backward compatible)', () {
      final input = 'cred = [%%secrets.netrc/foo%%]';

      // Should not throw when lists are null
      final result = substitute(input, {});

      expect(result, equals('cred = foo'));
    });

    test('netrc secrets coexist with regular substitutions', () {
      final expectedSecrets = <String>[];
      final expectedNetrcSecrets = <String>[];
      final input = 'host = [%%nodeName%%], cred = [%%secrets.netrc/github-netrc%%]';

      final result = substitute(input, {
        'nodeName': 'worker001',
      },
          expectedSecrets: expectedSecrets,
          expectedNetrcSecrets: expectedNetrcSecrets);

      expect(result, equals('host = worker001, cred = github-netrc'));
      expect(expectedSecrets, equals(['github-netrc']));
      expect(expectedNetrcSecrets, equals(['github-netrc']));
    });
  });
}