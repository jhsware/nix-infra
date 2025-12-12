import 'package:test/test.dart';
import '../../bin/mcp_server/utils/bash_command_parser.dart';

void main() {
  group('BashCommandParser', () {
    group('simple commands', () {
      test('parses single command without arguments', () {
        final result = BashCommandParser.parseCommands('ls');
        expect(result.length, 1);
        expect(result[0].binary, 'ls');
        expect(result[0].arguments, isEmpty);
      });

      test('parses command with single argument', () {
        final result = BashCommandParser.parseCommands('ls -la');
        expect(result.length, 1);
        expect(result[0].binary, 'ls');
        expect(result[0].arguments, ['-la']);
      });

      test('parses command with multiple arguments', () {
        final result = BashCommandParser.parseCommands('cp -r source dest');
        expect(result.length, 1);
        expect(result[0].binary, 'cp');
        expect(result[0].arguments, ['-r', 'source', 'dest']);
      });

      test('parses command with path arguments', () {
        final result = BashCommandParser.parseCommands('cat /etc/passwd');
        expect(result.length, 1);
        expect(result[0].binary, 'cat');
        expect(result[0].arguments, ['/etc/passwd']);
      });

      test('handles multiple spaces between arguments', () {
        final result = BashCommandParser.parseCommands('ls    -la     /tmp');
        expect(result.length, 1);
        expect(result[0].binary, 'ls');
        expect(result[0].arguments, ['-la', '/tmp']);
      });

      test('handles leading and trailing whitespace', () {
        final result = BashCommandParser.parseCommands('   ls -la   ');
        expect(result.length, 1);
        expect(result[0].binary, 'ls');
        expect(result[0].arguments, ['-la']);
      });

      test('handles tabs as whitespace', () {
        final result = BashCommandParser.parseCommands('ls\t-la\t/tmp');
        expect(result.length, 1);
        expect(result[0].binary, 'ls');
        expect(result[0].arguments, ['-la', '/tmp']);
      });
    });

    group('double quoted strings', () {
      test('parses argument with double quotes', () {
        final result = BashCommandParser.parseCommands('echo "hello world"');
        expect(result.length, 1);
        expect(result[0].binary, 'echo');
        expect(result[0].arguments, ['hello world']);
      });

      test('parses multiple double quoted arguments', () {
        final result = BashCommandParser.parseCommands('echo "hello" "world"');
        expect(result.length, 1);
        expect(result[0].binary, 'echo');
        expect(result[0].arguments, ['hello', 'world']);
      });

      test('parses mixed quoted and unquoted arguments', () {
        final result = BashCommandParser.parseCommands('grep "hello world" file.txt');
        expect(result.length, 1);
        expect(result[0].binary, 'grep');
        expect(result[0].arguments, ['hello world', 'file.txt']);
      });

      test('handles empty double quoted string', () {
        final result = BashCommandParser.parseCommands('echo ""');
        expect(result.length, 1);
        expect(result[0].binary, 'echo');
        // Empty string becomes empty token which may not be added
      });

      test('preserves spaces inside double quotes', () {
        final result = BashCommandParser.parseCommands('echo "   spaces   "');
        expect(result.length, 1);
        expect(result[0].arguments, ['   spaces   ']);
      });

      test('handles double quotes with special characters', () {
        final result = BashCommandParser.parseCommands('echo "hello; world"');
        expect(result.length, 1);
        expect(result[0].arguments, ['hello; world']);
      });
    });

    group('single quoted strings', () {
      test('parses argument with single quotes', () {
        final result = BashCommandParser.parseCommands("echo 'hello world'");
        expect(result.length, 1);
        expect(result[0].binary, 'echo');
        expect(result[0].arguments, ['hello world']);
      });

      test('parses multiple single quoted arguments', () {
        final result = BashCommandParser.parseCommands("echo 'hello' 'world'");
        expect(result.length, 1);
        expect(result[0].binary, 'echo');
        expect(result[0].arguments, ['hello', 'world']);
      });

      test('preserves double quotes inside single quotes', () {
        final result = BashCommandParser.parseCommands("echo 'say \"hello\"'");
        expect(result.length, 1);
        expect(result[0].arguments, ['say "hello"']);
      });

      test('preserves backslash inside single quotes', () {
        final result = BashCommandParser.parseCommands(r"echo 'path\to\file'");
        expect(result.length, 1);
        expect(result[0].arguments, [r'path\to\file']);
      });

      test('handles single quotes with pipe character', () {
        final result = BashCommandParser.parseCommands("echo 'hello | world'");
        expect(result.length, 1);
        expect(result[0].arguments, ['hello | world']);
      });
    });

    group('mixed quotes', () {
      test('handles single quotes inside double quotes', () {
        final result = BashCommandParser.parseCommands("echo \"it's working\"");
        expect(result.length, 1);
        expect(result[0].arguments, ["it's working"]);
      });

      test('handles alternating quote styles', () {
        final result = BashCommandParser.parseCommands("echo 'single' \"double\" 'single'");
        expect(result.length, 1);
        expect(result[0].arguments, ['single', 'double', 'single']);
      });

      test('handles adjacent different quotes', () {
        final result = BashCommandParser.parseCommands("echo 'hello'\"world\"");
        expect(result.length, 1);
        expect(result[0].arguments, ['helloworld']);
      });
    });

    group('escaped characters', () {
      test('handles escaped double quotes', () {
        final result = BashCommandParser.parseCommands(r'echo "escaped \"quotes\""');
        expect(result.length, 1);
        expect(result[0].arguments, ['escaped "quotes"']);
      });

      test('handles escaped backslash', () {
        final result = BashCommandParser.parseCommands(r'echo "path\\to\\file"');
        expect(result.length, 1);
        expect(result[0].arguments, [r'path\to\file']);
      });

      test('handles escaped space outside quotes', () {
        final result = BashCommandParser.parseCommands(r'echo hello\ world');
        expect(result.length, 1);
        expect(result[0].arguments, ['hello world']);
      });

      test('backslash does not escape in single quotes', () {
        final result = BashCommandParser.parseCommands(r"echo '\n'");
        expect(result.length, 1);
        expect(result[0].arguments, [r'\n']);
      });
    });

    group('pipe separator', () {
      test('splits commands by pipe', () {
        final result = BashCommandParser.parseCommands('ls -la | grep test');
        expect(result.length, 2);
        expect(result[0].binary, 'ls');
        expect(result[0].arguments, ['-la']);
        expect(result[1].binary, 'grep');
        expect(result[1].arguments, ['test']);
      });

      test('handles multiple pipes', () {
        final result = BashCommandParser.parseCommands('cat file | grep pattern | wc -l');
        expect(result.length, 3);
        expect(result[0].binary, 'cat');
        expect(result[1].binary, 'grep');
        expect(result[2].binary, 'wc');
      });

      test('pipe inside quotes is not a separator', () {
        final result = BashCommandParser.parseCommands('echo "hello | world"');
        expect(result.length, 1);
        expect(result[0].arguments, ['hello | world']);
      });
    });

    group('semicolon separator', () {
      test('splits commands by semicolon', () {
        final result = BashCommandParser.parseCommands('cd /tmp; ls -la');
        expect(result.length, 2);
        expect(result[0].binary, 'cd');
        expect(result[0].arguments, ['/tmp']);
        expect(result[1].binary, 'ls');
        expect(result[1].arguments, ['-la']);
      });

      test('handles multiple semicolons', () {
        final result = BashCommandParser.parseCommands('cmd1; cmd2; cmd3');
        expect(result.length, 3);
        expect(result[0].binary, 'cmd1');
        expect(result[1].binary, 'cmd2');
        expect(result[2].binary, 'cmd3');
      });

      test('semicolon inside quotes is not a separator', () {
        final result = BashCommandParser.parseCommands('echo "hello; world"');
        expect(result.length, 1);
        expect(result[0].arguments, ['hello; world']);
      });
    });

    group('&& operator', () {
      test('splits commands by &&', () {
        final result = BashCommandParser.parseCommands('cd /tmp && ls -la');
        expect(result.length, 2);
        expect(result[0].binary, 'cd');
        expect(result[0].arguments, ['/tmp']);
        expect(result[1].binary, 'ls');
        expect(result[1].arguments, ['-la']);
      });

      test('handles multiple && operators', () {
        final result = BashCommandParser.parseCommands('cmd1 && cmd2 && cmd3');
        expect(result.length, 3);
      });

      test('&& inside quotes is not a separator', () {
        final result = BashCommandParser.parseCommands('echo "a && b"');
        expect(result.length, 1);
        expect(result[0].arguments, ['a && b']);
      });

      test('single & is not treated as separator', () {
        final result = BashCommandParser.parseCommands('echo hello &');
        expect(result.length, 1);
        expect(result[0].binary, 'echo');
        // The & should be part of the command or as a separate token
      });
    });

    group('|| operator', () {
      test('splits commands by ||', () {
        final result = BashCommandParser.parseCommands('false || echo fallback');
        expect(result.length, 2);
        expect(result[0].binary, 'false');
        expect(result[1].binary, 'echo');
        expect(result[1].arguments, ['fallback']);
      });

      test('handles multiple || operators', () {
        final result = BashCommandParser.parseCommands('cmd1 || cmd2 || cmd3');
        expect(result.length, 3);
      });

      test('|| inside quotes is not a separator', () {
        final result = BashCommandParser.parseCommands('echo "a || b"');
        expect(result.length, 1);
        expect(result[0].arguments, ['a || b']);
      });
    });

    group('mixed separators', () {
      test('handles pipe and semicolon together', () {
        final result = BashCommandParser.parseCommands('cat file | grep test; echo done');
        expect(result.length, 3);
        expect(result[0].binary, 'cat');
        expect(result[1].binary, 'grep');
        expect(result[2].binary, 'echo');
      });

      test('handles && and || together', () {
        final result = BashCommandParser.parseCommands('cmd1 && cmd2 || cmd3');
        expect(result.length, 3);
      });

      test('handles all separator types', () {
        final result = BashCommandParser.parseCommands('a | b; c && d || e');
        expect(result.length, 5);
        expect(result[0].binary, 'a');
        expect(result[1].binary, 'b');
        expect(result[2].binary, 'c');
        expect(result[3].binary, 'd');
        expect(result[4].binary, 'e');
      });
    });

    group('complex real-world commands', () {
      test('git commit with message', () {
        final result = BashCommandParser.parseCommands('git commit -m "Initial commit"');
        expect(result.length, 1);
        expect(result[0].binary, 'git');
        expect(result[0].arguments, ['commit', '-m', 'Initial commit']);
      });

      test('find command with name pattern', () {
        final result = BashCommandParser.parseCommands('find /home -name "*.dart"');
        expect(result.length, 1);
        expect(result[0].binary, 'find');
        expect(result[0].arguments, ['/home', '-name', '*.dart']);
      });

      test('grep with regex pattern', () {
        final result = BashCommandParser.parseCommands(r'grep -E "^[0-9]+$" file.txt');
        expect(result.length, 1);
        expect(result[0].binary, 'grep');
        expect(result[0].arguments, ['-E', r'^[0-9]+$', 'file.txt']);
      });

      test('docker run with multiple options', () {
        final result = BashCommandParser.parseCommands(
          'docker run -d --name myapp -p 8080:80 -v /data:/app/data nginx:latest'
        );
        expect(result.length, 1);
        expect(result[0].binary, 'docker');
        expect(result[0].arguments, [
          'run', '-d', '--name', 'myapp', '-p', '8080:80',
          '-v', '/data:/app/data', 'nginx:latest'
        ]);
      });

      test('ssh command with remote command', () {
        final result = BashCommandParser.parseCommands(
          'ssh user@host "cd /app && git pull"'
        );
        expect(result.length, 1);
        expect(result[0].binary, 'ssh');
        expect(result[0].arguments, ['user@host', 'cd /app && git pull']);
      });

      test('curl with headers', () {
        final result = BashCommandParser.parseCommands(
          'curl -H "Content-Type: application/json" -d \'{"key":"value"}\' https://api.example.com'
        );
        expect(result.length, 1);
        expect(result[0].binary, 'curl');
        expect(result[0].arguments, [
          '-H', 'Content-Type: application/json',
          '-d', '{"key":"value"}',
          'https://api.example.com'
        ]);
      });

      test('awk command with script', () {
        final result = BashCommandParser.parseCommands(
          "awk '{print \$1}' file.txt"
        );
        expect(result.length, 1);
        expect(result[0].binary, 'awk');
        expect(result[0].arguments, ['{print \$1}', 'file.txt']);
      });

      test('sed with substitution', () {
        final result = BashCommandParser.parseCommands(
          "sed 's/old/new/g' file.txt"
        );
        expect(result.length, 1);
        expect(result[0].binary, 'sed');
        expect(result[0].arguments, ['s/old/new/g', 'file.txt']);
      });

      test('pipeline with xargs', () {
        final result = BashCommandParser.parseCommands(
          'find . -name "*.log" | xargs rm -f'
        );
        expect(result.length, 2);
        expect(result[0].binary, 'find');
        expect(result[0].arguments, ['.', '-name', '*.log']);
        expect(result[1].binary, 'xargs');
        expect(result[1].arguments, ['rm', '-f']);
      });

      test('chained git commands', () {
        final result = BashCommandParser.parseCommands(
          'git add . && git commit -m "Update" && git push'
        );
        expect(result.length, 3);
        expect(result[0].binary, 'git');
        expect(result[0].arguments, ['add', '.']);
        expect(result[1].binary, 'git');
        expect(result[1].arguments, ['commit', '-m', 'Update']);
        expect(result[2].binary, 'git');
        expect(result[2].arguments, ['push']);
      });
    });

    group('edge cases', () {
      test('empty string returns empty list', () {
        final result = BashCommandParser.parseCommands('');
        expect(result, isEmpty);
      });

      test('whitespace only returns empty list', () {
        final result = BashCommandParser.parseCommands('   \t\n   ');
        expect(result, isEmpty);
      });

      test('handles command with equals sign', () {
        final result = BashCommandParser.parseCommands('ENV_VAR=value ./script.sh');
        expect(result.length, 1);
        expect(result[0].binary, 'ENV_VAR=value');
        expect(result[0].arguments, ['./script.sh']);
      });

      test('handles command starting with ./', () {
        final result = BashCommandParser.parseCommands('./my-script.sh arg1 arg2');
        expect(result.length, 1);
        expect(result[0].binary, './my-script.sh');
        expect(result[0].arguments, ['arg1', 'arg2']);
      });

      test('handles absolute path as binary', () {
        final result = BashCommandParser.parseCommands('/usr/bin/python3 script.py');
        expect(result.length, 1);
        expect(result[0].binary, '/usr/bin/python3');
        expect(result[0].arguments, ['script.py']);
      });

      test('handles empty segments between separators', () {
        final result = BashCommandParser.parseCommands('ls; ; echo done');
        expect(result.length, 2);
        expect(result[0].binary, 'ls');
        expect(result[1].binary, 'echo');
      });

      test('handles trailing separator', () {
        final result = BashCommandParser.parseCommands('ls -la;');
        expect(result.length, 1);
        expect(result[0].binary, 'ls');
      });

      test('handles leading separator', () {
        final result = BashCommandParser.parseCommands('; ls -la');
        expect(result.length, 1);
        expect(result[0].binary, 'ls');
      });

      test('handles unclosed double quote', () {
        // This is malformed but should not crash
        final result = BashCommandParser.parseCommands('echo "unclosed');
        expect(result.length, 1);
        expect(result[0].binary, 'echo');
      });

      test('handles unclosed single quote', () {
        // This is malformed but should not crash
        final result = BashCommandParser.parseCommands("echo 'unclosed");
        expect(result.length, 1);
        expect(result[0].binary, 'echo');
      });

      test('handles arguments with colons', () {
        final result = BashCommandParser.parseCommands('docker run -p 8080:80 image');
        expect(result.length, 1);
        expect(result[0].binary, 'docker');
        expect(result[0].arguments, ['run', '-p', '8080:80', 'image']);
      });

      test('handles arguments with @ symbol', () {
        final result = BashCommandParser.parseCommands('ssh user@hostname');
        expect(result.length, 1);
        expect(result[0].arguments, ['user@hostname']);
      });

      test('handles Unicode characters', () {
        final result = BashCommandParser.parseCommands('echo "Héllo Wörld 你好"');
        expect(result.length, 1);
        expect(result[0].arguments, ['Héllo Wörld 你好']);
      });

      test('handles newlines in quoted strings', () {
        final result = BashCommandParser.parseCommands('echo "line1\nline2"');
        expect(result.length, 1);
        expect(result[0].arguments, ['line1\nline2']);
      });
    });

    group('ParsedCommand class', () {
      test('toString returns readable format', () {
        final result = BashCommandParser.parseCommands('ls -la /tmp');
        expect(result[0].toString(), contains('ls'));
        expect(result[0].toString(), contains('-la'));
        expect(result[0].toString(), contains('/tmp'));
      });

      test('binary property is accessible', () {
        final result = BashCommandParser.parseCommands('echo hello');
        expect(result[0].binary, 'echo');
      });

      test('arguments property is a list', () {
        final result = BashCommandParser.parseCommands('cp -r src dest');
        expect(result[0].arguments, isA<List<String>>());
        expect(result[0].arguments.length, 3);
      });
    });

    group('special characters in arguments', () {
      test('handles glob patterns in quotes', () {
        final result = BashCommandParser.parseCommands('find . -name "*.dart"');
        expect(result[0].arguments[2], '*.dart');
      });

      test('handles question mark glob', () {
        final result = BashCommandParser.parseCommands('ls file?.txt');
        expect(result[0].arguments, ['file?.txt']);
      });

      test('handles brackets in arguments', () {
        final result = BashCommandParser.parseCommands('echo [test]');
        expect(result[0].arguments, ['[test]']);
      });

      test('handles parentheses in quotes', () {
        final result = BashCommandParser.parseCommands('echo "(test)"');
        expect(result[0].arguments, ['(test)']);
      });

      test('handles hash symbol', () {
        final result = BashCommandParser.parseCommands('echo "#comment"');
        expect(result[0].arguments, ['#comment']);
      });

      test('handles dollar sign in single quotes', () {
        final result = BashCommandParser.parseCommands("echo '\$HOME'");
        expect(result[0].arguments, ['\$HOME']);
      });

      test('handles backticks in single quotes', () {
        final result = BashCommandParser.parseCommands("echo '\`date\`'");
        expect(result[0].arguments, ['`date`']);
      });

      test('handles exclamation mark', () {
        final result = BashCommandParser.parseCommands('echo "Hello!"');
        expect(result[0].arguments, ['Hello!']);
      });

      test('handles tilde', () {
        final result = BashCommandParser.parseCommands('ls ~/Documents');
        expect(result[0].arguments, ['~/Documents']);
      });
    });
  });
}
