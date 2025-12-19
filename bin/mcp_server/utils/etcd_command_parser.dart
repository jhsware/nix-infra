/// Parsed etcdctl command with validation support
class ParsedEtcdCommand {
  final String? command;
  final String? subcommand;
  final List<String> arguments;
  final List<String> options;
  final String rawInput;

  ParsedEtcdCommand({
    this.command,
    this.subcommand,
    this.arguments = const [],
    this.options = const [],
    required this.rawInput,
  });

  /// Returns the full command string (command + subcommand if present)
  String get fullCommand {
    if (subcommand != null) {
      return '$command $subcommand';
    }
    return command ?? '';
  }

  @override
  String toString() {
    return 'ParsedEtcdCommand(command: $command, subcommand: $subcommand, '
        'arguments: $arguments, options: $options)';
  }
}

/// Result of etcdctl command validation
class EtcdValidationResult {
  final bool isAllowed;
  final String? reason;
  final ParsedEtcdCommand? parsedCommand;

  EtcdValidationResult.allowed(this.parsedCommand)
      : isAllowed = true,
        reason = null;

  EtcdValidationResult.denied(this.reason)
      : isAllowed = false,
        parsedCommand = null;

  @override
  String toString() {
    if (isAllowed) {
      return 'EtcdValidationResult(allowed: $parsedCommand)';
    }
    return 'EtcdValidationResult(denied: $reason)';
  }
}

/// Parser and validator for etcdctl commands
/// Only allows read-only, non-destructive commands
class EtcdCommandParser {
  /// Commands that are safe (read-only operations)
  /// Format: 'command' for single commands, 'command subcommand' for two-word commands
  static const Set<String> allowedCommands = {
    // Key-value read operations
    'get',
    'watch', // Read-only observation

    // Cluster membership queries
    'member list',

    // Endpoint queries
    'endpoint health',
    'endpoint status',
    'endpoint hashkv',

    // Alarm queries (list only)
    'alarm list',

    // User queries (read-only)
    'user get',
    'user list',

    // Role queries (read-only)
    'role get',
    'role list',

    // Performance checks
    'check perf',
    'check datascale',

    // Version info
    'version',
  };

  /// Commands that are explicitly denied (write/destructive operations)
  static const Set<String> deniedCommands = {
    // Key-value write operations
    'put',
    'del',
    'txn', // Transactions can write

    // Compaction (modifies data)
    'compaction',

    // Lease operations (can affect data TTL)
    'lease grant',
    'lease revoke',
    'lease keep-alive',
    'lease timetolive',
    'lease list',

    // Cluster membership modifications
    'member add',
    'member remove',
    'member update',
    'member promote',

    // Snapshot operations
    'snapshot save',
    'snapshot restore',
    'snapshot status', // Could be allowed but grouping with snapshot

    // Alarm modifications
    'alarm disarm',

    // Defragmentation (modifies storage)
    'defrag',

    // Authentication modifications
    'auth enable',
    'auth disable',
    'auth status', // Could be allowed but grouping with auth

    // User modifications
    'user add',
    'user delete',
    'user passwd',
    'user grant-role',
    'user revoke-role',

    // Role modifications
    'role add',
    'role delete',
    'role grant-permission',
    'role revoke-permission',

    // Leadership operations
    'move-leader',
    'elect',

    // Locking (can block operations)
    'lock',

    // Mirroring
    'make-mirror',
  };

  /// Options that are generally safe for read operations
  static const Set<String> safeOptions = {
    // Output formatting
    '-w', '--write-out',
    '--hex',
    '--print-value-only',
    '--consistency',
    '--order',
    '--sort-by',
    '--limit',
    '--from-key',
    '--prefix',
    '--keys-only',
    '--count-only',
    '--rev',

    // Connection options
    '--endpoints',
    '--dial-timeout',
    '--command-timeout',
    '--keepalive-time',
    '--keepalive-timeout',

    // TLS options
    '--cacert',
    '--cert',
    '--key',
    '--insecure-skip-tls-verify',
    '--insecure-transport',

    // Auth options (for connecting, not modifying)
    '--user',
    '--password',

    // Debug/info
    '--debug',
    '-h', '--help',

    // Discovery
    '--discovery-srv',
    '--discovery-srv-name',

    // Watch specific
    '--interactive',
    '--progress-notify',
    '--prev-kv',
  };

  /// Options that could be dangerous
  static const Set<String> dangerousOptions = {
    // These options could have side effects or be used for attacks
    '--exec', // Command execution
  };

  /// Parses and validates an etcdctl command string
  /// Returns a validation result indicating if the command is allowed
  static EtcdValidationResult validate(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return EtcdValidationResult.denied('Empty command');
    }

    // Check for command chaining attempts
    if (_containsCommandChaining(trimmed)) {
      return EtcdValidationResult.denied(
        'Command chaining (;, &&, ||, |) is not allowed for security reasons',
      );
    }

    // Check for shell expansion attempts
    if (_containsShellExpansion(trimmed)) {
      return EtcdValidationResult.denied(
        'Shell expansion (\$, `, subshells) is not allowed for security reasons',
      );
    }

    // Tokenize the command
    final tokens = _tokenize(trimmed);
    if (tokens.isEmpty) {
      return EtcdValidationResult.denied('Empty command after parsing');
    }

    // Parse into command, subcommand, options, and arguments
    final parsed = _parseTokens(tokens, trimmed);

    // Validate the command
    return _validateParsedCommand(parsed);
  }

  /// Check for command chaining attempts
  static bool _containsCommandChaining(String input) {
    bool inSingleQuote = false;
    bool inDoubleQuote = false;
    bool escaped = false;

    for (int i = 0; i < input.length; i++) {
      final char = input[i];
      final next = i + 1 < input.length ? input[i + 1] : null;

      if (escaped) {
        escaped = false;
        continue;
      }

      if (char == '\\') {
        escaped = true;
        continue;
      }

      if (char == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
        continue;
      }

      if (char == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
        continue;
      }

      if (!inSingleQuote && !inDoubleQuote) {
        if (char == ';' || char == '|') return true;
        if (char == '&' && next == '&') return true;
        if (char == '|' && next == '|') return true;
      }
    }

    return false;
  }

  /// Check for shell expansion attempts
  static bool _containsShellExpansion(String input) {
    bool inSingleQuote = false;
    bool inDoubleQuote = false;
    bool escaped = false;

    for (int i = 0; i < input.length; i++) {
      final char = input[i];
      final next = i + 1 < input.length ? input[i + 1] : null;

      if (escaped) {
        escaped = false;
        continue;
      }

      if (char == '\\' && !inSingleQuote) {
        escaped = true;
        continue;
      }

      if (char == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
        continue;
      }

      if (char == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
        continue;
      }

      // Inside single quotes, no expansion occurs
      if (inSingleQuote) continue;

      // Check for expansion characters
      if (char == '\$') return true;
      if (char == '`') return true;
      if (char == '(' && next == '(') return true;
    }

    return false;
  }

  /// Tokenize command string respecting quotes
  static List<String> _tokenize(String input) {
    List<String> tokens = [];
    StringBuffer current = StringBuffer();
    bool inSingleQuote = false;
    bool inDoubleQuote = false;
    bool escaped = false;

    void addToken() {
      if (current.isNotEmpty) {
        tokens.add(current.toString());
        current.clear();
      }
    }

    for (int i = 0; i < input.length; i++) {
      final char = input[i];

      if (escaped) {
        current.write(char);
        escaped = false;
        continue;
      }

      if (char == '\\' && !inSingleQuote) {
        escaped = true;
        continue;
      }

      if (char == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
        continue;
      }

      if (char == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
        continue;
      }

      if (!inSingleQuote && !inDoubleQuote && char.trim().isEmpty) {
        addToken();
        continue;
      }

      current.write(char);
    }

    addToken();
    return tokens;
  }

  /// Commands that have subcommands
  static const Set<String> commandsWithSubcommands = {
    'member',
    'endpoint',
    'alarm',
    'user',
    'role',
    'lease',
    'snapshot',
    'auth',
    'check',
  };

  /// Parse tokens into structured command
  static ParsedEtcdCommand _parseTokens(List<String> tokens, String rawInput) {
    String? command;
    String? subcommand;
    List<String> options = [];
    List<String> arguments = [];
    bool expectingOptionValue = false;

    // Options that expect a value
    const optionsWithValues = {
      '-w', '--write-out',
      '--endpoints',
      '--dial-timeout',
      '--command-timeout',
      '--keepalive-time',
      '--keepalive-timeout',
      '--cacert',
      '--cert',
      '--key',
      '--user',
      '--password',
      '--limit',
      '--rev',
      '--discovery-srv',
      '--discovery-srv-name',
      '--consistency',
      '--order',
      '--sort-by',
    };

    for (final token in tokens) {
      if (expectingOptionValue) {
        options.add(token);
        expectingOptionValue = false;
        continue;
      }

      if (token.startsWith('-')) {
        // Handle combined option=value format
        if (token.contains('=')) {
          options.add(token);
        } else if (optionsWithValues.contains(token)) {
          options.add(token);
          expectingOptionValue = true;
        } else {
          options.add(token);
        }
      } else if (command == null) {
        // First non-option token is the command
        command = token.toLowerCase();
      } else if (subcommand == null && commandsWithSubcommands.contains(command)) {
        // Second token is subcommand for commands that have them
        subcommand = token.toLowerCase();
      } else {
        // Everything else is an argument (like key names)
        arguments.add(token);
      }
    }

    return ParsedEtcdCommand(
      command: command,
      subcommand: subcommand,
      arguments: arguments,
      options: options,
      rawInput: rawInput,
    );
  }

  /// Validate the parsed command
  static EtcdValidationResult _validateParsedCommand(ParsedEtcdCommand parsed) {
    if (parsed.command == null) {
      return EtcdValidationResult.denied('No command specified');
    }

    final command = parsed.command!;
    final fullCommand = parsed.fullCommand;

    // First check if explicitly denied
    if (deniedCommands.contains(command) || deniedCommands.contains(fullCommand)) {
      return EtcdValidationResult.denied(
        'Command "$fullCommand" is not allowed - it modifies data or cluster state',
      );
    }

    // Check if command requires a subcommand
    if (commandsWithSubcommands.contains(command) && parsed.subcommand == null) {
      return EtcdValidationResult.denied(
        'Command "$command" requires a subcommand',
      );
    }

    // Check if explicitly allowed
    if (allowedCommands.contains(command) || allowedCommands.contains(fullCommand)) {
      // Validate options
      final optionValidation = _validateOptions(parsed.options);
      if (!optionValidation.isAllowed) {
        return optionValidation;
      }

      // Validate key patterns for get command
      if (command == 'get') {
        final keyValidation = _validateKeyPatterns(parsed.arguments);
        if (!keyValidation.isAllowed) {
          return keyValidation;
        }
      }

      return EtcdValidationResult.allowed(parsed);
    }

    // Unknown command - deny by default for safety
    return EtcdValidationResult.denied(
      'Command "$fullCommand" is not in the allowed list. '
      'Only read-only commands are permitted: ${allowedCommands.join(", ")}',
    );
  }

  /// Validate options
  static EtcdValidationResult _validateOptions(List<String> options) {
    for (final option in options) {
      // Extract the option name (handle --option=value format)
      String optionName;
      if (option.contains('=')) {
        optionName = option.split('=').first;
      } else if (!option.startsWith('-')) {
        // This is likely an option value, skip
        continue;
      } else {
        optionName = option;
      }

      // Check for dangerous options
      if (dangerousOptions.contains(optionName)) {
        return EtcdValidationResult.denied(
          'Option "$optionName" is not allowed for security reasons',
        );
      }
    }

    return EtcdValidationResult.allowed(null);
  }

  /// Validate key patterns to prevent accessing sensitive paths
  static EtcdValidationResult _validateKeyPatterns(List<String> keys) {
    // For now, allow all key patterns for read operations
    // Could add restrictions here if needed (e.g., blocking /secrets prefix)
    for (final key in keys) {
      // Check for path traversal attempts
      if (key.contains('..')) {
        return EtcdValidationResult.denied(
          'Path traversal ("..") is not allowed in key names',
        );
      }
    }
    return EtcdValidationResult.allowed(null);
  }

  /// Convenience method to check if a command string is allowed
  static bool isAllowed(String input) {
    return validate(input).isAllowed;
  }

  /// Build a safe etcdctl command string from validated components
  static String? buildCommand({
    required String command,
    String? subcommand,
    List<String>? keys,
    List<String>? options,
  }) {
    final fullCommand = subcommand != null ? '$command $subcommand' : command;
    
    // Validate the command first
    if (!allowedCommands.contains(command.toLowerCase()) && 
        !allowedCommands.contains(fullCommand.toLowerCase())) {
      return null;
    }

    final parts = <String>[command];
    
    if (subcommand != null) {
      parts.add(subcommand);
    }

    if (keys != null) {
      for (final key in keys) {
        if (!_isValidKey(key)) {
          return null;
        }
        parts.add(key);
      }
    }

    if (options != null) {
      parts.addAll(options);
    }

    return parts.join(' ');
  }

  /// Validate key format
  static bool _isValidKey(String key) {
    // Keys should not contain path traversal or dangerous characters
    if (key.contains('..')) return false;
    if (key.contains('\$')) return false;
    if (key.contains('`')) return false;
    return true;
  }
}
