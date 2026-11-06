// Material navigation adapted from PiliPlus lib/pages/main/view.dart
// (NavigationBar and NavigationRail branches), commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../services/app_runtime.dart';
import '../services/update_service.dart';
import 'settings_page.dart';
import 'home_page.dart';
import 'listening_page.dart';
import 'usage_page.dart';
import '../models/xmly_models.dart';
import 'download_page.dart';
import 'catalogue_page.dart';
import 'player_panel.dart';

class ShellPage extends StatefulWidget {
  const ShellPage({required this.appearance, required this.runtime, super.key});

  final AppAppearance appearance;
  final AppRuntime runtime;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int _selectedIndex = 0;
  bool _preparingDownload = false;
  late final UpdateService _updates;

  @override
  void initState() {
    super.initState();
    _updates = UpdateService(widget.runtime.storage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_updates.check(context));
    });
  }

  @override
  void dispose() {
    _updates.dispose();
    super.dispose();
  }

  Future<void> _download(List<Track> tracks) async {
    if (_preparingDownload) return;
    _preparingDownload = true;
    try {
      var identity = widget.runtime.accounts.primaryAccountId ?? 'anonymous';
      if (widget.runtime.accounts.accountIds.isNotEmpty) {
        final chosen = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('下载账号'),
            children: [
              for (final id in widget.runtime.accounts.accountIds)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, id),
                  child: Text(
                    '账号 ${(widget.runtime.storage.state['accounts'] as Map)[id]['uid']}${id == identity ? " · 主账号" : ""}',
                  ),
                ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, 'anonymous'),
                child: const Text('不登录（免费内容）'),
              ),
            ],
          ),
        );
        if (chosen == null) return;
        identity = chosen;
      }
      final batch = await widget.runtime.prepareDownloads(
        tracks,
        accountIdentity: identity,
      );
      if (!mounted) return;
      if (await confirmDownloadBatch(context, batch))
        await widget.runtime.downloads.enqueue(batch, confirmed: true);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is XmlyException ? error.message : '下载未开始，请检查账号及下载目录',
            ),
          ),
        );
    } finally {
      _preparingDownload = false;
    }
  }

  static const _destinations = [
    (label: '主页', icon: Icons.home_outlined, selected: Icons.home),
    (label: '听过', icon: Icons.headphones_outlined, selected: Icons.headphones),
    (label: '下载', icon: Icons.download_outlined, selected: Icons.download),
    (label: '设置', icon: Icons.settings_outlined, selected: Icons.settings),
  ];

  void _select(int index) => setState(() => _selectedIndex = index);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= 840;
        return Scaffold(
          appBar: AppBar(
            title: Text(_destinations[_selectedIndex].label),
            actions: [
              IconButton(
                tooltip: '搜索专辑或声音',
                icon: const Icon(Icons.search),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('搜索')),
                      body: DiscoveryPage(
                        runtime: widget.runtime,
                        onDownload: _download,
                        onPlayAlbum: widget.runtime.player.playAlbum,
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '听时记录',
                icon: const Icon(Icons.receipt_long_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => UsagePage(
                      runtime: widget.runtime,
                      ledger: widget.runtime.ledger,
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            bottom: false,
            child: Row(
              children: [
                if (useRail) ...[
                  NavigationRail(
                    groupAlignment: constraints.maxHeight < 560 ? -1 : 0,
                    labelType: constraints.maxHeight < 480
                        ? NavigationRailLabelType.selected
                        : NavigationRailLabelType.all,
                    backgroundColor: Colors.transparent,
                    onDestinationSelected: _select,
                    selectedIndex: _selectedIndex,
                    destinations: _destinations.map((destination) {
                      return NavigationRailDestination(
                        label: Text(destination.label),
                        icon: Icon(destination.icon),
                        selectedIcon: Icon(destination.selected),
                      );
                    }).toList(),
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: Column(
                    children: [
                      ListenableBuilder(
                        listenable: widget.runtime,
                        builder: (context, _) =>
                            widget.runtime.lifecycleError == null
                            ? const SizedBox.shrink()
                            : MaterialBanner(
                                content: Text(widget.runtime.lifecycleError!),
                                actions: [
                                  TextButton(
                                    onPressed: () {
                                      widget.runtime.lifecycleError = null;
                                      widget.runtime.changed();
                                    },
                                    child: const Text('知道了'),
                                  ),
                                ],
                              ),
                      ),
                      Expanded(
                        child: IndexedStack(
                          index: _selectedIndex,
                          children: [
                            HomePage(
                              runtime: widget.runtime,
                              onDownload: _download,
                              onPlayAlbum: widget.runtime.player.playAlbum,
                            ),
                            ListeningPage(
                              runtime: widget.runtime,
                              onDownload: _download,
                              onPlayAlbum: widget.runtime.player.playAlbum,
                            ),
                            DownloadPage(
                              service: widget.runtime.downloads,
                              onPause: widget.runtime.pauseDownload,
                              onCancel: widget.runtime.cancelDownload,
                              onStop: widget.runtime.player.stopTaskReference,
                              onPauseAll: widget.runtime.pauseAllDownloads,
                              onReacquire: widget.runtime.reacquireDownload,
                              onRelocate: widget.runtime.relocateDownload,
                              autoDownloads: widget.runtime.autoDownloads,
                            ),
                            SettingsPage(
                              appearance: widget.appearance,
                              runtime: widget.runtime,
                              updates: _updates,
                            ),
                          ],
                        ),
                      ),
                      PlayerPanel(runtime: widget.runtime),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: useRail
              ? null
              : NavigationBar(
                  maintainBottomViewPadding: true,
                  onDestinationSelected: _select,
                  selectedIndex: _selectedIndex,
                  destinations: _destinations.map((destination) {
                    return NavigationDestination(
                      label: destination.label,
                      icon: Icon(destination.icon),
                      selectedIcon: Icon(destination.selected),
                    );
                  }).toList(),
                ),
        );
      },
    );
  }
}
