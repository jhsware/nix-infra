import 'package:dartssh2/dartssh2.dart'
    show SSHAuthAbortError, SSHAuthFailError, SSHInternalError, SSHSocketError;

import 'package:nix_infra/ssh_agent.dart';
import 'package:nix_infra/types.dart';

// The errors of the key of a machine, and their texts (docs/design/
// ssh_agent_keys.md §7). Every text is written in [nodeKeyErrorText], the one
// place; [nodeKeyErrorOf] finds the error of the key inside an error of a
// login, so no text is found by searching another text.
//
// No text names the path of a key file, of the key map or of the socket of
// the agent: an MCP tool result shows these texts. A text may name the
// machine, a variable and a fingerprint. The CLI may print paths; the
// classes keep the path where one exists ([NodeKeyFileException.path]).

/// The key of a machine cannot be used to log in to it.
///
/// [message] and [toString] are the text of design §7 ([nodeKeyErrorText]).
sealed class NodeKeyException implements Exception {
  const NodeKeyException(this.nodeName);

  /// The name of the machine ([ClusterNode.name]).
  final String nodeName;

  /// The text of the error, without a path.
  String get message => nodeKeyErrorText(this);

  @override
  String toString() => message;
}

/// The key map says that the key of the machine is not available
/// ([UnavailableKeySource]).
final class NodeKeyUnavailableException extends NodeKeyException {
  const NodeKeyUnavailableException(super.nodeName, this.reason);

  /// The reason of the entry, with its ring when there is one.
  final String reason;
}

/// The key map could not be read when the machines were listed
/// ([KeyMapUnreadableSource]).
final class NodeKeyMapUnreadableException extends NodeKeyException {
  const NodeKeyMapUnreadableException(super.nodeName, this.detail);

  /// What is wrong with the key map, without its path. Not in the text.
  final String detail;
}

/// The key map gives the machine an agent key, but `SSH_AUTH_SOCK` is not
/// set.
final class NodeKeyNoAgentSocketException extends NodeKeyException {
  const NodeKeyNoAgentSocketException(super.nodeName);
}

/// The socket of the agent does not exist, or nothing accepts a connection
/// on it.
final class NodeKeyAgentUnreachableException extends NodeKeyException {
  const NodeKeyAgentUnreachableException(super.nodeName);
}

/// The agent does not hold the key of the machine, or refuses to sign with
/// it. A lock of the sysops vault removes the keys from the agent, so this
/// is a normal case (design §13).
final class NodeKeyNotInAgentException extends NodeKeyException {
  const NodeKeyNotInAgentException(super.nodeName, this.fingerprint);

  final String fingerprint;
}

/// Another error of the agent: it did not answer in time, or its answer
/// does not follow the protocol ([cause]). The text of [cause] holds no
/// path.
final class NodeKeyAgentFailedException extends NodeKeyException {
  const NodeKeyAgentFailedException(
      super.nodeName, this.fingerprint, this.cause);

  final String fingerprint;
  final SshAgentException cause;
}

/// The machine does not accept the agent key that the key map gives it.
final class NodeKeyNotAcceptedException extends NodeKeyException {
  const NodeKeyNotAcceptedException(super.nodeName, this.fingerprint);

  final String fingerprint;
}

/// Why a private key file cannot be used.
enum NodeKeyFileProblem { missing, unreadable, passphrase, invalid }

/// The private key file of the machine cannot be used. The text does not
/// show [path]; the CLI may.
final class NodeKeyFileException extends NodeKeyException {
  const NodeKeyFileException(super.nodeName, this.path, this.problem);

  final String path;
  final NodeKeyFileProblem problem;
}

/// The text of [error] (design §7).
///
/// Two texts have no row in §7: a key map that cannot be read while an MCP
/// server runs ([NodeKeyMapUnreadableException]), and another error of the
/// agent ([NodeKeyAgentFailedException]). A key file that cannot be read or
/// parsed gets a text in the style of the row for a missing key file.
String nodeKeyErrorText(NodeKeyException error) => switch (error) {
      NodeKeyUnavailableException(:final nodeName, :final reason) =>
        'The SSH key of machine "$nodeName" is not available ($reason).',
      NodeKeyMapUnreadableException(:final nodeName) =>
        'The key map of this session cannot be read. The key of machine '
            '"$nodeName" is not available.',
      NodeKeyNoAgentSocketException() =>
        'SSH_KEY_MAP_PATH is set but SSH_AUTH_SOCK is not.',
      NodeKeyAgentUnreachableException(:final nodeName) =>
        'The SSH agent of this session cannot be reached. The key of machine '
            '"$nodeName" is not available.',
      NodeKeyNotInAgentException(:final nodeName, :final fingerprint) =>
        'The SSH agent does not hold the key of machine "$nodeName" '
            '($fingerprint). If sysops filled the agent: the vault may be '
            'locked.',
      NodeKeyAgentFailedException(
        :final nodeName,
        :final fingerprint,
        :final cause
      ) =>
        'The SSH agent of this session failed for the key of machine '
            '"$nodeName" ($fingerprint): ${cause.message}',
      NodeKeyNotAcceptedException(:final nodeName, :final fingerprint) =>
        'Machine "$nodeName" does not accept its key ($fingerprint).',
      NodeKeyFileException(:final nodeName, :final problem) => switch (
            problem) {
          NodeKeyFileProblem.missing =>
            'The SSH key file of machine "$nodeName" does not exist.',
          NodeKeyFileProblem.unreadable =>
            'The SSH key file of machine "$nodeName" cannot be read.',
          NodeKeyFileProblem.passphrase =>
            'The SSH key file of machine "$nodeName" has a passphrase; '
                'nix-infra cannot use it.',
          NodeKeyFileProblem.invalid =>
            'The SSH key file of machine "$nodeName" is not a private key '
                'that nix-infra can read.',
        },
    };

/// The error of the key of [node] for [error], an error of its agent.
NodeKeyException nodeKeyErrorOfAgent(
    ClusterNode node, SshAgentException error) {
  final fingerprint = switch (node.keySource) {
    AgentKeySource(:final fingerprint) => fingerprint,
    _ => switch (error) {
        SshAgentKeyNotFoundException(:final fingerprint) => fingerprint,
        SshAgentRefusedException(:final fingerprint?) => fingerprint,
        SshAgentWrongAlgorithmException(:final fingerprint) => fingerprint,
        _ => 'unknown key',
      },
  };
  return switch (error) {
    SshAgentUnreachableException() =>
      NodeKeyAgentUnreachableException(node.name),
    SshAgentKeyNotFoundException() || SshAgentRefusedException() =>
      NodeKeyNotInAgentException(node.name, fingerprint),
    _ => NodeKeyAgentFailedException(node.name, fingerprint, error),
  };
}

/// The error of the key of [node] in [error], an error of a login to [node]
/// or of the steps before it, or null when [error] is not about the key.
///
/// Looks inside the errors of dartssh2 that wrap another error: a signer
/// that throws ends the login with an `SSHAuthAbortError` that holds an
/// `SSHInternalError` with the error of the agent. A failed login of a
/// machine with an agent key ([AgentKeySource]) is a
/// [NodeKeyNotAcceptedException]: no other key was tried.
NodeKeyException? nodeKeyErrorOf(ClusterNode node, Object error) {
  final inner = _unwrap(error);
  return switch (inner) {
    NodeKeyException() => inner,
    SshAgentException() => nodeKeyErrorOfAgent(node, inner),
    SSHAuthFailError() => switch (node.keySource) {
        AgentKeySource(:final fingerprint) =>
          NodeKeyNotAcceptedException(node.name, fingerprint),
        _ => null,
      },
    _ => null,
  };
}

/// The error inside the errors of dartssh2 that wrap it.
Object _unwrap(Object error) => switch (error) {
      SSHAuthAbortError(reason: final reason?) => _unwrap(reason),
      SSHInternalError(error: final inner) => _unwrap(inner),
      SSHSocketError(error: final inner) => _unwrap(inner),
      _ => error,
    };
