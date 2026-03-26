/// Parsed cscli command with validation support
class ParsedCscliCommand {
  final String? command;
  final String? subcommand;
  final List<String> options;
  final String rawInput;

  ParsedCscliCommand({
    this.command,
    this.subcommand,
    this.options = const [],
    required this.rawInput,
  });

  @override
  String toString() {
    return 'ParsedCscliCommand(command: $command, subcommand: $subcommand, options: $options)';
  }
}

/// Result of cscli command validation
class CscliValidationResult {
  final bool isAllowed;
  final String? reason;
  final ParsedCscliCommand? parsedCommand;

  CscliValidationResult.allowed(this.parsedCommand)
      : isAllowed = true,
        reason = null;

  CscliValidationResult.denied(this.reason)
      : isAllowed = false,
        parsedCommand = null;

  @override
  String toString() {
    if (isAllowed) {
      return 'CscliValidationResult(allowed: $parsedCommand)';
    }
    return 'CscliValidationResult(denied: $reason)';
  }
}

/// Parser and validator for cscli (CrowdSec) commands
/// Only allows read-only, non-destructive commands using a whitelist approach
class CscliCommandParser {
  /// Allowed command + subcommand pairs (whitelist)
  /// Commands with empty sets are standalone (no subcommand required)
  /// Commands with non-empty sets require one of the listed subcommands
  static const Map<String, Set<String>> allowedCommands = {
    // Decision/alert queries
    'decisions': {'list'},
    'alerts': {'list', 'inspect'},

    // Metrics (standalone)
    'metrics': {},

    // Hub queries
    'hub': {'list'},

    // Infrastructure queries
    'bouncers': {'list'},
    'machines': {'list'},

    // API status checks
    'lapi': {'status'},
    'capi': {'status'},

    // Explain (standalone)
    'explain': {},

    // Installed component queries
    'parsers': {'list'},
    'scenarios': {'list'},
    'postoverflows': {'list'},
    'collections': {'list'},

    // Config (read-only)
    'config': {'show'},
  };

  /// Explicitly denied destructive commands for clear error messages
  static const Map<String, Set<String>> deniedCommands = {
    'decisions': {'delete', 'add'},
    'alerts': {'delete'},
    'machines': {'remove', 'add'},
    'bouncers': {'delete', 'add'},
    'hub': {'remove', 'upgrade', 'install', 'update'},
    'config': {'restore', 'backup'},
    'console': {'enroll', 'disable', 'enable', 'status'},
    'simulation': {'enable', 'disable'},
  };

  /// Entirely denied commands (all subcommands blocked)
  static const Set<String> deniedCommandsAll = {
    'papi',
  };

  /// Options that are safe for read operations
  static const Set<String> safeOptions = {
    '-o', '--output',
    '--limit',
    '--since', '--until',
    '--type',
    '--scope',
    '--value',
    '--scenario',
    '-a', '--all',
    '--no-pager',
    '-d',
    '--machine',
    '--origin',
    '--range',
    '--ip',
    '--reason',
    '-h', '--help',
    '--version',
    '--color',
    '--no-color',
  };

  /// Options that could be dangerous
  static const Set<String> dangerousOptions = {
    '--remediation',
    '--purge',
    '--force',
  };

  /// Parses and validates a cscli command string
  /// Returns a validation result indicating if the command is allowed
  static CscliValidationResult validate(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return CscliValidationResult.denied('Empty command');
    }

    // Check for command chaining attempts
    if (_containsCommandChaining(trimmed)) {
      return CscliValidationResult.denied(
        'Command chaining (;, &&, ||, |) is not allowed for security reasons',
      );
    }

    // Check for shell expansion attempts
    if (_containsShellExpansion(trimmed)) {
      return CscliValidationResult.denied(
        'Shell expansion (\$, `, subshells) is not allowed for security reasons',
      );
    }

    // Tokenize the command
    final tokens = _tokenize(trimmed);
    if (tokens.isEmpty) {
      return CscliValidationResult.denied('Empty command after parsing');
    }

    // Parse into command, subcommand, and options
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

  /// Parse tokens into structured command
  static ParsedCscliCommand _parseTokens(List<String> tokens, String rawInput) {
    String? command;
    String? subcommand;
    List<String> options = [];
    bool expectingOptionValue = false;
    String? currentOption;

    // Options that expect a value
    const optionsWithValues = {
      '-o', '--output',
      '--limit',
      '--since', '--until',
      '--type',
      '--scope',
      '--value',
      '--scenario',
      '-d',
      '--machine',
      '--origin',
      '--range',
      '--ip',
      '--reason',
      '--color',
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
      } else if (subcommand == null) {
        // Second non-option token is the subcommand
        subcommand = token.toLowerCase();
      } else {
        // Additional positional args treated as options (e.g. explain args)
        options.add(token);
      }
    }

    return ParsedCscliCommand(
      command: command,
      subcommand: subcommand,
      options: options,
      rawInput: rawInput,
    );
  }

  /// Validate the parsed command
  static CscliValidationResult _validateParsedCommand(ParsedCscliCommand parsed) {
    if (parsed.command == null) {
      return CscliValidationResult.denied(
        'No command specified. Available commands: ${allowedCommands.keys.join(", ")}',
      );
    }

    final command = parsed.command!;

    // Check if entirely denied command
    if (deniedCommandsAll.contains(command)) {
      return CscliValidationResult.denied(
        'Command "$command" is not allowed - all subcommands are destructive',
      );
    }

    // Check if command is in the denied list with specific subcommand
    if (deniedCommands.containsKey(command)) {
      final deniedSubs = deniedCommands[command]!;
      if (parsed.subcommand != null && deniedSubs.contains(parsed.subcommand)) {
        return CscliValidationResult.denied(
          'Command "$command ${parsed.subcommand}" is not allowed - it modifies system state',
        );
      }
    }

    // Check if command is in the allowed list
    if (!allowedCommands.containsKey(command)) {
      return CscliValidationResult.denied(
        'Command "$command" is not in the allowed list. '
        'Only read-only commands are permitted: ${allowedCommands.keys.join(", ")}',
      );
    }

    final allowedSubs = allowedCommands[command]!;

    // Standalone commands (empty subcommand set)
    if (allowedSubs.isEmpty) {
      // Validate options
      final optionValidation = _validateOptions(parsed.options);
      if (!optionValidation.isAllowed) {
        return optionValidation;
      }
      return CscliValidationResult.allowed(parsed);
    }

    // Commands that require a subcommand
    if (parsed.subcommand == null) {
      return CscliValidationResult.denied(
        'Command "$command" requires a subcommand. '
        'Allowed subcommands: ${allowedSubs.join(", ")}',
      );
    }

    if (!allowedSubs.contains(parsed.subcommand)) {
      return CscliValidationResult.denied(
        'Subcommand "${parsed.subcommand}" is not allowed for "$command". '
        'Allowed subcommands: ${allowedSubs.join(", ")}',
      );
    }

    // Validate options
    final optionValidation = _validateOptions(parsed.options);
    if (!optionValidation.isAllowed) {
      return optionValidation;
    }

    return CscliValidationResult.allowed(parsed);
  }

  /// Validate options
  static CscliValidationResult _validateOptions(List<String> options) {
    for (final option in options) {
      // Only check options that start with -
      if (!option.startsWith('-')) continue;

      // Extract the option name (handle --option=value format)
      String optionName;
      if (option.contains('=')) {
        optionName = option.split('=').first;
      } else {
        optionName = option;
      }

      // Check for dangerous options
      if (dangerousOptions.contains(optionName)) {
        return CscliValidationResult.denied(
          'Option "$optionName" is not allowed for security reasons',
        );
      }
    }

    return CscliValidationResult.allowed(null);
  }

  /// Convenience method to check if a command string is allowed
  static bool isAllowed(String input) {
    return validate(input).isAllowed;
  }

  /// Build a safe cscli command string from validated components
  static String? buildCommand({
    required String? command,
    String? subcommand,
    List<String>? options,
  }) {
    if (command == null) return null;

    final cmdLower = command.toLowerCase();

    // Check if command is allowed
    if (!allowedCommands.containsKey(cmdLower)) {
      return null;
    }

    final allowedSubs = allowedCommands[cmdLower]!;
    final parts = <String>[cmdLower];

    // If subcommands are required, validate
    if (allowedSubs.isNotEmpty) {
      if (subcommand == null) return null;
      final subLower = subcommand.toLowerCase();
      if (!allowedSubs.contains(subLower)) return null;
      parts.add(subLower);
    }

    if (options != null) {
      parts.addAll(options);
    }

    return parts.join(' ');
  }
}
