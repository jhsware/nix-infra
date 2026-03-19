import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'archive_unpacker.dart';
import 'nar.dart';


/// Nix-compatible base32 encoding and hash utilities.
///
/// Implements the custom base32 encoding used by Nix package manager,
/// which differs from standard RFC 4648 base32 in both alphabet and bit ordering.
class NixHash {
  /// The Nix base32 alphabet (32 characters, excludes E, O, U, T).
  static const String nix32Alphabet = '0123456789abcdfghijklmnpqrsvwxyz';

  /// Encodes bytes to Nix base32 format.
  ///
  /// This implements the exact algorithm from Nix's libutil/hash.cc:
  /// - Processes 5-bit chunks from the byte array
  /// - Uses a specific bit extraction order (different from RFC 4648)
  /// - No padding
  static String toNix32(Uint8List bytes) {
    if (bytes.isEmpty) return '';

    final hashSize = bytes.length;
    // Calculate output length: ceil(hashSize * 8 / 5)
    final len = (hashSize * 8 + 4) ~/ 5;

    final result = StringBuffer();

    // Process from n = len-1 down to 0
    for (var n = len - 1; n >= 0; n--) {
      final b = n * 5; // bit position
      final i = b ~/ 8; // byte index
      final j = b % 8; // bit offset within byte

      // Extract 5 bits, potentially spanning two bytes
      int c = bytes[i] >> j;
      if (i + 1 < hashSize) {
        c |= bytes[i + 1] << (8 - j);
      }

      result.write(nix32Alphabet[c & 0x1f]);
    }

    return result.toString();
  }

  /// Decodes Nix base32 format to bytes.
  ///
  /// Reverses the encoding process from toNix32.
  static Uint8List fromNix32(String encoded) {
    if (encoded.isEmpty) return Uint8List(0);

    final len = encoded.length;
    // Calculate byte size: floor(len * 5 / 8)
    final hashSize = (len * 5) ~/ 8;
    final result = Uint8List(hashSize);

    // Process each character and place bits in the correct position
    for (var n = len - 1; n >= 0; n--) {
      final charIndex = len - 1 - n;
      final char = encoded[charIndex];
      final c = nix32Alphabet.indexOf(char);
      if (c < 0) {
        throw ArgumentError('Invalid nix32 character: $char');
      }

      final b = n * 5; // bit position
      final i = b ~/ 8; // byte index
      final j = b % 8; // bit offset within byte

      // Place the 5 bits back, potentially spanning two bytes
      result[i] |= (c << j) & 0xff;
      if (i + 1 < hashSize && j > 3) {
        result[i + 1] |= c >> (8 - j);
      }
    }

    return result;
  }

  /// Computes SHA256 hash of bytes and returns nix32-encoded result.
  static String sha256Nix32(Uint8List bytes) {
    final digest = sha256.convert(bytes);
    return toNix32(Uint8List.fromList(digest.bytes));
  }

  /// Computes SHA256 hash of bytes and returns SRI format (sha256-base64).
  static String sha256Sri(Uint8List bytes) {
    final digest = sha256.convert(bytes);
    final base64Hash = base64.encode(digest.bytes);
    return 'sha256-$base64Hash';
  }

  /// Computes SHA256 hash of bytes and returns hex-encoded result.
  static String sha256Hex(Uint8List bytes) {
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Converts hex string to bytes.
  static Uint8List hexToBytes(String hex) {
    if (hex.length % 2 != 0) {
      throw ArgumentError('Hex string must have even length');
    }
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  /// Converts bytes to hex string.
  static String bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // --- NAR hash methods ---
  // These compute hashes of the NAR serialization of a NarNode tree,
  // which is what Nix uses for fetchzip/fetchFromGitHub.

  /// Computes SHA256 of NAR serialization and returns nix32-encoded result.
  ///
  /// This produces the same hash as `nix-prefetch-url --unpack` or
  /// `nix hash path` for the given file system tree.
  static String sha256NarNix32(NarNode node) {
    final narBytes = NarSerializer.serialize(node);
    return sha256Nix32(narBytes);
  }

  /// Computes SHA256 of NAR serialization and returns SRI format.
  static String sha256NarSri(NarNode node) {
    final narBytes = NarSerializer.serialize(node);
    return sha256Sri(narBytes);
  }

  /// Computes SHA256 of NAR serialization and returns hex format.
  static String sha256NarHex(NarNode node) {
    final narBytes = NarSerializer.serialize(node);
    return sha256Hex(narBytes);
  }

  /// Convenience: unpacks archive bytes, strips top-level directory,
  /// serializes to NAR, and returns nix32-encoded SHA256 hash.
  ///
  /// This is the all-in-one method that replicates `nix-prefetch-url --unpack`.
  /// [archiveBytes] - raw archive file bytes (tar.gz or zip)
  /// [url] - used to detect archive type; if null, defaults to tar.gz
  static String sha256UnpackNix32(Uint8List archiveBytes, {String? url}) {
    final type = url != null
        ? ArchiveUnpacker.detectType(url)
        : ArchiveType.tarGz;
    final tree = ArchiveUnpacker.unpack(archiveBytes, type);
    return sha256NarNix32(tree);
  }

  /// Convenience: unpacks archive bytes and returns all hash formats.
  static Map<String, String> sha256UnpackAll(Uint8List archiveBytes,
      {String? url}) {
    final type = url != null
        ? ArchiveUnpacker.detectType(url)
        : ArchiveType.tarGz;
    final tree = ArchiveUnpacker.unpack(archiveBytes, type);
    final narBytes = NarSerializer.serialize(tree);
    return {
      'nix32': sha256Nix32(narBytes),
      'sri': sha256Sri(narBytes),
      'hex': sha256Hex(narBytes),
    };
  }
}

