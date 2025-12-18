import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';
import 'utils/line_endings.dart';

class FileSystem extends McpTool {
  static const description = 'Read configuration of cluster project.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'operation': {
      'type': 'string',
      'description':
          'list-content -- recursively list configuration files and directories in cluster project'
              'read-file -- read the content of a file at given path'
              'read-files -- read the content of several files provided as comma separated list of paths'
              'search-text -- recursively search for text pattern (regex) in files and return matches as JSON',
      'enum': [
        'list-content',
        'read-file',
        'read-files',
        'search-text',
      ],
    },
    'path': {
      'type': 'string',
      'description':
          'Relative path to file or directory, comma separated list if applicable'
    },
    'pattern': {
      'type': 'string',
      'description':
          'Regex pattern to search for (required for search-text operation)'
    },
    'file-pattern': {
      'type': 'string',
      'description':
          'Optional glob pattern to filter files (e.g., "*.dart", "*.nix"). Default: all files'
    },
    'case-sensitive': {
      'type': 'boolean',
      'description': 'Whether search is case-sensitive. Default: true'
    },
  };

  final List<String> allowedPaths;

  FileSystem({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
    required this.allowedPaths,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final operation = args!['operation'];
    final path = args!['path'] ?? '.';

    String result = 'No operation specified';

    switch (operation) {
      case 'list-content':
        result = await listContent(path: path);
        break;
      case 'read-file':
        result = await readFile(path: path);
        break;
      case 'read-files':
        result = await readFiles(paths: path.split(','));
        break;
      case 'search-text':
        final pattern = args!['pattern'];
        final filePattern = args!['file-pattern'];
        final caseSensitive = args!['case-sensitive'] ?? true;
        result = await searchText(
          path: path,
          pattern: pattern,
          filePattern: filePattern,
          caseSensitive: caseSensitive,
        );
        break;
    }

    return CallToolResult.fromContent(
      content: [
        TextContent(
          text: result,
        ),
      ],
    );
  }

  Future<String> listContent({required String path}) async {
    if (path.toString().startsWith('/')) {
      return 'No absolute paths allowed';
    }

    final dirPath = getAbsolutePath(path);
    if (!isAllowedPath(allowedPaths, dirPath)) {
      return 'Not allowed for: $dirPath';
    }

    final directory = Directory(dirPath);
    if (!await directory.exists()) {
      return 'Directory not found: $path';
    }

    final List<FileSystemEntity> allContents = await directory.list().toList();
    final outp = [];
    while (allContents.isNotEmpty) {
      final List<FileSystemEntity> tmp = List.from(allContents);
      allContents.clear();

      final fut = tmp.map((item) async {
        final relPath = item.path.substring(Directory.current.path.length + 1);

        // Omit hidden files
        if (isHiddenPath(relPath)) return '';

        final s = await item.stat();
        if (s.type == FileSystemEntityType.directory) {
          allContents.addAll(await Directory(item.path).list().toList());
        }
        return '$relPath -- size: ${s.size}; type: ${s.type}';
      });
      outp.addAll(await Future.wait(fut));
    }
    return outp.join('\n');
  }

  Future<String> readFile({required String path}) async {
    if (path.toString().startsWith('/')) {
      return 'No absolute paths allowed';
    }

    if (path.split('/').any((s) => s.startsWith('.'))) {
      return 'No hidden files or directories allowed';
    }

    final filePath = getAbsolutePath(path);
    if (!isAllowedPath(allowedPaths, filePath)) {
      return 'Not allowed for: $path';
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return 'File not found: $path';
    }

    final content = await file.readAsString();
    final normalized = normalizeLineEndings(content);
    return addLineNumbers(normalized);
  }

  Future<String> readFiles({required List<String> paths}) async {
    final List<String> outp = [];

    for (final path in paths) {
      if (path.toString().startsWith('/')) {
        outp.add('$path: No absolute paths allowed');
        continue;
      }

      if (path.split('/').any((s) => s.startsWith('.'))) {
        outp.add('$path: No hidden files or directories allowed');
        continue;
      }

      final filePath = getAbsolutePath(path);
      if (!isAllowedPath(allowedPaths, filePath)) {
        outp.add('Not allowed for: $path');
        continue;
      }

      final file = File(filePath);
      if (!await file.exists()) {
        outp.add('File not found: $path');
        continue;
      }

      final content = await file.readAsString();
      final normalized = normalizeLineEndings(content);
      outp.addAll(['$path:', addLineNumbers(normalized)]);
    }

    return outp.join('\n');
  }

  /// Search for text pattern recursively in files.
  ///
  /// Uses `grep` command for maximum performance. Falls back to Dart
  /// implementation if grep is not available.
  ///
  /// Returns JSON array of matches:
  /// ```json
  /// [
  ///   {"file": "path/to/file.dart", "line": 42, "content": "matching line content"},
  ///   ...
  /// ]
  /// ```
  Future<String> searchText({
    required String path,
    required String? pattern,
    String? filePattern,
    bool caseSensitive = true,
  }) async {
    // Validate inputs
    if (pattern == null || pattern.isEmpty) {
      return 'Error: pattern is required for search-text operation';
    }

    if (path.toString().startsWith('/')) {
      return 'Error: No absolute paths allowed';
    }

    if (path.split('/').any((s) => s.startsWith('.'))) {
      return 'Error: No hidden files or directories allowed';
    }

    final dirPath = getAbsolutePath(path);
    if (!isAllowedPath(allowedPaths, dirPath)) {
      return 'Error: Not allowed for: $path';
    }

    final directory = Directory(dirPath);
    if (!await directory.exists()) {
      return 'Error: Directory not found: $path';
    }

    // Validate regex pattern
    try {
      RegExp(pattern, caseSensitive: caseSensitive);
    } catch (e) {
      return 'Error: Invalid regex pattern: $e';
    }

    // Try using grep for maximum performance
    try {
      return await _searchWithGrep(
        dirPath: dirPath,
        basePath: path,
        pattern: pattern,
        filePattern: filePattern,
        caseSensitive: caseSensitive,
      );
    } catch (e) {
      // Fall back to Dart implementation
      return await _searchWithDart(
        dirPath: dirPath,
        basePath: path,
        pattern: pattern,
        filePattern: filePattern,
        caseSensitive: caseSensitive,
      );
    }
  }

  /// Search using grep command (fastest method)
  Future<String> _searchWithGrep({
    required String dirPath,
    required String basePath,
    required String pattern,
    String? filePattern,
    bool caseSensitive = true,
  }) async {
    final args = <String>[
      '-r', // Recursive
      '-n', // Show line numbers
      '-E', // Extended regex
      '--include=${filePattern ?? '*'}', // File pattern filter
      if (!caseSensitive) '-i', // Case insensitive
      pattern,
      dirPath,
    ];

    final result = await Process.run('grep', args);

    if (result.exitCode != 0 && result.exitCode != 1) {
      // Exit code 1 means no matches found (not an error)
      throw Exception('grep failed: ${result.stderr}');
    }

    final stdout = result.stdout as String;
    if (stdout.isEmpty) {
      return '[]'; // No matches
    }

    final matches = <Map<String, dynamic>>[];
    final lines = stdout.split('\n');
    final projectRoot = Directory.current.path;

    for (final line in lines) {
      if (line.isEmpty) continue;

      // Parse grep output format: /path/to/file:linenum:content
      // Handle files with colons in name by finding the line number position
      final firstColonIdx = line.indexOf(':');
      if (firstColonIdx == -1) continue;

      final afterFirstColon = line.substring(firstColonIdx + 1);
      final secondColonIdx = afterFirstColon.indexOf(':');
      if (secondColonIdx == -1) continue;

      final filePath = line.substring(0, firstColonIdx);
      final lineNumStr = afterFirstColon.substring(0, secondColonIdx);
      final content = afterFirstColon.substring(secondColonIdx + 1);

      final lineNum = int.tryParse(lineNumStr);
      if (lineNum == null) continue;

      // Convert to relative path
      String relPath = filePath;
      if (filePath.startsWith(projectRoot)) {
        relPath = filePath.substring(projectRoot.length + 1);
      }

      // Skip hidden files
      if (relPath.split('/').any((s) => s.startsWith('.'))) {
        continue;
      }

      matches.add({
        'file': relPath,
        'line': lineNum,
        'content': content.trim(),
      });
    }

    return jsonEncode(matches);
  }

  /// Fallback Dart implementation for systems without grep
  Future<String> _searchWithDart({
    required String dirPath,
    required String basePath,
    required String pattern,
    String? filePattern,
    bool caseSensitive = true,
  }) async {
    final regex = RegExp(pattern, caseSensitive: caseSensitive);
    final fileRegex = filePattern != null ? _globToRegex(filePattern) : null;

    final matches = <Map<String, dynamic>>[];
    final directory = Directory(dirPath);
    final projectRoot = Directory.current.path;

    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final filePath = entity.path;
      final fileName = basename(filePath);

      // Skip hidden files and directories
      final relPath = filePath.startsWith(projectRoot)
          ? filePath.substring(projectRoot.length + 1)
          : filePath;

      if (relPath.split('/').any((s) => s.startsWith('.'))) {
        continue;
      }

      // Apply file pattern filter
      if (fileRegex != null && !fileRegex.hasMatch(fileName)) {
        continue;
      }

      // Skip binary files (simple heuristic)
      try {
        final content = await entity.readAsString();
        final lines = content.split('\n');

        for (var i = 0; i < lines.length; i++) {
          if (regex.hasMatch(lines[i])) {
            matches.add({
              'file': relPath,
              'line': i + 1, // 1-indexed
              'content': lines[i].trim(),
            });
          }
        }
      } catch (e) {
        // Skip files that can't be read as text (binary files, etc.)
        continue;
      }
    }

    return jsonEncode(matches);
  }

  /// Convert glob pattern to regex
  RegExp _globToRegex(String glob) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      switch (c) {
        case '*':
          buffer.write('.*');
          break;
        case '?':
          buffer.write('.');
          break;
        case '.':
        case '(':
        case ')':
        case '[':
        case ']':
        case '{':
        case '}':
        case '^':
        case r'$':
        case '|':
        case r'\':
        case '+':
          buffer.write('\\$c');
          break;
        default:
          buffer.write(c);
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }
}

String getAbsolutePath(String path) {
  final projectRootPath = Directory.current.absolute.path;
  final outp = path == '.' ? projectRootPath : '$projectRootPath/$path';
  return normalize(outp);
}

bool isHiddenPath(String path) {
  return path.split('/').last.startsWith('.');
}

bool isAllowedPath(List<String> allowedPaths, String path) {
  return allowedPaths.any((String root) => path.startsWith(root));
}
