/// Parsed systemctl command with validation support
class ParsedSystemctlCommand {
  final String? command;
  final List<String> units;
  final List<String> options;
  final String rawInput;

  ParsedSystemctlCommand({
    this.command,
    this.units = const [],
    this.options = const [],
    required this.rawInput,
  });

  @override
  String toString() {
    return 'ParsedSystemctlCommand(command: $command, units: $units, options: $options)';
  }
}

/// Result of systemctl command validation
class SystemctlValidationResult {
  final bool isAllowed;
  final String? reason;
  final ParsedSystemctlCommand? parsedCommand;

  SystemctlValidationResult.allowed(this.parsedCommand)
      : isAllowed = true,
        reason = null;

  SystemctlValidationResult.denied(this.reason)
      : isAllowed = false,
        parsedCommand = null;

  @override
  String toString() {
    if (isAllowed) {
      return 'SystemctlValidationResult(allowed: $parsedCommand)';
    }
    return 'SystemctlValidationResult(denied: $reason)';
  }
}

/// Parser and validator for systemctl commands
/// Only allows read-only, non-destructive commands
class SystemctlCommandParser {
  /// Commands that are safe (read-only, query-only operations)
  static const Set<String> allowedCommands = {
    // Query commands
    'status',
    'show',
    'cat',
    'help',

    // List commands
    'list-units',
    'list-sockets',
    'list-timers',
    'list-jobs',
    'list-unit-files',
    'list-dependencies',
    'list-machines',

    // Check commands
    'is-active',
    'is-enabled',
    'is-failed',
    'is-system-running',

    // Other safe commands
    'get-default',
    'show-environment',
  };

  /// Commands that are explicitly denied (destructive operations)
  static const Set<String> deniedCommands = {
    // Service lifecycle commands
    'start',
    'stop',
    'restart',
    'reload',
    'reload-or-restart',
    'try-restart',
    'try-reload-or-restart',
    'condrestart',
    'force-reload',

    // Kill/clean commands
    'kill',
    'clean',
    'reset-failed',

    // Enable/disable commands
    'enable',
    'disable',
    'reenable',
    'preset',
    'preset-all',
    'mask',
    'unmask',
    'link',
    'revert',
    'add-wants',
    'add-requires',

    // Edit/modify commands
    'edit',
    'set-default',
    'set-property',

    // Daemon commands
    'daemon-reload',
    'daemon-reexec',

    // System state commands
    'isolate',
    'default',
    'rescue',
    'emergency',
    'halt',
    'poweroff',
    'reboot',
    'kexec',
    'exit',
    'switch-root',
    'suspend',
    'hibernate',
    'hybrid-sleep',
    'suspend-then-hibernate',

    // Job control
    'cancel',

    // Environment manipulation
    'import-environment',
    'set-environment',
    'unset-environment',

    // Mount operations
    'bind',
    'mount-image',

    // Logging config (can affect system behavior)
    'log-level',
    'log-target',
    'service-watchdogs',
  };

  /// Options that are safe for read operations
  static const Set<String> safeOptions = {
    // Output formatting
    '-t', '--type',
    '-a', '--all',
    '--state',
    '-l', '--full',
    '-r', '--recursive',
    '--reverse',
    '--after',
    '--before',
    '-n', '--lines',
    '-o', '--output',
    '--plain',
    '--no-legend',
    '--no-pager',
    '-q', '--quiet',
    '-H', '--host',
    '-M', '--machine',
    '--user',
    '--system',
    '--global',
    '-p', '--property',
    '--value',
    '--failed',
    '--now', // Only safe when used with query commands
    '--runtime',
    '-f', '--force', // Only safe in query context
    '--show-types',
    '--job-mode',
    '--fail',
    '--no-block',
    '--wait',
    '--no-wall',
    '--no-reload',
    '--no-ask-password',
    '--kill-who',
    '--signal',
    '-i', '--ignore-inhibitors',
    '--firmware-setup',
    '--boot-loader-menu',
    '--boot-loader-entry',
    '--check-inhibitors',
    '--dry-run', // Safe - preview only
    '--timestamp',
    '--mkdir',
    '-h', '--help',
    '--version',
    '--no-warn',
    '--marked',
    '--with-dependencies',
    '--json',
    '--legend',
  };

  /// Options that could be dangerous (modify state)
  static const Set<String> dangerousOptions = {
    '--root', // Operates on different root filesystem
  };

  /// Parses and validates a systemctl command string
  /// Returns a validation result indicating if the command is allowed
  static SystemctlValidationResult validate(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return SystemctlValidationResult.denied('Empty command');
    }

    // Check for command chaining attempts
    if (_containsCommandChaining(trimmed)) {
      return SystemctlValidationResult.denied(
        'Command chaining (;, &&, ||, |) is not allowed for security reasons',
      );
    }

    // Check for shell expansion attempts
    if (_containsShellExpansion(trimmed)) {
      return SystemctlValidationResult.denied(
        'Shell expansion (\$, `, subshells) is not allowed for security reasons',
      );
    }

    // Tokenize the command
    final tokens = _tokenize(trimmed);
    if (tokens.isEmpty) {
      return SystemctlValidationResult.denied('Empty command after parsing');
    }

    // Parse into command, options, and units
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
        // Check for dangerous characters
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

  /// Parse tokens into structured command
  static ParsedSystemctlCommand _parseTokens(List<String> tokens, String rawInput) {
    String? command;
    List<String> options = [];
    List<String> units = [];
    bool expectingOptionValue = false;
    String? currentOption;

    // Options that expect a value
    const optionsWithValues = {
      '-t', '--type',
      '-n', '--lines',
      '-o', '--output',
      '-H', '--host',
      '-M', '--machine',
      '-p', '--property',
      '--state',
      '--signal',
      '--kill-who',
      '--job-mode',
      '--timestamp',
      '--boot-loader-menu',
      '--boot-loader-entry',
    };

    for (final token in tokens) {
      if (expectingOptionValue) {
        options.add('$currentOption=$token');
        expectingOptionValue = false;
        currentOption = null;
        continue;
      }

      if (token.startsWith('-')) {
        // Handle combined option=value format
        if (token.contains('=')) {
          options.add(token);
        } else if (optionsWithValues.contains(token)) {
          expectingOptionValue = true;
          currentOption = token;
        } else {
          options.add(token);
        }
      } else if (command == null) {
        // First non-option token is the command
        command = token.toLowerCase();
      } else {
        // Everything else is a unit name
        units.add(token);
      }
    }

    return ParsedSystemctlCommand(
      command: command,
      units: units,
      options: options,
      rawInput: rawInput,
    );
  }

  /// Validate the parsed command
  static SystemctlValidationResult _validateParsedCommand(ParsedSystemctlCommand parsed) {
    // If no command specified, systemctl defaults to list-units which is safe
    if (parsed.command == null) {
      return SystemctlValidationResult.allowed(parsed);
    }

    final command = parsed.command!;

    // Check if explicitly denied
    if (deniedCommands.contains(command)) {
      return SystemctlValidationResult.denied(
        'Command "$command" is not allowed - it modifies system state',
      );
    }

    // Check if explicitly allowed
    if (allowedCommands.contains(command)) {
      // Validate options
      final optionValidation = _validateOptions(parsed.options);
      if (!optionValidation.isAllowed) {
        return optionValidation;
      }
      return SystemctlValidationResult.allowed(parsed);
    }

    // Unknown command - deny by default for safety
    return SystemctlValidationResult.denied(
      'Command "$command" is not in the allowed list. '
      'Only read-only commands are permitted: ${allowedCommands.join(", ")}',
    );
  }

  /// Validate options
  static SystemctlValidationResult _validateOptions(List<String> options) {
    for (final option in options) {
      // Extract the option name (handle --option=value format)
      String optionName;
      if (option.contains('=')) {
        optionName = option.split('=').first;
      } else {
        optionName = option;
      }

      // Check for dangerous options
      if (dangerousOptions.contains(optionName)) {
        return SystemctlValidationResult.denied(
          'Option "$optionName" is not allowed for security reasons',
        );
      }

      // We don't strictly validate against safeOptions since there are many
      // harmless options we might not have listed. The main security comes
      // from restricting commands, not options.
    }

    return SystemctlValidationResult.allowed(null);
  }

  /// Convenience method to check if a command string is allowed
  static bool isAllowed(String input) {
    return validate(input).isAllowed;
  }

  /// Build a safe systemctl command string from validated components
  static String? buildCommand({
    required String? command,
    List<String>? units,
    List<String>? options,
  }) {
    // Validate the command first
    final parts = <String>[];
    
    if (command != null) {
      if (!allowedCommands.contains(command.toLowerCase())) {
        return null;
      }
      parts.add(command);
    }

    if (units != null) {
      for (final unit in units) {
        // Basic sanitization - only allow alphanumeric, dash, underscore, dot, @
        if (!_isValidUnitName(unit)) {
          return null;
        }
        parts.add(unit);
      }
    }

    if (options != null) {
      parts.addAll(options);
    }

    return parts.join(' ');
  }

  /// Validate unit name format
  static bool _isValidUnitName(String name) {
    // Unit names should only contain safe characters
    // Pattern: alphanumeric, dash, underscore, dot, @, and optionally colon for templates
    final validPattern = RegExp(r'^[a-zA-Z0-9._@:\-]+$');
    return validPattern.hasMatch(name) && !name.contains('..');
  }
}
