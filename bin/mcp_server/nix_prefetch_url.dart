import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/nix_hash.dart';
import 'mcp_tool.dart';

/// MCP tool for calculating nix-prefetch-url compatible hashes.
///
/// Downloads a URL and calculates the SHA256 hash in various formats:
/// - nix32: Nix-compatible base32 (default, same as nix-prefetch-url output)
/// - sri: Subresource Integrity format (sha256-base64)
/// - hex: Hexadecimal format
///
/// Supports `unpack` mode for fetchzip/fetchFromGitHub which computes
/// NAR hash of unpacked archive contents.
class NixPrefetchUrl extends McpTool {
  static const description = '''Calculate the hash of a URL for NixOS package configuration.

This tool downloads a file from a URL and computes its SHA256 hash in different formats:
- nix32: Nix-compatible base32 encoding (default, same as nix-prefetch-url)
- sri: Subresource Integrity format (sha256-base64), used with fetchzip
- hex: Standard hexadecimal format

Set unpack=true for fetchzip/fetchFromGitHub hashes. This unpacks the archive,
strips the single top-level directory, and computes the NAR hash of the contents
(equivalent to nix-prefetch-url --unpack).

Common use cases:
- Get hash for fetchurl { url = "..."; sha256 = "..."; }
- Get hash for fetchFromGitHub (use GitHub archive URLs with unpack=true)
- Verify file integrity

GitHub archive URL formats:
- https://github.com/OWNER/REPO/archive/REF.tar.gz (REF can be tag, branch, or commit SHA)
- https://github.com/OWNER/REPO/archive/refs/tags/TAG.tar.gz
- https://github.com/OWNER/REPO/archive/refs/heads/BRANCH.tar.gz

Note: GitHub archives may have unstable hashes. Use commit SHAs for reproducibility.''';

  static const Map<String, dynamic> inputSchemaProperties = {
    'operation': {
      'type': 'string',
      'description': '''
hash -- Download URL and calculate hash (requires 'url' parameter)
verify -- Verify a URL against an expected hash (requires 'url' and 'expected_hash')
convert -- Convert hash between formats (requires 'hash' and 'from_format')
''',
      'enum': ['hash', 'verify', 'convert'],
    },
    'url': {
      'type': 'string',
      'description': 'URL to download and hash (required for hash and verify operations)',
    },
    'format': {
      'type': 'string',
      'description': 'Output format: nix32 (default), sri, or hex',
      'enum': ['nix32', 'sri', 'hex'],
    },
    'expected_hash': {
      'type': 'string',
      'description': 'Expected hash for verify operation (any format: nix32, sri, or hex)',
    },
    'hash': {
      'type': 'string',
      'description': 'Hash to convert (for convert operation)',
    },
    'from_format': {
      'type': 'string',
      'description': 'Source format for convert operation: nix32, sri, or hex',
      'enum': ['nix32', 'sri', 'hex'],
    },
    'unpack': {
      'type': 'boolean',
      'description':
          'Unpack archive before hashing (like nix-prefetch-url --unpack). '
              'Required for correct fetchzip/fetchFromGitHub hashes. '
              'Supports tar.gz and zip archives. Default: false.',
    },
  };

  NixPrefetchUrl({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  @override
  Future<CallToolResult> callback({args, extra}) async {
    final operation = args?['operation'] ?? 'hash';
    final url = args?['url'] as String?;
    final format = args?['format'] ?? 'nix32';
    final expectedHash = args?['expected_hash'] as String?;
    final hash = args?['hash'] as String?;
    final fromFormat = args?['from_format'] as String?;
    final unpack = args?['unpack'] == true;

    switch (operation) {
      case 'hash':
        return await _hashUrl(url, format, unpack: unpack);
      case 'verify':
        return await _verifyUrl(url, expectedHash, unpack: unpack);
      case 'convert':
        return _convertHash(hash, fromFormat, format);
      default:
        return _errorResult('Unknown operation: $operation');
    }
  }

  /// Computes hashes from downloaded bytes, using flat or NAR hash as appropriate.
  Map<String, String> _computeHashes(Uint8List bytes,
      {required bool unpack, String? url}) {
    if (unpack) {
      return NixHash.sha256UnpackAll(bytes, url: url);
    }
    return {
      'nix32': NixHash.sha256Nix32(bytes),
      'sri': NixHash.sha256Sri(bytes),
      'hex': NixHash.sha256Hex(bytes),
    };
  }

  /// Downloads URL and calculates hash.
  Future<CallToolResult> _hashUrl(String? url, String format,
      {bool unpack = false}) async {
    if (url == null || url.isEmpty) {
      return _errorResult('Missing required parameter: url');
    }

    try {
      final bytes = await _downloadUrl(url);
      final allFormats = _computeHashes(bytes, unpack: unpack, url: url);

      final hashResult = allFormats[format];
      if (hashResult == null) {
        return _errorResult('Unknown format: $format');
      }

      final response = {
        'url': url,
        'hash': hashResult,
        'format': format,
        'size': bytes.length,
        'unpack': unpack,
        'all_formats': allFormats,
      };

      return CallToolResult.fromContent(
        content: [TextContent(text: jsonEncode(response))],
      );
    } catch (e) {
      return _errorResult('Failed to hash URL: $e');
    }
  }

  /// Verifies URL against expected hash.
  Future<CallToolResult> _verifyUrl(String? url, String? expectedHash,
      {bool unpack = false}) async {
    if (url == null || url.isEmpty) {
      return _errorResult('Missing required parameter: url');
    }
    if (expectedHash == null || expectedHash.isEmpty) {
      return _errorResult('Missing required parameter: expected_hash');
    }

    try {
      final bytes = await _downloadUrl(url);
      final allFormats = _computeHashes(bytes, unpack: unpack, url: url);

      final nix32 = allFormats['nix32']!;
      final sri = allFormats['sri']!;
      final hex = allFormats['hex']!;

      // Check if expected hash matches any format
      final normalized = expectedHash.toLowerCase().trim();
      final matches = normalized == nix32 ||
          normalized == hex ||
          expectedHash.trim() == sri ||
          (expectedHash.startsWith('sha256-') &&
              expectedHash.substring(7) == sri.substring(7));

      final response = {
        'url': url,
        'expected_hash': expectedHash,
        'matches': matches,
        'unpack': unpack,
        'actual': allFormats,
        'size': bytes.length,
      };

      return CallToolResult.fromContent(
        content: [TextContent(text: jsonEncode(response))],
      );
    } catch (e) {
      return _errorResult('Failed to verify URL: $e');
    }
  }

  /// Converts hash between formats.
  CallToolResult _convertHash(
      String? hash, String? fromFormat, String toFormat) {
    if (hash == null || hash.isEmpty) {
      return _errorResult('Missing required parameter: hash');
    }
    if (fromFormat == null || fromFormat.isEmpty) {
      return _errorResult('Missing required parameter: from_format');
    }

    try {
      // First convert to bytes
      Uint8List hashBytes;

      switch (fromFormat) {
        case 'nix32':
          hashBytes = NixHash.fromNix32(hash);
          break;
        case 'hex':
          hashBytes = NixHash.hexToBytes(hash);
          break;
        case 'sri':
          // Remove sha256- prefix if present
          final base64Part =
              hash.startsWith('sha256-') ? hash.substring(7) : hash;
          hashBytes = Uint8List.fromList(base64.decode(base64Part));
          break;
        default:
          return _errorResult('Unknown from_format: $fromFormat');
      }

      // Then convert to requested format
      final String result;
      switch (toFormat) {
        case 'nix32':
          result = NixHash.toNix32(hashBytes);
          break;
        case 'hex':
          result = NixHash.bytesToHex(hashBytes);
          break;
        case 'sri':
          result = 'sha256-${base64.encode(hashBytes)}';
          break;
        default:
          return _errorResult('Unknown format: $toFormat');
      }

      final response = {
        'input': hash,
        'from_format': fromFormat,
        'output': result,
        'to_format': toFormat,
        'all_formats': {
          'nix32': NixHash.toNix32(hashBytes),
          'hex': NixHash.bytesToHex(hashBytes),
          'sri': 'sha256-${base64.encode(hashBytes)}',
        },
      };

      return CallToolResult.fromContent(
        content: [TextContent(text: jsonEncode(response))],
      );
    } catch (e) {
      return _errorResult('Failed to convert hash: $e');
    }
  }

  /// Downloads URL content as bytes.
  Future<Uint8List> _downloadUrl(String url) async {
    final uri = Uri.parse(url);
    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
    }

    return response.bodyBytes;
  }

  /// Creates error result.
  CallToolResult _errorResult(String message) {
    return CallToolResult.fromContent(
      content: [TextContent(text: jsonEncode({'error': message}))],
    );
  }
}
