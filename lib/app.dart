// Adapted from PiliPlus lib/main.dart::MyApp, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

import 'common/theme.dart';
import 'common/widgets/scroll_behavior.dart';
import 'pages/shell_page.dart';
import 'pages/download_page.dart';
import 'services/app_runtime.dart';

class MyApp extends StatefulWidget {
  const MyApp({required this.runtime, super.key});

  final AppRuntime runtime;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WindowListener {
  late final _appearance = AppAppearance(widget.runtime.storage);
  final _navigator = GlobalKey<NavigatorState>();
  bool _closeRequested = false;

  @override
  void initState() {
    super.initState();
    widget.runtime.confirmDownload = (batch) async {
      final context = _navigator.currentContext;
      return context == null ? false : confirmDownloadBatch(context, batch);
    };
    widget.runtime.requestExit = () async {
      if (Platform.isAndroid) {
        await onCloseRequested();
      } else {
        await windowManager.close();
      }
    };
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
  }

  @override
  void onWindowClose() async {
    await onCloseRequested();
  }

  Future<void> onCloseRequested() async {
    if (_closeRequested || !mounted) return;
    _closeRequested = true;
    try {
      final context = _navigator.currentContext;
      if (!widget.runtime.scheduledExit &&
          widget.runtime.downloads.tasks.any((task) => task.active)) {
        final confirmed = context == null
            ? false
            : await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('暂停下载并退出？'),
                  content: const Text('下次打开后可手动继续。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('暂停并退出'),
                    ),
                  ],
                ),
              );
        if (confirmed != true) return;
      }
      if (await widget.runtime.close()) {
        if (Platform.isAndroid) {
          await SystemNavigator.pop();
        } else {
          await windowManager.setPreventClose(false);
          await windowManager.close();
        }
      }
    } finally {
      _closeRequested = false;
      widget.runtime.scheduledExit = false;
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.removeListener(this);
    }
    widget.runtime.confirmDownload = null;
    widget.runtime.requestExit = null;
    _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _appearance,
      builder: (context, _) => GetMaterialApp(
        title: 'XMPlus',
        navigatorKey: _navigator,
        debugShowCheckedModeBanner: false,
        theme: getThemeData(
          seedColor: _appearance.seedColor,
          brightness: Brightness.light,
        ),
        darkTheme: getThemeData(
          seedColor: _appearance.seedColor,
          brightness: Brightness.dark,
        ),
        themeMode: _appearance.themeMode,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        locale: const Locale('zh', 'CN'),
        fallbackLocale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        scrollBehavior: const CustomScrollBehavior(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(_appearance.textScale)),
          child: child!,
        ),
        home: PopScope(
          canPop: !Platform.isAndroid,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && Platform.isAndroid) unawaited(onCloseRequested());
          },
          child: ShellPage(appearance: _appearance, runtime: widget.runtime),
        ),
      ),
    );
  }
}
