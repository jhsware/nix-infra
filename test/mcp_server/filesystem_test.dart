import 'dart:convert';
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
      test('reads file content with line numbers', () async {
        final testContent = 'Hello, World!\nThis is a test.';
        await File('${testDir.path}/test.txt').writeAsString(testContent);

        final result = await fs.callback(
          args: {
            'operation': 'read-file',
            'path': '$testDirName/test.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'L1: Hello, World!\nL2: This is a test.');
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
        expect(text, 'L1: Hej! 你好 🎉 émoji');
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
        expect(text, 'L1: nested content');
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
        expect(text, contains('L1: Content 1'));
        expect(text, contains('$testDirName/file2.txt:'));
        expect(text, contains('L1: Content 2'));
        expect(text, contains('$testDirName/file3.txt:'));
        expect(text, contains('L1: Content 3'));
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
        expect(text, contains('L1: Single content'));
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
        expect(text, contains('L1: I exist'));
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
        expect(text, contains('L1: allowed'));
        expect(text, contains('Not allowed for: outside/path.txt'));
      });
    });

    group('searchText', () {
      test('finds simple text pattern', () async {
        await File('${testDir.path}/file1.txt').writeAsString('''
Line one
Line two with target word
Line three
''');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'target',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches, isNotEmpty);
        expect(matches.length, 1);
        expect(matches[0]['file'], contains('file1.txt'));
        expect(matches[0]['line'], 2);
        expect(matches[0]['content'], contains('target'));
      });

      test('finds multiple matches in single file', () async {
        await File('${testDir.path}/multi.txt').writeAsString('''
First match here
No hit here
Second match here
Third match here
''');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'match',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches.length, 3);
      });

      test('finds matches across multiple files', () async {
        await File('${testDir.path}/a.txt').writeAsString('match in file a');
        await File('${testDir.path}/b.txt').writeAsString('match in file b');
        await File('${testDir.path}/c.txt').writeAsString('no hit here');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'match',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches.length, 2);

        final files = matches.map((m) => m['file']).toList();
        expect(files.any((f) => f.contains('a.txt')), isTrue);
        expect(files.any((f) => f.contains('b.txt')), isTrue);
      });

      test('searches recursively in subdirectories', () async {
        await Directory('${testDir.path}/sub/deep').create(recursive: true);
        await File('${testDir.path}/root.txt').writeAsString('match at root');
        await File('${testDir.path}/sub/middle.txt')
            .writeAsString('match in middle');
        await File('${testDir.path}/sub/deep/bottom.txt')
            .writeAsString('match at bottom');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'match',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches.length, 3);
      });

      test('supports regex patterns', () async {
        await File('${testDir.path}/regex.txt').writeAsString('''
foo123bar
foo456bar
fooxyzbar
foobar
''');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'foo[0-9]+bar',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches.length, 2);
      });

      test('supports case-insensitive search', () async {
        await File('${testDir.path}/case.txt').writeAsString('''
HELLO world
hello WORLD
HeLLo WoRLd
goodbye
''');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'hello',
            'case-sensitive': false,
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches.length, 3);
      });

      test('case-sensitive by default', () async {
        await File('${testDir.path}/case.txt').writeAsString('''
HELLO
hello
Hello
''');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'hello',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches.length, 1);
      });

      test('filters by file pattern', () async {
        await File('${testDir.path}/code.dart').writeAsString('match in dart');
        await File('${testDir.path}/code.txt').writeAsString('match in txt');
        await File('${testDir.path}/code.js').writeAsString('match in js');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'match',
            'file-pattern': '*.dart',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches.length, 1);
        expect(matches[0]['file'], contains('.dart'));
      });

      test('returns empty array when no matches', () async {
        await File('${testDir.path}/file.txt').writeAsString('no hits here');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'nonexistent',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches, isEmpty);
      });

      test('skips hidden files', () async {
        await File('${testDir.path}/visible.txt').writeAsString('match visible');
        await File('${testDir.path}/.hidden').writeAsString('match hidden');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'match',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches.length, 1);
        expect(matches[0]['file'], contains('visible.txt'));
      });

      test('skips hidden directories', () async {
        await Directory('${testDir.path}/.hidden_dir').create();
        await File('${testDir.path}/visible.txt').writeAsString('match visible');
        await File('${testDir.path}/.hidden_dir/file.txt')
            .writeAsString('match hidden');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'match',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches.length, 1);
        expect(matches[0]['file'], contains('visible.txt'));
      });

      test('returns error when pattern is missing', () async {
        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('Error'));
        expect(text, contains('pattern is required'));
      });

      test('returns error when pattern is empty', () async {
        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': '',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('Error'));
        expect(text, contains('pattern is required'));
      });

      test('returns error for invalid regex pattern', () async {
        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': '[invalid',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('Error'));
        expect(text, contains('Invalid regex'));
      });

      test('rejects absolute paths', () async {
        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': '/absolute/path',
            'pattern': 'test',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('Error'));
        expect(text, contains('No absolute paths allowed'));
      });

      test('rejects hidden directory paths', () async {
        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': '$testDirName/.hidden',
            'pattern': 'test',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('Error'));
        expect(text, contains('No hidden files or directories allowed'));
      });

      test('rejects paths outside allowed directories', () async {
        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': 'some/other/path',
            'pattern': 'test',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('Error'));
        expect(text, contains('Not allowed for'));
      });

      test('returns error for non-existent directory', () async {
        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': '$testDirName/nonexistent',
            'pattern': 'test',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('Error'));
        expect(text, contains('Directory not found'));
      });

      test('returns correct line numbers', () async {
        await File('${testDir.path}/lines.txt').writeAsString('''
Line 1
Line 2
Target on line 3
Line 4
Another target on line 5
Line 6
''');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'target',
            'case-sensitive': false,
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches.length, 2);

        // Sort by line number for consistent testing
        matches.sort((a, b) => (a['line'] as int).compareTo(b['line'] as int));

        expect(matches[0]['line'], 3);
        expect(matches[1]['line'], 5);
      });

      test('handles unicode content', () async {
        await File('${testDir.path}/unicode.txt').writeAsString('''
Hello 你好
World 世界
Match 匹配
''');

        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': '匹配',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches.length, 1);
        expect(matches[0]['content'], contains('匹配'));
      });

      test('handles empty directory', () async {
        final result = await fs.callback(
          args: {
            'operation': 'search-text',
            'path': testDirName,
            'pattern': 'anything',
          },
        );

        final text = (result.content.first as TextContent).text;
        final matches = jsonDecode(text) as List;

        expect(matches, isEmpty);
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
