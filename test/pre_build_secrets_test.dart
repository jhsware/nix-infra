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
}
