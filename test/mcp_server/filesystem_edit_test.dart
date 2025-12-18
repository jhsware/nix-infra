import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/types.dart';
import '../../bin/mcp_server/filesystem_edit.dart';

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
  late FileSystemEdit fsEdit;
  late String testFilePath;
  final String testDirName = '_filesystem_edit_test_temp';

  setUp(() async {
    // Create a test directory under current working directory
    // since getAbsolutePath uses Directory.current
    testDir = Directory('${Directory.current.path}/$testDirName');
    if (await testDir.exists()) {
      await testDir.delete(recursive: true);
    }
    await testDir.create();

    // Create the FileSystemEdit instance with testDir as allowed path
    fsEdit = FileSystemEdit(
      workingDir: Directory.current,
      sshKeyName: 'fake',
      provider: MockProvider(),
      allowedPaths: [testDir.path],
    );

    testFilePath = '$testDirName/test_file.txt';
  });

  tearDown(() async {
    // Clean up the test directory after each test
    if (await testDir.exists()) {
      await testDir.delete(recursive: true);
    }
  });

  group('FileSystemEdit', () {
    group('createDirectory', () {
      test('creates a new directory', () async {
        final result = await fsEdit.callback(
          args: {
            'operation': 'create-directory',
            'path': '$testDirName/new_dir',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'Created directory: $testDirName/new_dir');

        final dir = Directory('${testDir.path}/new_dir');
        expect(await dir.exists(), isTrue);
      });

      test('creates nested directories', () async {
        final result = await fsEdit.callback(
          args: {
            'operation': 'create-directory',
            'path': '$testDirName/parent/child/grandchild',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'Created directory: $testDirName/parent/child/grandchild');

        final dir = Directory('${testDir.path}/parent/child/grandchild');
        expect(await dir.exists(), isTrue);
      });

      test('returns error for existing directory', () async {
        await Directory('${testDir.path}/existing_dir').create();

        final result = await fsEdit.callback(
          args: {
            'operation': 'create-directory',
            'path': '$testDirName/existing_dir',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'Directory exists: $testDirName/existing_dir');
      });

      test('rejects absolute paths', () async {
        final result = await fsEdit.callback(
          args: {
            'operation': 'create-directory',
            'path': '/absolute/path',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'No absolute paths allowed');
      });

      test('rejects hidden directories', () async {
        final result = await fsEdit.callback(
          args: {
            'operation': 'create-directory',
            'path': '$testDirName/.hidden_dir',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'No hidden files or directories allowed');
      });
    });

    group('createFile', () {
      test('creates a new empty file', () async {
        final result = await fsEdit.callback(
          args: {
            'operation': 'create-file',
            'path': testFilePath,
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'Created file: $testFilePath');

        final file = File('${testDir.path}/test_file.txt');
        expect(await file.exists(), isTrue);
        expect(await file.readAsString(), '');
      });

      test('creates a new file with content', () async {
        final result = await fsEdit.callback(
          args: {
            'operation': 'create-file',
            'path': testFilePath,
            'content': 'Hello, World!',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'Created file: $testFilePath');

        final file = File('${testDir.path}/test_file.txt');
        expect(await file.exists(), isTrue);
        expect(await file.readAsString(), 'Hello, World!');
      });

      test('creates file with parent directories', () async {
        final result = await fsEdit.callback(
          args: {
            'operation': 'create-file',
            'path': '$testDirName/subdir/nested/test_file.txt',
            'content': 'Nested content',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'Created file: $testDirName/subdir/nested/test_file.txt');

        final file = File('${testDir.path}/subdir/nested/test_file.txt');
        expect(await file.exists(), isTrue);
        expect(await file.readAsString(), 'Nested content');
      });

      test('strips line numbers from content when creating file', () async {
        final result = await fsEdit.callback(
          args: {
            'operation': 'create-file',
            'path': testFilePath,
            'content': 'L1: Line one\nL2: Line two\nL3: Line three',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'Created file: $testFilePath');

        final file = File('${testDir.path}/test_file.txt');
        expect(await file.exists(), isTrue);
        expect(await file.readAsString(), 'Line one\nLine two\nLine three');
      });

      test('handles content without line numbers when creating file', () async {
        final result = await fsEdit.callback(
          args: {
            'operation': 'create-file',
            'path': testFilePath,
            'content': 'No line numbers here\nJust plain text',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'Created file: $testFilePath');

        final file = File('${testDir.path}/test_file.txt');
        expect(await file.readAsString(), 'No line numbers here\nJust plain text');
      });

      test('returns error for existing file', () async {
        final file = File('${testDir.path}/test_file.txt');
        await file.create();

        final result = await fsEdit.callback(
          args: {
            'operation': 'create-file',
            'path': testFilePath,
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('File exists:'));
      });

      test('rejects absolute paths', () async {
        final result = await fsEdit.callback(
          args: {
            'operation': 'create-file',
            'path': '/absolute/path/file.txt',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'No absolute paths allowed');
      });

      test('rejects hidden files', () async {
        final result = await fsEdit.callback(
          args: {
            'operation': 'create-file',
            'path': '$testDirName/.hidden_file',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, 'No hidden files or directories allowed');
      });
    });

    group('editFile', () {
      group('overwrite entire file (no line numbers)', () {
        test('overwrites entire file content', () async {
          // Create initial file
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New content\nReplaced everything',
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));
          expect(text, contains('Overwrote entire file'));

          expect(await file.readAsString(), 'New content\nReplaced everything');
        });

        test('overwrites with empty content', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Original content');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': '',
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          expect(await file.readAsString(), '');
        });
      });

      group('insert at line (startLine only)', () {
        test('inserts at beginning of file', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'Inserted line',
              'startLine': 1,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));
          expect(text, contains('Inserted'));
          expect(text, contains('at line 1'));

          expect(
              await file.readAsString(), 'Inserted line\nLine 1\nLine 2\nLine 3');
        });

        test('inserts in middle of file', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'Inserted line',
              'startLine': 2,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          expect(
              await file.readAsString(), 'Line 1\nInserted line\nLine 2\nLine 3');
        });

        test('inserts at end of file', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'Inserted line',
              'startLine': 4,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          expect(
              await file.readAsString(), 'Line 1\nLine 2\nLine 3\nInserted line');
        });

        test('inserts multiple lines', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New A\nNew B',
              'startLine': 2,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));
          expect(text, contains('2 line(s)'));

          expect(await file.readAsString(), 'Line 1\nNew A\nNew B\nLine 3');
        });

        test('inserts beyond file length with padding', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'Line 5',
              'startLine': 5,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          final content = await file.readAsString();
          final lines = content.split('\n');
          expect(lines.length, 5);
          expect(lines[0], 'Line 1');
          expect(lines[4], 'Line 5');
        });
      });

      group('replace line range (startLine and endLine)', () {
        test('replaces single line', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'Replaced line',
              'startLine': 2,
              'endLine': 2,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));
          expect(text, contains('Replaced'));

          expect(await file.readAsString(), 'Line 1\nReplaced line\nLine 3');
        });

        test('replaces multiple lines with single line', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3\nLine 4\nLine 5');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'Replaced',
              'startLine': 2,
              'endLine': 4,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));
          expect(text, contains('3 line(s)'));

          expect(await file.readAsString(), 'Line 1\nReplaced\nLine 5');
        });

        test('replaces single line with multiple lines', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New A\nNew B\nNew C',
              'startLine': 2,
              'endLine': 2,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          expect(
              await file.readAsString(), 'Line 1\nNew A\nNew B\nNew C\nLine 3');
        });

        test('replaces first line', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New first line',
              'startLine': 1,
              'endLine': 1,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          expect(await file.readAsString(), 'New first line\nLine 2\nLine 3');
        });

        test('replaces last line', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New last line',
              'startLine': 3,
              'endLine': 3,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          expect(await file.readAsString(), 'Line 1\nLine 2\nNew last line');
        });

        test('replaces all lines', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'Single replacement',
              'startLine': 1,
              'endLine': 3,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          expect(await file.readAsString(), 'Single replacement');
        });

        test('handles endLine beyond file length', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'Replaced',
              'startLine': 2,
              'endLine': 100,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          expect(await file.readAsString(), 'Line 1\nReplaced');
        });
      });

      group('error handling', () {
        test('returns error for non-existent file', () async {
          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': '$testDirName/non_existent.txt',
              'content': 'Some content',
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Error'));
          expect(text, contains('File not found'));
        });

        test('returns error when content is missing', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Original');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Error'));
          expect(text, contains('Content is required'));
        });

        test('returns error for startLine < 1', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Original');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New',
              'startLine': 0,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Error'));
          expect(text, contains('startLine must be >= 1'));
        });

        test('returns error for endLine < 1', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Original');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New',
              'startLine': 1,
              'endLine': 0,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Error'));
          expect(text, contains('endLine must be >= 1'));
        });

        test('returns error for endLine without startLine', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Original');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New',
              'endLine': 2,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Error'));
          expect(text, contains('endLine requires startLine'));
        });

        test('returns error when endLine < startLine', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New',
              'startLine': 3,
              'endLine': 1,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Error'));
          expect(text, contains('endLine must be >= startLine'));
        });

        test('returns error when startLine exceeds file length (replace mode)',
            () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New',
              'startLine': 10,
              'endLine': 12,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Error'));
          expect(text, contains('exceeds file length'));
        });

        test('rejects absolute paths', () async {
          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': '/absolute/path/file.txt',
              'content': 'New',
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Error'));
          expect(text, contains('No absolute paths allowed'));
        });

        test('rejects hidden files', () async {
          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': '$testDirName/.hidden_file',
              'content': 'New',
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Error'));
          expect(text, contains('No hidden files or directories allowed'));
        });

        test('rejects paths with hidden directories', () async {
          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': '$testDirName/normal/.hidden/file.txt',
              'content': 'New',
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Error'));
          expect(text, contains('No hidden files or directories allowed'));
        });
      });

      group('edge cases', () {
        test('handles empty file', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New content',
              'startLine': 1,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          expect(await file.readAsString(), 'New content\n');
        });

        test('handles file with only newlines', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('\n\n\n');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'Inserted',
              'startLine': 2,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          final content = await file.readAsString();
          expect(content.contains('Inserted'), isTrue);
        });

        test('handles file with trailing newline', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\n');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'New last',
              'startLine': 3,
              'endLine': 3,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));
        });

        test('preserves unicode content', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'Hej! 你好 🎉 émoji',
              'startLine': 2,
              'endLine': 2,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));

          expect(
              await file.readAsString(), 'Line 1\nHej! 你好 🎉 émoji\nLine 3');
        });
      });

      group('line number stripping', () {
        test('strips line numbers when editing file (overwrite mode)', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'L1: New line one\nL2: New line two',
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));
          expect(await file.readAsString(), 'New line one\nNew line two');
        });

        test('strips line numbers when inserting at line', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 3');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'L1: Inserted line',
              'startLine': 2,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));
          expect(await file.readAsString(), 'Line 1\nInserted line\nLine 3');
        });

        test('strips line numbers when replacing line range', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2\nLine 3\nLine 4');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'L1: Replacement A\nL2: Replacement B',
              'startLine': 2,
              'endLine': 3,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));
          expect(await file.readAsString(),
              'Line 1\nReplacement A\nReplacement B\nLine 4');
        });

        test('handles mixed content with and without line numbers', () async {
          final file = File('${testDir.path}/test_file.txt');
          await file.writeAsString('Line 1\nLine 2');

          final result = await fsEdit.callback(
            args: {
              'operation': 'edit-file',
              'path': testFilePath,
              'content': 'L1: Has line number\nNo line number\nL3: Also has line number',
              'startLine': 2,
            },
          );

          final text = (result.content.first as TextContent).text;
          expect(text, contains('Success'));
          expect(await file.readAsString(),
              'Line 1\nHas line number\nNo line number\nAlso has line number\nLine 2');
        });
      });
    });

    group('path validation', () {
      test('rejects paths outside allowed directories', () async {
        // Create FileSystemEdit with restricted allowed paths
        final allowedSubDir = Directory('${testDir.path}/allowed');
        await allowedSubDir.create();

        final restrictedFsEdit = FileSystemEdit(
          workingDir: Directory.current,
          sshKeyName: 'fake',
          provider: MockProvider(),
          allowedPaths: [allowedSubDir.path],
        );

        // Try to create in the parent directory (not allowed)
        final result = await restrictedFsEdit.callback(
          args: {
            'operation': 'create-directory',
            'path': '$testDirName/not_allowed_subdir',
          },
        );

        final text = (result.content.first as TextContent).text;
        expect(text, contains('Not allowed for'));
      });
    });
  });
}
