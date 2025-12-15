import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/types.dart';
import '../../bin/mcp_server/filesystem.dart';

/// Mock provider for testing purposes
class MockProvider implements InfrastructureProvider {
  @override
  String get providerName => 'Mock';

  @override
  bool get supportsCreateServer => false;

  @override
  bool get supportsDestroyServer => false;

  @override
  bool get supportsPlacementGroups => false;

  @override
  Future<Iterable<ClusterNode>> getServers({List<String>? only}) async => [];

  @override
  Future<void> createServer(
    String name,
    String machineType,
    String location,
    String sshKeyName,
    int? placementGroupId,
  ) async {
    throw UnsupportedError('Mock provider does not support creating servers');
  }

  @override
  Future<void> destroyServer(int id) async {
    throw UnsupportedError('Mock provider does not support destroying servers');
  }

  @override
  Future<String?> getIpAddr(String name) async => null;

  @override
  Future<void> addSshKeyToCloudProvider(
      Directory workingDir, String keyName) async {}

  @override
  Future<void> removeSshKeyFromCloudProvider(
      Directory workingDir, String keyName) async {}
}

void main() {
  late Directory testDir;
  late FileSystem fs;
  final String testDirName = '_filesystem_test_temp';

  setUp(() async {
    // Create a test directory under current working directory
    // since getAbsolutePath uses Directory.current
    testDir = Directory('${Directory.current.path}/$testDirName');
    if (await testDir.exists()) {
      await testDir.delete(recursive: true);
    }
    await testDir.create();

    // Create the FileSystem instance with testDir as allowed path
    fs = FileSystem(
      workingDir: Directory.current,
      sshKeyName: 'fake',
      provider: MockProvider(),
      allowedPaths: [testDir.path],
    );
  });

  tearDown(() async {
    // Clean up the test directory after each test
    if (await testDir.exists()) {
      await testDir.delete(recursive: true);
    }
  });

  group('FileSystem', () {
    group('listContent', () {
      test('lists files in directory', () async {
        // Create some test files
        await File('${testDir.path}/file1.txt').writeAsString('content1');
        await File('${testDir.path}/file2.txt').writeAsString('content2');

        final result = await fs.callback(
          args: {
            'operation': 'list-content',
            'path': testDirName,
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('file1.txt'));
        expect(text, contains('file2.txt'));
        expect(text, contains('type: file'));
      });

      test('lists directories and their contents recursively', () async {
        // Create nested structure
        await Directory('${testDir.path}/subdir').create();
        await File('${testDir.path}/root.txt').writeAsString('root');
        await File('${testDir.path}/subdir/nested.txt').writeAsString('nested');

        final result = await fs.callback(
          args: {
            'operation': 'list-content',
            'path': testDirName,
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('root.txt'));
        expect(text, contains('subdir'));
        expect(text, contains('nested.txt'));
      });

      test('omits hidden files', () async {
        await File('${testDir.path}/visible.txt').writeAsString('visible');
        await File('${testDir.path}/.hidden').writeAsString('hidden');

        final result = await fs.callback(
          args: {
            'operation': 'list-content',
            'path': testDirName,
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('visible.txt'));
        expect(text, isNot(contains('.hidden')));
      });

      test('returns error for non-existent directory', () async {
        final result = await fs.callback(
          args: {
            'operation': 'list-content',
            'path': '$testDirName/non_existent',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'Directory not found: $testDirName/non_existent');
      });

      test('rejects absolute paths', () async {
        final result = await fs.callback(
          args: {
            'operation': 'list-content',
            'path': '/absolute/path',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'No absolute paths allowed');
      });

      test('rejects paths outside allowed directories', () async {
        // Create a directory outside allowed paths
        final outsideDir = Directory('${Directory.current.path}/_outside_test');
        await outsideDir.create();

        try {
          final result = await fs.callback(
            args: {
              'operation': 'list-content',
              'path': '_outside_test',
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Not allowed for'));
        } finally {
          await outsideDir.delete(recursive: true);
        }
      });

      test('handles empty directory', () async {
        final result = await fs.callback(
          args: {
            'operation': 'list-content',
            'path': testDirName,
          },
        );

        final text = (result.content.first as TextContent).text;
        // Empty directory should return empty or whitespace-only string
        expect(text.trim(), isEmpty);
      });
    });

    group('readFile', () {
      test('reads file content', () async {
        final testContent = 'Hello, World!\nThis is a test.';
        await File('${testDir.path}/test.txt').writeAsString(testContent);

        final result = await fs.callback(
          args: {
            'operation': 'read-file',
            'path': '$testDirName/test.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, testContent);
      });

      test('reads file with unicode content', () async {
        final testContent = 'Hej! 你好 🎉 émoji';
        await File('${testDir.path}/unicode.txt').writeAsString(testContent);

        final result = await fs.callback(
          args: {
            'operation': 'read-file',
            'path': '$testDirName/unicode.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, testContent);
      });

      test('reads empty file', () async {
        await File('${testDir.path}/empty.txt').writeAsString('');

        final result = await fs.callback(
          args: {
            'operation': 'read-file',
            'path': '$testDirName/empty.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, '');
      });

      test('reads file in nested directory', () async {
        await Directory('${testDir.path}/sub/dir').create(recursive: true);
        await File('${testDir.path}/sub/dir/nested.txt')
            .writeAsString('nested content');

        final result = await fs.callback(
          args: {
            'operation': 'read-file',
            'path': '$testDirName/sub/dir/nested.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'nested content');
      });

      test('returns error for non-existent file', () async {
        final result = await fs.callback(
          args: {
            'operation': 'read-file',
            'path': '$testDirName/non_existent.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'File not found: $testDirName/non_existent.txt');
      });

      test('rejects absolute paths', () async {
        final result = await fs.callback(
          args: {
            'operation': 'read-file',
            'path': '/absolute/path/file.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'No absolute paths allowed');
      });

      test('rejects hidden files', () async {
        await File('${testDir.path}/.hidden').writeAsString('hidden');

        final result = await fs.callback(
          args: {
            'operation': 'read-file',
            'path': '$testDirName/.hidden',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'No hidden files or directories allowed');
      });

      test('rejects paths with hidden directories', () async {
        await Directory('${testDir.path}/.hidden_dir').create();
        await File('${testDir.path}/.hidden_dir/file.txt')
            .writeAsString('content');

        final result = await fs.callback(
          args: {
            'operation': 'read-file',
            'path': '$testDirName/.hidden_dir/file.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'No hidden files or directories allowed');
      });

      test('rejects paths outside allowed directories', () async {
        final result = await fs.callback(
          args: {
            'operation': 'read-file',
            'path': 'some/other/path.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'Not allowed for: some/other/path.txt');
      });
    });

    group('readFiles', () {
      test('reads multiple files', () async {
        await File('${testDir.path}/file1.txt').writeAsString('Content 1');
        await File('${testDir.path}/file2.txt').writeAsString('Content 2');
        await File('${testDir.path}/file3.txt').writeAsString('Content 3');

        final result = await fs.callback(
          args: {
            'operation': 'read-files',
            'path':
                '$testDirName/file1.txt,$testDirName/file2.txt,$testDirName/file3.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('$testDirName/file1.txt:'));
        expect(text, contains('Content 1'));
        expect(text, contains('$testDirName/file2.txt:'));
        expect(text, contains('Content 2'));
        expect(text, contains('$testDirName/file3.txt:'));
        expect(text, contains('Content 3'));
      });

      test('reads single file via read-files', () async {
        await File('${testDir.path}/single.txt').writeAsString('Single content');

        final result = await fs.callback(
          args: {
            'operation': 'read-files',
            'path': '$testDirName/single.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('$testDirName/single.txt:'));
        expect(text, contains('Single content'));
      });

      test('handles mix of existing and non-existing files', () async {
        await File('${testDir.path}/exists.txt').writeAsString('I exist');

        final result = await fs.callback(
          args: {
            'operation': 'read-files',
            'path': '$testDirName/exists.txt,$testDirName/not_exists.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('$testDirName/exists.txt:'));
        expect(text, contains('I exist'));
        expect(text, contains('File not found: $testDirName/not_exists.txt'));
      });

      test('reports error for each absolute path', () async {
        final result = await fs.callback(
          args: {
            'operation': 'read-files',
            'path': '/absolute/path1.txt,/absolute/path2.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('/absolute/path1.txt: No absolute paths allowed'));
        expect(text, contains('/absolute/path2.txt: No absolute paths allowed'));
      });

      test('reports error for hidden files in list', () async {
        await File('${testDir.path}/visible.txt').writeAsString('visible');
        await File('${testDir.path}/.hidden').writeAsString('hidden');

        final result = await fs.callback(
          args: {
            'operation': 'read-files',
            'path': '$testDirName/visible.txt,$testDirName/.hidden',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('$testDirName/visible.txt:'));
        expect(text, contains('visible'));
        expect(text,
            contains('$testDirName/.hidden: No hidden files or directories allowed'));
      });

      test('reports error for paths outside allowed directories', () async {
        await File('${testDir.path}/allowed.txt').writeAsString('allowed');

        final result = await fs.callback(
          args: {
            'operation': 'read-files',
            'path': '$testDirName/allowed.txt,outside/path.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('$testDirName/allowed.txt:'));
        expect(text, contains('allowed'));
        expect(text, contains('Not allowed for: outside/path.txt'));
      });
    });

    group('default path handling', () {
      test('uses current directory as default path for list-content', () async {
        // This test verifies that when path is not provided, it defaults to '.'
        // But since '.' resolves to Directory.current which may not be in allowedPaths,
        // we need to set up allowedPaths to include it
        final fsWithCurrentAllowed = FileSystem(
          workingDir: Directory.current,
          sshKeyName: 'fake',
          provider: MockProvider(),
          allowedPaths: [Directory.current.path],
        );

        final result = await fsWithCurrentAllowed.callback(
          args: {'operation': 'list-content'},
        );

        final text = (result.content.first as TextContent).text;
        // Should not return "Directory not found" since current dir exists
        expect(text, isNot('Directory not found: .'));
      });
    });
  });

  group('Utility functions', () {
    group('getAbsolutePath', () {
      test('returns current directory for "."', () {
        final result = getAbsolutePath('.');
        expect(result, Directory.current.absolute.path);
      });

      test('appends relative path to current directory', () {
        final result = getAbsolutePath('some/path');
        expect(result, '${Directory.current.absolute.path}/some/path');
      });

      test('normalizes path with ..', () {
        final result = getAbsolutePath('some/path/../other');
        expect(result, '${Directory.current.absolute.path}/some/other');
      });

      test('normalizes path with .', () {
        final result = getAbsolutePath('some/./path');
        expect(result, '${Directory.current.absolute.path}/some/path');
      });
    });

    group('isHiddenPath', () {
      test('returns true for hidden files', () {
        expect(isHiddenPath('.hidden'), isTrue);
        expect(isHiddenPath('path/to/.hidden'), isTrue);
      });

      test('returns false for visible files', () {
        expect(isHiddenPath('visible'), isFalse);
        expect(isHiddenPath('path/to/visible'), isFalse);
      });

      test('checks only the last path component', () {
        // A file in a hidden directory but with a visible name
        expect(isHiddenPath('.hidden/visible'), isFalse);
      });
    });

    group('isAllowedPath', () {
      test('returns true for paths within allowed directories', () {
        final allowed = ['/home/user/project'];
        expect(isAllowedPath(allowed, '/home/user/project'), isTrue);
        expect(isAllowedPath(allowed, '/home/user/project/sub'), isTrue);
        expect(isAllowedPath(allowed, '/home/user/project/sub/dir'), isTrue);
      });

      test('returns false for paths outside allowed directories', () {
        final allowed = ['/home/user/project'];
        expect(isAllowedPath(allowed, '/home/user/other'), isFalse);
        expect(isAllowedPath(allowed, '/root'), isFalse);
        expect(isAllowedPath(allowed, '/home/user'), isFalse);
      });

      test('handles multiple allowed paths', () {
        final allowed = ['/home/user/project1', '/home/user/project2'];
        expect(isAllowedPath(allowed, '/home/user/project1/file'), isTrue);
        expect(isAllowedPath(allowed, '/home/user/project2/file'), isTrue);
        expect(isAllowedPath(allowed, '/home/user/project3/file'), isFalse);
      });

      test('returns false for empty allowed list', () {
        final allowed = <String>[];
        expect(isAllowedPath(allowed, '/any/path'), isFalse);
      });
    });
  });
}
