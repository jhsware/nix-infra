import 'dart:io';

import 'package:path/path.dart' as p;

// The rule for a local path that the caller of an MCP tool gives: a path
// inside the project folder (`--project-dir`, the `workingDir` of the tool),
// never a path elsewhere on the machine of the MCP server
// (docs/design/ssh_agent_keys.md §9). Used by `file-upload`.
//
// A path is accepted when, in this order:
// 1. it is not empty;
// 2. it is relative (a `~` is not expanded);
// 3. no segment starts with `.` (no `..`, `.env`, `.git`, `.ssh`);
// 4. its first segment is not one of [protectedProjectFolders];
// 5. it exists;
// 6. its real path (symbolic links resolved) is the real path of the
//    project folder or inside it, compared by path segments and not as a
//    string prefix (`/p/proj2` is not inside `/p/proj`), and, relative to
//    the project folder, has no hidden segment and does not start with one
//    of [protectedProjectFolders]. So a symbolic link inside the project
//    that leads out of it, or to `.env` or `ssh/`, is refused too.
//
// The texts of the errors name only the path that the caller gave (or a
// path below it, inside the project folder), never a resolved path.

/// The folders of the project that hold the private key files of the
/// classic way (`ssh/<SSH_KEY>`) and the encrypted secrets (`secrets/`).
/// They are inside the project folder and still refused.
const protectedProjectFolders = {'ssh', 'secrets'};

/// A local path that the rule refuses. [message] is the short reason.
class ProjectPathException implements Exception {
  const ProjectPathException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The real path of [projectDir]: absolute, with its symbolic links
/// resolved (the project folder itself may be below a link, such as `/tmp`
/// or `/var` on macOS).
String projectRealPath(Directory projectDir) {
  try {
    return projectDir.absolute.resolveSymbolicLinksSync();
  } on FileSystemException {
    throw const ProjectPathException('The project folder cannot be read');
  }
}

/// The real path of [input], a path relative to [projectDir], when the rule
/// accepts it. Throws a [ProjectPathException] with the reason otherwise.
String resolveProjectPath(Directory projectDir, String input) {
  final path = input.trim();
  if (path.isEmpty) {
    throw const ProjectPathException('Empty local path');
  }
  if (p.isAbsolute(path)) {
    throw ProjectPathException('No absolute paths allowed: $path');
  }
  final segments = p.split(path);
  if (_hasHiddenSegment(segments)) {
    throw ProjectPathException('No hidden files or directories allowed: $path');
  }
  if (protectedProjectFolders.contains(segments.first)) {
    throw ProjectPathException(_protectedMessage(path));
  }
  return checkProjectEntry(projectRealPath(projectDir),
      p.join(projectDir.absolute.path, p.normalize(path)), path);
}

/// The real path of [path] when it is an entry of the project whose real
/// path is [root] that the rule accepts (step 5 and 6 of the rule). [path]
/// is absolute and may be, or pass through, a symbolic link. [shown] is the
/// path that the errors name: the path that the caller gave, or a path
/// below it.
///
/// Throws a [ProjectPathException] with the reason otherwise.
String checkProjectEntry(String root, String path, String shown) {
  final String real;
  try {
    real = File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    // Missing, a broken symbolic link, or a loop of links. The text of the
    // exception holds the path: not passed on.
    throw ProjectPathException('Local path not found: $shown');
  }
  if (real == root) return real;
  if (!p.isWithin(root, real)) {
    throw ProjectPathException('Path is outside the project folder: $shown');
  }
  final segments = p.split(p.relative(real, from: root));
  if (_hasHiddenSegment(segments)) {
    throw ProjectPathException(
        'No hidden files or directories allowed: $shown');
  }
  if (protectedProjectFolders.contains(segments.first)) {
    throw ProjectPathException(_protectedMessage(shown));
  }
  return real;
}

bool _hasHiddenSegment(List<String> segments) =>
    segments.any((s) => s.startsWith('.'));

String _protectedMessage(String shown) =>
    'No files from ssh/ or secrets/ allowed: $shown';
