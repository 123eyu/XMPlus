import 'dart:async';

import 'package:flutter/material.dart';

import '../api/xmly_experience.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/content_cross_fade.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart';
import 'home_album_section.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    required this.runtime,
    required this.onDownload,
    required this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final Future<void> Function(List<Track>) onDownload;
  final AlbumPlayback onPlayAlbum;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Duration get _motionDuration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 180);
  Timer? _loadingDelay;
  bool _showLoading = false;
  List<HomeChannel> _channels = const [];
  List<HomeTab> _tabs = const [];
  int? _tabsPageId;
  int? _tabId;
  HomeContent? _content;
  int? _pageId;
  int _generation = 0;
  bool _busy = true;
  String? _error;
  late String _identity;

  @override
  void initState() {
    super.initState();
    _identity = widget.runtime.client.cacheIdentity;
    widget.runtime.addListener(_accountChanged);
    _loadChannels(reset: true);
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_accountChanged);
      widget.runtime.addListener(_accountChanged);
      _identity = widget.runtime.client.cacheIdentity;
      _loadChannels(reset: true);
    }
  }

  void _accountChanged() {
    final identity = widget.runtime.client.cacheIdentity;
    if (identity == _identity) return;
    _identity = identity;
    _loadChannels(reset: true);
  }

  bool _current(int generation, String identity) =>
      mounted &&
      generation == _generation &&
      identity == widget.runtime.client.cacheIdentity;

  void _startLoading(int generation, String identity) {
    _loadingDelay?.cancel();
    _showLoading = false;
    _loadingDelay = Timer(const Duration(milliseconds: 240), () {
      if (_current(generation, identity) && _busy) {
        setState(() => _showLoading = true);
      }
    });
  }

  void _stopLoading() {
    _loadingDelay?.cancel();
    _showLoading = false;
    _busy = false;
  }

  Future<void> _loadChannels({bool reset = false}) async {
    final generation = ++_generation;
    final client = widget.runtime.client;
    final identity = client.cacheIdentity;
    setState(() {
      _busy = true;
      _error = null;
      if (reset) {
        _content = null;
        _channels = const [];
        _tabs = const [];
        _tabsPageId = null;
        _pageId = null;
        _tabId = null;
      }
    });
    _startLoading(generation, identity);
    try {
      final api = XmlyExperience(client);
      final channels = await api.channels();
      if (!_current(generation, identity)) return;
      if (channels.isEmpty)
        throw const XmlyException('empty_channels', '暂时没有可用频道');
      final selected = channels.any((channel) => channel.pageId == _pageId)
          ? _pageId!
          : channels.first.pageId;
      final selectedTab = selected == _pageId ? _tabId : null;
      setState(() {
        _channels = channels;
        _pageId = selected;
        _tabId = selectedTab;
      });
      await _fetchHome(api, selected, generation, identity, tabId: selectedTab);
    } catch (error) {
      if (_current(generation, identity)) _loadFailed(error);
    }
  }

  Future<void> _loadHome(int pageId, {int? tabId}) async {
    final generation = ++_generation;
    final client = widget.runtime.client;
    final identity = client.cacheIdentity;
    setState(() {
      _pageId = pageId;
      _tabId = tabId;
      _busy = true;
      _error = null;
    });
    _startLoading(generation, identity);
    try {
      await _fetchHome(
        XmlyExperience(client),
        pageId,
        generation,
        identity,
        tabId: tabId,
      );
    } catch (error) {
      if (_current(generation, identity)) _loadFailed(error);
    }
  }

  void _loadFailed(Object error) => setState(() {
    _error = _safeError(error);
    _stopLoading();
    _content = null;
    if (_tabsPageId != _pageId) {
      _tabs = const [];
      _tabsPageId = null;
    }
  });

  Future<void> _fetchHome(
    XmlyExperience api,
    int pageId,
    int generation,
    String identity, {
    int? tabId,
  }) async {
    var content = await api.home(pageId, tabId: tabId);
    if (!_current(generation, identity)) return;
    var tabs = content.tabs;
    var selectedTab = tabId;
    if (tabs.isNotEmpty && selectedTab == null) {
      selectedTab = tabs.first.tabId;
      content = await api.home(pageId, tabId: selectedTab);
      if (!_current(generation, identity)) return;
    }
    if (content.tabs.isNotEmpty) {
      tabs = content.tabs;
    } else if (tabs.isEmpty && tabId != null && _tabsPageId == pageId) {
      tabs = _tabs;
    }
    final covers = content.sections
        .expand((section) => section.albums)
        .map((album) => album.coverUrl)
        .whereType<Uri>()
        .take(12);
    await Future.wait([
      for (final uri in covers)
        precacheImage(
          NetworkImage(uri.toString()),
          context,
          onError: (_, _) {},
        ),
    ]).timeout(const Duration(milliseconds: 180), onTimeout: () => []);
    if (!_current(generation, identity)) return;
    setState(() {
      // Keep the controls and their content in the same loaded snapshot.
      _tabs = tabs;
      _tabsPageId = pageId;
      _tabId = selectedTab;
      _content = content;
      _stopLoading();
    });
  }

  void _search() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppHeader(title: const Text('搜索')),
        body: DiscoveryPage(
          runtime: widget.runtime,
          onDownload: widget.onDownload,
          onPlayAlbum: widget.onPlayAlbum,
        ),
      ),
    ),
  );

  void _openAlbum(Album album) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AlbumPageView(
        runtime: widget.runtime,
        albumId: album.id,
        onDownload: widget.onDownload,
        onPlayAlbum: widget.onPlayAlbum,
      ),
    ),
  );

  @override
  void dispose() {
    _generation++;
    widget.runtime.removeListener(_accountChanged);
    _loadingDelay?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabsCurrent = _tabsPageId == _pageId;
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = constraints.maxWidth < 360
            ? 12.0
            : (constraints.maxWidth * .025).clamp(20.0, 56.0);
        return Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .55,
              ),
              child: SingleChildScrollView(
                primary: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(horizontal, 20, horizontal, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _discoveryHeader(),
                      if (_channels.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 16, bottom: 4),
                          child: SizedBox(
                            height:
                                36 + MediaQuery.textScalerOf(context).scale(16),
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _channels.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (_, index) {
                                final channel = _channels[index];
                                return Center(
                                  key: ValueKey(channel.pageId),
                                  child: _categoryChip(
                                    title: channel.title,
                                    selected: channel.pageId == _pageId,
                                    onSelected: (_) {
                                      if (channel.pageId != _pageId) {
                                        _loadHome(channel.pageId);
                                      }
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      AnimatedSize(
                        duration: _motionDuration,
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topLeft,
                        child: _tabs.isEmpty
                            ? const SizedBox(width: double.infinity, height: 0)
                            : IgnorePointer(
                                ignoring: !tabsCurrent,
                                child: ExcludeFocus(
                                  excluding: !tabsCurrent,
                                  child: ExcludeSemantics(
                                    excluding: !tabsCurrent,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 4,
                                      ),
                                      child: Wrap(
                                        spacing: 8,
                                        runSpacing: 4,
                                        children: [
                                          for (final tab in _tabs)
                                            _categoryChip(
                                              key: ValueKey(tab.tabId),
                                              title: tab.title,
                                              selected: tab.tabId == _tabId,
                                              onSelected: (_) {
                                                if (tabsCurrent &&
                                                    tab.tabId != _tabId) {
                                                  _loadHome(
                                                    _pageId!,
                                                    tabId: tab.tabId,
                                                  );
                                                }
                                              },
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontal),
              child: SizedBox(
                height: 2,
                child: AnimatedOpacity(
                  opacity: _showLoading ? 1 : 0,
                  duration: _motionDuration,
                  child: TickerMode(
                    enabled: _showLoading,
                    child: const LinearProgressIndicator(
                      semanticsLabel: '正在加载频道',
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ContentCrossFade(
                key: ValueKey(_identity),
                child: _HomeFeed(
                  key: ObjectKey(_content ?? _error ?? 'initial-home'),
                  content: _content,
                  busy: _busy,
                  error: _error,
                  horizontal: horizontal,
                  onRefresh: _loadChannels,
                  onOpenAlbum: _busy ? null : _openAlbum,
                  onRetry: _busy
                      ? null
                      : _pageId == null || _channels.isEmpty
                      ? _loadChannels
                      : () => _loadHome(_pageId!, tabId: _tabId),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _discoveryHeader() => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final title = Text(
        '发现好声音',
        style: theme.textTheme.headlineLarge?.copyWith(
          fontSize: 30,
          fontWeight: FontWeight.w600,
          letterSpacing: .5,
        ),
      );
      final search = Row(
        children: [
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: _search,
              style: FilledButton.styleFrom(
                alignment: Alignment.centerLeft,
                backgroundColor: colors.surfaceContainerHigh,
                foregroundColor: colors.onSurfaceVariant,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
              ),
              icon: const Icon(Icons.search, size: 20),
              label: const AdaptiveText('搜索专辑、声音'),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '刷新首页',
            onPressed: _busy ? null : _loadChannels,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      );
      if (constraints.maxWidth <
          720 * MediaQuery.textScalerOf(context).scale(14) / 14) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [title, const SizedBox(height: 16), search],
        );
      }
      return Row(
        children: [
          Expanded(child: title),
          const SizedBox(width: 32),
          SizedBox(
            width: (constraints.maxWidth * .45).clamp(320.0, 560.0),
            child: search,
          ),
        ],
      );
    },
  );

  Widget _categoryChip({
    Key? key,
    required String title,
    required bool selected,
    required ValueChanged<bool>? onSelected,
  }) {
    final colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      key: key,
      constraints: const BoxConstraints(maxWidth: 220),
      child: ChoiceChip(
        label: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        labelStyle: TextStyle(
          fontWeight: FontWeight.w500,
          color: selected ? colors.onPrimaryContainer : colors.onSurfaceVariant,
        ),
        labelPadding: const EdgeInsets.symmetric(horizontal: 12),
        backgroundColor: colors.surface,
        selectedColor: colors.primaryContainer,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        selected: selected,
        showCheckmark: false,
        chipAnimationStyle: ChipAnimationStyle(
          selectAnimation: AnimationStyle(
            duration: _motionDuration,
            reverseDuration: _motionDuration,
          ),
        ),
        onSelected: onSelected,
      ),
    );
  }
}

class _HomeFeed extends StatefulWidget {
  const _HomeFeed({
    required this.content,
    required this.busy,
    required this.error,
    required this.horizontal,
    required this.onRefresh,
    required this.onOpenAlbum,
    required this.onRetry,
    super.key,
  });

  final HomeContent? content;
  final bool busy;
  final String? error;
  final double horizontal;
  final Future<void> Function() onRefresh;
  final ValueChanged<Album>? onOpenAlbum;
  final VoidCallback? onRetry;

  @override
  State<_HomeFeed> createState() => _HomeFeedState();
}

class _HomeFeedState extends State<_HomeFeed> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sections = widget.content?.sections ?? const <HomeSection>[];
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: Scrollbar(
        controller: _scroll,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                widget.horizontal,
                0,
                widget.horizontal,
                32,
              ),
              sliver: SliverMainAxisGroup(
                slivers: [
                  if (widget.error != null)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: widget.onRetry,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (!widget.busy && sections.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text('这个频道暂时没有推荐专辑')),
                    )
                  else
                    SliverIgnorePointer(
                      key: const ValueKey('home-content'),
                      ignoring: widget.busy,
                      sliver: SliverMainAxisGroup(
                        slivers: [
                          for (final section in sections)
                            HomeAlbumSection(
                              section: section,
                              onOpenAlbum: widget.onOpenAlbum,
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
    );
  }
}

String _safeError(Object error) =>
    error is XmlyException ? error.message : '加载失败，请稍后重试';
