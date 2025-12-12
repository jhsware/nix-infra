import 'package:test/test.dart';
import '../../bin/mcp_server/utils/systemctl_command_parser.dart';

void main() {
  group('SystemctlCommandParser', () {
    group('allowed read-only commands', () {
      test('status command is allowed', () {
        final result = SystemctlCommandParser.validate('status nginx');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'status');
        expect(result.parsedCommand?.units, ['nginx']);
      });

      test('show command is allowed', () {
        final result = SystemctlCommandParser.validate('show nginx.service');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'show');
      });

      test('cat command is allowed', () {
        final result = SystemctlCommandParser.validate('cat sshd.service');
        expect(result.isAllowed, isTrue);
      });

      test('list-units is allowed', () {
        final result = SystemctlCommandParser.validate('list-units --type=service');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'list-units');
      });

      test('list-sockets is allowed', () {
        final result = SystemctlCommandParser.validate('list-sockets');
        expect(result.isAllowed, isTrue);
      });

      test('list-timers is allowed', () {
        final result = SystemctlCommandParser.validate('list-timers --all');
        expect(result.isAllowed, isTrue);
      });

      test('list-unit-files is allowed', () {
        final result = SystemctlCommandParser.validate('list-unit-files');
        expect(result.isAllowed, isTrue);
      });

      test('list-dependencies is allowed', () {
        final result = SystemctlCommandParser.validate('list-dependencies nginx.service');
        expect(result.isAllowed, isTrue);
      });

      test('is-active is allowed', () {
        final result = SystemctlCommandParser.validate('is-active nginx');
        expect(result.isAllowed, isTrue);
      });

      test('is-enabled is allowed', () {
        final result = SystemctlCommandParser.validate('is-enabled nginx');
        expect(result.isAllowed, isTrue);
      });

      test('is-failed is allowed', () {
        final result = SystemctlCommandParser.validate('is-failed nginx');
        expect(result.isAllowed, isTrue);
      });

      test('is-system-running is allowed', () {
        final result = SystemctlCommandParser.validate('is-system-running');
        expect(result.isAllowed, isTrue);
      });

      test('get-default is allowed', () {
        final result = SystemctlCommandParser.validate('get-default');
        expect(result.isAllowed, isTrue);
      });

      test('show-environment is allowed', () {
        final result = SystemctlCommandParser.validate('show-environment');
        expect(result.isAllowed, isTrue);
      });

      test('help is allowed', () {
        final result = SystemctlCommandParser.validate('help');
        expect(result.isAllowed, isTrue);
      });

      test('no command (defaults to list-units) is allowed', () {
        final result = SystemctlCommandParser.validate('');
        expect(result.isAllowed, isFalse); // Empty is denied
        
        final result2 = SystemctlCommandParser.validate('--type=service');
        expect(result2.isAllowed, isTrue); // Options only is allowed
      });
    });

    group('denied destructive commands', () {
      test('start is denied', () {
        final result = SystemctlCommandParser.validate('start nginx');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('not allowed'));
      });

      test('stop is denied', () {
        final result = SystemctlCommandParser.validate('stop nginx');
        expect(result.isAllowed, isFalse);
      });

      test('restart is denied', () {
        final result = SystemctlCommandParser.validate('restart nginx');
        expect(result.isAllowed, isFalse);
      });

      test('reload is denied', () {
        final result = SystemctlCommandParser.validate('reload nginx');
        expect(result.isAllowed, isFalse);
      });

      test('enable is denied', () {
        final result = SystemctlCommandParser.validate('enable nginx');
        expect(result.isAllowed, isFalse);
      });

      test('disable is denied', () {
        final result = SystemctlCommandParser.validate('disable nginx');
        expect(result.isAllowed, isFalse);
      });

      test('mask is denied', () {
        final result = SystemctlCommandParser.validate('mask nginx');
        expect(result.isAllowed, isFalse);
      });

      test('unmask is denied', () {
        final result = SystemctlCommandParser.validate('unmask nginx');
        expect(result.isAllowed, isFalse);
      });

      test('kill is denied', () {
        final result = SystemctlCommandParser.validate('kill nginx');
        expect(result.isAllowed, isFalse);
      });

      test('reboot is denied', () {
        final result = SystemctlCommandParser.validate('reboot');
        expect(result.isAllowed, isFalse);
      });

      test('poweroff is denied', () {
        final result = SystemctlCommandParser.validate('poweroff');
        expect(result.isAllowed, isFalse);
      });

      test('suspend is denied', () {
        final result = SystemctlCommandParser.validate('suspend');
        expect(result.isAllowed, isFalse);
      });

      test('hibernate is denied', () {
        final result = SystemctlCommandParser.validate('hibernate');
        expect(result.isAllowed, isFalse);
      });

      test('daemon-reload is denied', () {
        final result = SystemctlCommandParser.validate('daemon-reload');
        expect(result.isAllowed, isFalse);
      });

      test('set-default is denied', () {
        final result = SystemctlCommandParser.validate('set-default multi-user.target');
        expect(result.isAllowed, isFalse);
      });

      test('isolate is denied', () {
        final result = SystemctlCommandParser.validate('isolate rescue.target');
        expect(result.isAllowed, isFalse);
      });

      test('edit is denied', () {
        final result = SystemctlCommandParser.validate('edit nginx.service');
        expect(result.isAllowed, isFalse);
      });

      test('reset-failed is denied', () {
        final result = SystemctlCommandParser.validate('reset-failed');
        expect(result.isAllowed, isFalse);
      });
    });

    group('command chaining prevention', () {
      test('semicolon chaining is denied', () {
        final result = SystemctlCommandParser.validate('status nginx; reboot');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('&& chaining is denied', () {
        final result = SystemctlCommandParser.validate('status nginx && restart nginx');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('|| chaining is denied', () {
        final result = SystemctlCommandParser.validate('status nginx || start nginx');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('pipe chaining is denied', () {
        final result = SystemctlCommandParser.validate('list-units | grep nginx');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });
    });

    group('shell expansion prevention', () {
      test('variable expansion is denied', () {
        final result = SystemctlCommandParser.validate('status \$SERVICE');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });

      test('backtick expansion is denied', () {
        final result = SystemctlCommandParser.validate('status `cat /etc/service`');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });

      test('subshell expansion is denied', () {
        final result = SystemctlCommandParser.validate('status \$(cat /etc/service)');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });
    });

    group('quoted strings handling', () {
      test('single quoted strings preserve content', () {
        // Single quotes should protect the content, but we still deny $ inside
        // because some shells might process it differently
        final result = SystemctlCommandParser.validate("status 'my-service'");
        expect(result.isAllowed, isTrue);
      });

      test('double quoted strings work', () {
        final result = SystemctlCommandParser.validate('status "my-service"');
        expect(result.isAllowed, isTrue);
      });

      test('escaped quotes work', () {
        final result = SystemctlCommandParser.validate('status my\\"service');
        expect(result.isAllowed, isTrue);
      });
    });

    group('options handling', () {
      test('common options are allowed', () {
        final result = SystemctlCommandParser.validate('status nginx --full --no-pager');
        expect(result.isAllowed, isTrue);
      });

      test('type filter is allowed', () {
        final result = SystemctlCommandParser.validate('list-units --type=service');
        expect(result.isAllowed, isTrue);
      });

      test('state filter is allowed', () {
        final result = SystemctlCommandParser.validate('list-units --state=failed');
        expect(result.isAllowed, isTrue);
      });

      test('property option is allowed', () {
        final result = SystemctlCommandParser.validate('show nginx -p MainPID');
        expect(result.isAllowed, isTrue);
      });

      test('--root option is denied', () {
        final result = SystemctlCommandParser.validate('status nginx --root=/mnt');
        expect(result.isAllowed, isFalse);
      });
    });

    group('unit name validation', () {
      test('simple unit names work', () {
        final result = SystemctlCommandParser.validate('status nginx');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.units, ['nginx']);
      });

      test('unit names with extensions work', () {
        final result = SystemctlCommandParser.validate('status nginx.service');
        expect(result.isAllowed, isTrue);
      });

      test('template units work', () {
        final result = SystemctlCommandParser.validate('status container@myapp.service');
        expect(result.isAllowed, isTrue);
      });

      test('multiple units work', () {
        final result = SystemctlCommandParser.validate('status nginx sshd docker');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.units, ['nginx', 'sshd', 'docker']);
      });
    });

    group('isAllowed convenience method', () {
      test('returns true for allowed commands', () {
        expect(SystemctlCommandParser.isAllowed('status nginx'), isTrue);
      });

      test('returns false for denied commands', () {
        expect(SystemctlCommandParser.isAllowed('restart nginx'), isFalse);
      });
    });

    group('buildCommand method', () {
      test('builds valid commands', () {
        final cmd = SystemctlCommandParser.buildCommand(
          command: 'status',
          units: ['nginx', 'sshd'],
          options: ['--full'],
        );
        expect(cmd, 'status nginx sshd --full');
      });

      test('returns null for invalid commands', () {
        final cmd = SystemctlCommandParser.buildCommand(
          command: 'restart',
          units: ['nginx'],
        );
        expect(cmd, isNull);
      });

      test('handles null units and options', () {
        final cmd = SystemctlCommandParser.buildCommand(command: 'list-units');
        expect(cmd, 'list-units');
      });
    });

    group('case insensitivity', () {
      test('commands are case-insensitive', () {
        final result1 = SystemctlCommandParser.validate('STATUS nginx');
        final result2 = SystemctlCommandParser.validate('Status nginx');
        expect(result1.isAllowed, isTrue);
        expect(result2.isAllowed, isTrue);
      });
    });

    group('edge cases', () {
      test('empty input is denied', () {
        final result = SystemctlCommandParser.validate('');
        expect(result.isAllowed, isFalse);
      });

      test('whitespace only is denied', () {
        final result = SystemctlCommandParser.validate('   ');
        expect(result.isAllowed, isFalse);
      });

      test('unknown commands are denied', () {
        final result = SystemctlCommandParser.validate('unknown-command nginx');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('not in the allowed list'));
      });
    });
  });
}
