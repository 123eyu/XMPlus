import 'package:flutter/material.dart';

import '../api/xmly_experience.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({required this.runtime, required this.onDownload,
      required this.onPlayAlbum, super.key});
  final AppRuntime runtime;
  final Future<void> Function(List<Track>) onDownload;
  final AlbumPlayback onPlayAlbum;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _scroll = ScrollController();
  List<HomeChannel> _channels = const [];
  List<HomeTab> _tabs = const [];
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
    _loadChannels();
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_accountChanged);
      widget.runtime.addListener(_accountChanged);
      _identity = widget.runtime.client.cacheIdentity;
      _loadChannels();
    }
  }

  void _accountChanged() {
    final identity = widget.runtime.client.cacheIdentity;
    if (identity == _identity) return;
    _identity = identity;
    _loadChannels();
  }

  bool _current(int generation, String identity) => mounted && generation == _generation &&
      identity == widget.runtime.client.cacheIdentity;

  Future<void> _loadChannels() async {
    final generation = ++_generation;
    final client = widget.runtime.client;
    final identity = client.cacheIdentity;
    setState(() {
      _busy = true; _error = null; _content = null; _channels = const [];
      _tabs = const []; _tabId = null;
    });
    try {
      final api = XmlyExperience(client);
      final channels = await api.channels();
      if (!_current(generation, identity)) return;
      if (channels.isEmpty) throw const XmlyException('empty_channels', '暂时没有可用频道');
      final selected = channels.any((channel) => channel.pageId == _pageId)
          ? _pageId! : channels.first.pageId;
      setState(() { _channels = channels; _pageId = selected; });
      await _fetchHome(api, selected, generation, identity);
    } catch (error) {
      if (_current(generation, identity)) setState(() { _error = _safeError(error); });
    } finally {
      if (_current(generation, identity)) setState(() { _busy = false; });
    }
  }

  Future<void> _loadHome(int pageId, {int? tabId}) async {
    final generation = ++_generation;
    final client = widget.runtime.client;
    final identity = client.cacheIdentity;
    setState(() {
      if (_pageId != pageId) _tabs = const [];
      _pageId = pageId; _tabId = tabId; _busy = true; _error = null; _content = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    try {
      await _fetchHome(XmlyExperience(client), pageId, generation, identity, tabId: tabId);
    } catch (error) {
      if (_current(generation, identity)) setState(() { _error = _safeError(error); });
    } finally {
      if (_current(generation, identity)) setState(() { _busy = false; });
    }
  }
  Future<void> _fetchHome(XmlyExperience api, int pageId, int generation, String identity, {int? tabId}) async {
    var content = await api.home(pageId, tabId: tabId);
    if (!_current(generation, identity)) return;
    if (content.tabs.isNotEmpty) {
      setState(() { _tabs = content.tabs; });
      if (tabId == null) {
        final selected = content.tabs.first.tabId;
        setState(() { _tabId = selected; });
        content = await api.home(pageId, tabId: selected);
        if (!_current(generation, identity)) return;
      }
    }
    setState(() { _content = content; });
  }


  void _search() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Scaffold(
    appBar: AppBar(title: const Text('搜索')),
    body: DiscoveryPage(runtime: widget.runtime, onDownload: widget.onDownload, onPlayAlbum: widget.onPlayAlbum),
  )));

  void _openAlbum(Album album) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumPageView(
    runtime: widget.runtime, albumId: album.id, onDownload: widget.onDownload, onPlayAlbum: widget.onPlayAlbum,
  )));

  @override
  void dispose() {
    _generation++;
    widget.runtime.removeListener(_accountChanged);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sections = _content?.sections ?? const <HomeSection>[];
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 8, 8), child: Row(children: [
        Expanded(child: OutlinedButton.icon(onPressed: _search,
          style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft, padding: const EdgeInsets.all(16)),
          icon: const Icon(Icons.search), label: const Text('搜索专辑、声音'))),
        IconButton(tooltip: '刷新首页', onPressed: _busy ? null : _loadChannels, icon: const Icon(Icons.refresh)),
      ])),
      if (_channels.isNotEmpty) SizedBox(height: 52, child: ListView.separated(
        scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _channels.length, separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final channel = _channels[index];
          return Center(child: ChoiceChip(label: Text(channel.title), selected: channel.pageId == _pageId,
            onSelected: (_) { if (channel.pageId != _pageId) _loadHome(channel.pageId); }));
        })),
      if (_tabs.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 8, runSpacing: 4, children: [
          for (final tab in _tabs) ChoiceChip(label: Text(tab.title), selected: tab.tabId == _tabId,
            onSelected: (_) { if (tab.tabId != _tabId) _loadHome(_pageId!, tabId: tab.tabId); }),
        ]))),
      if (_busy) const LinearProgressIndicator(),
      Expanded(child: RefreshIndicator(onRefresh: _loadChannels, child: Scrollbar(controller: _scroll,
        child: CustomScrollView(controller: _scroll, physics: const AlwaysScrollableScrollPhysics(), slivers: [
          if (_error != null) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _busy ? null : _pageId == null ? _loadChannels : () => _loadHome(_pageId!, tabId: _tabId),
              child: const Text('重试')),
          ]))),
          if (!_busy && _error == null && sections.isEmpty) const SliverFillRemaining(hasScrollBody: false,
            child: Center(child: Text('这个频道暂时没有推荐专辑'))),
          for (final section in sections) SliverToBoxAdapter(child: _section(section)),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ])))),
    ]);
  }

  Widget _section(HomeSection section) => Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(section.isRanking ? '排行榜 · ${section.title}' : section.title,
        style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1100 ? 3 : constraints.maxWidth >= (section.isRanking ? 330 : 700) ? 2 : 1;
        final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (var index = 0; index < section.albums.length; index++) SizedBox(width: width,
            child: _albumCard(section.albums[index], section.stats[section.albums[index].id],
              section.isRanking ? index + 1 : null)),
        ]);
      }),
    ]));

  Widget _albumCard(Album album, HomeAlbumStats? stats, int? rank) {
    final details = <String>[
      if (album.total > 0) '${album.total} 集',
      if (stats?.playCount != null) '${_count(stats!.playCount!)} 播放',
      if (stats?.subscribeCount != null) '${_count(stats!.subscribeCount!)} 订阅',
    ];
    return Card(margin: EdgeInsets.zero, clipBehavior: Clip.antiAlias, child: InkWell(
      onTap: () => _openAlbum(album), child: Padding(padding: const EdgeInsets.all(12), child: Row(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            CoverImage(uri: album.coverUrl, size: rank == null ? 96 : 52),
            if (rank != null) Positioned(top: 0, left: 0, child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary,
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(8), bottomRight: Radius.circular(8))),
              child: Text('$rank', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)))),
          ]),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(album.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
            if (album.artist.isNotEmpty) Text(album.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (rank == null && album.intro.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
              child: Text(album.intro, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall)),
            if (stats?.score != null) Text('${stats!.score!.toStringAsFixed(1)} 分',
              style: TextStyle(color: Theme.of(context).colorScheme.primary)),
            if (details.isNotEmpty && rank == null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(details.join(' · '),
              style: Theme.of(context).textTheme.bodySmall)),
            if (stats?.finished == true) Text('完结', style: Theme.of(context).textTheme.labelSmall),
          ])),
        ]))));
  }
}

String _count(int count) => count >= 100000000 ? '${(count / 100000000).toStringAsFixed(1)}亿'
    : count >= 10000 ? '${(count / 10000).toStringAsFixed(1)}万' : '$count';
String _safeError(Object error) => error is XmlyException ? error.message : '加载失败，请稍后重试';
