// The limit of the MCP tool `file-upload` (docs/design/ssh_agent_keys.md
// §9): local paths inside the project folder only, and not in ssh/ or
// secrets/. Tested here:
// - the rule (resolveProjectPath of bin/mcp_server/utils/project_path.dart),
//   with a temporary project folder and folders outside it;
// - the check phase of the tool (uploadPlan): every entry of a folder;
// - the tool (FileUpload.callback) with a fake provider and no network: a
//   refused path does not even look up a machine;
// - one upload over SFTP to a local `sshd` (skipped when `ssh-keygen` or
//   `sshd` cannot be found). The tool itself connects to port 22 only, so
//   this test drives the upload part (sendUploadPlan) on its own client.
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../bin/mcp_server/file_upload.dart';
import '../../bin/mcp_server/utils/project_path.dart';
import '../support/ssh_test_env.dart';

const _timeout = Duration(seconds: 10);

String textOf(CallToolResult result) =>
    (result.content.first as TextContent).text;

/// A provider that lists [nodes] and counts the calls of [getServers].
class _CountingProvider implements InfrastructureProvider {
  _CountingProvider(this.nodes);

  final List<ClusterNode> nodes;
  int getServersCalls = 0;

  @override
  Future<Iterable<ClusterNode>> getServers({List<String>? only}) async {
    getServersCalls++;
    return nodes.where((n) => only == null || only.contains(n.name));
  }

  @override
  String get providerName => 'Counting';

  @override
  bool get supportsCreateServer => false;

  @override
  bool get supportsAddSshKey => false;

  @override
  bool get supportsDestroyServer => false;

  @override
  bool get supportsPlacementGroups => false;

  @override
  Future<void> createServer(String name, String machineType, String location,
          String sshKeyName, int? placementGroupId) =>
      throw UnsupportedError('not in this test');

  @override
  Future<void> destroyServer(int id) =>
      throw UnsupportedError('not in this test');

  @override
  Future<String?> getIpAddr(String name) async => null;

  @override
  Future<void> addSshKeyToCloudProvider(
      Directory workingDir, String keyName) async {}

  @override
  Future<void> removeSshKeyFromCloudProvider(
      Directory workingDir, String keyName) async {}
}

void main() {
  // base/
  //   proj/        the project folder
  //   proj2/       named like the project plus a suffix (string prefix trap)
  //   outside/     a folder outside the project
  //   outside.txt
  late Directory base;
  late Directory project;
  late Directory outside;
  late Directory trap;
  late String projectReal;

  String inProject(String relative) => p.join(project.path, relative);

  void write(String path, [String content = 'x']) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  void link(String path, String target) =>
      Link(path).createSync(target, recursive: true);

  setUp(() {
    base = Directory.systemTemp.createTempSync('nix_infra_file_upload_');
    project = Directory(p.join(base.path, 'proj'))..createSync();
    outside = Directory(p.join(base.path, 'outside'))..createSync();
    trap = Directory(p.join(base.path, 'proj2'))..createSync();

    write(inProject('file.txt'), 'file');
    write(inProject('sub/file.txt'), 'sub file');
    write(inProject('sub/.git/config'));
    write(inProject('modules/ssh/config.nix'));
    write(inProject('.env'), 'SECRET=1');
    write(inProject('ssh/test-key'));
    write(inProject('secrets/token'));
    write(p.join(base.path, 'outside.txt'));
    write(p.join(outside.path, 'outside.txt'));
    write(p.join(trap.path, 'file.txt'));

    link(inProject('link-in'), 'file.txt');
    link(inProject('link-out'), p.join(outside.path, 'outside.txt'));
    link(inProject('dir-out'), outside.path);
    link(inProject('trap-link'), trap.path);
    link(inProject('env-link'), '.env');
    link(inProject('key-link'), 'ssh/test-key');
    link(inProject('broken-link'), 'no-such-file');

    // On macOS the temporary folder is below a link (/var -> /private/var).
    projectReal = project.resolveSymbolicLinksSync();
  });

  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  /// The paths of the folders outside the project, as given and real: no
  /// error text may hold them.
  List<String> outsidePaths() => [
        outside.path,
        outside.resolveSymbolicLinksSync(),
        trap.path,
        trap.resolveSymbolicLinksSync(),
      ];

  void expectNoOutsidePath(String text) {
    for (final path in outsidePaths()) {
      expect(text, isNot(contains(path)));
    }
  }

  group('resolveProjectPath', () {
    /// The reason why the rule refuses [input].
    String reasonFor(String input, {Directory? projectDir}) {
      try {
        resolveProjectPath(projectDir ?? project, input);
      } on ProjectPathException catch (e) {
        return e.message;
      }
      fail('"$input" is allowed');
    }

    for (final (input, real) in [
      ('file.txt', 'file.txt'),
      ('sub/file.txt', 'sub/file.txt'),
      ('sub', 'sub'),
      ('sub/', 'sub'),
      (' file.txt ', 'file.txt'),
      ('link-in', 'file.txt'),
      // Only ssh/ and secrets/ at the top of the project are refused.
      ('modules/ssh/config.nix', 'modules/ssh/config.nix'),
    ]) {
      test('allows "$input"', () {
        expect(resolveProjectPath(project, input), p.join(projectReal, real));
      });
    }

    test('allows a path of a project folder reached through a link', () {
      final viaLink = Link(p.join(base.path, 'proj-link'))
        ..createSync(project.path);
      expect(resolveProjectPath(Directory(viaLink.path), 'sub/file.txt'),
          p.join(projectReal, 'sub/file.txt'));
    });

    const absolute = 'No absolute paths allowed';
    const hidden = 'No hidden files or directories allowed';
    const notFound = 'Local path not found';
    const outsideText = 'Path is outside the project folder';
    const protected = 'No files from ssh/ or secrets/ allowed';

    for (final (input, reason) in [
      ('', 'Empty local path'),
      ('  ', 'Empty local path'),
      ('/etc/hosts', '$absolute: /etc/hosts'),
      ('../outside.txt', '$hidden: ../outside.txt'),
      ('sub/../../outside.txt', '$hidden: sub/../../outside.txt'),
      ('./file.txt', '$hidden: ./file.txt'),
      ('.env', '$hidden: .env'),
      ('sub/.git/config', '$hidden: sub/.git/config'),
      ('missing.txt', '$notFound: missing.txt'),
      // A tilde is not expanded: it is a folder name in the project.
      ('~/file.txt', '$notFound: ~/file.txt'),
      ('broken-link', '$notFound: broken-link'),
      ('link-out', '$outsideText: link-out'),
      ('dir-out', '$outsideText: dir-out'),
      ('dir-out/outside.txt', '$outsideText: dir-out/outside.txt'),
      ('trap-link', '$outsideText: trap-link'),
      ('trap-link/file.txt', '$outsideText: trap-link/file.txt'),
      // A link inside the project to a hidden file or into ssh/.
      ('env-link', '$hidden: env-link'),
      ('key-link', '$protected: key-link'),
      ('ssh', '$protected: ssh'),
      ('ssh/test-key', '$protected: ssh/test-key'),
      ('ssh/missing', '$protected: ssh/missing'),
      ('secrets/token', '$protected: secrets/token'),
    ]) {
      test('refuses "$input": $reason', () {
        final text = reasonFor(input);
        expect(text, reason);
        expectNoOutsidePath(text);
      });
    }

    test('refuses the absolute path of a file inside the project', () {
      final input = inProject('file.txt');
      expect(reasonFor(input), '$absolute: $input');
    });

    // On a file system that ignores case (the default on macOS), `SSH/` is
    // the folder ssh/: the real path has the case on disk, so the rule
    // still refuses it. Elsewhere `SSH/` is another folder, here missing.
    for (final input in ['SSH/test-key', 'Ssh', 'SECRETS/token']) {
      test('refuses "$input", a case variant of ssh/ or secrets/', () {
        final ignoresCase = FileSystemEntity.typeSync(inProject(input)) !=
            FileSystemEntityType.notFound;
        expect(reasonFor(input),
            ignoresCase ? '$protected: $input' : '$notFound: $input');
      });
    }
  });

  group('uploadPlan', () {
    /// An entry as text: a folder ends with `/`.
    String entry(UploadEntry e) =>
        e.isFolder ? '${e.remoteRelPath}/' : e.remoteRelPath;

    test('a file and a folder: the layout of before, hidden entries skipped',
        () {
      write(inProject('sub/deeper/x.txt'));
      final plan = uploadPlan(project, ['file.txt', ' sub ']);
      expect(plan.map(entry), [
        'file.txt',
        'sub/',
        // The order of a folder listing is the order of the system.
        ...plan.skip(2).take(2).map(entry),
        'sub/deeper/x.txt',
      ]);
      expect(plan.skip(2).take(2).map(entry),
          unorderedEquals(['sub/file.txt', 'sub/deeper/']));
      expect(
          {
            for (final e in plan.where((e) => !e.isFolder))
              e.remoteRelPath: e.localPath
          },
          {
            'file.txt': p.join(projectReal, 'file.txt'),
            'sub/file.txt': p.join(projectReal, 'sub/file.txt'),
            'sub/deeper/x.txt': p.join(projectReal, 'sub/deeper/x.txt'),
          });
    });

    test('a link inside the project: its name, the real path of its target',
        () {
      link(inProject('links/to-file'), '../file.txt');
      link(inProject('links/to-sub'), '../sub');
      final plan = uploadPlan(project, ['links', 'link-in']);
      expect(plan.first.remoteRelPath, 'links');
      expect(
          {
            for (final e in plan)
              entry(e): e.localPath == null
                  ? null
                  : p.relative(e.localPath!, from: projectReal)
          },
          {
            'links/': null,
            'link-in': 'file.txt',
            'links/to-file': 'file.txt',
            'links/to-sub/': null,
            'links/to-sub/file.txt': 'sub/file.txt',
          });
    });

    test('empty items are left out; no item at all is refused', () {
      expect(uploadPlan(project, ['file.txt', '', ' ']).map(entry),
          ['file.txt']);
      expect(
          () => uploadPlan(project, ['', ' ']),
          throwsA(isA<ProjectPathException>()
              .having((e) => e.message, 'message', 'No local path given')));
    });

    test('one refused path refuses the whole call', () {
      expect(
          () => uploadPlan(project, ['file.txt', 'sub', 'link-out']),
          throwsA(isA<ProjectPathException>().having((e) => e.message,
              'message', 'Path is outside the project folder: link-out')));
    });

    for (final (what, setUpFolder, reason) in [
      (
        'a link to a file outside the project',
        () => link(inProject('f/out'), p.join(outside.path, 'outside.txt')),
        'Path is outside the project folder: f/out'
      ),
      (
        'a link to a folder outside the project',
        () => link(inProject('f/out'), outside.path),
        'Path is outside the project folder: f/out'
      ),
      (
        'a link to the folder named like the project plus a suffix',
        () => link(inProject('f/out'), trap.path),
        'Path is outside the project folder: f/out'
      ),
      (
        'a link to a hidden file of the project',
        () => link(inProject('f/env'), '../.env'),
        'No hidden files or directories allowed: f/env'
      ),
      (
        'a link into ssh/',
        () => link(inProject('f/key'), '../ssh/test-key'),
        'No files from ssh/ or secrets/ allowed: f/key'
      ),
      (
        'a link into secrets/',
        () => link(inProject('f/s'), '../secrets'),
        'No files from ssh/ or secrets/ allowed: f/s'
      ),
      (
        'a broken link',
        () => link(inProject('f/broken'), 'no-such-file'),
        'Local path not found: f/broken'
      ),
      (
        'a link to the folder itself',
        () => link(inProject('f/self'), '.'),
        'Symbolic link loop: f/self'
      ),
      (
        'a link to a folder above it',
        () => link(inProject('f/g/up'), '..'),
        'Symbolic link loop: f/g/up'
      ),
    ]) {
      test('a folder with $what refuses the whole call', () {
        write(inProject('f/a.txt'));
        setUpFolder();
        expect(
            () => uploadPlan(project, ['file.txt', 'f']),
            throwsA(isA<ProjectPathException>()
                .having((e) => e.message, 'message', reason)
                .having((e) => e.message, 'no outside path',
                    isNot(anyOf([for (final o in outsidePaths()) contains(o)])))));
      });
    }

    test('a link to the project folder: walked, refused, and it ends', () {
      link(inProject('f/root'), '../');
      // The project holds ssh/, links that leave it and f itself: one of
      // them refuses the call; which one depends on the order of the folder
      // listing.
      expect(() => uploadPlan(project, ['f']),
          throwsA(isA<ProjectPathException>()));
    });
  });

  group('FileUpload.callback', () {
    late _CountingProvider provider;
    late FileUpload upload;

    setUp(() {
      // web-1 on an address of TEST-NET-1 (RFC 5737), never reached: its key
      // file ssh/web-1 does not exist, so the key step fails first.
      provider =
          _CountingProvider([ClusterNode('web-1', '192.0.2.10', 1, 'web-1')]);
      upload = FileUpload(
          workingDir: project,
          sshKeyName: 'web-1',
          provider: provider,
          sshConnectTimeout: const Duration(seconds: 2));
    });

    Future<String> call(String localPath) async => textOf(await upload
        .callback(args: {'target': 'web-1', 'local_path': localPath}));

    for (final (localPath, text) in [
      ('link-out', 'ERROR: Path is outside the project folder: link-out'),
      ('dir-out', 'ERROR: Path is outside the project folder: dir-out'),
      ('file.txt,/etc/hosts', 'ERROR: No absolute paths allowed: /etc/hosts'),
      (
        'file.txt, ../outside.txt',
        'ERROR: No hidden files or directories allowed: ../outside.txt'
      ),
      ('.env', 'ERROR: No hidden files or directories allowed: .env'),
      ('ssh/test-key', 'ERROR: No files from ssh/ or secrets/ allowed: '
          'ssh/test-key'),
      ('missing.txt', 'ERROR: Local path not found: missing.txt'),
      // The current folder of the test process has a pubspec.yaml; the
      // project folder does not.
      ('pubspec.yaml', 'ERROR: Local path not found: pubspec.yaml'),
      ('', 'ERROR: No local path given'),
    ]) {
      test('refuses "$localPath" before a machine is looked up', () async {
        final result = await call(localPath);
        expect(result, text);
        expectNoOutsidePath(result);
        expect(provider.getServersCalls, 0);
      });
    }

    test('a folder with a link that leaves the project: refused, no lookup',
        () async {
      write(inProject('f/a.txt'));
      link(inProject('f/out'), outside.path);
      expect(await call('f'),
          'ERROR: Path is outside the project folder: f/out');
      expect(provider.getServersCalls, 0);
    });

    test('an allowed path reaches the machine', () async {
      expect(await call('sub/file.txt,sub'),
          'web-1: ERROR - The SSH key file of machine "web-1" does not exist.');
      expect(provider.getServersCalls, 1);
    });
  });

  group('an upload over SFTP to a local sshd', () {
    late SshdKeyFileTestEnv env;

    setUpAll(() async {
      env = await SshdKeyFileTestEnv.start();
    });

    tearDownAll(() async => env.stop());

    test('sub/file.txt and the folder sub, as file-upload sends them',
        () async {
      // env.dir is the project folder: ssh/test-key is its key file.
      File(p.join(env.dir.path, 'sub', 'file.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('hello over sftp\n');
      File(p.join(env.dir.path, 'sub', '.env')).writeAsStringSync('SECRET=1\n');
      final plan = uploadPlan(env.dir, ['sub/file.txt', 'sub']);

      final remoteDir = p.join(env.dir.path, 'remote', 'uploads');
      final node = ClusterNode('local', '127.0.0.1', 1, 'test-key')
        ..username = env.user;
      final socket =
          await SSHSocket.connect('127.0.0.1', env.port, timeout: _timeout);
      final sshClient =
          await getSshClient(env.dir, node, socket, timeout: _timeout);
      SftpClient? sftp;
      var sent = <String>[];
      try {
        sftp = await sshClient.sftp();
        await sftpMkDirRecursive(sftp, remoteDir);
        sent = await sendUploadPlan(sftp, plan, remoteDir);
      } finally {
        await closeSshQuietly(sshClient, sftp: sftp);
      }

      expect(sent, ['file.txt', 'sub/file.txt']);
      expect(File(p.join(remoteDir, 'file.txt')).readAsStringSync(),
          'hello over sftp\n');
      expect(File(p.join(remoteDir, 'sub', 'file.txt')).readAsStringSync(),
          'hello over sftp\n');
      expect(File(p.join(remoteDir, 'sub', '.env')).existsSync(), isFalse);
    });
  }, skip: sshTestEnvSkip(SshdKeyFileTestEnv.tools));
}
