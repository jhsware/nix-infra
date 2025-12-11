import 'package:test/test.dart';
import '../../bin/mcp_server/utils/journalctl_command_parser.dart';

void main() {
  group('JournalctlCommandParser', () {
    group('allowed read-only options', () {
      test('empty input is allowed', () {
        final result = JournalctlCommandParser.validate('');
        expect(result.isAllowed, isTrue);
      });

      test('-u/--unit option is allowed', () {
        final result = JournalctlCommandParser.validate('-u nginx');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.options, ['-u', 'nginx']);
      });

      test('--unit=value format is allowed', () {
        final result = JournalctlCommandParser.validate('--unit=nginx.service');
        expect(result.isAllowed, isTrue);
      });

      test('-n/--lines option is allowed', () {
        final result = JournalctlCommandParser.validate('-n 100');
        expect(result.isAllowed, isTrue);
      });

      test('--lines=value format is allowed', () {
        final result = JournalctlCommandParser.validate('--lines=50');
        expect(result.isAllowed, isTrue);
      });

      test('-f/--follow option is allowed', () {
        final result = JournalctlCommandParser.validate('-f');
        expect(result.isAllowed, isTrue);
      });

      test('-p/--priority option is allowed', () {
        final result = JournalctlCommandParser.validate('-p err');
        expect(result.isAllowed, isTrue);
      });

      test('--priority=value format is allowed', () {
        final result = JournalctlCommandParser.validate('--priority=warning');
        expect(result.isAllowed, isTrue);
      });

      test('-S/--since option is allowed', () {
        final result = JournalctlCommandParser.validate('--since="2024-01-01"');
        expect(result.isAllowed, isTrue);
      });

      test('-U/--until option is allowed', () {
        final result = JournalctlCommandParser.validate('--until="2024-12-31"');
        expect(result.isAllowed, isTrue);
      });

      test('-b/--boot option is allowed', () {
        final result = JournalctlCommandParser.validate('-b -1');
        expect(result.isAllowed, isTrue);
      });

      test('-o/--output option is allowed', () {
        final result = JournalctlCommandParser.validate('-o json');
        expect(result.isAllowed, isTrue);
      });

      test('--no-pager option is allowed', () {
        final result = JournalctlCommandParser.validate('--no-pager');
        expect(result.isAllowed, isTrue);
      });

      test('-r/--reverse option is allowed', () {
        final result = JournalctlCommandParser.validate('-r');
        expect(result.isAllowed, isTrue);
      });

      test('-k/--dmesg option is allowed', () {
        final result = JournalctlCommandParser.validate('-k');
        expect(result.isAllowed, isTrue);
      });

      test('--list-boots option is allowed', () {
        final result = JournalctlCommandParser.validate('--list-boots');
        expect(result.isAllowed, isTrue);
      });

      test('--disk-usage option is allowed', () {
        final result = JournalctlCommandParser.validate('--disk-usage');
        expect(result.isAllowed, isTrue);
      });

      test('-F/--field option is allowed', () {
        final result = JournalctlCommandParser.validate('-F _SYSTEMD_UNIT');
        expect(result.isAllowed, isTrue);
      });

      test('-N/--fields option is allowed', () {
        final result = JournalctlCommandParser.validate('-N');
        expect(result.isAllowed, isTrue);
      });

      test('--verify option is allowed', () {
        final result = JournalctlCommandParser.validate('--verify');
        expect(result.isAllowed, isTrue);
      });

      test('-g/--grep option is allowed', () {
        final result = JournalctlCommandParser.validate('-g "error"');
        expect(result.isAllowed, isTrue);
      });

      test('-t/--identifier option is allowed', () {
        final result = JournalctlCommandParser.validate('-t sudo');
        expect(result.isAllowed, isTrue);
      });

      test('-e/--pager-end option is allowed', () {
        final result = JournalctlCommandParser.validate('-e');
        expect(result.isAllowed, isTrue);
      });

      test('-a/--all option is allowed', () {
        final result = JournalctlCommandParser.validate('-a');
        expect(result.isAllowed, isTrue);
      });

      test('-q/--quiet option is allowed', () {
        final result = JournalctlCommandParser.validate('-q');
        expect(result.isAllowed, isTrue);
      });

      test('-m/--merge option is allowed', () {
        final result = JournalctlCommandParser.validate('-m');
        expect(result.isAllowed, isTrue);
      });

      test('-x/--catalog option is allowed', () {
        final result = JournalctlCommandParser.validate('-x');
        expect(result.isAllowed, isTrue);
      });

      test('--header option is allowed', () {
        final result = JournalctlCommandParser.validate('--header');
        expect(result.isAllowed, isTrue);
      });

      test('--system option is allowed', () {
        final result = JournalctlCommandParser.validate('--system');
        expect(result.isAllowed, isTrue);
      });

      test('--user option is allowed', () {
        final result = JournalctlCommandParser.validate('--user');
        expect(result.isAllowed, isTrue);
      });

      test('-D/--directory option is allowed', () {
        final result = JournalctlCommandParser.validate('-D /var/log/journal');
        expect(result.isAllowed, isTrue);
      });

      test('--cursor option is allowed', () {
        final result = JournalctlCommandParser.validate('--cursor="s=abc123"');
        expect(result.isAllowed, isTrue);
      });

      test('--show-cursor option is allowed', () {
        final result = JournalctlCommandParser.validate('--show-cursor');
        expect(result.isAllowed, isTrue);
      });

      test('--utc option is allowed', () {
        final result = JournalctlCommandParser.validate('--utc');
        expect(result.isAllowed, isTrue);
      });
    });

    group('denied destructive options', () {
      test('--flush is denied', () {
        final result = JournalctlCommandParser.validate('--flush');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('not allowed'));
        expect(result.reason, contains('modifies journal state'));
      });

      test('--rotate is denied', () {
        final result = JournalctlCommandParser.validate('--rotate');
        expect(result.isAllowed, isFalse);
      });

      test('--vacuum-size is denied', () {
        final result = JournalctlCommandParser.validate('--vacuum-size=100M');
        expect(result.isAllowed, isFalse);
      });

      test('--vacuum-time is denied', () {
        final result = JournalctlCommandParser.validate('--vacuum-time=7d');
        expect(result.isAllowed, isFalse);
      });

      test('--vacuum-files is denied', () {
        final result = JournalctlCommandParser.validate('--vacuum-files=10');
        expect(result.isAllowed, isFalse);
      });

      test('--sync is denied', () {
        final result = JournalctlCommandParser.validate('--sync');
        expect(result.isAllowed, isFalse);
      });

      test('--relinquish-var is denied', () {
        final result = JournalctlCommandParser.validate('--relinquish-var');
        expect(result.isAllowed, isFalse);
      });

      test('--smart-relinquish-var is denied', () {
        final result = JournalctlCommandParser.validate('--smart-relinquish-var');
        expect(result.isAllowed, isFalse);
      });

      test('--setup-keys is denied', () {
        final result = JournalctlCommandParser.validate('--setup-keys');
        expect(result.isAllowed, isFalse);
      });

      test('--force is denied', () {
        final result = JournalctlCommandParser.validate('--force');
        expect(result.isAllowed, isFalse);
      });

      test('--interval is denied', () {
        final result = JournalctlCommandParser.validate('--interval=1h');
        expect(result.isAllowed, isFalse);
      });

      test('denied option with other allowed options is denied', () {
        final result = JournalctlCommandParser.validate('-u nginx --flush');
        expect(result.isAllowed, isFalse);
      });
    });

    group('command chaining prevention', () {
      test('semicolon chaining is denied', () {
        final result = JournalctlCommandParser.validate('-u nginx; rm -rf /');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('&& chaining is denied', () {
        final result = JournalctlCommandParser.validate('-u nginx && cat /etc/passwd');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('|| chaining is denied', () {
        final result = JournalctlCommandParser.validate('-u nginx || echo pwned');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('pipe chaining is denied', () {
        final result = JournalctlCommandParser.validate('-u nginx | grep error');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });
    });

    group('shell expansion prevention', () {
      test('variable expansion is denied', () {
        final result = JournalctlCommandParser.validate('-u \$SERVICE');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });

      test('backtick expansion is denied', () {
        final result = JournalctlCommandParser.validate('-u `cat /etc/unit`');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });

      test('subshell expansion is denied', () {
        final result = JournalctlCommandParser.validate('-u \$(cat /etc/unit)');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });
    });

    group('field matches', () {
      test('_SYSTEMD_UNIT match is allowed', () {
        final result = JournalctlCommandParser.validate('_SYSTEMD_UNIT=nginx.service');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.matches, ['_SYSTEMD_UNIT=nginx.service']);
      });

      test('SYSLOG_IDENTIFIER match is allowed', () {
        final result = JournalctlCommandParser.validate('SYSLOG_IDENTIFIER=sudo');
        expect(result.isAllowed, isTrue);
      });

      test('_PID match is allowed', () {
        final result = JournalctlCommandParser.validate('_PID=1234');
        expect(result.isAllowed, isTrue);
      });

      test('multiple matches are allowed', () {
        final result = JournalctlCommandParser.validate('_SYSTEMD_UNIT=nginx.service _PID=1234');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.matches.length, 2);
      });

      test('path traversal in match is denied', () {
        final result = JournalctlCommandParser.validate('_SYSTEMD_UNIT=../../../etc/passwd');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('traversal'));
      });
    });

    group('combined options and matches', () {
      test('options with matches are allowed', () {
        final result = JournalctlCommandParser.validate('-u nginx -n 100 _PID=1234');
        expect(result.isAllowed, isTrue);
      });

      test('complex query is allowed', () {
        final result = JournalctlCommandParser.validate(
          '--since="1 hour ago" --until="now" -u nginx.service -p err..warning --no-pager -o json'
        );
        expect(result.isAllowed, isTrue);
      });
    });

    group('quoted strings handling', () {
      test('double quoted time ranges work', () {
        final result = JournalctlCommandParser.validate('--since="2024-01-01 00:00:00"');
        expect(result.isAllowed, isTrue);
      });

      test('single quoted grep patterns work', () {
        final result = JournalctlCommandParser.validate("-g 'error|warning'");
        expect(result.isAllowed, isTrue);
      });

      test('separators inside quotes are preserved', () {
        final result = JournalctlCommandParser.validate('--since="today; drop table"');
        expect(result.isAllowed, isTrue);
        // The semicolon is inside quotes, so it's not a separator
      });
    });

    group('real-world usage patterns', () {
      test('view nginx logs', () {
        final result = JournalctlCommandParser.validate('-u nginx.service -n 50 --no-pager');
        expect(result.isAllowed, isTrue);
      });

      test('follow logs in real-time', () {
        final result = JournalctlCommandParser.validate('-u myapp.service -f');
        expect(result.isAllowed, isTrue);
      });

      test('view kernel messages', () {
        final result = JournalctlCommandParser.validate('-k -b 0');
        expect(result.isAllowed, isTrue);
      });

      test('view errors from last hour', () {
        final result = JournalctlCommandParser.validate('--since="1 hour ago" -p err');
        expect(result.isAllowed, isTrue);
      });

      test('JSON output for parsing', () {
        final result = JournalctlCommandParser.validate('-u docker.service -o json --no-pager');
        expect(result.isAllowed, isTrue);
      });

      test('list available boots', () {
        final result = JournalctlCommandParser.validate('--list-boots');
        expect(result.isAllowed, isTrue);
      });

      test('check disk usage', () {
        final result = JournalctlCommandParser.validate('--disk-usage');
        expect(result.isAllowed, isTrue);
      });

      test('view logs from previous boot', () {
        final result = JournalctlCommandParser.validate('-b -1 -p err..crit');
        expect(result.isAllowed, isTrue);
      });

      test('grep for specific pattern', () {
        final result = JournalctlCommandParser.validate('-g "connection refused" -u sshd --no-pager');
        expect(result.isAllowed, isTrue);
      });

      test('view logs for specific PID', () {
        final result = JournalctlCommandParser.validate('_PID=1 -n 20');
        expect(result.isAllowed, isTrue);
      });
    });

    group('edge cases', () {
      test('whitespace only is allowed', () {
        final result = JournalctlCommandParser.validate('   ');
        expect(result.isAllowed, isTrue);
      });

      test('multiple spaces between options', () {
        final result = JournalctlCommandParser.validate('-u   nginx    -n   100');
        expect(result.isAllowed, isTrue);
      });

      test('leading/trailing whitespace is handled', () {
        final result = JournalctlCommandParser.validate('  -u nginx  ');
        expect(result.isAllowed, isTrue);
      });

      test('unknown options are allowed (lenient mode)', () {
        // journalctl has many options, we're lenient on unknown ones
        // as long as they're not in the denied list
        final result = JournalctlCommandParser.validate('--some-future-option');
        expect(result.isAllowed, isTrue);
      });
    });

    group('isAllowed convenience method', () {
      test('returns true for allowed commands', () {
        expect(JournalctlCommandParser.isAllowed('-u nginx'), isTrue);
      });

      test('returns false for denied commands', () {
        expect(JournalctlCommandParser.isAllowed('--flush'), isFalse);
      });
    });

    group('buildCommand method', () {
      test('builds valid command', () {
        final cmd = JournalctlCommandParser.buildCommand(
          options: ['-u', 'nginx', '-n', '100'],
          matches: ['_PID=1234'],
        );
        expect(cmd, '-u nginx -n 100 _PID=1234');
      });

      test('returns null for denied options', () {
        final cmd = JournalctlCommandParser.buildCommand(
          options: ['--flush'],
        );
        expect(cmd, isNull);
      });

      test('returns null for path traversal in matches', () {
        final cmd = JournalctlCommandParser.buildCommand(
          matches: ['_UNIT=../../etc/passwd'],
        );
        expect(cmd, isNull);
      });

      test('handles empty options and matches', () {
        final cmd = JournalctlCommandParser.buildCommand();
        expect(cmd, '');
      });
    });

    group('ParsedJournalctlCommand class', () {
      test('toString returns readable format', () {
        final result = JournalctlCommandParser.validate('-u nginx _PID=123');
        expect(result.parsedCommand.toString(), contains('nginx'));
        expect(result.parsedCommand.toString(), contains('_PID=123'));
      });

      test('options and matches are separated correctly', () {
        final result = JournalctlCommandParser.validate('-u nginx -n 50 _SYSTEMD_UNIT=test');
        expect(result.parsedCommand?.options, containsAll(['-u', 'nginx', '-n', '50']));
        expect(result.parsedCommand?.matches, ['_SYSTEMD_UNIT=test']);
      });
    });
  });
}
