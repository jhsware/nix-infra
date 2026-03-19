import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'nar.dart';


/// Supported archive types for unpacking.
enum ArchiveType {
  tarGz,
  zip,
}

/// Unpacks archive bytes into a [NarNode] tree suitable for NAR serialization.
///
/// This replicates the behavior of `nix-prefetch-url --unpack`:
/// 1. Decompresses and extracts the archive
/// 2. If the result contains a single top-level directory, strips it
///    (uses the directory contents as the root)
/// 3. Returns the resulting tree as a [NarNode]
class ArchiveUnpacker {
  /// Unpacks archive bytes and returns a [NarNode] tree.
  ///
  /// [archiveBytes] - the raw archive file bytes
  /// [type] - the archive format (tar.gz or zip)
  ///
  /// The returned tree matches what `nix-prefetch-url --unpack` would produce:
  /// if the archive has a single top-level directory, it is stripped.
  static NarNode unpack(Uint8List archiveBytes, ArchiveType type) {
    final Archive archive;

    switch (type) {
      case ArchiveType.tarGz:
        final decompressed = GZipDecoder().decodeBytes(archiveBytes);
        archive = TarDecoder().decodeBytes(decompressed);
        break;
      case ArchiveType.zip:
        archive = ZipDecoder().decodeBytes(archiveBytes);
        break;
    }

    return _buildTree(archive);
  }

  /// Detects archive type from URL.
  static ArchiveType detectType(String url) {
    final lower = url.toLowerCase();
    if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      return ArchiveType.tarGz;
    } else if (lower.endsWith('.zip')) {
      return ArchiveType.zip;
    }
    // Default to tar.gz for GitHub archive URLs
    if (lower.contains('github.com') && lower.contains('/archive/')) {
      return ArchiveType.tarGz;
    }
    throw ArgumentError('Cannot detect archive type from URL: $url');
  }

  /// Builds a [NarNode] tree from archive entries, stripping the top-level
  /// directory if it is the only entry (matching nix-prefetch-url --unpack behavior).
  static NarNode _buildTree(Archive archive) {
    // Build an in-memory directory tree
    final root = NarDirectory.empty();

    for (final entry in archive) {
      final path = _normalizePath(entry.name);
      if (path.isEmpty) continue;

      final parts = path.split('/');

      if (entry.isFile || entry.isSymbolicLink) {
        // Navigate/create parent directories
        var current = root;
        for (var i = 0; i < parts.length - 1; i++) {
          final dirName = parts[i];
          if (dirName.isEmpty) continue;
          current = _getOrCreateDir(current, dirName);
        }

        final fileName = parts.last;
        if (fileName.isEmpty) continue;

        if (entry.isSymbolicLink) {
          final target = entry.symbolicLink ?? '';
          current.entries[fileName] = NarSymlink(target);
        } else {
          // Regular file
          final contents = entry.content as List<int>;
          final isExecutable = _isExecutable(entry.mode);
          current.entries[fileName] = NarFile(
            Uint8List.fromList(contents),
            executable: isExecutable,
          );
        }

      } else if (entry.isDirectory) {
        // Create directory entries in the tree
        var current = root;
        for (final part in parts) {
          if (part.isEmpty) continue;
          current = _getOrCreateDir(current, part);
        }
      }
    }

    // Strip single top-level directory (matching nix-prefetch-url --unpack)
    return _maybeStripRoot(root);
  }

  /// If the directory has exactly one entry and it's a directory,
  /// return that inner directory (stripping the root).
  /// This matches the behavior of nix-prefetch-url --unpack.
  static NarNode _maybeStripRoot(NarDirectory dir) {
    if (dir.entries.length == 1) {
      final singleEntry = dir.entries.values.first;
      if (singleEntry is NarDirectory) {
        return singleEntry;
      }
    }
    return dir;
  }

  /// Gets or creates a subdirectory in the given parent.
  static NarDirectory _getOrCreateDir(NarDirectory parent, String name) {
    final existing = parent.entries[name];
    if (existing is NarDirectory) {
      return existing;
    }
    final newDir = NarDirectory.empty();
    parent.entries[name] = newDir;
    return newDir;
  }

  /// Normalizes a path by removing leading ./ and trailing /
  static String _normalizePath(String path) {
    var normalized = path;
    // Remove leading ./
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    // Remove trailing /
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// Checks if a file mode indicates executable permission.
  /// In tar archives, mode 0755 or any user-execute bit set means executable.
  static bool _isExecutable(int mode) {
    // User execute bit (0100 in octal = 64 in decimal)
    return (mode & 64) != 0;
  }
}
