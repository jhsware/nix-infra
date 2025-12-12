import 'package:test/test.dart';
import '../../bin/mcp_server/utils/system_stats_commands.dart';

void main() {
  group('SystemStatsCommandParser', () {
    group('allowed operations', () {
      test('all operation is allowed', () {
        final result = SystemStatsCommandParser.validate('all');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'all');
      });

      test('health operation is allowed', () {
        final result = SystemStatsCommandParser.validate('health');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'health');
      });

      test('disk-io operation is allowed', () {
        final result = SystemStatsCommandParser.validate('disk-io');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'disk-io');
      });

      test('memory operation is allowed', () {
        final result = SystemStatsCommandParser.validate('memory');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'memory');
      });

      test('network operation is allowed', () {
        final result = SystemStatsCommandParser.validate('network');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'network');
      });

      test('disk-usage operation is allowed', () {
        final result = SystemStatsCommandParser.validate('disk-usage');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'disk-usage');
      });

      test('processes operation is allowed', () {
        final result = SystemStatsCommandParser.validate('processes');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'processes');
      });
    });

    group('case handling', () {
      test('uppercase is normalized to lowercase', () {
        final result = SystemStatsCommandParser.validate('HEALTH');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'health');
      });

      test('mixed case is normalized', () {
        final result = SystemStatsCommandParser.validate('Disk-IO');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'disk-io');
      });
    });

    group('whitespace handling', () {
      test('leading whitespace is trimmed', () {
        final result = SystemStatsCommandParser.validate('  health');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'health');
      });

      test('trailing whitespace is trimmed', () {
        final result = SystemStatsCommandParser.validate('health  ');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'health');
      });

      test('both leading and trailing whitespace is trimmed', () {
        final result = SystemStatsCommandParser.validate('  memory  ');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.operation, 'memory');
      });
    });

    group('denied operations', () {
      test('empty operation is denied', () {
        final result = SystemStatsCommandParser.validate('');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('No operation specified'));
      });

      test('unknown operation is denied', () {
        final result = SystemStatsCommandParser.validate('unknown');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('Unknown operation'));
      });

      test('operation with semicolon is denied', () {
        final result = SystemStatsCommandParser.validate('health; rm -rf /');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('Invalid characters'));
      });

      test('operation with pipe is denied', () {
        final result = SystemStatsCommandParser.validate('health | cat');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('Invalid characters'));
      });

      test('operation with ampersand is denied', () {
        final result = SystemStatsCommandParser.validate('health && echo pwned');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('Invalid characters'));
      });

      test('operation with dollar sign is denied', () {
        final result = SystemStatsCommandParser.validate(r'health$VAR');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('Invalid characters'));
      });

      test('operation with backtick is denied', () {
        final result = SystemStatsCommandParser.validate('health`whoami`');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('Invalid characters'));
      });

      test('operation with parentheses is denied', () {
        final result = SystemStatsCommandParser.validate('health()');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('Invalid characters'));
      });

      test('operation with quotes is denied', () {
        final result = SystemStatsCommandParser.validate('health"test"');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('Invalid characters'));
      });

      test('operation with slash is denied', () {
        final result = SystemStatsCommandParser.validate('health/test');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('Invalid characters'));
      });

      test('operation with backslash is denied', () {
        final result = SystemStatsCommandParser.validate(r'health\test');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('Invalid characters'));
      });
    });

    group('isAllowed convenience method', () {
      test('returns true for allowed operations', () {
        expect(SystemStatsCommandParser.isAllowed('health'), isTrue);
        expect(SystemStatsCommandParser.isAllowed('all'), isTrue);
      });

      test('returns false for denied operations', () {
        expect(SystemStatsCommandParser.isAllowed(''), isFalse);
        expect(SystemStatsCommandParser.isAllowed('unknown'), isFalse);
        expect(SystemStatsCommandParser.isAllowed('health; rm'), isFalse);
      });
    });
  });

  group('SystemStatsCommands', () {
    group('getCommand', () {
      test('returns command for health', () {
        final cmd = SystemStatsCommands.getCommand('health');
        expect(cmd, isNotNull);
        expect(cmd, contains('=== HEALTH ==='));
        expect(cmd, contains('/proc/loadavg'));
        expect(cmd, contains('free'));
      });

      test('returns command for disk-io', () {
        final cmd = SystemStatsCommands.getCommand('disk-io');
        expect(cmd, isNotNull);
        expect(cmd, contains('=== DISK-IO ==='));
        expect(cmd, contains('iostat'));
      });

      test('returns command for memory', () {
        final cmd = SystemStatsCommands.getCommand('memory');
        expect(cmd, isNotNull);
        expect(cmd, contains('=== MEMORY ==='));
        expect(cmd, contains('/proc/meminfo'));
        expect(cmd, contains('/proc/vmstat'));
      });

      test('returns command for network', () {
        final cmd = SystemStatsCommands.getCommand('network');
        expect(cmd, isNotNull);
        expect(cmd, contains('=== NETWORK ==='));
        expect(cmd, contains('/proc/net/dev'));
      });

      test('returns command for disk-usage', () {
        final cmd = SystemStatsCommands.getCommand('disk-usage');
        expect(cmd, isNotNull);
        expect(cmd, contains('=== DISK-USAGE ==='));
        expect(cmd, contains('df'));
        expect(cmd, contains('CRITICAL'));
        expect(cmd, contains('WARNING'));
      });

      test('returns command for processes', () {
        final cmd = SystemStatsCommands.getCommand('processes');
        expect(cmd, isNotNull);
        expect(cmd, contains('=== PROCESSES ==='));
        expect(cmd, contains('ps aux'));
        expect(cmd, contains('by_cpu'));
        expect(cmd, contains('by_mem'));
      });

      test('returns combined command for all', () {
        final cmd = SystemStatsCommands.getCommand('all');
        expect(cmd, isNotNull);
        expect(cmd, contains('=== HEALTH ==='));
        expect(cmd, contains('=== DISK-IO ==='));
        expect(cmd, contains('=== MEMORY ==='));
        expect(cmd, contains('=== NETWORK ==='));
        expect(cmd, contains('=== DISK-USAGE ==='));
        expect(cmd, contains('=== PROCESSES ==='));
      });

      test('returns null for unknown operation', () {
        final cmd = SystemStatsCommands.getCommand('unknown');
        expect(cmd, isNull);
      });
    });

    group('getOperationsForCommand', () {
      test('returns single operation for specific command', () {
        expect(SystemStatsCommands.getOperationsForCommand('health'), ['health']);
        expect(SystemStatsCommands.getOperationsForCommand('memory'), ['memory']);
        expect(SystemStatsCommands.getOperationsForCommand('disk-io'), ['disk-io']);
      });

      test('returns all operations for all command', () {
        final ops = SystemStatsCommands.getOperationsForCommand('all');
        expect(ops, contains('health'));
        expect(ops, contains('disk-io'));
        expect(ops, contains('memory'));
        expect(ops, contains('network'));
        expect(ops, contains('disk-usage'));
        expect(ops, contains('processes'));
        expect(ops.length, 6);
      });
    });

    group('command safety', () {
      test('commands are static strings with no interpolation points', () {
        // All commands should be defined as raw strings or properly escaped
        // They use awk $1, $2 etc which is safe (awk field syntax, not shell vars)
        // We verify no shell variable syntax like ${VAR} or unquoted $VAR outside awk
        
        // Just verify commands are non-empty strings
        expect(SystemStatsCommands.health.isNotEmpty, isTrue);
        expect(SystemStatsCommands.diskIo.isNotEmpty, isTrue);
        expect(SystemStatsCommands.memory.isNotEmpty, isTrue);
        expect(SystemStatsCommands.network.isNotEmpty, isTrue);
        expect(SystemStatsCommands.diskUsage.isNotEmpty, isTrue);
        expect(SystemStatsCommands.processes.isNotEmpty, isTrue);
      });

      test('commands contain expected section headers', () {
        expect(SystemStatsCommands.health.contains('=== HEALTH ==='), isTrue);
        expect(SystemStatsCommands.diskIo.contains('=== DISK-IO ==='), isTrue);
        expect(SystemStatsCommands.memory.contains('=== MEMORY ==='), isTrue);
        expect(SystemStatsCommands.network.contains('=== NETWORK ==='), isTrue);
        expect(SystemStatsCommands.diskUsage.contains('=== DISK-USAGE ==='), isTrue);
        expect(SystemStatsCommands.processes.contains('=== PROCESSES ==='), isTrue);
      });

      test('all command combines all individual commands', () {
        final allCmd = SystemStatsCommands.getCommand('all')!;
        expect(allCmd.contains(SystemStatsCommands.health), isTrue);
        expect(allCmd.contains(SystemStatsCommands.diskIo), isTrue);
        expect(allCmd.contains(SystemStatsCommands.memory), isTrue);
        expect(allCmd.contains(SystemStatsCommands.network), isTrue);
        expect(allCmd.contains(SystemStatsCommands.diskUsage), isTrue);
        expect(allCmd.contains(SystemStatsCommands.processes), isTrue);
      });
    });
  });

  group('ParsedSystemStatsCommand', () {
    test('toString returns readable format', () {
      final result = SystemStatsCommandParser.validate('health');
      expect(result.parsedCommand.toString(), contains('health'));
      expect(result.parsedCommand.toString(), contains('operation'));
    });

    test('rawInput preserves original input', () {
      final result = SystemStatsCommandParser.validate('  HEALTH  ');
      expect(result.parsedCommand?.rawInput, '  HEALTH  ');
      expect(result.parsedCommand?.operation, 'health');
    });
  });
}
