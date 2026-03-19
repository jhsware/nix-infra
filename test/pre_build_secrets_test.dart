import 'package:test/test.dart';
import 'package:nix_infra/helpers.dart';

void main() {
  group('substitute() - pre-build-secrets pattern recognition', () {
    test('regular secrets are collected in expectedSecrets only', () {
      final expectedSecrets = <String>[];
      final expectedPreBuildSecrets = <String>[];
      final input = 'netrc-file = [%%secrets/github-netrc%%]';

      final result = substitute(input, {},
          expectedSecrets: expectedSecrets,
          expectedPreBuildSecrets: expectedPreBuildSecrets);

      expect(result, equals('netrc-file = github-netrc'));
      expect(expectedSecrets, equals(['github-netrc']));
      expect(expectedPreBuildSecrets, isEmpty);
    });

    test('pre-build secrets are collected in both lists (dual deployment)', () {
      final expectedSecrets = <String>[];
      final expectedPreBuildSecrets = <String>[];
      final input = 'netrc-file = [%%pre-build-secrets/github-netrc%%]';

      final result = substitute(input, {},
          expectedSecrets: expectedSecrets,
          expectedPreBuildSecrets: expectedPreBuildSecrets);

      expect(result, equals('netrc-file = github-netrc'));
      expect(expectedSecrets, equals(['github-netrc']),
          reason: 'pre-build secrets should also be added to expectedSecrets');
      expect(expectedPreBuildSecrets, equals(['github-netrc']));
    });

    test('mixed placeholders are correctly separated', () {
      final expectedSecrets = <String>[];
      final expectedPreBuildSecrets = <String>[];
      final input = '''
        secret1 = [%%secrets/db-password%%]
        prebuild1 = [%%pre-build-secrets/github-netrc%%]
        secret2 = [%%secrets/api-key%%]
      ''';

      substitute(input, {},
          expectedSecrets: expectedSecrets,
          expectedPreBuildSecrets: expectedPreBuildSecrets);

      expect(expectedSecrets, containsAll(['db-password', 'github-netrc', 'api-key']));
      expect(expectedPreBuildSecrets, equals(['github-netrc']));
    });

    test('regular substitutions still work unchanged', () {
      final expectedSecrets = <String>[];
      final expectedPreBuildSecrets = <String>[];
      final input = 'hostname = [%%nodeName%%], ip = [%%nodeIp%%]';

      final result = substitute(input, {
        'nodeName': 'worker001',
        'nodeIp': '10.0.0.1',
      },
          expectedSecrets: expectedSecrets,
          expectedPreBuildSecrets: expectedPreBuildSecrets);

      expect(result, equals('hostname = worker001, ip = 10.0.0.1'));
      expect(expectedSecrets, isEmpty);
      expect(expectedPreBuildSecrets, isEmpty);
    });

    test('multiple pre-build secrets are all collected', () {
      final expectedSecrets = <String>[];
      final expectedPreBuildSecrets = <String>[];
      final input = '''
        netrc = [%%pre-build-secrets/github-netrc%%]
        token = [%%pre-build-secrets/nix-access-token%%]
      ''';

      substitute(input, {},
          expectedSecrets: expectedSecrets,
          expectedPreBuildSecrets: expectedPreBuildSecrets);

      expect(expectedPreBuildSecrets,
          equals(['github-netrc', 'nix-access-token']));
      expect(expectedSecrets,
          equals(['github-netrc', 'nix-access-token']));
    });

    test('unrecognized placeholders are left unchanged', () {
      final input = 'value = [%%unknown/path%%]';

      final result = substitute(input, {});

      expect(result, equals('value = [%%unknown/path%%]'));
    });

    test('works without optional lists (backward compatible)', () {
      final input = 'secret = [%%secrets/foo%%], prebuild = [%%pre-build-secrets/bar%%]';

      // Should not throw when lists are null
      final result = substitute(input, {});

      expect(result, equals('secret = foo, prebuild = bar'));
    });

    test('pre-build secret placeholder is replaced with just the name', () {
      final input = '[%%pre-build-secrets/my-netrc-file%%]';

      final result = substitute(input, {});

      expect(result, equals('my-netrc-file'));
    });
  });
}
