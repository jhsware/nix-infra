import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Nix-compatible base32 encoding and hash utilities.
///
/// Implements the custom base32 encoding used by Nix package manager,
/// which differs from standard RFC 4648 base32 in alphabet and byte ordering.
class NixHash {
  /// The Nix base32 alphabet (32 characters, excludes E, O, U, T).
  static const String nix32Alphabet = '0123456789abcdfghijklmnpqrsvwxyz';

  /// Standard RFC 4648 base32 alphabet for translation.
  static const String rfc4648Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// Encodes bytes to Nix base32 format.
  ///
  /// The Nix base32 encoding:
  /// 1. Reverses the input bytes
  /// 2. Applies RFC 4648 base32 encoding algorithm
  /// 3. Translates to Nix alphabet
  /// 4. Does not use padding
  static String toNix32(Uint8List bytes) {
    // Reverse the bytes
    final reversed = Uint8List.fromList(bytes.reversed.toList());

    // Encode using standard base32 algorithm
    final encoded = _base32Encode(reversed);

    // Translate from RFC4648 alphabet to Nix alphabet
    final buffer = StringBuffer();
    for (final char in encoded.codeUnits) {
      final charStr = String.fromCharCode(char);
      if (charStr == '=') continue; // Skip padding
      final index = rfc4648Alphabet.indexOf(charStr.toUpperCase());
      if (index >= 0) {
        buffer.write(nix32Alphabet[index]);
      }
    }

    return buffer.toString();
  }

  /// Decodes Nix base32 format to bytes.
  static Uint8List fromNix32(String encoded) {
    // Translate from Nix alphabet to RFC4648 alphabet
    final buffer = StringBuffer();
    for (final char in encoded.codeUnits) {
      final charStr = String.fromCharCode(char);
      final index = nix32Alphabet.indexOf(charStr);
      if (index >= 0) {
        buffer.write(rfc4648Alphabet[index]);
      }
    }

    // Add padding if needed
    final translated = buffer.toString();
    final paddingNeeded = (8 - translated.length % 8) % 8;
    final padded = translated + ('=' * paddingNeeded);

    // Decode using standard base32 algorithm
    final decoded = _base32Decode(padded);

    // Reverse the bytes
    return Uint8List.fromList(decoded.reversed.toList());
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

  /// Standard base32 encoding (RFC 4648).
  static String _base32Encode(Uint8List bytes) {
    if (bytes.isEmpty) return '';

    final result = StringBuffer();
    int buffer = 0;
    int bitsInBuffer = 0;

    for (final byte in bytes) {
      buffer = (buffer << 8) | byte;
      bitsInBuffer += 8;

      while (bitsInBuffer >= 5) {
        bitsInBuffer -= 5;
        final index = (buffer >> bitsInBuffer) & 0x1F;
        result.write(rfc4648Alphabet[index]);
      }
    }

    // Handle remaining bits
    if (bitsInBuffer > 0) {
      final index = (buffer << (5 - bitsInBuffer)) & 0x1F;
      result.write(rfc4648Alphabet[index]);
    }

    // Add padding
    while (result.length % 8 != 0) {
      result.write('=');
    }

    return result.toString();
  }

  /// Standard base32 decoding (RFC 4648).
  static Uint8List _base32Decode(String encoded) {
    // Remove padding
    final input = encoded.replaceAll('=', '').toUpperCase();
    if (input.isEmpty) return Uint8List(0);

    final result = <int>[];
    int buffer = 0;
    int bitsInBuffer = 0;

    for (final char in input.codeUnits) {
      final charStr = String.fromCharCode(char);
      final value = rfc4648Alphabet.indexOf(charStr);
      if (value < 0) continue;

      buffer = (buffer << 5) | value;
      bitsInBuffer += 5;

      if (bitsInBuffer >= 8) {
        bitsInBuffer -= 8;
        result.add((buffer >> bitsInBuffer) & 0xFF);
      }
    }

    return Uint8List.fromList(result);
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
}
