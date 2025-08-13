import 'dart:io';
import 'package:dotenv/dotenv.dart';
import 'package:nix_infra/helpers.dart';
import 'package:path/path.dart' as path;

Future<DotEnv> loadEnv(String? envFileName, Directory workingDir) async {
  // Load environment variables
  final env = DotEnv(includePlatformEnvironment: true);
  final envFile = File(envFileName ?? '${workingDir.path}/.env');
  if (await envFile.exists()) {
    env.load([envFile.path]);
  }
  return env;
}

Future<Directory> getWorkingDirectory(String dirName) async {
  final workingDir = Directory(path.normalize(path.absolute(dirName)));
  if (!await workingDir.exists()) {
    echo('ERROR! Working directory does not exist: ${workingDir.path}');
    exit(2);
  }
  return workingDir;
}
