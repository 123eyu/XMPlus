import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xmly_flutter/pages/startup_page.dart';
import 'package:xmly_flutter/services/app_log.dart';
import 'package:xmly_flutter/services/startup_directory.dart';

void main() {
  test('keeps the default profile when no data directory was requested', () {
    expect(startupDataDirectory(const []), isNull);
    expect(startupDataDirectory(const ['--other-option']), isNull);
  });

  test('uses the same absolute profile path for startup and logging', () {
    final directory = p.absolute('资料目录 with spaces');
    expect(
      startupDataDirectory(['--other-option', '--data-dir', directory]),
      directory,
    );
  });

  test('rejects missing and relative data directories', () {
    for (final arguments in const [
      ['--data-dir'],
      ['--data-dir', ''],
      ['--data-dir', 'relative-profile'],
      ['--data-dir', '--other-option'],
    ]) {
      expect(
        () => startupDataDirectory(arguments),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '资料目录必须是绝对路径',
          ),
        ),
      );
    }
  });

  testWidgets('invalid directory arguments retain the recovery screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      const StartupPage(arguments: ['--data-dir', 'relative-profile']),
    );
    await tester.runAsync(AppLog.instance.flush);
    await tester.pumpAndSettle();

    expect(find.textContaining('资料目录必须是绝对路径'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('选择其他资料目录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
