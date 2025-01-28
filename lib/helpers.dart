import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ansi_escapes/ansi_escapes.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/types.dart';
import 'package:dartssh2/dartssh2.dart';

void echo(String message) {
  final tmp = message.split('\n');
  final outp = tmp.map((str) => '- $str');
  print(outp.join('\n'));
}

void echoFromNode(String nodeName, String message) {
  final tmp = message.split('\n');
  final outp = tmp.map((str) => '$nodeName: $str');
  print(outp.join('\n'));
}

void echoDebug(String message) {
  print('DEBUG: $message');
}

void mkdir(String parentPath, {dynamic names}) {
  if (names == null) {
    Directory(parentPath).createSync(recursive: true);
  } else if (names is String) {
    Directory('$parentPath/$names').createSync(recursive: true);
  } else if (names is List<String>) {
    for (final name in names) {
      Directory('$parentPath/$name').createSync(recursive: true);
    }
  } else {
    throw Exception('Invalid type for names: ${names.runtimeType}');
  }
}

void touch(String parentPath, names) {
  if (names is String) {
    File('$parentPath/$names').createSync(recursive: true);
  } else if (names is List<String>) {
    for (final name in names) {
      File('$parentPath/$name').createSync(recursive: true);
    }
  } else {
    throw Exception('Invalid type for names: ${names.runtimeType}');
  }
}

final writeCreateMode = SftpFileOpenMode.write |
    SftpFileOpenMode.create |
    SftpFileOpenMode.truncate;

String substitute(String contents, Map<String, String> substitutions,
    {List<String>? expectedSecrets}) {
  return contents.replaceAllMapped(RegExp(r'\[\%\%(.*?)\%\%\]'), (match) {
    final key = match.group(1);
    // Secrets are deployed as encrypted files in /root/secrets of target node
    // so they won't exist in substitions.
    if (key != null && key.startsWith('secrets/')) {
      final secretName = key.split('/').last;
      expectedSecrets?.add(secretName);
      return secretName;
    }
    if (substitutions.containsKey(key)) {
      return substitutions[key]!;
    } else {
      return match.group(0)!;
    }
  });
}

Future<void> sftpSend(SftpClient sftp, String localPath, String remotePath,
    {Map<String, String>? substitutions, List<String>? expectedSecrets}) async {
  final local = File(localPath);
  final remote = await sftp.open(remotePath, mode: writeCreateMode);
  if (substitutions == null) {
    await remote.writeBytes(await local.readAsBytes());
  } else {
    // Do variable substitution [%%sshKeyPubPath%%] => { sshKeyPubPath }
    final contents = await local.readAsString();
    final newContents =
        substitute(contents, substitutions, expectedSecrets: expectedSecrets);
    await remote.writeBytes(Uint8List.fromList(utf8.encode(newContents)));
  }
}

Future<void> sftpMkDir(SftpClient sftp, String remotePath) async {
  try {
    await sftp.stat(remotePath);
  } on SftpStatusError catch (e) {
    if (e.code == 2) {
      // 2 = file not found
      await sftp.mkdir(remotePath);
    }
  }
}

Future<void> sftpWrite(
  SftpClient sftp,
  String contents,
  String remotePath,
) async {
  final remote = await sftp.open(remotePath, mode: writeCreateMode);
  await remote.writeBytes(Uint8List.fromList(utf8.encode(contents)));
}

Future<bool> sftpExists(
  SftpClient sftp,
  String remotePath,
) async {
  try {
    final remote = await sftp.stat(remotePath);
    return remote.isFile || remote.isDirectory || false;
  } catch (err) {
    return false;
  }
}

Future<String> getSshKeyAsPem(Directory workingDir, String name) async {
  // return File('${Platform.environment['HOME']}/.ssh/$name').readAsString();
  return File('${workingDir.path}/ssh/$name').readAsString();
}

String fileName(File file) {
  return file.path.split('/').last;
}

String trimQuotes(String inp) {
  if (inp.startsWith('"')) {
    inp = inp.substring(1, inp.length - 1);
  }
  if (inp.endsWith('"')) {
    inp = inp.substring(0, inp.length - 1);
  }
  return inp;
}

void printBar(int val) {
  if (val < 25) {
    stdout.write('.⎽');
  } else if (val < 60) {
    stdout.write('.⎼');
  } else if (val < 90) {
    stdout.write('.⎻');
  } else {
    stdout.write('.⎺');
  }
}

Future<List<ClusterNode>> getServersWithoutNixos(
    Directory workingDir, Iterable<ClusterNode> nodes,
    {bool debug = false}) async {
  List<ClusterNode> nodesWithUbuntu = [];
  await Future.wait(nodes.map((node) async {
    final res = await runCommandOverSsh(workingDir, node, 'uname -v');
    if (res.contains('Ubuntu')) {
      nodesWithUbuntu.add(node);
      if (debug) echoDebug('- ${node.name}: Ubuntu');
    } else {
      if (debug) echoDebug('+ ${node.name}: NixOS');
    }
  }));

  return nodesWithUbuntu;
}

class AsciiProgressBar {
  final progressBars = <List<String>>[];
  AsciiProgressBar();

  int update(int? index, String chars) {
    stdout.write(ansiEscapes.eraseLines(progressBars.length));
    if (index == null) {
      index = progressBars.length;
      progressBars.add([chars]);
    } else {
      progressBars[index].add(chars);
    }
    for (var i = -1; ++i < progressBars.length;) {
      stdout.write(progressBars[i].join(''));
      stdout.write(ansiEscapes.cursorNextLine);
    }
    return index;
  }
}

Future<Map<String, String>> getOverlayMeshIps(
  Directory workingDir,
  Iterable<ClusterNode> cluster,
) async {
  final etcdNode = cluster.firstWhere((node) => node.name == 'etcd001');
  final SSHSocket connection = await waitAndGetSshConnection(etcdNode);
  final SSHClient sshClient =
      await getSshClient(workingDir, etcdNode, connection);
  final res = await sshClient.run('''
      export ETCDCTL_DIAL_TIMEOUT=3s
      export ETCDCTL_CACERT=/root/certs/ca-chain.cert.pem
      export ETCDCTL_CERT=/root/certs/${etcdNode.name}-client-tls.cert.pem
      export ETCDCTL_KEY=/root/certs/${etcdNode.name}-client-tls.key.pem
      export ETCDCTL_API=3
      etcdctl --endpoints=https://${etcdNode.ipAddr}:2379 get --prefix /coreos.com/network/subnets
    ''', stdout: true, stderr: true);
  sshClient.close();
  final resStr = utf8.decode(res);

  Map<String, String> overlayIps = {};
  String subnet = '';
  for (final line in resStr.split('\n')) {
    if (line.isEmpty) {
      continue;
    }

    if (line.startsWith('/')) {
      subnet = line.split('/').last;
      continue;
    }

    if (line.startsWith('{')) {
      final json = jsonDecode(line);
      final nodeName = cluster.firstWhere((node) {
        return node.ipAddr == json['PublicIP'];
      }).name;
      // overlayIps[nodeName] = {
      //   'subnet': subnet,
      //   'overlayIp': subnet.split('-').first,
      // };
      overlayIps[nodeName] = subnet.split('-').first;
    }
  }

  echo(overlayIps.toString());
  return overlayIps;
}
