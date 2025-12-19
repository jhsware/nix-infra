import 'dart:io';
import 'package:args/args.dart';
import 'package:dotenv/dotenv.dart';
import 'package:nix_infra/helpers.dart';
import 'package:path/path.dart' as path;

String readInput(String label, bool batch) {
  // TODO: Consider using (interact)[https://github.com/frencojobs/interact] for input
  String? inp;
  if (!batch) {
    stdout.write('Enter $label: ');
    // TODO: Hide input
    inp = stdin.readLineSync();
  }

  if (inp == null || inp == '') {
    echo('ERROR! You may not leave $label null or empty');
    exit(2);
  }

  return inp;
}

enum ReadPasswordEnum { caRoot, caIntermediate, secrets }

final caPasswordLabel = {
  ReadPasswordEnum.caRoot: 'CA root',
  ReadPasswordEnum.caIntermediate: 'CA Intermediate',
  ReadPasswordEnum.secrets: 'secrets',
};

String readPassword(ReadPasswordEnum type, bool batch) {
  // TODO: Consider using (interact)[https://github.com/frencojobs/interact] for input
  String? pwd;
  if (!batch) {
    stdout.write('Enter ${caPasswordLabel[type]} password: ');
    // TODO: Hide input
    pwd = stdin.readLineSync();
  }

  if (pwd == null || pwd == '') {
    echo('ERROR! ${caPasswordLabel[type]} password cannot be null or empty');
    exit(2);
  }

  return pwd;
}

void areYouSure(String txt, bool batch) {
  // TODO: Consider using (interact)[https://github.com/frencojobs/interact] for input
  if (batch) return;

  stdout.write('$txt [y/n] ');
  final inp = stdin.readLineSync();
  if (inp != 'y') {
    echo('Aborted');
    exit(1);
  }
}

String prefixWithNodeName(String nodeName, String inp) {
  final tmp = inp.split('\n');
  final outp = tmp.map((str) => '$nodeName: $str');
  return outp.join('\n');
}
