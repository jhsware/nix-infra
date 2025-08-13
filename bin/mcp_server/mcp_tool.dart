import 'dart:io';
import 'package:nix_infra/hcloud.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Abstract base class defining the interface for MCP tools
abstract class McpTool {
  /// Description of what this tool does
  static const String description = '';
  
  /// JSON schema properties defining the input parameters for this tool
  static const Map<String, dynamic> inputSchemaProperties = <String, dynamic>{};

  final Directory workingDir;
  final String sshKeyName;
  late final HetznerCloud hcloud;

  McpTool({
    required this.workingDir,
    required hcloudToken,
    required this.sshKeyName,
  }) : hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);
  
  /// Callback method that executes the tool's functionality
  /// 
  /// [args] - Map containing the input arguments for the tool
  /// [extra] - Additional context or metadata (optional)
  /// 
  /// Returns a [CallToolResult] containing the tool's output
  static Future<CallToolResult> callback({
    Map<String, dynamic>? args,
    dynamic extra,
  }) async {
    throw UnimplementedError('callback method must be implemented');
  }
}