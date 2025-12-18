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
