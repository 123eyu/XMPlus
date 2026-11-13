import 'package:path/path.dart' as p;

import 'app_log.dart';

String? startupDataDirectory(List<String> arguments) {
  AppLog.instance.trace(
    "lib/services/startup_directory.dart::startupDataDirectory",
  );

  final index = arguments.indexOf('--data-dir');
  if (index < 0) return null;
  if (index + 1 >= arguments.length || !p.isAbsolute(arguments[index + 1])) {
    throw const FormatException('资料目录必须是绝对路径');
  }
  return arguments[index + 1];
}
