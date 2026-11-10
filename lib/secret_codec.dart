/// Codec for nix-infra secret files (`<project>/secrets/<name>`).
///
/// Three formats are read, one is written:
///
/// - [SecretFileFormat.v2]: `nix-infra-secret/v2`, an authenticated format
///   (AES-256-GCM, the header is the AAD). This is the only format that is
///   written, see [encryptSecretV2].
/// - [SecretFileFormat.opensslSalted]: base64 of `Salted__` + salt +
///   AES-256-CBC ciphertext, as `openssl enc -aes-256-cbc [-pbkdf2] -a`
///   writes it.
/// - [SecretFileFormat.legacyBase64]: base64 of the plain value. Older
///   nix-infra versions ran `openssl enc -pbkdf2 -a` without a cipher, which
///   only encodes base64. No key is needed to read these files.
///
/// The v2 file layout:
///
/// ```text
/// nix-infra-secret/v2
/// kind: text | github-netrc
/// created: <UTC ISO 8601, seconds>
/// kdf: hkdf-sha256 | pbkdf2-hmac-sha256
/// iterations: <only for pbkdf2>
/// salt: <base64, 16 bytes>
/// cipher: aes-256-gcm
/// nonce: <base64, 12 bytes>
/// key_id: <8 hex, only for hkdf>
/// ---
/// <base64 of ciphertext || 16-byte tag, 64 characters per line>
/// ```
///
/// The AAD is the exact header bytes from the first byte up to and including
/// the newline before `---`.
///
/// Keys: a key with the prefix `nisk1_` (see [generateFilesKey]) is a
/// generated files key; the file key is derived with HKDF-SHA256 and the
/// header carries its `key_id`. Any other key text is a password; the file
/// key is derived with PBKDF2-HMAC-SHA256.
///
/// Errors: structural problems (a file that is not a valid secret file, or a
/// v2 header that breaks the reader limits) throw [SecretFormatUnknown]. A
/// wrong key, a modified file or an OpenSSL file that cannot be opened throw
/// [SecretDecryptFailed]. A v2 file whose `key_id` (or key type) does not
/// match the given key throws [SecretKeyMismatch] before any key derivation.
/// No message ever contains a key, a password, a plaintext or ciphertext.
///
/// This library imports only `dart:*`, `package:cryptography` and
/// `package:crypto`, so that sysops_server can use it.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto show Hash, md5, sha256;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart' show DartAesGcm;

/// The first line of a v2 secret file.
const kSecretV2Magic = 'nix-infra-secret/v2';

/// The prefix of a generated files key.
const kFilesKeyPrefix = 'nisk1_';

/// PBKDF2 iterations used when a v2 file is encrypted with a password.
const kDefaultPbkdf2Iterations = 600000;

/// The lowest PBKDF2 iteration count that the v2 reader and writer accept.
const kMinPbkdf2Iterations = 100000;

/// The highest PBKDF2 iteration count that the v2 reader and writer accept.
const kMaxPbkdf2Iterations = 10000000;

/// The maximum length in bytes of a v2 header (up to and including the
/// newline before `---`).
const kMaxSecretV2HeaderLength = 4096;

/// `kind` of a plain text secret.
const kSecretKindText = 'text';

/// `kind` of a GitHub netrc secret.
const kSecretKindGithubNetrc = 'github-netrc';

const _cipherAes256Gcm = 'aes-256-gcm';
const _hkdfInfo = 'nix-infra-secret/v2';
const _keyIdLabel = 'nix-infra-secret/key-id';
const _filesKeyLength = 32;
const _filesKeyEncodedLength = 43;
const _saltLength = 16;
const _nonceLength = 12;
const _tagLength = 16;
const _bodyLineLength = 64;

const _opensslSaltLength = 8;
const _opensslPbkdf2Iterations = 10000;
const _aesBlockLength = 16;

final _random = Random.secure();
final _aesGcm = DartAesGcm.with256bits();
final _aesCbc = AesCbc.with256bits(
  macAlgorithm: MacAlgorithm.empty,
  paddingAlgorithm: PaddingAlgorithm.pkcs7,
);

final _v2MagicLine = ascii.encode('$kSecretV2Magic\n');
final _saltedMagic = ascii.encode('Salted__');

final _base64Pattern = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');
final _base64UrlKeyPattern = RegExp(
  '^[A-Za-z0-9_-]{$_filesKeyEncodedLength}\$',
);
final _headerLinePattern = RegExp(r'^([a-z_]+): (\S+)$');
final _kindPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$');
final _createdPattern = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$');
final _iterationsPattern = RegExp(r'^[1-9][0-9]{0,8}$');
final _keyIdPattern = RegExp(r'^[0-9a-f]{8}$');

const _headerFields = {
  'kind',
  'created',
  'kdf',
  'iterations',
  'salt',
  'cipher',
  'nonce',
  'key_id',
};

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

/// Base class of all errors thrown by the codec. Messages never contain a
/// key, a password, a plaintext or ciphertext.
sealed class SecretCodecException implements Exception {
  const SecretCodecException(this.message);

  final String message;

  String get _name;

  @override
  String toString() => '$_name: $message';
}

/// The bytes are not a secret file this codec understands, or a v2 header
/// breaks the reader limits (missing, duplicate or unknown fields, unknown
/// `kdf` or `cipher`, iterations out of range, wrong salt or nonce length,
/// header longer than [kMaxSecretV2HeaderLength]).
final class SecretFormatUnknown extends SecretCodecException {
  const SecretFormatUnknown(super.message);

  @override
  String get _name => 'SecretFormatUnknown';
}

/// The file could not be decrypted: no key, a wrong key, a modified file, or
/// an OpenSSL file with a cipher or KDF this codec does not support.
final class SecretDecryptFailed extends SecretCodecException {
  const SecretDecryptFailed(super.message);

  @override
  String get _name => 'SecretDecryptFailed';
}

/// A v2 file was encrypted with another files key (its `key_id` differs from
/// the id of the given key), or with another type of key (generated files
/// key versus password). Thrown before any key derivation.
final class SecretKeyMismatch extends SecretCodecException {
  const SecretKeyMismatch(super.message);

  @override
  String get _name => 'SecretKeyMismatch';
}

// ---------------------------------------------------------------------------
// Format detection
// ---------------------------------------------------------------------------

/// The format of a secret file.
enum SecretFileFormat { v2, opensslSalted, legacyBase64, unknown }

/// Detects the format of a secret file without decrypting it.
///
/// - [SecretFileFormat.v2] when the file starts with the line
///   `nix-infra-secret/v2`.
/// - Otherwise ASCII whitespace is removed and the rest is base64-decoded:
///   `Salted__` + 8-byte salt + whole AES blocks is
///   [SecretFileFormat.opensslSalted]; valid UTF-8 is
///   [SecretFileFormat.legacyBase64].
/// - Anything else is [SecretFileFormat.unknown].
SecretFileFormat detectSecretFormat(Uint8List bytes) {
  if (_startsWith(bytes, _v2MagicLine)) return SecretFileFormat.v2;
  final decoded = _decodeLegacyBase64(bytes);
  if (decoded == null) return SecretFileFormat.unknown;
  if (_isOpensslSalted(decoded)) return SecretFileFormat.opensslSalted;
  if (_strictUtf8(decoded) != null) return SecretFileFormat.legacyBase64;
  return SecretFileFormat.unknown;
}

bool _isOpensslSalted(Uint8List decoded) {
  final headerLength = _saltedMagic.length + _opensslSaltLength;
  return _startsWith(decoded, _saltedMagic) &&
      decoded.length >= headerLength + _aesBlockLength &&
      (decoded.length - headerLength) % _aesBlockLength == 0;
}

// ---------------------------------------------------------------------------
// Files key
// ---------------------------------------------------------------------------

/// Generates a new files key: `nisk1_` + 43 base64url characters (256
/// random bits from `Random.secure()`).
String generateFilesKey() {
  final encoded = base64Url.encode(_randomBytes(_filesKeyLength));
  return '$kFilesKeyPrefix${encoded.replaceAll('=', '')}';
}

/// True when [key] is a generated files key: the prefix `nisk1_`, exactly
/// 43 base64url characters, decoding to 32 bytes.
bool isGeneratedFilesKey(String key) => _decodeFilesKey(key) != null;

/// The `key_id` of a generated files key: the first 8 hex characters of
/// SHA-256(`nix-infra-secret/key-id` || key bytes).
///
/// Throws [ArgumentError] when [key] is not a generated files key. The
/// message does not contain the key.
String filesKeyId(String key) {
  final bytes = _decodeFilesKey(key);
  if (bytes == null) {
    throw ArgumentError(
      'is not a generated files key ($kFilesKeyPrefix followed by '
          '$_filesKeyEncodedLength base64url characters)',
      'key',
    );
  }
  return _keyIdOf(bytes);
}

Uint8List? _decodeFilesKey(String key) {
  if (key.length != kFilesKeyPrefix.length + _filesKeyEncodedLength ||
      !key.startsWith(kFilesKeyPrefix)) {
    return null;
  }
  final body = key.substring(kFilesKeyPrefix.length);
  if (!_base64UrlKeyPattern.hasMatch(body)) return null;
  final padded = '$body=';
  try {
    final bytes = base64Url.decode(padded);
    if (bytes.length != _filesKeyLength) return null;
    // Refuse non-canonical encodings (non-zero unused bits in the last
    // character), so one key has exactly one text form.
    if (base64Url.encode(bytes) != padded) return null;
    return bytes;
  } on FormatException {
    return null;
  }
}

String _keyIdOf(Uint8List keyBytes) => crypto.sha256
    .convert([...utf8.encode(_keyIdLabel), ...keyBytes])
    .toString()
    .substring(0, 8);

// ---------------------------------------------------------------------------
// v2 header
// ---------------------------------------------------------------------------

/// The key derivation function of a v2 file.
enum SecretKdf {
  hkdfSha256('hkdf-sha256'),
  pbkdf2HmacSha256('pbkdf2-hmac-sha256');

  const SecretKdf(this.id);

  /// The value of the `kdf` header field.
  final String id;

  static SecretKdf? _fromId(String id) {
    for (final kdf in values) {
      if (kdf.id == id) return kdf;
    }
    return null;
  }
}

/// The parsed header of a v2 secret file.
class SecretV2Header {
  const SecretV2Header({
    required this.kind,
    required this.created,
    required this.kdf,
    required this.salt,
    required this.nonce,
    this.iterations,
    this.keyId,
  });

  /// `text` or `github-netrc` (other lowercase tokens are read too).
  final String kind;

  /// UTC, seconds precision.
  final DateTime created;

  final SecretKdf kdf;

  /// PBKDF2 iterations; only for [SecretKdf.pbkdf2HmacSha256].
  final int? iterations;

  /// 16 bytes.
  final Uint8List salt;

  /// 12 bytes.
  final Uint8List nonce;

  /// 8 hex characters; only for [SecretKdf.hkdfSha256].
  final String? keyId;

  @override
  String toString() =>
      'SecretV2Header(kind: $kind, '
      'created: ${_formatCreated(created)}, kdf: ${kdf.id}'
      '${iterations != null ? ', iterations: $iterations' : ''}'
      '${keyId != null ? ', key_id: $keyId' : ''})';
}

/// Parses the header of a v2 secret file without decrypting it, so callers
/// can list metadata cheaply.
///
/// Throws [SecretFormatUnknown] when [bytes] is not a v2 file or the header
/// breaks the reader limits.
SecretV2Header parseSecretV2Header(Uint8List bytes) =>
    _parseV2Header(bytes).header;

class _ParsedV2Header {
  _ParsedV2Header(this.header, this.headerLength);

  final SecretV2Header header;

  /// Length of the header bytes (the AAD).
  final int headerLength;
}

_ParsedV2Header _parseV2Header(Uint8List bytes) {
  if (!_startsWith(bytes, _v2MagicLine)) {
    throw const SecretFormatUnknown('Not a $kSecretV2Magic file');
  }
  final headerLength = _findV2HeaderEnd(bytes);
  final String text;
  try {
    text = ascii.decode(Uint8List.sublistView(bytes, 0, headerLength));
  } on FormatException {
    throw const SecretFormatUnknown('The v2 header is not ASCII');
  }
  final lines = text.split('\n');
  // The header ends with a newline, so the last element is empty.
  final fields = <String, String>{};
  for (var i = 1; i < lines.length - 1; i++) {
    final match = _headerLinePattern.firstMatch(lines[i]);
    if (match == null) {
      throw SecretFormatUnknown('Malformed v2 header line ${i + 1}');
    }
    final name = match.group(1)!;
    if (!_headerFields.contains(name)) {
      throw SecretFormatUnknown('Unknown v2 header field on line ${i + 1}');
    }
    if (fields.containsKey(name)) {
      throw SecretFormatUnknown('Duplicate v2 header field "$name"');
    }
    fields[name] = match.group(2)!;
  }

  String require(String name) {
    final value = fields[name];
    if (value == null) {
      throw SecretFormatUnknown('Missing v2 header field "$name"');
    }
    return value;
  }

  final kind = require('kind');
  if (!_kindPattern.hasMatch(kind)) {
    throw const SecretFormatUnknown('Invalid v2 header field "kind"');
  }
  final created = _parseCreated(require('created'));
  final kdf = SecretKdf._fromId(require('kdf'));
  if (kdf == null) {
    throw const SecretFormatUnknown('Unsupported v2 kdf');
  }
  if (require('cipher') != _cipherAes256Gcm) {
    throw const SecretFormatUnknown('Unsupported v2 cipher');
  }
  final salt = _parseHeaderBytes(require('salt'), 'salt', _saltLength);
  final nonce = _parseHeaderBytes(require('nonce'), 'nonce', _nonceLength);

  int? iterations;
  String? keyId;
  switch (kdf) {
    case SecretKdf.hkdfSha256:
      if (fields.containsKey('iterations')) {
        throw const SecretFormatUnknown(
          'v2 header field "iterations" is not allowed with hkdf-sha256',
        );
      }
      keyId = require('key_id');
      if (!_keyIdPattern.hasMatch(keyId)) {
        throw const SecretFormatUnknown('Invalid v2 header field "key_id"');
      }
    case SecretKdf.pbkdf2HmacSha256:
      if (fields.containsKey('key_id')) {
        throw const SecretFormatUnknown(
          'v2 header field "key_id" is not allowed with pbkdf2-hmac-sha256',
        );
      }
      final value = require('iterations');
      iterations = _iterationsPattern.hasMatch(value) ? int.parse(value) : null;
      if (iterations == null ||
          iterations < kMinPbkdf2Iterations ||
          iterations > kMaxPbkdf2Iterations) {
        throw const SecretFormatUnknown(
          'v2 header field "iterations" must be between '
          '$kMinPbkdf2Iterations and $kMaxPbkdf2Iterations',
        );
      }
  }

  return _ParsedV2Header(
    SecretV2Header(
      kind: kind,
      created: created,
      kdf: kdf,
      iterations: iterations,
      salt: salt,
      nonce: nonce,
      keyId: keyId,
    ),
    headerLength,
  );
}

/// Returns the length of the header: the index after the newline that
/// precedes the `---` line.
int _findV2HeaderEnd(Uint8List bytes) {
  const nl = 0x0a;
  const dash = 0x2d;
  // `i` is the index of the newline before `---`.
  for (
    var i = _v2MagicLine.length - 1;
    i + 1 <= kMaxSecretV2HeaderLength && i + 4 < bytes.length;
    i++
  ) {
    if (bytes[i] == nl &&
        bytes[i + 1] == dash &&
        bytes[i + 2] == dash &&
        bytes[i + 3] == dash &&
        bytes[i + 4] == nl) {
      return i + 1;
    }
  }
  throw const SecretFormatUnknown(
    'No end of v2 header ("---") within $kMaxSecretV2HeaderLength bytes',
  );
}

Uint8List _parseHeaderBytes(String value, String name, int length) {
  if (value.length % 4 == 0 && _base64Pattern.hasMatch(value)) {
    try {
      final bytes = base64.decode(value);
      if (bytes.length == length) return bytes;
    } on FormatException {
      // Reported below.
    }
  }
  throw SecretFormatUnknown(
    'v2 header field "$name" must be base64 of $length bytes',
  );
}

DateTime _parseCreated(String value) {
  if (_createdPattern.hasMatch(value)) {
    final parsed = DateTime.tryParse(value);
    // The round trip refuses values like month 13 that DateTime normalizes.
    if (parsed != null && parsed.isUtc && _formatCreated(parsed) == value) {
      return parsed;
    }
  }
  throw const SecretFormatUnknown('Invalid v2 header field "created"');
}

String _formatCreated(DateTime time) {
  final t = time.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}Z';
}

DateTime _truncateToSeconds(DateTime time) {
  final t = time.toUtc();
  return DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
}

String _formatV2Header(SecretV2Header h) {
  final out = StringBuffer()
    ..write('$kSecretV2Magic\n')
    ..write('kind: ${h.kind}\n')
    ..write('created: ${_formatCreated(h.created)}\n')
    ..write('kdf: ${h.kdf.id}\n');
  if (h.iterations != null) out.write('iterations: ${h.iterations}\n');
  out
    ..write('salt: ${base64.encode(h.salt)}\n')
    ..write('cipher: $_cipherAes256Gcm\n')
    ..write('nonce: ${base64.encode(h.nonce)}\n');
  if (h.keyId != null) out.write('key_id: ${h.keyId}\n');
  return out.toString();
}

// ---------------------------------------------------------------------------
// v2 encryption
// ---------------------------------------------------------------------------

/// Encrypts [plaintext] as a `nix-infra-secret/v2` file.
///
/// [key] is a generated files key ([isGeneratedFilesKey], HKDF-SHA256) or a
/// password (PBKDF2-HMAC-SHA256 with [iterations]). [kind] is
/// [kSecretKindText] or [kSecretKindGithubNetrc] (any lowercase token of
/// letters, digits and `-` is accepted). [created] is stored in UTC with
/// seconds precision. Every call uses a new random salt and nonce.
///
/// Throws [ArgumentError] for an empty key, a key with the `nisk1_` prefix
/// that is not a valid generated files key, an invalid [kind] or
/// [iterations] out of range. Messages never contain the key or plaintext.
Future<Uint8List> encryptSecretV2({
  required String plaintext,
  required String key,
  required String kind,
  required DateTime created,
  int iterations = kDefaultPbkdf2Iterations,
}) async {
  if (!_kindPattern.hasMatch(kind)) {
    throw ArgumentError('must be a lowercase token like "text"', 'kind');
  }
  if (key.isEmpty) throw ArgumentError('must not be empty', 'key');
  final filesKey = _decodeFilesKey(key);
  if (filesKey == null && key.startsWith(kFilesKeyPrefix)) {
    throw ArgumentError(
      'starts with $kFilesKeyPrefix but is not a valid generated files key',
      'key',
    );
  }
  if (filesKey == null &&
      (iterations < kMinPbkdf2Iterations ||
          iterations > kMaxPbkdf2Iterations)) {
    throw ArgumentError(
      'must be between $kMinPbkdf2Iterations and $kMaxPbkdf2Iterations',
      'iterations',
    );
  }

  final header = SecretV2Header(
    kind: kind,
    created: _truncateToSeconds(created),
    kdf: filesKey != null ? SecretKdf.hkdfSha256 : SecretKdf.pbkdf2HmacSha256,
    iterations: filesKey != null ? null : iterations,
    salt: _randomBytes(_saltLength),
    nonce: _randomBytes(_nonceLength),
    keyId: filesKey != null ? _keyIdOf(filesKey) : null,
  );
  final headerBytes = ascii.encode(_formatV2Header(header));
  final fileKey = await _deriveV2FileKey(header, key, filesKey);
  final box = _aesGcm.encryptSync(
    utf8.encode(plaintext),
    secretKeyData: SecretKeyData(fileKey),
    nonce: header.nonce,
    aad: headerBytes,
  );
  final body = base64.encode([...box.cipherText, ...box.mac.bytes]);

  final out = BytesBuilder(copy: false)
    ..add(headerBytes)
    ..add(ascii.encode('---\n'));
  for (var i = 0; i < body.length; i += _bodyLineLength) {
    final end = min(i + _bodyLineLength, body.length);
    out.add(ascii.encode('${body.substring(i, end)}\n'));
  }
  return out.toBytes();
}

Future<Uint8List> _deriveV2FileKey(
  SecretV2Header header,
  String key,
  Uint8List? filesKey,
) async {
  switch (header.kdf) {
    case SecretKdf.hkdfSha256:
      final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(
            secretKey: SecretKey(filesKey!),
            nonce: header.salt,
            info: utf8.encode(_hkdfInfo),
          );
      return Uint8List.fromList(await derived.extractBytes());
    case SecretKdf.pbkdf2HmacSha256:
      return _pbkdf2Sha256(
        utf8.encode(key),
        header.salt,
        header.iterations!,
        32,
      );
  }
}

// ---------------------------------------------------------------------------
// Decryption
// ---------------------------------------------------------------------------

/// A decrypted secret file.
class DecryptedSecret {
  const DecryptedSecret({
    required this.format,
    required this.plaintext,
    this.kind,
    this.created,
  });

  /// The format the file was stored in.
  final SecretFileFormat format;

  /// The value, byte for byte as it was stored.
  final String plaintext;

  /// The `kind` of a v2 file; null for legacy files.
  final String? kind;

  /// The `created` time of a v2 file; null for legacy files.
  final DateTime? created;

  /// Does not contain the plaintext.
  @override
  String toString() =>
      'DecryptedSecret(format: ${format.name}'
      '${kind != null ? ', kind: $kind' : ''})';
}

/// Decrypts a secret file in any supported format.
///
/// [key] is not needed for [SecretFileFormat.legacyBase64] files. For v2
/// files the key type and `key_id` are checked before the key derivation
/// ([SecretKeyMismatch]). OpenSSL files are tried with AES-256-CBC and, in
/// this order, PBKDF2-HMAC-SHA256 (10000 iterations), EVP_BytesToKey with
/// SHA-256 and EVP_BytesToKey with MD5; the first result with valid PKCS#7
/// padding and valid UTF-8 wins.
///
/// Throws [SecretFormatUnknown], [SecretDecryptFailed] or
/// [SecretKeyMismatch].
Future<DecryptedSecret> decryptSecret(Uint8List bytes, {String? key}) async {
  switch (detectSecretFormat(bytes)) {
    case SecretFileFormat.v2:
      return _decryptV2(bytes, key);
    case SecretFileFormat.opensslSalted:
      return _decryptOpenssl(bytes, key);
    case SecretFileFormat.legacyBase64:
      return DecryptedSecret(
        format: SecretFileFormat.legacyBase64,
        plaintext: _strictUtf8(_decodeLegacyBase64(bytes)!)!,
      );
    case SecretFileFormat.unknown:
      throw const SecretFormatUnknown(
        'Not a nix-infra secret file (v2, OpenSSL or base64)',
      );
  }
}

Future<DecryptedSecret> _decryptV2(Uint8List bytes, String? key) async {
  final parsed = _parseV2Header(bytes);
  final header = parsed.header;
  final payload = _parseV2Body(bytes, parsed.headerLength);

  if (key == null || key.isEmpty) {
    throw const SecretDecryptFailed('A key is required to decrypt this file');
  }
  final filesKey = _decodeFilesKey(key);
  switch (header.kdf) {
    case SecretKdf.hkdfSha256:
      if (filesKey == null) {
        throw SecretKeyMismatch(
          'The file was encrypted with the generated files key '
          '${header.keyId}, but the given key is not a generated files key',
        );
      }
      final keyId = _keyIdOf(filesKey);
      if (keyId != header.keyId) {
        throw SecretKeyMismatch(
          'The file was encrypted with the files key ${header.keyId}, '
          'but the given key is $keyId',
        );
      }
    case SecretKdf.pbkdf2HmacSha256:
      if (filesKey != null) {
        throw const SecretKeyMismatch(
          'The file was encrypted with a password, '
          'but the given key is a generated files key',
        );
      }
      if (key.startsWith(kFilesKeyPrefix)) {
        throw const SecretKeyMismatch(
          'The given key starts with $kFilesKeyPrefix but is not a valid '
          'generated files key',
        );
      }
  }

  final fileKey = await _deriveV2FileKey(header, key, filesKey);
  final List<int> clear;
  try {
    clear = _aesGcm.decryptSync(
      SecretBox(
        payload.sublist(0, payload.length - _tagLength),
        nonce: header.nonce,
        mac: Mac(payload.sublist(payload.length - _tagLength)),
      ),
      secretKeyData: SecretKeyData(fileKey),
      aad: Uint8List.sublistView(bytes, 0, parsed.headerLength),
    );
  } on SecretBoxAuthenticationError {
    throw const SecretDecryptFailed('Wrong key, or the file was modified');
  }
  final plaintext = _strictUtf8(clear);
  if (plaintext == null) {
    throw const SecretDecryptFailed('The decrypted value is not valid UTF-8');
  }
  return DecryptedSecret(
    format: SecretFileFormat.v2,
    plaintext: plaintext,
    kind: header.kind,
    created: header.created,
  );
}

Uint8List _parseV2Body(Uint8List bytes, int headerLength) {
  // Skip "---\n".
  final body = Uint8List.sublistView(bytes, headerLength + 4);
  final payload = _decodeLegacyBase64(body);
  if (payload == null || payload.length < _tagLength) {
    throw const SecretFormatUnknown('Invalid v2 body');
  }
  return payload;
}

// ---------------------------------------------------------------------------
// Legacy OpenSSL reader
// ---------------------------------------------------------------------------

enum _OpensslKdf { pbkdf2Sha256, bytesToKeySha256, bytesToKeyMd5 }

const _opensslCannotOpen =
    'This is an OpenSSL encrypted file that nix-infra cannot open: the key is '
    'wrong, or the file was not made with AES-256-CBC and PBKDF2 or '
    'EVP_BytesToKey. Decrypt it manually with `openssl enc -d -a '
    '-<cipher> [-pbkdf2] [-md <digest>] -in <file>` and store the value again';

Future<DecryptedSecret> _decryptOpenssl(Uint8List bytes, String? key) async {
  if (key == null || key.isEmpty) {
    throw const SecretDecryptFailed(
      'key required to decrypt this OpenSSL file',
    );
  }
  final data = _decodeLegacyBase64(bytes)!;
  final saltEnd = _saltedMagic.length + _opensslSaltLength;
  final salt = data.sublist(_saltedMagic.length, saltEnd);
  final cipherText = data.sublist(saltEnd);
  final password = utf8.encode(key);

  for (final variant in _OpensslKdf.values) {
    final keyIv = await _opensslKeyIv(variant, password, salt);
    final clear = await _tryAesCbcDecrypt(
      Uint8List.sublistView(keyIv, 0, 32),
      Uint8List.sublistView(keyIv, 32, 48),
      cipherText,
    );
    if (clear == null) continue;
    final plaintext = _strictUtf8(clear);
    if (plaintext != null) {
      return DecryptedSecret(
        format: SecretFileFormat.opensslSalted,
        plaintext: plaintext,
      );
    }
  }
  throw const SecretDecryptFailed(_opensslCannotOpen);
}

/// 32 key bytes followed by 16 IV bytes.
Future<Uint8List> _opensslKeyIv(
  _OpensslKdf variant,
  List<int> password,
  List<int> salt,
) async {
  switch (variant) {
    case _OpensslKdf.pbkdf2Sha256:
      return _pbkdf2Sha256(password, salt, _opensslPbkdf2Iterations, 48);
    case _OpensslKdf.bytesToKeySha256:
      return _evpBytesToKey(crypto.sha256, password, salt, 48);
    case _OpensslKdf.bytesToKeyMd5:
      return _evpBytesToKey(crypto.md5, password, salt, 48);
  }
}

/// OpenSSL `EVP_BytesToKey` with count 1:
/// D_1 = HASH(password || salt), D_i = HASH(D_{i-1} || password || salt).
Uint8List _evpBytesToKey(
  crypto.Hash hash,
  List<int> password,
  List<int> salt,
  int length,
) {
  final out = BytesBuilder(copy: false);
  var previous = <int>[];
  while (out.length < length) {
    previous = hash.convert([...previous, ...password, ...salt]).bytes;
    out.add(previous);
  }
  return Uint8List.sublistView(out.toBytes(), 0, length);
}

/// Returns null when the ciphertext does not decrypt to valid PKCS#7
/// padding.
Future<Uint8List?> _tryAesCbcDecrypt(
  Uint8List key,
  Uint8List iv,
  Uint8List cipherText,
) async {
  if (cipherText.isEmpty || cipherText.length % _aesBlockLength != 0) {
    return null;
  }
  try {
    final clear = await _aesCbc.decrypt(
      SecretBox(cipherText, nonce: iv, mac: Mac.empty),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(clear);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<Uint8List> _pbkdf2Sha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int length,
) async {
  final derived = await Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: length * 8,
  ).deriveKey(secretKey: SecretKey(password), nonce: salt);
  return Uint8List.fromList(await derived.extractBytes());
}

/// Removes ASCII whitespace and decodes standard base64. Returns null when
/// the rest is not base64.
Uint8List? _decodeLegacyBase64(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    if (_isAsciiWhitespace(b)) continue;
    if (b > 0x7f) return null;
    buffer.writeCharCode(b);
  }
  final text = buffer.toString();
  if (text.length % 4 != 0 || !_base64Pattern.hasMatch(text)) return null;
  try {
    return base64.decode(text);
  } on FormatException {
    return null;
  }
}

bool _isAsciiWhitespace(int b) =>
    b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0b || b == 0x0c || b == 0x0d;

String? _strictUtf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

Uint8List _randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _random.nextInt(256);
  }
  return out;
}
