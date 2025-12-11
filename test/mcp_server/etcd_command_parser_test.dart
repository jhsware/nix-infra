import 'package:test/test.dart';
import '../../bin/mcp_server/utils/etcd_command_parser.dart';

void main() {
  group('EtcdCommandParser', () {
    group('allowed read-only commands', () {
      test('get command is allowed', () {
        final result = EtcdCommandParser.validate('get /mykey');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'get');
        expect(result.parsedCommand?.arguments, ['/mykey']);
      });

      test('get with --prefix is allowed', () {
        final result = EtcdCommandParser.validate('get /cluster/nodes --prefix');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'get');
      });

      test('get with --keys-only is allowed', () {
        final result = EtcdCommandParser.validate('get /cluster --prefix --keys-only');
        expect(result.isAllowed, isTrue);
      });

      test('get with --limit is allowed', () {
        final result = EtcdCommandParser.validate('get /logs --prefix --limit=100');
        expect(result.isAllowed, isTrue);
      });

      test('watch command is allowed', () {
        final result = EtcdCommandParser.validate('watch /mykey');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'watch');
      });

      test('member list is allowed', () {
        final result = EtcdCommandParser.validate('member list');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.command, 'member');
        expect(result.parsedCommand?.subcommand, 'list');
      });

      test('endpoint health is allowed', () {
        final result = EtcdCommandParser.validate('endpoint health');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.fullCommand, 'endpoint health');
      });

      test('endpoint status is allowed', () {
        final result = EtcdCommandParser.validate('endpoint status');
        expect(result.isAllowed, isTrue);
      });

      test('endpoint hashkv is allowed', () {
        final result = EtcdCommandParser.validate('endpoint hashkv');
        expect(result.isAllowed, isTrue);
      });

      test('alarm list is allowed', () {
        final result = EtcdCommandParser.validate('alarm list');
        expect(result.isAllowed, isTrue);
      });

      test('user get is allowed', () {
        final result = EtcdCommandParser.validate('user get myuser');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.arguments, ['myuser']);
      });

      test('user list is allowed', () {
        final result = EtcdCommandParser.validate('user list');
        expect(result.isAllowed, isTrue);
      });

      test('role get is allowed', () {
        final result = EtcdCommandParser.validate('role get myrole');
        expect(result.isAllowed, isTrue);
      });

      test('role list is allowed', () {
        final result = EtcdCommandParser.validate('role list');
        expect(result.isAllowed, isTrue);
      });

      test('check perf is allowed', () {
        final result = EtcdCommandParser.validate('check perf');
        expect(result.isAllowed, isTrue);
      });

      test('check datascale is allowed', () {
        final result = EtcdCommandParser.validate('check datascale');
        expect(result.isAllowed, isTrue);
      });

      test('version is allowed', () {
        final result = EtcdCommandParser.validate('version');
        expect(result.isAllowed, isTrue);
      });
    });

    group('denied write/destructive commands', () {
      test('put is denied', () {
        final result = EtcdCommandParser.validate('put /mykey myvalue');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('not allowed'));
      });

      test('del is denied', () {
        final result = EtcdCommandParser.validate('del /mykey');
        expect(result.isAllowed, isFalse);
      });

      test('txn is denied', () {
        final result = EtcdCommandParser.validate('txn');
        expect(result.isAllowed, isFalse);
      });

      test('compaction is denied', () {
        final result = EtcdCommandParser.validate('compaction 1234');
        expect(result.isAllowed, isFalse);
      });

      test('lease grant is denied', () {
        final result = EtcdCommandParser.validate('lease grant 60');
        expect(result.isAllowed, isFalse);
      });

      test('lease revoke is denied', () {
        final result = EtcdCommandParser.validate('lease revoke abc123');
        expect(result.isAllowed, isFalse);
      });

      test('member add is denied', () {
        final result = EtcdCommandParser.validate('member add newnode --peer-urls=http://node:2380');
        expect(result.isAllowed, isFalse);
      });

      test('member remove is denied', () {
        final result = EtcdCommandParser.validate('member remove abc123');
        expect(result.isAllowed, isFalse);
      });

      test('member update is denied', () {
        final result = EtcdCommandParser.validate('member update abc123');
        expect(result.isAllowed, isFalse);
      });

      test('snapshot save is denied', () {
        final result = EtcdCommandParser.validate('snapshot save backup.db');
        expect(result.isAllowed, isFalse);
      });

      test('snapshot restore is denied', () {
        final result = EtcdCommandParser.validate('snapshot restore backup.db');
        expect(result.isAllowed, isFalse);
      });

      test('alarm disarm is denied', () {
        final result = EtcdCommandParser.validate('alarm disarm');
        expect(result.isAllowed, isFalse);
      });

      test('defrag is denied', () {
        final result = EtcdCommandParser.validate('defrag');
        expect(result.isAllowed, isFalse);
      });

      test('auth enable is denied', () {
        final result = EtcdCommandParser.validate('auth enable');
        expect(result.isAllowed, isFalse);
      });

      test('auth disable is denied', () {
        final result = EtcdCommandParser.validate('auth disable');
        expect(result.isAllowed, isFalse);
      });

      test('user add is denied', () {
        final result = EtcdCommandParser.validate('user add newuser');
        expect(result.isAllowed, isFalse);
      });

      test('user delete is denied', () {
        final result = EtcdCommandParser.validate('user delete olduser');
        expect(result.isAllowed, isFalse);
      });

      test('user passwd is denied', () {
        final result = EtcdCommandParser.validate('user passwd myuser');
        expect(result.isAllowed, isFalse);
      });

      test('user grant-role is denied', () {
        final result = EtcdCommandParser.validate('user grant-role myuser myrole');
        expect(result.isAllowed, isFalse);
      });

      test('user revoke-role is denied', () {
        final result = EtcdCommandParser.validate('user revoke-role myuser myrole');
        expect(result.isAllowed, isFalse);
      });

      test('role add is denied', () {
        final result = EtcdCommandParser.validate('role add newrole');
        expect(result.isAllowed, isFalse);
      });

      test('role delete is denied', () {
        final result = EtcdCommandParser.validate('role delete oldrole');
        expect(result.isAllowed, isFalse);
      });

      test('role grant-permission is denied', () {
        final result = EtcdCommandParser.validate('role grant-permission myrole read /prefix');
        expect(result.isAllowed, isFalse);
      });

      test('role revoke-permission is denied', () {
        final result = EtcdCommandParser.validate('role revoke-permission myrole /prefix');
        expect(result.isAllowed, isFalse);
      });

      test('move-leader is denied', () {
        final result = EtcdCommandParser.validate('move-leader abc123');
        expect(result.isAllowed, isFalse);
      });

      test('elect is denied', () {
        final result = EtcdCommandParser.validate('elect myelection myproposal');
        expect(result.isAllowed, isFalse);
      });

      test('lock is denied', () {
        final result = EtcdCommandParser.validate('lock mylock');
        expect(result.isAllowed, isFalse);
      });

      test('make-mirror is denied', () {
        final result = EtcdCommandParser.validate('make-mirror destination');
        expect(result.isAllowed, isFalse);
      });
    });

    group('command chaining prevention', () {
      test('semicolon chaining is denied', () {
        final result = EtcdCommandParser.validate('get /key; put /key value');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('&& chaining is denied', () {
        final result = EtcdCommandParser.validate('get /key && del /key');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('|| chaining is denied', () {
        final result = EtcdCommandParser.validate('get /key || put /key default');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });

      test('pipe chaining is denied', () {
        final result = EtcdCommandParser.validate('get /key | grep value');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('chaining'));
      });
    });

    group('shell expansion prevention', () {
      test('variable expansion is denied', () {
        final result = EtcdCommandParser.validate('get \$KEY');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });

      test('backtick expansion is denied', () {
        final result = EtcdCommandParser.validate('get `cat /etc/key`');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });

      test('subshell expansion is denied', () {
        final result = EtcdCommandParser.validate('get \$(cat /etc/key)');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('expansion'));
      });
    });

    group('key validation', () {
      test('simple key is allowed', () {
        final result = EtcdCommandParser.validate('get /mykey');
        expect(result.isAllowed, isTrue);
      });

      test('nested key path is allowed', () {
        final result = EtcdCommandParser.validate('get /cluster/nodes/node001');
        expect(result.isAllowed, isTrue);
      });

      test('path traversal is denied', () {
        final result = EtcdCommandParser.validate('get /cluster/../secrets');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('traversal'));
      });
    });

    group('options handling', () {
      test('--write-out option is allowed', () {
        final result = EtcdCommandParser.validate('get /key -w json');
        expect(result.isAllowed, isTrue);
      });

      test('--endpoints option is allowed', () {
        final result = EtcdCommandParser.validate('get /key --endpoints=localhost:2379');
        expect(result.isAllowed, isTrue);
      });

      test('--hex option is allowed', () {
        final result = EtcdCommandParser.validate('get /key --hex');
        expect(result.isAllowed, isTrue);
      });

      test('--print-value-only is allowed', () {
        final result = EtcdCommandParser.validate('get /key --print-value-only');
        expect(result.isAllowed, isTrue);
      });

      test('TLS options are allowed', () {
        final result = EtcdCommandParser.validate('get /key --cacert=/path/ca.pem --cert=/path/cert.pem --key=/path/key.pem');
        expect(result.isAllowed, isTrue);
      });
    });

    group('quoted strings handling', () {
      test('double quoted key is allowed', () {
        final result = EtcdCommandParser.validate('get "/my key"');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.arguments, ['/my key']);
      });

      test('single quoted key is allowed', () {
        final result = EtcdCommandParser.validate("get '/my key'");
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.arguments, ['/my key']);
      });

      test('separators inside quotes are preserved', () {
        final result = EtcdCommandParser.validate('get "/key;with;semicolons"');
        expect(result.isAllowed, isTrue);
        expect(result.parsedCommand?.arguments, ['/key;with;semicolons']);
      });
    });

    group('real-world usage patterns', () {
      test('get cluster nodes', () {
        final result = EtcdCommandParser.validate('get /cluster/nodes --prefix');
        expect(result.isAllowed, isTrue);
      });

      test('get cluster services', () {
        final result = EtcdCommandParser.validate('get /cluster/services --prefix');
        expect(result.isAllowed, isTrue);
      });

      test('get with JSON output', () {
        final result = EtcdCommandParser.validate('get /config --prefix -w json');
        expect(result.isAllowed, isTrue);
      });

      test('get with limit and sort', () {
        final result = EtcdCommandParser.validate('get /logs --prefix --limit=50 --sort-by=CREATE');
        expect(result.isAllowed, isTrue);
      });

      test('endpoint health check', () {
        final result = EtcdCommandParser.validate('endpoint health --endpoints=etcd001:2379,etcd002:2379');
        expect(result.isAllowed, isTrue);
      });

      test('member list with table output', () {
        final result = EtcdCommandParser.validate('member list -w table');
        expect(result.isAllowed, isTrue);
      });
    });

    group('subcommand requirements', () {
      test('member without subcommand is denied', () {
        final result = EtcdCommandParser.validate('member');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('requires a subcommand'));
      });

      test('endpoint without subcommand is denied', () {
        final result = EtcdCommandParser.validate('endpoint');
        expect(result.isAllowed, isFalse);
      });

      test('user without subcommand is denied', () {
        final result = EtcdCommandParser.validate('user');
        expect(result.isAllowed, isFalse);
      });

      test('role without subcommand is denied', () {
        final result = EtcdCommandParser.validate('role');
        expect(result.isAllowed, isFalse);
      });
    });

    group('edge cases', () {
      test('empty input is denied', () {
        final result = EtcdCommandParser.validate('');
        expect(result.isAllowed, isFalse);
      });

      test('whitespace only is denied', () {
        final result = EtcdCommandParser.validate('   ');
        expect(result.isAllowed, isFalse);
      });

      test('unknown command is denied', () {
        final result = EtcdCommandParser.validate('unknowncommand /key');
        expect(result.isAllowed, isFalse);
        expect(result.reason, contains('not in the allowed list'));
      });

      test('case insensitive commands', () {
        final result1 = EtcdCommandParser.validate('GET /key');
        final result2 = EtcdCommandParser.validate('Get /key');
        expect(result1.isAllowed, isTrue);
        expect(result2.isAllowed, isTrue);
      });

      test('leading/trailing whitespace is handled', () {
        final result = EtcdCommandParser.validate('  get /key  ');
        expect(result.isAllowed, isTrue);
      });
    });

    group('isAllowed convenience method', () {
      test('returns true for allowed commands', () {
        expect(EtcdCommandParser.isAllowed('get /key'), isTrue);
      });

      test('returns false for denied commands', () {
        expect(EtcdCommandParser.isAllowed('put /key value'), isFalse);
      });
    });

    group('buildCommand method', () {
      test('builds valid get command', () {
        final cmd = EtcdCommandParser.buildCommand(
          command: 'get',
          keys: ['/cluster/nodes'],
          options: ['--prefix'],
        );
        expect(cmd, 'get /cluster/nodes --prefix');
      });

      test('builds valid member list command', () {
        final cmd = EtcdCommandParser.buildCommand(
          command: 'member',
          subcommand: 'list',
        );
        expect(cmd, 'member list');
      });

      test('returns null for invalid commands', () {
        final cmd = EtcdCommandParser.buildCommand(
          command: 'put',
          keys: ['/key'],
        );
        expect(cmd, isNull);
      });

      test('returns null for keys with path traversal', () {
        final cmd = EtcdCommandParser.buildCommand(
          command: 'get',
          keys: ['/cluster/../secrets'],
        );
        expect(cmd, isNull);
      });
    });

    group('ParsedEtcdCommand class', () {
      test('fullCommand returns command for simple commands', () {
        final result = EtcdCommandParser.validate('get /key');
        expect(result.parsedCommand?.fullCommand, 'get');
      });

      test('fullCommand returns combined for subcommands', () {
        final result = EtcdCommandParser.validate('member list');
        expect(result.parsedCommand?.fullCommand, 'member list');
      });

      test('toString returns readable format', () {
        final result = EtcdCommandParser.validate('get /key --prefix');
        expect(result.parsedCommand.toString(), contains('get'));
        expect(result.parsedCommand.toString(), contains('/key'));
      });
    });
  });
}
