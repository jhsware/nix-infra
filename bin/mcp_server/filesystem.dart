import 'dart:io';
import 'package:path/path.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';

class FileSystem extends McpTool {
  static const description = 'Read configuration of cluster project.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'operation': {
      'type': 'string',
      'description': '''
list-content -- recursively list configuration files and directories in cluster project
read-file -- read the content of a file at given path
read-files -- read the content of several files provided as comma separated list of paths
''',
      'enum': [
        'list-content',
        'read-file',
        'read-files',
      ],
    },
    'path': {
      'type': 'string',
      'description': 'Relative path to file, comma separated list if applicable'
    },
  };

  FileSystem({
    required super.workingDir,
    required super.sshKeyName,
    required super.hcloudToken,
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

    final directory = Directory(getAbsolutePath(path));
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
    final file = File(filePath);
    if (!await file.exists()) {
      return 'File not found: $filePath';
    }

    return await file.readAsString();
  }

  Future<String> readFiles({required List<String> paths}) async {
    final List<String> outp = [];

    for (final path in paths) {
      if (path.toString().startsWith('/')) {
        outp.add('$path: No absolute paths allowed');
      }

      if (path.split('/').any((s) => s.startsWith('.'))) {
        outp.add('$path: No hidden files or directories allowed');
      }

      final file = File(getAbsolutePath(path));
      if (!await file.exists()) {
        outp.add('$path: File not found');
      }

      outp.addAll(['$path:', await file.readAsString()]);
    }

    return outp.join('\n');
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
