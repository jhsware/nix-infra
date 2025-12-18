/// Line ending style detected in a file
enum LineEndingStyle {
  unix,    // LF (\n)
  windows, // CRLF (\r\n)
  mixed,   // Both styles present
}

/// Normalize line endings to Unix style (\n)
/// 
/// Converts all line endings (CRLF, CR, LF) to LF (\n)
String normalizeLineEndings(String content) {
  // Replace CRLF with LF first to avoid double conversion
  return content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

/// Detect the line ending style used in the content
/// 
/// Returns:
/// - [LineEndingStyle.windows] if CRLF (\r\n) is used
/// - [LineEndingStyle.unix] if only LF (\n) is used
/// - [LineEndingStyle.mixed] if both styles are present
LineEndingStyle detectLineEndings(String content) {
  if (content.isEmpty) {
    return LineEndingStyle.unix; // Default to Unix for empty files
  }

  // Count occurrences of each line ending type
  final crlfCount = '\r\n'.allMatches(content).length;
  final lfOnlyCount = '\n'.allMatches(content).length - crlfCount;
  
  // If we have both CRLF and standalone LF, it's mixed
  if (crlfCount > 0 && lfOnlyCount > 0) {
    return LineEndingStyle.mixed;
  }
  
  // If we have CRLF, it's Windows style
  if (crlfCount > 0) {
    return LineEndingStyle.windows;
  }
  
  // Otherwise it's Unix style (including files with no line endings)
  return LineEndingStyle.unix;
}

/// Apply line ending style to content
/// 
/// Converts Unix-style line endings (\n) to the specified style
String applyLineEndings(String content, LineEndingStyle style) {
  switch (style) {
    case LineEndingStyle.windows:
      // Convert LF to CRLF
      return content.replaceAll('\n', '\r\n');
    case LineEndingStyle.unix:
    case LineEndingStyle.mixed:
      // Keep as Unix style (LF)
      // For mixed files, default to Unix to avoid corruption
      return content;
  }
}

/// Add line numbers to content
/// 
/// Adds "L#: " prefix to each line where # is the line number (1-indexed)
String addLineNumbers(String content) {
  if (content.isEmpty) {
    return content;
  }
  
  final lines = content.split('\n');
  final numberedLines = <String>[];
  
  for (var i = 0; i < lines.length; i++) {
    numberedLines.add('L${i + 1}: ${lines[i]}');
  }
  
  return numberedLines.join('\n');
}

/// Strip line numbers from content
/// 
/// Removes "L#: " prefix from each line if present
/// Returns the content unchanged if no line numbers are detected
String stripLineNumbers(String content) {
  if (content.isEmpty) {
    return content;
  }
  
  final lines = content.split('\n');
  final strippedLines = <String>[];
  
  // Regex to match "L<number>: " at the start of a line
  final lineNumberPattern = RegExp(r'^L\d+: ');
  
  for (final line in lines) {
    if (lineNumberPattern.hasMatch(line)) {
      // Strip the line number prefix
      strippedLines.add(line.replaceFirst(lineNumberPattern, ''));
    } else {
      // Keep the line as-is if no line number prefix
      strippedLines.add(line);
    }
  }
  
  return strippedLines.join('\n');
}
