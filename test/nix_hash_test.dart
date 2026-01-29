import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:nix_infra/nix_hash.dart';

void main() {
  group('NixHash', () {
    group('toNix32/fromNix32', () {
      test('round-trip encoding/decoding', () {
        // Test with a known SHA256 hash (32 bytes)
        final original = Uint8List.fromList(List.generate(32, (i) => i));
        final encoded = NixHash.toNix32(original);
        final decoded = NixHash.fromNix32(encoded);
        
        expect(decoded, equals(original));
      });

      test('encodes empty bytes', () {
        final empty = Uint8List(0);
        final encoded = NixHash.toNix32(empty);
        expect(encoded, isEmpty);
      });

      test('round-trip with random-ish data', () {
        // Test with various byte patterns
        for (final seed in [0, 42, 128, 255]) {
          final original = Uint8List.fromList(
            List.generate(32, (i) => (i * seed + i) % 256),
          );
          final encoded = NixHash.toNix32(original);
          final decoded = NixHash.fromNix32(encoded);
          expect(decoded, equals(original), reason: 'Failed for seed $seed');
        }
      });
    });

    group('sha256Nix32', () {
      // These expected values are verified against actual nix:
      // echo -n "" | nix hash file --base32 /dev/stdin
      // echo -n "hello" | nix hash file --base32 /dev/stdin
      
      test('hashes empty input to known nix value', () {
        final empty = Uint8List(0);
        final hash = NixHash.sha256Nix32(empty);
        
        // Verified: echo -n "" | nix hash file --base32 /dev/stdin
        expect(hash, equals('0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73'));
      });

      test('hashes "hello" to known nix value', () {
        final hello = Uint8List.fromList(utf8.encode('hello'));
        final hash = NixHash.sha256Nix32(hello);
        
        // Verified: echo -n "hello" | nix hash file --base32 /dev/stdin
        expect(hash, equals('094qif9n4cq4fdg459qzbhg1c6wywawwaaivx0k0x8xhbyx4vwic'));
      });

      test('produces 52-character output for 32-byte hash', () {
        // SHA256 always produces 32 bytes = 52 nix32 characters
        expect(NixHash.sha256Nix32(Uint8List(0)).length, equals(52));
        expect(NixHash.sha256Nix32(Uint8List.fromList([1, 2, 3])).length, equals(52));
      });

      test('only uses nix32 alphabet characters', () {
        final hash = NixHash.sha256Nix32(Uint8List.fromList(utf8.encode('test')));
        final nix32Chars = '0123456789abcdfghijklmnpqrsvwxyz'.split('');
        for (final char in hash.split('')) {
          expect(nix32Chars, contains(char), reason: 'Invalid char: $char');
        }
      });
    });

    group('sha256Sri', () {
      test('produces valid SRI format for empty input', () {
        final empty = Uint8List(0);
        final sri = NixHash.sha256Sri(empty);
        
        // SHA256 of empty string in SRI format
        expect(sri, equals('sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU='));
      });

      test('produces valid SRI format for hello', () {
        final hello = Uint8List.fromList(utf8.encode('hello'));
        final sri = NixHash.sha256Sri(hello);
        
        expect(sri, startsWith('sha256-'));
        // SRI hash should be valid base64
        final base64Part = sri.substring(7);
        expect(() => base64.decode(base64Part), returnsNormally);
        expect(sri, equals('sha256-LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ='));
      });
    });

    group('sha256Hex', () {
      test('hashes empty to known hex value', () {
        final empty = Uint8List(0);
        final hex = NixHash.sha256Hex(empty);
        
        expect(
          hex,
          equals('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'),
        );
      });

      test('hashes "hello" to known hex value', () {
        final hello = Uint8List.fromList(utf8.encode('hello'));
        final hex = NixHash.sha256Hex(hello);
        
        expect(
          hex,
          equals('2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'),
        );
      });
    });

    group('hexToBytes/bytesToHex', () {
      test('round-trip conversion', () {
        final original = 'deadbeef0123456789abcdef';
        final bytes = NixHash.hexToBytes(original);
        final hex = NixHash.bytesToHex(bytes);
        
        expect(hex, equals(original));
      });

      test('converts known values', () {
        final bytes = NixHash.hexToBytes('0102030405');
        expect(bytes, equals(Uint8List.fromList([1, 2, 3, 4, 5])));
      });
    });

    group('format conversions', () {
      test('all formats produce consistent results', () {
        final data = Uint8List.fromList(utf8.encode('test data'));
        
        // Get hash in all formats
        final nix32 = NixHash.sha256Nix32(data);
        final sri = NixHash.sha256Sri(data);
        final hex = NixHash.sha256Hex(data);
        
        // Convert hex back to bytes
        final hashBytes = NixHash.hexToBytes(hex);
        
        // Verify nix32 encodes the same bytes
        expect(NixHash.toNix32(hashBytes), equals(nix32));
        
        // Verify SRI contains same hash in base64
        final sriBase64 = sri.substring(7);
        expect(base64.encode(hashBytes), equals(sriBase64));
      });

      test('nix32 encoding matches hex when converted through bytes', () {
        // For any input, sha256Nix32 should equal toNix32(hexToBytes(sha256Hex))
        for (final input in ['', 'hello', 'test data', 'longer test string']) {
          final data = Uint8List.fromList(utf8.encode(input));
          final nix32Direct = NixHash.sha256Nix32(data);
          final hex = NixHash.sha256Hex(data);
          final nix32ViaHex = NixHash.toNix32(NixHash.hexToBytes(hex));
          expect(nix32Direct, equals(nix32ViaHex), reason: 'Mismatch for "$input"');
        }
      });
    });
  });
}
