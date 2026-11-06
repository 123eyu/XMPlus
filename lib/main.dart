// Adapted from PiliPlus lib/main.dart, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
// Desktop setup only; audio and account services are not initialized here.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'pages/startup_page.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux)) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(800, 600));
  }
  runApp(StartupPage(arguments: arguments));
}
