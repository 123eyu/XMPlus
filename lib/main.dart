// Adapted from PiliPlus lib/main.dart, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
// Desktop setup only; audio and account services are not initialized here.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:window_manager/window_manager.dart';

import 'pages/startup_page.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final entry in const {
      'XMPlus': 'LICENSE',
      'XMPlus — 版权与来源': 'NOTICE',
      'PiliPlus': 'windows/LICENSE.PiliPlus',
      'Android 原生音频组件': 'licenses/android/THIRD-PARTY-NOTICES.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        entry.key,
      ], await rootBundle.loadString(entry.value));
    }
  });
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux)) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(800, 600));
  }
  runApp(StartupPage(arguments: arguments));
}
