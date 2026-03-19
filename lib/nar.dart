import 'dart:convert';
import 'dart:typed_data';

/// Represents a file system object for NAR serialization.
///
/// NAR (Nix Archive) is a deterministic serialization format used by Nix
/// to hash directory trees. Unlike tar/zip, NAR produces identical output
/// for identical directory contents regardless of filesystem metadata like
/// timestamps or ownership.
sealed class NarNode {
  const NarNode();
}

/// A regular file in the NAR tree.
class NarFile extends NarNode {
  final Uint8List contents;
  final bool executable;

  const NarFile(this.contents, {this.executable = false});
}

/// A directory in the NAR tree.
class NarDirectory extends NarNode {
  final Map<String, NarNode> entries;

  const NarDirectory([Map<String, NarNode>? entries])
      : entries = entries ?? const {};

  NarDirectory.empty() : entries = {};
}

/// A symbolic link in the NAR tree.
class NarSymlink extends NarNode {
  final String target;

  const NarSymlink(this.target);
}

/// Serializes a [NarNode] tree to the Nix Archive (NAR) binary format.
///
/// The NAR format is defined as:
/// ```
/// nar = str("nix-archive-1"), nar-obj
/// nar-obj = str("("), nar-obj-inner, str(")")
/// nar-obj-inner = str("type"), str("regular"), [str("executable"), str("")], str("contents"), str(contents)
///               | str("type"), str("symlink"), str("target"), str(target)
///               | str("type"), str("directory"), { directory-entry }
/// directory-entry = str("entry"), str("("), str("name"), str(name), str("node"), nar-obj, str(")")
/// str(s) = int(|s|), pad(s)
/// int(n) = 64-bit little-endian
/// pad(s) = s padded with zeros to 8-byte boundary
/// ```
class NarSerializer {
  /// Serializes a [NarNode] tree to NAR format bytes.
  ///
  /// Returns the complete NAR binary representation that can be hashed
  /// to produce the same result as `nix-prefetch-url --unpack`.
  static Uint8List serialize(NarNode root) {
    final writer = _NarWriter();
    writer._writeStr('nix-archive-1');
    writer._serializeNode(root);
    return writer._toBytes();
  }
}

class _NarWriter {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  Uint8List _toBytes() => _buffer.toBytes();

  /// Writes a NAR-encoded string: 8-byte LE length + content + padding.
  void _writeStr(String s) {
    _writeRawBytes(utf8.encode(s));
  }

  /// Writes raw bytes in NAR string format: 8-byte LE length + bytes + padding.
  void _writeRawBytes(List<int> bytes) {
    final len = bytes.length;

    // Write 8-byte little-endian length
    final lenBytes = Uint8List(8);
    lenBytes[0] = len & 0xff;
    lenBytes[1] = (len >> 8) & 0xff;
    lenBytes[2] = (len >> 16) & 0xff;
    lenBytes[3] = (len >> 24) & 0xff;
    // bytes[4..7] stay 0 for lengths < 4GB (which is always the case)
    _buffer.add(lenBytes);

    // Write content
    _buffer.add(bytes);

    // Pad to 8-byte boundary
    final padding = (8 - (len % 8)) % 8;
    if (padding > 0) {
      _buffer.add(Uint8List(padding));
    }
  }

  /// Recursively serializes a NAR node.
  void _serializeNode(NarNode node) {
    _writeStr('(');
    _writeStr('type');

    switch (node) {
      case NarFile():
        _writeStr('regular');
        if (node.executable) {
          _writeStr('executable');
          _writeStr('');
        }
        _writeStr('contents');
        _writeRawBytes(node.contents);

      case NarDirectory():
        _writeStr('directory');
        // Directory entries MUST be sorted lexicographically by name
        final sortedNames = node.entries.keys.toList()..sort();
        for (final name in sortedNames) {
          _writeStr('entry');
          _writeStr('(');
          _writeStr('name');
          _writeStr(name);
          _writeStr('node');
          _serializeNode(node.entries[name]!);
          _writeStr(')');
        }

      case NarSymlink():
        _writeStr('symlink');
        _writeStr('target');
        _writeStr(node.target);
    }

    _writeStr(')');
  }
}
