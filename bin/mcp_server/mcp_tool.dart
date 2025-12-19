import 'dart:io';
import 'package:nix_infra/providers/providers.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Abstract base class defining the interface for MCP tools
abstract class McpTool {
  /// Description of what this tool does
  static const String description = '';
  
  /// JSON schema properties defining the input parameters for this tool
  static const Map<String, dynamic> inputSchemaProperties = <String, dynamic>{};

  final Directory workingDir;
  final String sshKeyName;
  final InfrastructureProvider provider;

  McpTool({
    required this.workingDir,
    required this.provider,
    required this.sshKeyName,
  });
  
  /// Callback method that executes the tool's functionality
  /// 
  /// [args] - Map containing the input arguments for the tool
  /// [extra] - Additional context or metadata (optional)
  /// 
  /// Returns a [CallToolResult] containing the tool's output
  Future<CallToolResult> callback({
    Map<String, dynamic>? args,
    dynamic extra,
  }) async {
    throw UnimplementedError('callback method must be implemented');
  }
}
