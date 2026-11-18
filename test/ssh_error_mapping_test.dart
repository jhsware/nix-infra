// The texts of a failed SSH connection, login or command, by the type of the
// error (dartssh2 4.1). No network and no sshd: each error is built here.
//
// The texts must be the ones nix-infra gave before the errors were mapped by
// their type. The old mapping (a search in the text of the error) is kept
// below as `old*Message`, copied from lib/ssh.dart at 188897b, and the new
// texts are compared with it.
import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/types.dart';
import 'package:test/test.dart';

int _errno({required int linux, required int macos, required int windows}) =>
    Platform.isWindows ? windows : (Platform.isMacOS ? macos : linux);

final _econnrefused = _errno(linux: 111, macos: 61, windows: 10061);
final _etimedout = _errno(linux: 110, macos: 60, windows: 10060);
final _ehostunreach = _errno(linux: 113, macos: 65, windows: 10065);
final _enetunreach = _errno(linux: 101, macos: 51, windows: 10051);
final _econnreset = _errno(linux: 104, macos: 54, windows: 10054);

SocketException _socketError(String message, int errno) => SocketException(
      message,
      osError: OSError(message, errno),
      address: InternetAddress('203.0.113.7'),
      port: 22,
    );

// --- The old mapping (lib/ssh.dart at 188897b), by the text of the error ---

String oldCommandMessage(ClusterNode node, Object e) {
  final errorMsg = e.toString();
  if (errorMsg.contains('Connection refused')) {
    return 'Failed to connect to server "${node.name}" at ${node.ipAddr}:22\n'
        'Reason: Connection refused - SSH service may not be running or firewall is blocking port 22'
        '${vpnRequiredHint(node)}';
  } else if (errorMsg.contains('timed out') || errorMsg.contains('timeout')) {
    return 'Failed to connect to server "${node.name}" at ${node.ipAddr}:22\n'
        'Reason: Connection timeout - server may be unreachable or offline'
        '${vpnRequiredHint(node)}';
  } else if (errorMsg.contains('Authentication failed') ||
      errorMsg.contains('auth')) {
    return sshAuthenticationFailedMessage(node);
  } else {
    return 'Failed to execute command on server "${node.name}" at ${node.ipAddr}:22\n'
        'Reason: $errorMsg${vpnRequiredHint(node)}';
  }
}

String oldShellMessage(ClusterNode node, Object e) {
  final errorMsg = e.toString();
  if (errorMsg.contains('Connection refused')) {
    return 'Failed to connect to server "${node.name}" at ${node.ipAddr}:22\n'
        'Reason: Connection refused - SSH service may not be running or firewall is blocking port 22';
  } else if (errorMsg.contains('timed out') || errorMsg.contains('timeout')) {
    return 'Failed to connect to server "${node.name}" at ${node.ipAddr}:22\n'
        'Reason: Connection timeout - server may be unreachable or offline';
  } else if (errorMsg.contains('Authentication failed') ||
      errorMsg.contains('auth')) {
    return sshAuthenticationFailedMessage(node);
  } else {
    return 'Failed to open SSH shell to server "${node.name}" at ${node.ipAddr}:22\n'
        'Reason: $errorMsg';
  }
}

String oldConnectMessage(ClusterNode node, Object? e) {
  final Exception? lastError =
      e == null ? null : (e is Exception ? e : Exception(e.toString()));
  final errorDetails = lastError?.toString() ?? 'Unknown error';
  String errorMsg =
      'Failed to connect to server "${node.name}" at ${node.ipAddr}:22\n';
  if (errorDetails.contains('Connection refused')) {
    errorMsg +=
        'Reason: Connection refused - SSH service may not be running or firewall is blocking port 22';
  } else if (errorDetails.contains('timed out') ||
      errorDetails.contains('timeout')) {
    errorMsg +=
        'Reason: Connection timeout - server may be unreachable or offline';
  } else if (errorDetails.contains('No route to host')) {
    errorMsg +=
        'Reason: No route to host - check network configuration and IP address';
  } else if (errorDetails.contains('Network is unreachable')) {
    errorMsg += 'Reason: Network unreachable - check your network connection';
  } else {
    errorMsg += 'Reason: $errorDetails';
  }
  return errorMsg + vpnRequiredHint(node);
}

void main() {
  final node = ClusterNode('web001', '203.0.113.7', 1, 'my-key',
      sshKeyPath: './ssh/my-key');
  final vpnNode = ClusterNode('db001', '10.0.0.5', 2, 'my-key', vpn: 'office');

  const refusedText = 'Failed to connect to server "web001" at 203.0.113.7:22\n'
      'Reason: Connection refused - SSH service may not be running or '
      'firewall is blocking port 22';
  const timeoutText = 'Failed to connect to server "web001" at 203.0.113.7:22\n'
      'Reason: Connection timeout - server may be unreachable or offline';
  const authText = 'Failed to authenticate to server "web001" at '
      '203.0.113.7:22\n'
      'Reason: SSH authentication failed - check SSH key permissions and '
      'configuration';

  // Each error with its kind. The text of each one must be the old text.
  final unchanged = <String, (Object, SshFailure)>{
    'SocketException ECONNREFUSED': (
      _socketError('Connection refused', _econnrefused),
      SshFailure.connectionRefused
    ),
    'SocketException ETIMEDOUT': (
      _socketError('Operation timed out', _etimedout),
      SshFailure.timeout
    ),
    'SocketException of the dart:io connect timeout (no OS error)': (
      SocketException('Connection timed out, host: 203.0.113.7, port: 22'),
      SshFailure.timeout
    ),
    'SocketException EHOSTUNREACH': (
      _socketError('No route to host', _ehostunreach),
      SshFailure.noRouteToHost
    ),
    'SocketException ENETUNREACH': (
      _socketError('Network is unreachable', _enetunreach),
      SshFailure.networkUnreachable
    ),
    'SocketException ECONNRESET': (
      _socketError('Connection reset by peer', _econnreset),
      SshFailure.other
    ),
    'SSHAuthFailError': (
      SSHAuthFailError('All authentication methods failed'),
      SshFailure.authenticationFailed
    ),
    'SSHAuthAbortError of authTimeout': (
      SSHAuthAbortError('Authentication timed out'),
      SshFailure.timeout
    ),
    'SSHAuthAbortError, connection closed before the login': (
      SSHAuthAbortError('Connection closed before authentication'),
      SshFailure.authenticationFailed
    ),
    'SSHAuthAbortError, the machine disconnected before the login': (
      SSHAuthAbortError('Connection closed before authentication',
          SSHDisconnectError(14, 'Too many authentication failures')),
      SshFailure.authenticationFailed
    ),
    'SSHAuthAbortError, socket error before the login': (
      SSHAuthAbortError(
          'Connection closed before authentication',
          SSHSocketError(
              _socketError('Connection reset by peer', _econnreset))),
      SshFailure.authenticationFailed
    ),
    'SSHHandshakeError of handshakeTimeout': (
      SSHHandshakeError('Handshake timed out'),
      SshFailure.timeout
    ),
    'SSHSocketError around ECONNREFUSED': (
      SSHSocketError(_socketError('Connection refused', _econnrefused)),
      SshFailure.connectionRefused
    ),
    'SSHSocketError around ECONNRESET': (
      SSHSocketError(_socketError('Connection reset by peer', _econnreset)),
      SshFailure.other
    ),
    'SSHDisconnectError': (
      SSHDisconnectError(11, 'disconnected by user'),
      SshFailure.other
    ),
    'SSHPacketError': (SSHPacketError('Packet too long'), SshFailure.other),
    'SSHStateError': (
      SSHStateError('SSH connection closed'),
      SshFailure.other
    ),
    'SSHChannelOpenError': (
      SSHChannelOpenError(1, 'administratively prohibited'),
      SshFailure.other
    ),
    'SSHChannelRequestError': (
      SSHChannelRequestError('Failed to execute'),
      SshFailure.other
    ),
    'SSHInternalError after the login': (
      SSHInternalError(StateError('boom')),
      SshFailure.other
    ),
    'an Exception of nix-infra (a key file that does not exist)': (
      Exception('SSH key file not found for node web001'),
      SshFailure.other
    ),
  };

  group('classifySshError', () {
    for (final MapEntry(key: name, value: (error, kind)) in unchanged.entries) {
      test(name, () => expect(classifySshError(error), kind));
    }

    test('TimeoutException is a timeout', () {
      expect(classifySshError(TimeoutException('connect', Duration(seconds: 10))),
          SshFailure.timeout);
    });

    test('a login ended by a failed handshake is not a failed login', () {
      expect(
          classifySshError(SSHAuthAbortError(
              'Connection closed before authentication',
              SSHInternalError(
                  StateError('No matching key exchange algorithm')))),
          SshFailure.other);
      expect(
          classifySshError(SSHAuthAbortError(
              'Connection closed before authentication',
              SSHHandshakeError('Handshake timed out'))),
          SshFailure.timeout);
      expect(
          classifySshError(SSHAuthAbortError(
              'Connection closed before authentication',
              SSHHostkeyError('Signature verification failed'))),
          SshFailure.other);
    });
  });

  group('the texts did not change', () {
    for (final MapEntry(key: name, value: (error, _)) in unchanged.entries) {
      test(name, () {
        for (final n in [node, vpnNode]) {
          expect(sshCommandErrorMessage(n, error), oldCommandMessage(n, error),
              reason: 'runCommandOverSsh');
          expect(sshShellErrorMessage(n, error), oldShellMessage(n, error),
              reason: 'openShellOverSsh');
        }
      });
    }

    // waitAndGetSshConnection only meets the errors of a TCP connect.
    final connectErrors = {
      for (final entry in unchanged.entries)
        if (entry.value.$1 is SocketException) entry.key: entry.value.$1,
      'no error': null,
      'an error that is not an Exception': StateError('odd'),
    };
    for (final MapEntry(key: name, value: error) in connectErrors.entries) {
      test('waitAndGetSshConnection: $name', () {
        for (final n in [node, vpnNode]) {
          expect(sshConnectErrorMessage(n, error), oldConnectMessage(n, error));
        }
      });
    }
  });

  group('the texts', () {
    test('a refused connection', () {
      expect(
          sshCommandErrorMessage(
              node, _socketError('Connection refused', _econnrefused)),
          refusedText);
    });

    test('a timeout of the TCP connect, the handshake and the login', () {
      for (final error in [
        SocketException(
            'Connection timed out, host: 203.0.113.7, port: 22'),
        SSHHandshakeError('Handshake timed out'),
        SSHAuthAbortError('Authentication timed out'),
        TimeoutException('connect', Duration(seconds: 10)),
      ]) {
        expect(sshCommandErrorMessage(node, error), timeoutText,
            reason: '$error');
      }
    });

    test('a failed login', () {
      expect(
          sshCommandErrorMessage(
              node, SSHAuthFailError('All authentication methods failed')),
          authText);
    });

    test('the VPN hint follows a refused connection and a timeout', () {
      final hint = vpnRequiredHint(vpnNode);
      expect(hint, contains('"office"'));
      expect(
          sshCommandErrorMessage(
              vpnNode, _socketError('Connection refused', _econnrefused)),
          endsWith(hint));
      expect(
          sshCommandErrorMessage(
              vpnNode, SSHHandshakeError('Handshake timed out')),
          endsWith(hint));
      expect(
          sshConnectErrorMessage(
              vpnNode, _socketError('No route to host', _ehostunreach)),
          'Failed to connect to server "db001" at 10.0.0.5:22\n'
          'Reason: No route to host - check network configuration and IP '
          'address$hint');
    });

    test('a failed handshake names the error of the handshake', () {
      final error = SSHAuthAbortError(
          'Connection closed before authentication',
          SSHInternalError(StateError('No matching key exchange algorithm')));
      expect(
          sshCommandErrorMessage(node, error),
          'Failed to execute command on server "web001" at 203.0.113.7:22\n'
          'Reason: SSHInternalError(Bad state: No matching key exchange '
          'algorithm)');
      expect(
          sshShellErrorMessage(node, error),
          'Failed to open SSH shell to server "web001" at 203.0.113.7:22\n'
          'Reason: SSHInternalError(Bad state: No matching key exchange '
          'algorithm)');
    });
  });
}
