import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'filesystem.dart';
import 'mcp_tool.dart';

class FileSystemEdit extends McpTool {
  static const description = 'Read configuration of cluster project.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'operation': {
      'type': 'string',
      'description': '''
create-directory -- create a directory
create-file -- create a new file
edit-file -- edit the content of a file
''',
      'enum': [
        'create-directory',
        'create-file',
        'edit-file',
      ],
    },
    'path': {
      'type': 'string',
      'description': 'Relative path to file, comma separated list if applicable'
    },
    'content': {
      'type': 'string',
      'description':
          'Content to write to file (required for create-file and edit-file operations)'
    },
    'startLine': {
      'type': 'integer',
      'description':
        'Optional starting line number (1-indexed) for edit-file operation:'
        '- If not provided: overwrites the entire file with content'
        '- If provided without endLine: inserts content at this line, pushing existing content down'
        '- If provided with endLine: replaces lines from startLine to endLine (inclusive) with content'
    },
    'endLine': {
      'type': 'integer',
      'description':
          'Optional ending line number (1-indexed, inclusive) for edit-file operation. Used with startLine to replace a range of lines.'
    },
  };

  final List<String> allowedPaths;

  FileSystemEdit({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
    required this.allowedPaths,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final operation = args!['operation'];
    final path = args!['path'] ?? '.';
    final content = args!['content'];
    final startLine = args!['startLine'];
    final endLine = args!['endLine'];

    String result = 'No operation specified';

    switch (operation) {
      case 'create-directory':
        result = await createDirectory(path: path);
        break;
      case 'create-file':
        result = await createFile(path: path, content: content);
        break;
      case 'edit-file':
        result = await editFile(
          path: path,
          content: content,
          startLine: startLine,
          endLine: endLine,
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

  Future<String> createDirectory({required String path}) async {
    if (path.toString().startsWith('/')) {
      return 'No absolute paths allowed';
    }

    if (path.split('/').any((s) => s.startsWith('.'))) {
      return 'No hidden files or directories allowed';
    }

    final dirPath = getAbsolutePath(path);
    if (!isAllowedPath(allowedPaths, dirPath)) {
      return 'Not allowed for: $path';
    }

    final directory = Directory(dirPath);
    if (await directory.exists()) {
      return 'Directory exists: $path';
    }

    await directory.create(recursive: true);

    return 'Created directory: $path';
  }

  Future<String> createFile({
    required String path,
    String? content,
  }) async {
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
    if (await file.exists()) {
      return 'File exists: $filePath';
    }

    await file.create(recursive: true);

    if (content != null) {
      await file.writeAsString(content);
    }

    return 'Created file: $path';
  }

  /// Edit the content of a file.
  ///
  /// Supports three modes of operation:
  /// - **Overwrite entire file**: If [startLine] is not provided, the entire
  ///   file content is replaced with [content].
  /// - **Insert at line**: If only [startLine] is provided (no [endLine]),
  ///   [content] is inserted at the specified line, pushing existing content down.
  /// - **Replace line range**: If both [startLine] and [endLine] are provided,
  ///   lines from [startLine] to [endLine] (inclusive) are replaced with [content].
  ///
  /// Line numbers are 1-indexed. Returns an error message if the path is invalid
  /// or the file doesn't exist.
  Future<String> editFile({
    required String path,
    String? content,
    int? startLine,
    int? endLine,
  }) async {
    // Validate path
    if (path.toString().startsWith('/')) {
      return 'Error: No absolute paths allowed';
    }

    if (path.split('/').any((s) => s.startsWith('.'))) {
      return 'Error: No hidden files or directories allowed';
    }

    final filePath = getAbsolutePath(path);
    if (!isAllowedPath(allowedPaths, filePath)) {
      return 'Error: Not allowed for: $path';
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return 'Error: File not found: $path';
    }

    // Validate content
    if (content == null) {
      return 'Error: Content is required for edit-file operation';
    }

    // Validate line numbers
    if (startLine != null && startLine < 1) {
      return 'Error: startLine must be >= 1 (1-indexed)';
    }

    if (endLine != null && endLine < 1) {
      return 'Error: endLine must be >= 1 (1-indexed)';
    }

    if (endLine != null && startLine == null) {
      return 'Error: endLine requires startLine to be specified';
    }

    if (startLine != null && endLine != null && endLine < startLine) {
      return 'Error: endLine must be >= startLine';
    }

    // Read existing file content
    final existingContent = await file.readAsString();
    final lines = existingContent.split('\n');
    final newContentLines = content.split('\n');

    String resultContent;
    String operationDescription;

    if (startLine == null) {
      // Mode 1: Overwrite entire file
      resultContent = content;
      operationDescription = 'Overwrote entire file';
    } else if (endLine == null) {
      // Mode 2: Insert at line (push existing content down)
      final insertIndex = startLine - 1; // Convert to 0-indexed

      if (insertIndex > lines.length) {
        // If inserting beyond the file, pad with empty lines
        final padding = List.filled(insertIndex - lines.length, '');
        lines.addAll(padding);
      }

      lines.insertAll(insertIndex, newContentLines);
      resultContent = lines.join('\n');
      operationDescription =
          'Inserted ${newContentLines.length} line(s) at line $startLine';
    } else {
      // Mode 3: Replace line range (startLine to endLine inclusive)
      final startIndex = startLine - 1; // Convert to 0-indexed
      final endIndex = endLine; // endLine is inclusive, so we use it directly for removeRange

      if (startIndex >= lines.length) {
        return 'Error: startLine ($startLine) exceeds file length (${lines.length} lines)';
      }

      // Clamp endIndex to file length
      final actualEndIndex = endIndex > lines.length ? lines.length : endIndex;

      // Remove the lines in the range
      lines.removeRange(startIndex, actualEndIndex);

      // Insert new content at the start position
      lines.insertAll(startIndex, newContentLines);

      resultContent = lines.join('\n');
      final replacedCount = actualEndIndex - startIndex;
      operationDescription =
          'Replaced $replacedCount line(s) (lines $startLine-${startIndex + replacedCount}) with ${newContentLines.length} line(s)';
    }

    // Write the result back to the file
    await file.writeAsString(resultContent);

    return 'Success: $operationDescription in $path';
  }
}
