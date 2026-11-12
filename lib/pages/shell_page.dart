// Material navigation adapted from PiliPlus lib/pages/main/view.dart
// (NavigationBar and NavigationRail branches), commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_header.dart';
import '../services/app_runtime.dart';
import '../services/update_service.dart';
import 'settings_page.dart';
import 'home_page.dart';
import 'listening_page.dart';
import 'usage_page.dart';
import '../models/xmly_models.dart';
import 'download_page.dart';
import 'catalogue_page.dart';

class ShellPage extends StatefulWidget {
  const ShellPage({
    required this.appearance,
    required this.runtime,
    this.onMiniPlayer,
    this.onTray,
    super.key,
  });

  final AppAppearance appearance;
  final AppRuntime runtime;
  final VoidCallback? onMiniPlayer;
  final VoidCallback? onTray;

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
      await requestDownloads(context, widget.runtime, tracks);
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

  void _select(int index) {
    if (_selectedIndex == index) return;
    setState(() => _selectedIndex = index);
  }

  void _openSearch() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppHeader(title: const Text('搜索')),
        body: DiscoveryPage(
          runtime: widget.runtime,
          onDownload: _download,
          onPlayAlbum: widget.runtime.player.playAlbum,
        ),
      ),
    ),
  );

  void _openUsage() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          UsagePage(runtime: widget.runtime, ledger: widget.runtime.ledger),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth =
            constraints.maxWidth - MediaQuery.paddingOf(context).horizontal;
        final useRail = availableWidth >= 840;
        final expandedRail = availableWidth >= 1440;
        final compact = availableWidth < (usesWindowHeader ? 600 : 320);
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final railLabelStyle = expandedRail
            ? theme.textTheme.titleMedium
            : theme.textTheme.labelMedium;
        return Scaffold(
          appBar: AppHeader(
            showBrand: !compact,
            title: AdaptiveText(_destinations[_selectedIndex].label),
            actions: [
              if (widget.onMiniPlayer != null)
                PopupMenuButton<String>(
                  tooltip: '窗口操作',
                  offset: const Offset(0, 12),
                  onSelected: (value) {
                    if (value == 'mini') {
                      widget.onMiniPlayer!();
                    } else if (value == 'tray') {
                      widget.onTray?.call();
                    } else {
                      widget.runtime.requestExit?.call();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'mini', child: Text('收起到小窗')),
                    if (widget.onTray != null)
                      const PopupMenuItem(value: 'tray', child: Text('收起到托盘')),
                    const PopupMenuItem(value: 'exit', child: Text('彻底退出')),
                  ],
                ),
              if (compact)
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  offset: const Offset(0, 12),
                  onSelected: (value) =>
                      value == 'search' ? _openSearch() : _openUsage(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'search', child: Text('搜索专辑或声音')),
                    PopupMenuItem(value: 'usage', child: Text('听时记录')),
                  ],
                )
              else ...[
                IconButton(
                  tooltip: '搜索专辑或声音',
                  icon: const Icon(Icons.search),
                  onPressed: _openSearch,
                ),
                IconButton(
                  tooltip: '听时记录',
                  icon: const Icon(Icons.receipt_long_outlined),
                  onPressed: _openUsage,
                ),
              ],
            ],
          ),
          body: SafeArea(
            bottom: useRail,
            child: Row(
              children: [
                if (useRail)
                  ColoredBox(
                    key: const ValueKey('shellNavigation'),
                    color: colors.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 20, 8, 16),
                      child: NavigationRail(
                        extended: expandedRail,
                        minWidth: 72,
                        minExtendedWidth: 168,
                        groupAlignment: -1,
                        scrollable: true,
                        labelType: expandedRail
                            ? NavigationRailLabelType.none
                            : NavigationRailLabelType.all,
                        backgroundColor: Colors.transparent,
                        selectedLabelTextStyle: railLabelStyle?.copyWith(
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                        unselectedLabelTextStyle: railLabelStyle?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        indicatorColor: colors.primaryContainer,
                        selectedIconTheme: IconThemeData(
                          color: colors.onPrimaryContainer,
                          size: 24,
                        ),
                        unselectedIconTheme: IconThemeData(
                          color: colors.onSurfaceVariant,
                          size: 24,
                        ),
                        onDestinationSelected: _select,
                        selectedIndex: _selectedIndex,
                        destinations: _destinations.map((destination) {
                          return NavigationRailDestination(
                            label: Text(
                              destination.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: expandedRail
                                  ? TextAlign.start
                                  : TextAlign.center,
                            ),
                            icon: Icon(destination.icon),
                            selectedIcon: Icon(destination.selected),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                Expanded(
                  key: const ValueKey('shellContent'),
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
                        child: _ShellPageStack(
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
                            DownloadPage(runtime: widget.runtime),
                            SettingsPage(
                              appearance: widget.appearance,
                              runtime: widget.runtime,
                              updates: _updates,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: useRail
              ? null
              : compact
              ? Material(
                  child: SafeArea(
                    top: false,
                    child: PopupMenuButton<int>(
                      tooltip: '切换页面',
                      initialValue: _selectedIndex,
                      onSelected: _select,
                      itemBuilder: (_) => [
                        for (
                          var index = 0;
                          index < _destinations.length;
                          index++
                        )
                          PopupMenuItem(
                            value: index,
                            child: Text(_destinations[index].label),
                          ),
                      ],
                      child: SizedBox(
                        height: 56,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Icon(_destinations[_selectedIndex].selected),
                              const SizedBox(width: 12),
                              Expanded(
                                child: AdaptiveText(
                                  _destinations[_selectedIndex].label,
                                ),
                              ),
                              const Icon(Icons.unfold_more),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                )
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

/// Cross-fades destinations without replacing their state or scroll positions.
class _ShellPageStack extends StatefulWidget {
  const _ShellPageStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_ShellPageStack> createState() => _ShellPageStackState();
}

class _ShellPageStackState extends State<_ShellPageStack> {
  final _leaving = <int>{};
  bool _disableAnimations = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.disableAnimationsOf(context);
    if (disabled != _disableAnimations) {
      _disableAnimations = disabled;
      _leaving.clear();
    }
  }

  @override
  void didUpdateWidget(covariant _ShellPageStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      if (!_disableAnimations) _leaving.add(oldWidget.index);
      _leaving.remove(widget.index);
    }
  }

  void _finishTransition(int index) {
    if (!mounted || index == widget.index || !_leaving.contains(index)) return;
    setState(() => _leaving.remove(index));
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      for (var index = 0; index < widget.children.length; index++)
        Offstage(
          offstage: index != widget.index && !_leaving.contains(index),
          child: TickerMode(
            enabled: index == widget.index || _leaving.contains(index),
            child: ExcludeFocus(
              excluding: index != widget.index,
              child: ExcludeSemantics(
                excluding: index != widget.index,
                child: IgnorePointer(
                  ignoring: index != widget.index,
                  child: AnimatedOpacity(
                    opacity: index == widget.index ? 1 : 0,
                    duration: _disableAnimations
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    onEnd: () => _finishTransition(index),
                    child: RepaintBoundary(child: widget.children[index]),
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
