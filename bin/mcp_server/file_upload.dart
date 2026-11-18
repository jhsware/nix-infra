import 'dart:io';
import 'package:dartssh2/dartssh2.dart' show SftpClient;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'mcp_tool.dart';
import 'utils/project_path.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/ssh_identity.dart';

class FileUpload extends McpTool {
  static const description =
      'Upload one or more files or directories of the project folder to a '
      'remote node over SFTP. Only paths inside the project folder are '
      'uploaded: absolute paths, hidden files and folders, the folders ssh/ '
      'and secrets/, and symbolic links that leave the project folder are '
      'refused.';

  static const inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description': 'Node name to upload files to.',
    },
    'local_path': {
      'type': 'string',
      'description':
          'Path relative to the project folder; files outside the project '
              'folder, hidden files, the folders ssh/ and secrets/ and '
              'absolute paths are refused. Use comma-separated values for '
              'multiple paths.',
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
    super.sshConnectTimeout,
  });

  @override
  Future<CallToolResult> callback({args, extra}) async {
    final target = args!['target'] as String;
    final localPath = args['local_path'] as String;
    final remotePath = (args['remote_path'] as String?) ?? '/root/uploads';

    // Every local path, and every entry of a folder, is checked before a
    // machine is looked up or contacted: one refused path refuses the whole
    // call.
    final List<UploadEntry> plan;
    try {
      plan = uploadPlan(workingDir, localPath.split(','));
    } on ProjectPathException catch (e) {
      return CallToolResult.fromContent(
        content: [
          TextContent(text: 'ERROR: ${e.message}'),
        ],
      );
    }

    final targets = target.split(',');
    final nodes = await provider.getServers(only: targets);

    if (nodes.isEmpty) {
      return CallToolResult.fromContent(
        content: [
          TextContent(text: 'ERROR: Node(s) not found: $targets'),
        ],
      );
    }

    final List<String> results = [];

    for (final node in nodes) {
      final List<String> uploadedFiles = [];

      try {
        // The key first: a machine whose key is not available is not
        // contacted.
        final identities = await identitiesOf(workingDir, node,
            agentTimeout: sshConnectTimeout);
        final connection =
            await waitAndGetSshConnection(node, totalBudget: sshConnectTimeout);
        final sshClient = await getSshClient(workingDir, node, connection,
            timeout: sshConnectTimeout, identities: identities);
        SftpClient? sftp;

        try {
          sftp = await sshClient.sftp();
          await sftpMkDirRecursive(sftp, remotePath);
          uploadedFiles.addAll(await sendUploadPlan(sftp, plan, remotePath));
        } finally {
          await closeSshQuietly(sshClient, sftp: sftp);
        }

        results.add(
            '${node.name}: Uploaded ${uploadedFiles.length} file(s) to $remotePath\n'
            '  Files: ${uploadedFiles.join(", ")}');
      } catch (e) {
        // An error about the key of the machine gives its text of design
        // §7, which names no path (of a key file, the key map or the
        // socket of the agent).
        results.add('${node.name}: ERROR - ${sshKeyErrorMessage(node, e) ?? e}');
      }
    }

    return CallToolResult.fromContent(
      content: [
        TextContent(text: results.join('\n\n')),
      ],
    );
  }
}

/// One step of an upload: a folder to make, or a file to send.
class UploadEntry {
  /// The folder `<remote_path>/<remoteRelPath>` to make.
  const UploadEntry.folder(this.remoteRelPath) : localPath = null;

  /// The file [localPath] (a real path inside the project folder) to send
  /// to `<remote_path>/<remoteRelPath>`.
  const UploadEntry.file(String this.localPath, this.remoteRelPath);

  /// The real path of the local file; null for a folder.
  final String? localPath;

  /// The path below the remote destination path.
  final String remoteRelPath;

  bool get isFolder => localPath == null;

  @override
  String toString() =>
      isFolder ? 'folder $remoteRelPath' : 'file $remoteRelPath <- $localPath';
}

/// The upload of the local paths [inputs], relative to [projectDir], as
/// `file-upload` made it before: each path under its last segment, then the
/// content of each folder, breadth first, each entry under its own name (a
/// symbolic link under the name of the link, with the content of what it
/// points to). Empty inputs are left out.
///
/// Every path, and every entry of a folder, passes the rule of
/// utils/project_path.dart before anything is sent:
/// - an entry of a folder whose name starts with `.` (`.git`, `.env`) is
///   skipped, as `configuration-files` hides it;
/// - any other entry that the rule refuses (a symbolic link that leaves the
///   project folder or leads to a hidden file or into ssh/ or secrets/, a
///   broken link), a link back to a folder above it, and anything that is
///   neither a file nor a folder refuse the whole upload.
///
/// Throws a [ProjectPathException] with the reason; its text names only the
/// path the caller gave or a path below it inside the project folder.
List<UploadEntry> uploadPlan(Directory projectDir, Iterable<String> inputs) {
  final paths =
      inputs.map((i) => i.trim()).where((i) => i.isNotEmpty).toList();
  if (paths.isEmpty) {
    throw const ProjectPathException('No local path given');
  }

  final root = projectRealPath(projectDir);
  final queue = <_PlanItem>[
    for (final path in paths)
      _PlanItem(
        real: resolveProjectPath(projectDir, path),
        remote: p.basename(p.normalize(path)),
        shown: p.normalize(path),
        ancestors: const [],
      ),
  ];

  final plan = <UploadEntry>[];
  while (queue.isNotEmpty) {
    final item = queue.removeAt(0);
    final type = FileSystemEntity.typeSync(item.real);

    if (type == FileSystemEntityType.file) {
      plan.add(UploadEntry.file(item.real, item.remote));
      continue;
    }
    if (type != FileSystemEntityType.directory) {
      throw ProjectPathException('Not a file or folder: ${item.shown}');
    }
    // A symbolic link to the folder itself or to a folder above it.
    if (item.ancestors.contains(item.real)) {
      throw ProjectPathException('Symbolic link loop: ${item.shown}');
    }

    plan.add(UploadEntry.folder(item.remote));
    for (final entry in _entriesOf(item)) {
      final name = p.basename(entry.path);
      if (name.startsWith('.')) continue;
      final shown = '${item.shown}/$name';
      queue.add(_PlanItem(
        real: checkProjectEntry(root, entry.path, shown),
        remote: '${item.remote}/$name',
        shown: shown,
        ancestors: [...item.ancestors, item.real],
      ));
    }
  }
  return plan;
}

/// Sends [plan] over [sftp] below [remotePath], in its order, and returns
/// the paths of the files sent, relative to [remotePath].
Future<List<String>> sendUploadPlan(
    SftpClient sftp, List<UploadEntry> plan, String remotePath) async {
  final sent = <String>[];
  for (final entry in plan) {
    final remote = '$remotePath/${entry.remoteRelPath}';
    final local = entry.localPath;
    if (local == null) {
      await sftpMkDir(sftp, remote);
    } else {
      await sftpSend(sftp, local, remote);
      sent.add(entry.remoteRelPath);
    }
  }
  return sent;
}

/// A path of an upload in the check phase of [uploadPlan].
class _PlanItem {
  const _PlanItem({
    required this.real,
    required this.remote,
    required this.shown,
    required this.ancestors,
  });

  /// The real path (symbolic links resolved), inside the project folder.
  final String real;

  /// The path below the remote destination path.
  final String remote;

  /// The path that the errors name: the input, or a path below it.
  final String shown;

  /// The real paths of the folders above it in this upload.
  final List<String> ancestors;
}

/// The entries of the folder of [item]; symbolic links are not followed.
List<FileSystemEntity> _entriesOf(_PlanItem item) {
  try {
    return Directory(item.real).listSync(followLinks: false);
  } on FileSystemException {
    // The text of the exception holds the real path: not passed on.
    throw ProjectPathException('Cannot read folder: ${item.shown}');
  }
}
