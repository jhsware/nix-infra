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

    String result = 'No operation specified';

    switch (operation) {
      case 'create-directory':
        result = await createDirectory(path: path);
        break;
      case 'create-file':
        result = await createFile(path: path);
        break;
      case 'edit-file':
        result = await editFile(path: path);
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

  Future<String> createFile({required String path}) async {
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

    return 'Created file: $path';
  }

  Future<String> editFile({required String path}) async {
    final List<String> outp = [];

    if (path.toString().startsWith('/')) {
      outp.add('$path: No absolute paths allowed');
    }

    if (path.split('/').any((s) => s.startsWith('.'))) {
      outp.add('$path: No hidden files or directories allowed');
    }

    final filePath = getAbsolutePath(path);
    if (!isAllowedPath(allowedPaths, filePath)) {
      return 'Not allowed for: $path';
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return 'File not found: $path';
    }


    return await file.readAsString();
  }
}
