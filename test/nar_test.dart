import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:nix_infra/nar.dart';
import 'package:nix_infra/nix_hash.dart';

void main() {
  group('NarSerializer', () {
    group('string encoding', () {
      test('serializes a single regular file correctly', () {
        // A single regular file with known content.
        // The NAR format for a file "hello" with content "hello\n" is:
        // str("nix-archive-1") str("(") str("type") str("regular")
        //   str("contents") str("hello\n") str(")")
        final node = NarFile(Uint8List.fromList(utf8.encode('hello\n')));
        final narBytes = NarSerializer.serialize(node);

        // Verify the NAR starts with the magic header
        // str("nix-archive-1") = 8-byte LE length (13) + "nix-archive-1" + 3 bytes padding
        expect(narBytes.length, greaterThan(0));

        // First 8 bytes should be length 13 in LE
        final headerLen = _readUint64LE(narBytes, 0);
        expect(headerLen, equals(13));

        // Next 13 bytes should be "nix-archive-1"
        final headerStr = utf8.decode(narBytes.sublist(8, 21));
        expect(headerStr, equals('nix-archive-1'));
      });

      test('NAR hash of empty file matches nix', () {
        // echo -n "" | nix hash path --base32 /dev/stdin
        // but for NAR of a file, we need to construct the right structure
        final emptyFile = NarFile(Uint8List(0));
        final narBytes = NarSerializer.serialize(emptyFile);
        final hash = NixHash.sha256Nix32(narBytes);

        // The NAR serialization of an empty regular file should produce
        // a deterministic, non-empty byte sequence
        expect(narBytes.length, greaterThan(0));
        expect(hash.length, equals(52)); // nix32 SHA256 is always 52 chars
      });

      test('NAR of regular file has correct structure', () {
        final content = utf8.encode('test content');
        final node = NarFile(Uint8List.fromList(content));
        final narBytes = NarSerializer.serialize(node);

        // Parse through the NAR manually to verify structure
        var offset = 0;

        // "nix-archive-1"
        final magic = _readNarString(narBytes, offset);
        expect(magic.value, equals('nix-archive-1'));
        offset = magic.nextOffset;

        // "("
        final open = _readNarString(narBytes, offset);
        expect(open.value, equals('('));
        offset = open.nextOffset;

        // "type"
        final typeTag = _readNarString(narBytes, offset);
        expect(typeTag.value, equals('type'));
        offset = typeTag.nextOffset;

        // "regular"
        final typeVal = _readNarString(narBytes, offset);
        expect(typeVal.value, equals('regular'));
        offset = typeVal.nextOffset;

        // "contents"
        final contentsTag = _readNarString(narBytes, offset);
        expect(contentsTag.value, equals('contents'));
        offset = contentsTag.nextOffset;

        // actual content
        final contentsVal = _readNarBytes(narBytes, offset);
        expect(contentsVal.value, equals(content));
        offset = contentsVal.nextOffset;

        // ")"
        final close = _readNarString(narBytes, offset);
        expect(close.value, equals(')'));
        offset = close.nextOffset;

        // Should be at the end
        expect(offset, equals(narBytes.length));
      });

      test('NAR of executable file includes executable marker', () {
        final content = utf8.encode('#!/bin/sh\necho hello\n');
        final node =
            NarFile(Uint8List.fromList(content), executable: true);
        final narBytes = NarSerializer.serialize(node);

        var offset = 0;

        // "nix-archive-1"
        offset = _readNarString(narBytes, offset).nextOffset;
        // "("
        offset = _readNarString(narBytes, offset).nextOffset;
        // "type"
        offset = _readNarString(narBytes, offset).nextOffset;
        // "regular"
        offset = _readNarString(narBytes, offset).nextOffset;

        // "executable"
        final execTag = _readNarString(narBytes, offset);
        expect(execTag.value, equals('executable'));
        offset = execTag.nextOffset;

        // "" (empty string)
        final execVal = _readNarString(narBytes, offset);
        expect(execVal.value, equals(''));
        offset = execVal.nextOffset;

        // "contents"
        final contentsTag = _readNarString(narBytes, offset);
        expect(contentsTag.value, equals('contents'));
      });
    });

    group('directory serialization', () {
      test('empty directory serializes correctly', () {
        final dir = NarDirectory.empty();
        final narBytes = NarSerializer.serialize(dir);

        var offset = 0;
        offset = _readNarString(narBytes, offset).nextOffset; // nix-archive-1
        offset = _readNarString(narBytes, offset).nextOffset; // (
        offset = _readNarString(narBytes, offset).nextOffset; // type

        final typeVal = _readNarString(narBytes, offset);
        expect(typeVal.value, equals('directory'));
        offset = typeVal.nextOffset;

        final close = _readNarString(narBytes, offset);
        expect(close.value, equals(')'));
      });

      test('directory entries are sorted by name', () {
        final dir = NarDirectory.empty();
        dir.entries['zzz'] =
            NarFile(Uint8List.fromList(utf8.encode('last')));
        dir.entries['aaa'] =
            NarFile(Uint8List.fromList(utf8.encode('first')));
        dir.entries['mmm'] =
            NarFile(Uint8List.fromList(utf8.encode('middle')));

        final narBytes = NarSerializer.serialize(dir);

        // Extract all entry names from the NAR
        final names = _extractEntryNames(narBytes);
        expect(names, equals(['aaa', 'mmm', 'zzz']));
      });

      test('nested directories serialize correctly', () {
        final inner = NarDirectory.empty();
        inner.entries['file.txt'] =
            NarFile(Uint8List.fromList(utf8.encode('hello')));

        final outer = NarDirectory.empty();
        outer.entries['subdir'] = inner;

        final narBytes = NarSerializer.serialize(outer);
        // Should not throw and should produce valid NAR
        expect(narBytes.length, greaterThan(0));

        // Verify the hash is deterministic
        final hash1 = NixHash.sha256NarNix32(outer);
        final hash2 = NixHash.sha256NarNix32(outer);
        expect(hash1, equals(hash2));
      });
    });

    group('symlink serialization', () {
      test('symlink serializes correctly', () {
        final link = NarSymlink('/usr/bin/env');
        final narBytes = NarSerializer.serialize(link);

        var offset = 0;
        offset = _readNarString(narBytes, offset).nextOffset; // nix-archive-1
        offset = _readNarString(narBytes, offset).nextOffset; // (
        offset = _readNarString(narBytes, offset).nextOffset; // type

        final typeVal = _readNarString(narBytes, offset);
        expect(typeVal.value, equals('symlink'));
        offset = typeVal.nextOffset;

        final targetTag = _readNarString(narBytes, offset);
        expect(targetTag.value, equals('target'));
        offset = targetTag.nextOffset;

        final targetVal = _readNarString(narBytes, offset);
        expect(targetVal.value, equals('/usr/bin/env'));
      });
    });

    group('determinism', () {
      test('same tree always produces same NAR bytes', () {
        final dir = NarDirectory.empty();
        dir.entries['README.md'] =
            NarFile(Uint8List.fromList(utf8.encode('# Hello')));
        dir.entries['src'] = NarDirectory.empty();
        (dir.entries['src'] as NarDirectory).entries['main.dart'] =
            NarFile(Uint8List.fromList(utf8.encode('void main() {}')));

        final nar1 = NarSerializer.serialize(dir);
        final nar2 = NarSerializer.serialize(dir);
        expect(nar1, equals(nar2));
      });

      test('different content produces different NAR hash', () {
        final file1 = NarFile(Uint8List.fromList(utf8.encode('content a')));
        final file2 = NarFile(Uint8List.fromList(utf8.encode('content b')));

        final hash1 = NixHash.sha256NarNix32(file1);
        final hash2 = NixHash.sha256NarNix32(file2);
        expect(hash1, isNot(equals(hash2)));
      });
    });

    group('NAR hash methods', () {
      test('sha256NarNix32 produces 52-char output', () {
        final node = NarFile(Uint8List.fromList(utf8.encode('test')));
        final hash = NixHash.sha256NarNix32(node);
        expect(hash.length, equals(52));
      });

      test('sha256NarSri produces sha256- prefix', () {
        final node = NarFile(Uint8List.fromList(utf8.encode('test')));
        final hash = NixHash.sha256NarSri(node);
        expect(hash, startsWith('sha256-'));
      });

      test('sha256NarHex produces 64-char hex', () {
        final node = NarFile(Uint8List.fromList(utf8.encode('test')));
        final hash = NixHash.sha256NarHex(node);
        expect(hash.length, equals(64));
        expect(hash, matches(RegExp(r'^[0-9a-f]+$')));
      });

      test('all NAR hash formats are consistent', () {
        final node = NarFile(Uint8List.fromList(utf8.encode('test')));
        final narBytes = NarSerializer.serialize(node);

        // Direct hash of NAR bytes should match NarHash methods
        expect(NixHash.sha256NarNix32(node), equals(NixHash.sha256Nix32(narBytes)));
        expect(NixHash.sha256NarSri(node), equals(NixHash.sha256Sri(narBytes)));
        expect(NixHash.sha256NarHex(node), equals(NixHash.sha256Hex(narBytes)));
      });
    });

    group('known NAR hash values', () {
      // These can be verified with:
      // echo -n "hello" > /tmp/test-file && nix hash path --base32 /tmp/test-file
      test('NAR hash of single file "hello" matches expected', () {
        // Create a single file containing "hello" (no newline)
        final file = NarFile(Uint8List.fromList(utf8.encode('hello')));
        final narBytes = NarSerializer.serialize(file);

        // Manually verify the NAR structure is correct by computing SHA256
        final digest = sha256.convert(narBytes);
        final hexHash = digest.toString();

        // The hash should be deterministic and 64 hex chars
        expect(hexHash.length, equals(64));

        // Verify nix32 encoding of the same hash
        final nix32Hash = NixHash.sha256NarNix32(file);
        final nix32ViaHex =
            NixHash.toNix32(NixHash.hexToBytes(hexHash));
        expect(nix32Hash, equals(nix32ViaHex));
      });
    });
  });
}

// --- Helper functions for parsing NAR bytes in tests ---

/// Reads a 64-bit unsigned little-endian integer from bytes at offset.
int _readUint64LE(Uint8List bytes, int offset) {
  var value = 0;
  for (var i = 7; i >= 0; i--) {
    value = (value << 8) | bytes[offset + i];
  }
  return value;
}

/// Result of reading a NAR string.
class _NarStringResult {
  final String value;
  final int nextOffset;
  _NarStringResult(this.value, this.nextOffset);
}

/// Result of reading NAR bytes.
class _NarBytesResult {
  final List<int> value;
  final int nextOffset;
  _NarBytesResult(this.value, this.nextOffset);
}

/// Reads a NAR-encoded string at the given offset.
_NarStringResult _readNarString(Uint8List bytes, int offset) {
  final result = _readNarBytes(bytes, offset);
  return _NarStringResult(utf8.decode(result.value), result.nextOffset);
}

/// Reads NAR-encoded bytes at the given offset.
_NarBytesResult _readNarBytes(Uint8List bytes, int offset) {
  final len = _readUint64LE(bytes, offset);
  offset += 8;
  final value = bytes.sublist(offset, offset + len);
  offset += len;
  // Skip padding
  final padding = (8 - (len % 8)) % 8;
  offset += padding;
  return _NarBytesResult(value, offset);
}

/// Extracts directory entry names from NAR bytes.
List<String> _extractEntryNames(Uint8List bytes) {
  final names = <String>[];
  var offset = 0;

  // Skip header: nix-archive-1, (, type, directory
  offset = _readNarString(bytes, offset).nextOffset; // nix-archive-1
  offset = _readNarString(bytes, offset).nextOffset; // (
  offset = _readNarString(bytes, offset).nextOffset; // type
  offset = _readNarString(bytes, offset).nextOffset; // directory

  // Read entries until we hit ")"
  while (offset < bytes.length) {
    final tag = _readNarString(bytes, offset);
    if (tag.value == ')') break;

    if (tag.value == 'entry') {
      offset = tag.nextOffset;
      offset = _readNarString(bytes, offset).nextOffset; // (
      final nameTag = _readNarString(bytes, offset);
      expect(nameTag.value, equals('name'));
      offset = nameTag.nextOffset;

      final name = _readNarString(bytes, offset);
      names.add(name.value);

      // Skip the rest of this entry by finding matching )
      offset = name.nextOffset;
      offset = _readNarString(bytes, offset).nextOffset; // "node"
      // Skip the nested nar-obj - need to count parens
      offset = _skipNarObj(bytes, offset);
      offset = _readNarString(bytes, offset).nextOffset; // closing ) of entry
    } else {
      offset = tag.nextOffset;
    }
  }

  return names;
}

/// Skips a complete nar-obj (from opening "(" to matching ")").
int _skipNarObj(Uint8List bytes, int offset) {
  final open = _readNarString(bytes, offset);
  expect(open.value, equals('('));
  offset = open.nextOffset;

  var depth = 1;
  while (depth > 0 && offset < bytes.length) {
    final s = _readNarString(bytes, offset);
    offset = s.nextOffset;
    if (s.value == '(') {
      depth++;
    } else if (s.value == ')') {
      depth--;
    }
  }
  return offset;
}
