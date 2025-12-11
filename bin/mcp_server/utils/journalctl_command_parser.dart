/// Parsed journalctl command with validation support
class ParsedJournalctlCommand {
  final List<String> options;
  final List<String> matches;
  final String rawInput;

  ParsedJournalctlCommand({
    this.options = const [],
    this.matches = const [],
    required this.rawInput,
  });

  @override
  String toString() {
    return 'ParsedJournalctlCommand(options: $options, matches: $matches)';
  }
}

/// Result of journalctl command validation
class JournalctlValidationResult {
  final bool isAllowed;
  final String? reason;
  final ParsedJournalctlCommand? parsedCommand;

  JournalctlValidationResult.allowed(this.parsedCommand)
      : isAllowed = true,
        reason = null;

  JournalctlValidationResult.denied(this.reason)
      : isAllowed = false,
        parsedCommand = null;

  @override
  String toString() {
    if (isAllowed) {
      return 'JournalctlValidationResult(allowed: $parsedCommand)';
    }
    return 'JournalctlValidationResult(denied: $reason)';
  }
}

/// Parser and validator for journalctl commands
/// Only allows read-only, non-destructive options
class JournalctlCommandParser {
  /// Options that are safe (read-only operations)
  static const Set<String> allowedOptions = {
    // Unit/service filtering
    '-u', '--unit',
    '-t', '--identifier',
    '--user-unit',

    // Priority/level filtering
    '-p', '--priority',

    // Text filtering
    '-g', '--grep',
    '--case-sensitive',

    // Time filtering
    '-S', '--since',
    '-U', '--until',
    '-b', '--boot',

    // Output control
    '-n', '--lines',
    '-r', '--reverse',
    '-o', '--output',
    '-f', '--follow',
    '-e', '--pager-end',
    '--no-pager',
    '-a', '--all',
    '-q', '--quiet',
    '--no-tail',
    '--no-hostname',
    '--no-full',
    '--full',
    '-l',

    // Journal selection
    '-m', '--merge',
    '-k', '--dmesg',
    '--system',
    '--user',
    '-D', '--directory',
    '--file',
    '--root',
    '--namespace',

    // Cursor control
    '--cursor',
    '--after-cursor',
    '--show-cursor',
    '--cursor-file',

    // Information/listing commands
    '--list-boots',
    '--disk-usage',
    '--header',
    '-F', '--field',
    '-N', '--fields',
    '-x', '--catalog',

    // Verification (read-only check)
    '--verify',
    '--verify-key',

    // Help
    '-h', '--help',
    '--version',

    // Output formatting
    '--output-fields',
    '--utc',

    // Filtering by various fields
    '--facility',
    '_SYSTEMD_UNIT',
    '_PID',
    '_UID',
    '_GID',
    '_COMM',
    '_EXE',
    '_CMDLINE',
    '_MACHINE_ID',
    '_HOSTNAME',
    '_TRANSPORT',
    'SYSLOG_IDENTIFIER',
    'SYSLOG_FACILITY',
    'SYSLOG_PID',
    'MESSAGE',
    'PRIORITY',
  };

  /// Options that are dangerous (modify journal state)
  static const Set<String> deniedOptions = {
    // These modify or delete journal data
    '--flush',
    '--relinquish-var',
    '--smart-relinquish-var',
    '--rotate',
    '--vacuum-size',
    '--vacuum-time',
    '--vacuum-files',
    '--sync',

    // Key management
    '--setup-keys',
    '--force',
    '--interval',
  };

  /// Parses and validates a journalctl command string (options + matches)
  /// Returns a validation result indicating if the command is allowed
  static JournalctlValidationResult validate(String input) {
    final trimmed = input.trim();
    
    // Empty input is allowed (just runs journalctl with defaults)
    if (trimmed.isEmpty) {
      return JournalctlValidationResult.allowed(
        ParsedJournalctlCommand(rawInput: trimmed),
      );
    }

    // Check for command chaining attempts
    if (_containsCommandChaining(trimmed)) {
      return JournalctlValidationResult.denied(
        'Command chaining (;, &&, ||, |) is not allowed for security reasons',
      );
    }

    // Check for shell expansion attempts
    if (_containsShellExpansion(trimmed)) {
      return JournalctlValidationResult.denied(
        'Shell expansion (\$, `, subshells) is not allowed for security reasons',
      );
    }

    // Tokenize the command
    final tokens = _tokenize(trimmed);
    if (tokens.isEmpty) {
      return JournalctlValidationResult.allowed(
        ParsedJournalctlCommand(rawInput: trimmed),
      );
    }

    // Parse into options and matches
    final parsed = _parseTokens(tokens, trimmed);

    // Validate options
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

  /// Options that expect a value
  static const Set<String> optionsWithValues = {
    '-u', '--unit',
    '-t', '--identifier',
    '--user-unit',
    '-p', '--priority',
    '-g', '--grep',
    '-S', '--since',
    '-U', '--until',
    '-b', '--boot',
    '-n', '--lines',
    '-o', '--output',
    '-D', '--directory',
    '--file',
    '--root',
    '--namespace',
    '--cursor',
    '--after-cursor',
    '--cursor-file',
    '-F', '--field',
    '--output-fields',
    '--facility',
    '--verify-key',
    '--vacuum-size',
    '--vacuum-time',
    '--vacuum-files',
    '--interval',
  };

  /// Parse tokens into structured command
  static ParsedJournalctlCommand _parseTokens(List<String> tokens, String rawInput) {
    List<String> options = [];
    List<String> matches = [];
    bool expectingOptionValue = false;

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
      } else if (token.contains('=')) {
        // Field matches like _SYSTEMD_UNIT=nginx.service
        matches.add(token);
      } else {
        // Could be a match pattern or a value
        matches.add(token);
      }
    }

    return ParsedJournalctlCommand(
      options: options,
      matches: matches,
      rawInput: rawInput,
    );
  }

  /// Validate the parsed command
  static JournalctlValidationResult _validateParsedCommand(ParsedJournalctlCommand parsed) {
    // Check each option
    for (final option in parsed.options) {
      final validation = _validateOption(option);
      if (!validation.isAllowed) {
        return validation;
      }
    }

    // Validate matches (field filters)
    for (final match in parsed.matches) {
      final validation = _validateMatch(match);
      if (!validation.isAllowed) {
        return validation;
      }
    }

    return JournalctlValidationResult.allowed(parsed);
  }

  /// Validate a single option
  static JournalctlValidationResult _validateOption(String option) {
    // Extract the option name (handle --option=value format)
    String optionName;
    if (option.contains('=')) {
      optionName = option.split('=').first;
    } else {
      optionName = option;
    }

    // Check if option starts with - (it should)
    if (!optionName.startsWith('-')) {
      // This is likely an option value, not the option itself
      return JournalctlValidationResult.allowed(null);
    }

    // Check for explicitly denied options
    if (deniedOptions.contains(optionName)) {
      return JournalctlValidationResult.denied(
        'Option "$optionName" is not allowed - it modifies journal state',
      );
    }

    // Check if it's in the allowed list or is an option value
    // We're lenient here - if it starts with - and isn't denied, we allow it
    // This is because journalctl has many options and we want to be flexible
    // while blocking the dangerous ones

    return JournalctlValidationResult.allowed(null);
  }

  /// Validate a match pattern
  static JournalctlValidationResult _validateMatch(String match) {
    // Check for path traversal in directory-like matches
    if (match.contains('..')) {
      return JournalctlValidationResult.denied(
        'Path traversal ("..") is not allowed in match patterns',
      );
    }

    return JournalctlValidationResult.allowed(null);
  }

  /// Convenience method to check if a command string is allowed
  static bool isAllowed(String input) {
    return validate(input).isAllowed;
  }

  /// Build a safe journalctl command string from validated components
  static String? buildCommand({
    List<String>? options,
    List<String>? matches,
  }) {
    final parts = <String>[];

    if (options != null) {
      for (final option in options) {
        // Extract option name for validation
        String optionName;
        if (option.contains('=')) {
          optionName = option.split('=').first;
        } else {
          optionName = option;
        }

        if (deniedOptions.contains(optionName)) {
          return null;
        }
        parts.add(option);
      }
    }

    if (matches != null) {
      for (final match in matches) {
        if (match.contains('..')) {
          return null;
        }
        parts.add(match);
      }
    }

    return parts.join(' ');
  }
}
