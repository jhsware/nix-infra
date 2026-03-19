import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:nix_infra/archive_unpacker.dart';
import 'package:nix_infra/nar.dart';
import 'package:nix_infra/nix_hash.dart';

/// Helper to create a tar.gz archive from an Archive object.
Uint8List _makeTarGz(Archive archive) {
  final tarBytes = TarEncoder().encode(archive);
  final gzBytes = GZipEncoder().encode(tarBytes);
  return Uint8List.fromList(gzBytes);
}

/// Helper to create a zip archive from an Archive object.
Uint8List _makeZip(Archive archive) {
  final zipBytes = ZipEncoder().encode(archive);
  return Uint8List.fromList(zipBytes);
}

void main() {
  group('ArchiveUnpacker', () {
    group('detectType', () {
      test('detects tar.gz from URL', () {
        expect(
          ArchiveUnpacker.detectType(
              'https://github.com/owner/repo/archive/v1.0.tar.gz'),
          equals(ArchiveType.tarGz),
        );
      });

      test('detects tgz from URL', () {
        expect(
          ArchiveUnpacker.detectType('https://example.com/file.tgz'),
          equals(ArchiveType.tarGz),
        );
      });

      test('detects zip from URL', () {
        expect(
          ArchiveUnpacker.detectType(
              'https://github.com/owner/repo/archive/v1.0.zip'),
          equals(ArchiveType.zip),
        );
      });

      test('defaults to tar.gz for GitHub archive URLs', () {
        expect(
          ArchiveUnpacker.detectType(
              'https://github.com/owner/repo/archive/abc123'),
          equals(ArchiveType.tarGz),
        );
      });

      test('throws for unknown URL format', () {
        expect(
          () => ArchiveUnpacker.detectType('https://example.com/file.dat'),
          throwsArgumentError,
        );
      });
    });

    group('unpack tar.gz', () {
      test('unpacks and strips single top-level directory', () {
        final archive = Archive();
        archive.addFile(
          ArchiveFile.bytes(
            'repo-v1.0.0/README.md',
            utf8.encode('# Hello World'),
          ),
        );
        archive.addFile(
          ArchiveFile.bytes(
            'repo-v1.0.0/src/main.dart',
            utf8.encode('void main() {}'),
          ),
        );

        final result = ArchiveUnpacker.unpack(
          _makeTarGz(archive),
          ArchiveType.tarGz,
        );

        // Should be a directory (the stripped repo-v1.0.0)
        expect(result, isA<NarDirectory>());
        final dir = result as NarDirectory;

        // Should contain README.md and src/
        expect(dir.entries.containsKey('README.md'), isTrue);
        expect(dir.entries.containsKey('src'), isTrue);

        // README.md should be a file with correct content
        final readme = dir.entries['README.md'] as NarFile;
        expect(utf8.decode(readme.contents), equals('# Hello World'));

        // src should be a directory containing main.dart
        final srcDir = dir.entries['src'] as NarDirectory;
        expect(srcDir.entries.containsKey('main.dart'), isTrue);
        final mainDart = srcDir.entries['main.dart'] as NarFile;
        expect(utf8.decode(mainDart.contents), equals('void main() {}'));
      });

      test('does not strip when multiple top-level entries exist', () {
        final archive = Archive();
        archive.addFile(
          ArchiveFile.bytes('file1.txt', utf8.encode('content 1')),
        );
        archive.addFile(
          ArchiveFile.bytes('file2.txt', utf8.encode('content 2')),
        );

        final result = ArchiveUnpacker.unpack(
          _makeTarGz(archive),
          ArchiveType.tarGz,
        );

        // Should be a directory with two files (no stripping)
        expect(result, isA<NarDirectory>());
        final dir = result as NarDirectory;
        expect(dir.entries.length, equals(2));
        expect(dir.entries.containsKey('file1.txt'), isTrue);
        expect(dir.entries.containsKey('file2.txt'), isTrue);
      });

      test('does not strip when single top-level entry is a file', () {
        final archive = Archive();
        archive.addFile(
          ArchiveFile.bytes('single-file.txt', utf8.encode('alone')),
        );

        final result = ArchiveUnpacker.unpack(
          _makeTarGz(archive),
          ArchiveType.tarGz,
        );

        expect(result, isA<NarDirectory>());
        final dir = result as NarDirectory;
        expect(dir.entries.length, equals(1));
        expect(dir.entries.containsKey('single-file.txt'), isTrue);
      });
    });

    group('unpack zip', () {
      test('unpacks zip and strips single top-level directory', () {
        final archive = Archive();
        archive.addFile(
          ArchiveFile.bytes(
            'project-main/index.html',
            utf8.encode('<h1>Hello</h1>'),
          ),
        );
        archive.addFile(
          ArchiveFile.bytes(
            'project-main/style.css',
            utf8.encode('body { color: red; }'),
          ),
        );

        final result = ArchiveUnpacker.unpack(
          _makeZip(archive),
          ArchiveType.zip,
        );

        expect(result, isA<NarDirectory>());
        final dir = result as NarDirectory;
        expect(dir.entries.containsKey('index.html'), isTrue);
        expect(dir.entries.containsKey('style.css'), isTrue);
      });
    });

    group('NAR hash of unpacked archive', () {
      test('produces deterministic hash', () {
        final archive = Archive();
        archive.addFile(
          ArchiveFile.bytes(
            'myrepo-abc123/hello.txt',
            utf8.encode('hello world'),
          ),
        );

        final gzBytes = _makeTarGz(archive);
        final hash1 = NixHash.sha256UnpackNix32(gzBytes);
        final hash2 = NixHash.sha256UnpackNix32(gzBytes);
        expect(hash1, equals(hash2));
        expect(hash1.length, equals(52));
      });

      test('sha256UnpackAll returns all formats', () {
        final archive = Archive();
        archive.addFile(
          ArchiveFile.bytes(
            'repo-v1/file.txt',
            utf8.encode('test'),
          ),
        );

        final gzBytes = _makeTarGz(archive);
        final allHashes = NixHash.sha256UnpackAll(gzBytes);
        expect(allHashes.containsKey('nix32'), isTrue);
        expect(allHashes.containsKey('sri'), isTrue);
        expect(allHashes.containsKey('hex'), isTrue);
        expect(allHashes['nix32']!.length, equals(52));
        expect(allHashes['sri']!, startsWith('sha256-'));
        expect(allHashes['hex']!.length, equals(64));
      });

      test('different archive content produces different hash', () {
        NarNode makeArchive(String content) {
          final archive = Archive();
          archive.addFile(
            ArchiveFile.bytes('repo-v1/file.txt', utf8.encode(content)),
          );
          return ArchiveUnpacker.unpack(
            _makeTarGz(archive),
            ArchiveType.tarGz,
          );
        }

        final hash1 = NixHash.sha256NarNix32(makeArchive('content A'));
        final hash2 = NixHash.sha256NarNix32(makeArchive('content B'));
        expect(hash1, isNot(equals(hash2)));
      });
    });
  });
}
