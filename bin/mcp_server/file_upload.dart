import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/ssh.dart';

class FileUpload extends McpTool {
  static const description =
      'Upload one or more local files or directories to a remote node over SFTP';

  static const inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description': 'Node name to upload files to.',
    },
    'local_path': {
      'type': 'string',
      'description':
          'Local file or directory path to upload. Use comma-separated values for multiple paths.',
    },
    'remote_path': {
      'type': 'string',
      'description':
          'Remote destination path. Defaults to /root/uploads if not specified.',
    },
  };

  FileUpload({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  @override
  Future<CallToolResult> callback({args, extra}) async {
    final target = args!['target'] as String;
    final localPath = args['local_path'] as String;
    final remotePath = (args['remote_path'] as String?) ?? '/root/uploads';

    final targets = target.split(',');
    final nodes = await provider.getServers(only: targets);

    if (nodes.isEmpty) {
      return CallToolResult.fromContent(
        content: [
          TextContent(text: 'ERROR: Node(s) not found: $targets'),
        ],
      );
    }

    final localPaths =
        localPath.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty);

    // Validate local paths exist
    for (final path in localPaths) {
      final entityType = FileSystemEntity.typeSync(path);
      if (entityType == FileSystemEntityType.notFound) {
        return CallToolResult.fromContent(
          content: [
            TextContent(text: 'ERROR: Local path not found: $path'),
          ],
        );
      }
    }

    final List<String> results = [];

    for (final node in nodes) {
      final List<String> uploadedFiles = [];

      try {
        final connection = await waitAndGetSshConnection(node);
        final sshClient = await getSshClient(workingDir, node, connection);
        final sftp = await sshClient.sftp();

        try {
          await sftpMkDirRecursive(sftp, remotePath);

          final queue = <Map<String, dynamic>>[];
          for (final path in localPaths) {
            FileSystemEntity entity =
                FileSystemEntity.typeSync(path) ==
                        FileSystemEntityType.directory
                    ? Directory(path)
                    : File(path);

            final relPath = entity.path.split("/").last;
            queue.add({
              "relPath": relPath,
              "entity": entity,
            });
          }

          while (queue.isNotEmpty) {
            final item = queue.removeAt(0);
            final entity = item["entity"] as FileSystemEntity;
            final relPath = item["relPath"] as String;

            if (entity is Directory) {
              await sftpMkDir(sftp, '$remotePath/$relPath');
              queue.addAll(entity.listSync().map((e) {
                final newRelPath = "$relPath/${e.path.split("/").last}";
                return {
                  "relPath": newRelPath,
                  "entity": e,
                };
              }));
              continue;
            }

            await sftpSend(sftp, entity.path, '$remotePath/$relPath');
            uploadedFiles.add(relPath);
          }

          sftp.close();
        } finally {
          sshClient.close();
        }

        results.add(
            '${node.name}: Uploaded ${uploadedFiles.length} file(s) to $remotePath\n'
            '  Files: ${uploadedFiles.join(", ")}');
      } catch (e) {
        results.add('${node.name}: ERROR - $e');
      }
    }

    return CallToolResult.fromContent(
      content: [
        TextContent(text: results.join('\n\n')),
      ],
    );
  }
}
