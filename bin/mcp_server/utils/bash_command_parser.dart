class ParsedCommand {
  final String binary;
  final List<String> arguments;
  
  ParsedCommand({required this.binary, required this.arguments});
  
  @override
  String toString() {
    return 'ParsedCommand(binary: $binary, arguments: $arguments)';
  }
}

class BashCommandParser {
  /// Parses a bash command string into a list of ParsedCommand objects
  /// Handles basic command separation by pipes (|), semicolons (;), and logical operators (&&, ||)
  static List<ParsedCommand> parseCommands(String commandString) {
    if (commandString.trim().isEmpty) return [];
    
    // Split by command separators while preserving quoted sections
    List<String> commandStrings = _splitCommands(commandString);
    
    return commandStrings
        .map((cmd) => _parseCommand(cmd.trim()))
        .where((cmd) => cmd != null)
        .cast<ParsedCommand>()
        .toList();
  }
  
  /// Splits command string by separators (|, ;, &&, ||) while respecting quotes
  static List<String> _splitCommands(String input) {
    List<String> commands = [];
    StringBuffer current = StringBuffer();
    bool inSingleQuote = false;
    bool inDoubleQuote = false;
    bool escaped = false;
    
    for (int i = 0; i < input.length; i++) {
      String char = input[i];
      String? next = i + 1 < input.length ? input[i + 1] : null;
      
      if (escaped) {
        current.write(char);
        escaped = false;
        continue;
      }
      
      if (char == '\\' && !inSingleQuote) {
        escaped = true;
        current.write(char);
        continue;
      }
      
      if (char == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
        current.write(char);
        continue;
      }
      
      if (char == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
        current.write(char);
        continue;
      }
      
      if (!inSingleQuote && !inDoubleQuote) {
        // Check for command separators
        if (char == '|' || char == ';') {
          commands.add(current.toString());
          current.clear();
          continue;
        }
        
        if (char == '&' && next == '&') {
          commands.add(current.toString());
          current.clear();
          i++; // Skip next character
          continue;
        }
        
        if (char == '|' && next == '|') {
          commands.add(current.toString());
          current.clear();
          i++; // Skip next character
          continue;
        }
      }
      
      current.write(char);
    }
    
    if (current.isNotEmpty) {
      commands.add(current.toString());
    }
    
    return commands;
  }
  
  /// Parses a single command into binary and arguments
  static ParsedCommand? _parseCommand(String command) {
    if (command.isEmpty) return null;
    
    List<String> tokens = _tokenize(command);
    if (tokens.isEmpty) return null;
    
    String binary = tokens.first;
    List<String> arguments = tokens.skip(1).toList();
    
    return ParsedCommand(binary: binary, arguments: arguments);
  }
  
  /// Tokenizes a command string into individual arguments, respecting quotes and escapes
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
      String char = input[i];
      
      if (escaped) {
        current.write(char);
        escaped = false;
        continue;
      }
      
      if (char == '\\' && !inSingleQuote) {
        escaped = true;
        // Don't write the backslash for now, handle in next iteration
        continue;
      }
      
      if (char == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
        // Don't include quotes in the final token
        continue;
      }
      
      if (char == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
        // Don't include quotes in the final token
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
}

// Example usage and test cases
/*
void main() {
  // Test cases
  List<String> testCommands = [
    'ls -la',
    'grep "hello world" file.txt',
    "echo 'single quoted string'",
    'find /home -name "*.dart" | grep test',
    'cd /tmp && ls -la',
    'echo "escaped \\"quotes\\"" file.txt',
    'ps aux; echo "done"',
    'git commit -m "Initial commit" && git push',
  ];
  
  for (String cmd in testCommands) {
    print('Input: $cmd');
    List<ParsedCommand> parsed = BashCommandParser.parseCommands(cmd);
    for (int i = 0; i < parsed.length; i++) {
      print('  Command ${i + 1}: ${parsed[i]}');
    }
    print('');
  }
}
*/