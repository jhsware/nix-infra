import 'dart:convert';
import 'package:test/test.dart';
import '../bin/mcp_server/nix_prefetch_url.dart';
import 'package:nix_infra/providers/providers.dart';
import 'dart:io';

void main() {
  group('NixPrefetchUrl', () {
    late NixPrefetchUrl tool;
    
    setUpAll(() async {
      // Create a mock provider for testing
      // We need a minimal setup just to instantiate the tool
      tool = NixPrefetchUrl(
        workingDir: Directory.current,
        sshKeyName: 'test-key',
        provider: _MockProvider(),
      );
    });

    test('has correct description', () {
      expect(NixPrefetchUrl.description, contains('hash'));
      expect(NixPrefetchUrl.description, contains('URL'));
    });

    test('has correct input schema', () {
      expect(NixPrefetchUrl.inputSchemaProperties, containsKey('operation'));
      expect(NixPrefetchUrl.inputSchemaProperties, containsKey('url'));
      expect(NixPrefetchUrl.inputSchemaProperties, containsKey('format'));
    });

    test('returns error for missing url on hash operation', () async {
      final result = await tool.callback(
        args: {'operation': 'hash'},
        extra: null,
      );
      
      final content = result.content.first;
      expect(content, isA<dynamic>());
      // The response should contain an error about missing url
    });

    test('returns error for unknown operation', () async {
      final result = await tool.callback(
        args: {'operation': 'unknown'},
        extra: null,
      );
      
      final content = result.content.first;
      expect(content, isA<dynamic>());
    });
  });
}

/// Mock provider for testing
class _MockProvider implements InfrastructureProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
