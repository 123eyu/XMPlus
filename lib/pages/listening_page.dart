import 'dart:async';

import 'package:flutter/material.dart';

import '../api/xmly_experience.dart';
import '../api/xmly_history.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart';
import 'download_page.dart';
import 'library_page.dart';
import 'player_panel.dart';

class ListeningPage extends StatefulWidget {
  const ListeningPage({required this.runtime, required this.onDownload,
    required this.onPlayAlbum, super.key});
  final AppRuntime runtime;
  final Future<void> Function(List<Track>) onDownload;
  final AlbumPlayback onPlayAlbum;

  @override
  State<ListeningPage> createState() => _ListeningPageState();
}

class _ListeningPageState extends State<ListeningPage> {
  final _search = TextEditingController();
  final _busy = [false, false, false];
  final List<String?> _errors = [null, null, null];
  final _requests = [0, 0, 0];
  List<UpdateItem> _updates = [];
  List<SubscriptionItem> _subscriptions = [];
  List<Map<String, dynamic>> _cloudHistory = [];
  bool _moreUpdates = false, _moreSubscriptions = false, _acting = false;
  int? _before;
  int _subscriptionPage = 0, _accountEpoch = 0;
  late String _accountKey;
  AppRuntime get _runtime => widget.runtime;
  String get _currentKey => _runtime.client.cacheIdentity;
  bool get _signedIn => _runtime.accounts.activeClient != null;
  String get _query => _search.text.trim().toLowerCase();

  @override
  void initState() {
    super.initState();
    _accountKey = _currentKey;
    _runtime.addListener(_runtimeChanged);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant ListeningPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_runtimeChanged);
      _runtime.addListener(_runtimeChanged);
      _resetAccount();
    }
  }

  void _runtimeChanged() {
    if (_accountKey != _currentKey) { _resetAccount(); }
    else if (mounted) { setState(() {}); }
  }

  void _resetAccount() {
    _accountKey = _currentKey;
    ++_accountEpoch;
    setState(() {
      _updates = []; _subscriptions = []; _cloudHistory = [];
      _before = null; _subscriptionPage = 0;
      _moreUpdates = false; _moreSubscriptions = false;
      for (var i = 0; i < _busy.length; i++) {
        _busy[i] = false; _errors[i] = null; ++_requests[i];
      }
    });
    _refresh();
  }

  void _refresh() {
    if (!_signedIn) return;
    unawaited(_loadUpdates(reset: true));
    unawaited(_loadSubscriptions(reset: true));
    unawaited(_loadHistory());
  }

  bool _valid(int section, int request, int epoch, String key) => mounted &&
    epoch == _accountEpoch && request == _requests[section] && key == _currentKey;

  Future<void> _loadUpdates({bool reset = false}) async {
    if (!_signedIn || (!reset && (_busy[0] || !_moreUpdates))) return;
    final client = _runtime.client, epoch = _accountEpoch, request = ++_requests[0];
    final key = client.cacheIdentity;
    final before = reset ? null : _before;
    setState(() { _busy[0] = true; _errors[0] = null; });
    try {
      final result = await XmlyExperience(client).updates(before: before, pageSize: 50);
      if (!_valid(0, request, epoch, key)) return;
      final known = reset ? <String>{} : _updates.map((item) => item.track.id).toSet();
      final added = result.items.where((item) => known.add(item.track.id)).toList();
      if ((!reset && result.hasMore && added.isEmpty) ||
          (result.hasMore && (result.nextTimeline == null || result.nextTimeline == before))) {
        throw const XmlyException('repeated_page', '更新列表没有前进，请稍后重试');
      }
      if ((reset ? 0 : _updates.length) + added.length > 5000) {
        throw const XmlyException('feed_limit', '已加载 5000 条更新，请搜索或刷新列表');
      }
      setState(() {
        _updates = [if (!reset) ..._updates, ...added];
        _before = result.nextTimeline; _moreUpdates = result.hasMore;
      });
    } catch (error) {
      if (_valid(0, request, epoch, key)) setState(() {
        _errors[0] = error is XmlyException && error.code == 'repeated_page'
          ? '更多更新分页暂不可用，已保留当前列表' : _message(error);
        if (error is XmlyException && error.code == 'repeated_page') _moreUpdates = false;
      });
    } finally {
      if (_valid(0, request, epoch, key)) setState(() => _busy[0] = false);
    }
  }

  Future<void> _loadSubscriptions({bool reset = false}) async {
    if (!_signedIn || (!reset && (_busy[1] || !_moreSubscriptions))) return;
    final client = _runtime.client, epoch = _accountEpoch, request = ++_requests[1];
    final key = client.cacheIdentity, page = reset ? 1 : _subscriptionPage + 1;
    setState(() { _busy[1] = true; _errors[1] = null; });
    try {
      final result = await XmlyExperience(client).subscriptions(page: page);
      if (!_valid(1, request, epoch, key)) return;
      final known = reset ? <String>{} : _subscriptions.map((item) => item.album.id).toSet();
      final added = result.items.where((item) => known.add(item.album.id)).toList();
      if (!reset && result.hasMore && added.isEmpty) {
        throw const XmlyException('repeated_page', '订阅列表没有前进，请稍后重试');
      }
      if ((reset ? 0 : _subscriptions.length) + added.length > 5000) {
        throw const XmlyException('subscription_limit', '已加载 5000 个订阅');
      }
      setState(() {
        _subscriptions = [if (!reset) ..._subscriptions, ...added];
        _subscriptionPage = page; _moreSubscriptions = result.hasMore;
      });
    } catch (error) {
      if (_valid(1, request, epoch, key)) setState(() => _errors[1] = _message(error));
    } finally {
      if (_valid(1, request, epoch, key)) setState(() => _busy[1] = false);
    }
  }

  Future<void> _loadHistory() async {
    if (!_signedIn) return;
    final client = _runtime.client, epoch = _accountEpoch, request = ++_requests[2];
    final key = client.cacheIdentity;
    setState(() { _busy[2] = true; _errors[2] = null; });
    try {
      final result = await XmlyHistory(client).records();
      if (_valid(2, request, epoch, key)) setState(() => _cloudHistory = result);
    } catch (error) {
      if (_valid(2, request, epoch, key)) setState(() => _errors[2] = _message(error));
    } finally {
      if (_valid(2, request, epoch, key)) setState(() => _busy[2] = false);
    }
  }

  static String _message(Object error) => error is XmlyException ? error.message : '加载失败，请重试';

  Future<void> _act(Future<void> Function() action) async {
    if (_acting) return;
    final epoch = _accountEpoch;
    setState(() => _acting = true);
    try { await action(); }
    catch (error) {
      if (mounted && epoch == _accountEpoch) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_message(error))));
    } finally { if (mounted) setState(() => _acting = false); }
  }

  void _openAlbum(String id) => Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AlbumPageView(runtime: _runtime, albumId: id,
      onDownload: widget.onDownload, onPlayAlbum: widget.onPlayAlbum)));

  Map get _positions => (((_runtime.storage.state['history'] as Map)
    [_runtime.player.libraryIdentity] as Map?)?['positions'] as Map?) ?? const {};

  bool _matches(Track track) => _query.isEmpty ||
    '${track.title} ${track.album} ${track.artist}'.toLowerCase().contains(_query);

  double _position(Track track) {
    final value = (_positions[track.id] as Map?)?['position'];
    return value is num && value.isFinite && value > 0 ? value.toDouble() : 0;
  }

  List<_ListeningRecord> _history() {
    final records = <String, _ListeningRecord>{};
    for (final raw in _cloudHistory) {
      final track = Track.fromApi({
        'trackId': raw['track_id'], 'albumId': raw['album_id'],
        'title': raw['title'], 'albumTitle': raw['album_title'],
        'duration': raw['duration'], 'cover_url': raw['cover_url'],
      });
      records[track.id] = _ListeningRecord(track, (raw['position'] as num).toDouble(),
        ((raw['updated_at'] as num) * 1000).toInt());
    }
    for (final entry in _positions.entries) {
      final raw = entry.value;
      if (raw is! Map || raw['track'] is! Map) continue;
      try {
        final track = Track.fromJson(xmlyMap(raw['track']));
        final updated = raw['updatedAt'] is int ? raw['updatedAt'] as int : 0;
        final position = raw['position'];
        if (position is! num || !position.isFinite || position < 0) continue;
        if (updated >= (records[track.id]?.updatedAt ?? 0)) {
          records[track.id] = _ListeningRecord(track, position.toDouble(), updated);
        }
      } on XmlyException { continue; }
    }
    return records.values.where((row) => _matches(row.track)).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  String _day(int timestamp) {
    if (timestamp <= 0) return '更早';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    if (day == today) return '今天';
    if (day == DateTime(today.year, today.month, today.day - 1)) return '昨天';
    return '${date.year}年${date.month}月${date.day}日';
  }

  Widget _empty(String message) => Padding(padding: const EdgeInsets.all(28),
    child: Center(child: Text(message)));

  Widget _sectionState(int section, VoidCallback refresh) => Column(mainAxisSize: MainAxisSize.min, children: [
    if (_busy[section]) const LinearProgressIndicator(),
    if (_errors[section] != null) ListTile(title: Text(_errors[section]!),
      trailing: TextButton(onPressed: _busy[section] ? null : refresh, child: const Text('重试'))),
  ]);

  Widget _trackTile(Track track, {required VoidCallback? play, double position = 0}) {
    final duration = track.duration;
    final progress = duration > 0 ? (position / duration).clamp(0.0, 1.0).toDouble() : null;
    return ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: CoverImage(uri: track.coverUrl, size: 56),
      title: Text(track.title.isEmpty ? track.id : track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (track.album.isNotEmpty) Text(track.album, maxLines: 1, overflow: TextOverflow.ellipsis),
        Text(position > 0 ? '已听 ${playbackTime(position)}${duration > 0 ? ' / ${playbackTime(duration)}' : ''}' : playbackTime(duration)),
        if (position > 0 && progress != null) Padding(padding: const EdgeInsets.only(top: 4),
          child: LinearProgressIndicator(value: progress, minHeight: 2)),
      ]),
      onTap: _acting ? null : play,
      trailing: PopupMenuButton<String>(tooltip: '声音操作', enabled: !_acting,
        onSelected: (value) {
          if (value == 'album') _openAlbum(track.albumId);
          if (value == 'download') unawaited(_act(() => widget.onDownload([track])));
        }, itemBuilder: (_) => [
          if (track.albumId.isNotEmpty) const PopupMenuItem(value: 'album', child: Text('查看专辑')),
          const PopupMenuItem(value: 'download', child: Text('下载')),
        ]));
  }

  Widget _dated<T>(List<T> items, int Function(T) timestamp, Widget Function(T) tile,
      {Widget? footer}) {
    if (items.isEmpty && footer == null) return _empty('暂无记录');
    final rows = <Object>[];
    String? previous;
    for (final item in items) {
      final day = _day(timestamp(item));
      if (day != previous) { rows.add(day); previous = day; }
      rows.add(item as Object);
    }
    return Scrollbar(child: ListView.builder(itemCount: rows.length + (footer == null ? 0 : 1),
      itemBuilder: (_, index) {
        if (index == rows.length) return footer!;
        final row = rows[index];
        return row is String ? Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(row, style: Theme.of(context).textTheme.titleMedium)) : tile(row as T);
      }));
  }

  Widget _subscriptionStrip() {
    return SizedBox(height: 118, child: ListView.separated(
    scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    itemCount: _subscriptions.length, separatorBuilder: (_, _) => const SizedBox(width: 12),
    itemBuilder: (_, index) {
      final item = _subscriptions[index];
      return SizedBox(width: 82, child: InkWell(onTap: () => _openAlbum(item.album.id),
        child: Column(children: [CoverImage(uri: item.album.coverUrl, size: 70),
          const SizedBox(height: 4), Text(item.album.title, maxLines: 1, overflow: TextOverflow.ellipsis)])));
    }));
  }

  Widget _updatesTab() {
    final visible = _updates.where((row) => _matches(row.track)).toList();
    return Column(children: [
      if (_subscriptions.isNotEmpty && MediaQuery.sizeOf(context).height >= 500) _subscriptionStrip(),
      if (_updates.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Align(alignment: Alignment.centerLeft, child: Text('当前 API 返回的最近 ${_updates.length} 条更新'))),
      _sectionState(0, () => _loadUpdates(reset: true)),
      if (_subscriptions.isEmpty) _sectionState(1, () => _loadSubscriptions(reset: true)),
      Expanded(child: visible.isEmpty && !_moreUpdates ? _empty(_signedIn ? '暂无更新' : '登录后查看订阅更新') :
        _dated<UpdateItem>(visible, (row) => row.publishedAt, (row) => _trackTile(row.track,
          position: _position(row.track), play: () => _act(() => _runtime.player.playUpdates(
            visible.map((item) => item.track).toList(), row.track.id))),
          footer: _moreUpdates ? Padding(padding: const EdgeInsets.all(16), child: Center(child: OutlinedButton(
            onPressed: _busy[0] ? null : () => _loadUpdates(), child: const Text('加载更多更新')))) : null)),
    ]);
  }

  Widget _subscriptionsTab() {
    final items = _subscriptions.where((row) => _query.isEmpty ||
      '${row.album.title} ${row.latestTitle} ${row.album.artist}'.toLowerCase().contains(_query)).toList();
    return Column(children: [
      _sectionState(1, () => _loadSubscriptions(reset: true)),
      Expanded(child: items.isEmpty && !_moreSubscriptions ? _empty(_signedIn ? '暂无订阅' : '登录后查看订阅') :
        _dated<SubscriptionItem>(items, (row) => row.updatedAt, (row) => ListTile(
          leading: CoverImage(uri: row.album.coverUrl, size: 60),
          title: Text(row.album.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(row.latestTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: row.unreadCount > 0 ? Badge(label: Text('${row.unreadCount}'),
            child: const Icon(Icons.chevron_right)) : const Icon(Icons.chevron_right),
          onTap: () => _openAlbum(row.album.id)), footer: _moreSubscriptions ? Padding(
            padding: const EdgeInsets.all(16), child: Center(child: OutlinedButton(
              onPressed: _busy[1] ? null : () => _loadSubscriptions(), child: const Text('加载更多订阅')))) : null)),
    ]);
  }

  Widget _historyTab() {
    final rows = _history();
    return Column(children: [
      _sectionState(2, _loadHistory),
      Expanded(child: rows.isEmpty ? _empty('暂无收听记录') : _dated<_ListeningRecord>(rows,
        (row) => row.updatedAt, (row) => _trackTile(row.track, position: row.position,
          play: () => _act(() => _runtime.player.playTrack(row.track, resumePosition: row.position))))),
    ]);
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(length: 4, child: Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(16, 8, 8, 8), child: Row(children: [
      Expanded(child: TextField(controller: _search, onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(hintText: '搜索更新、订阅和历史', prefixIcon: Icon(Icons.search)))),
      IconButton(tooltip: '收藏与书签', icon: const Icon(Icons.bookmarks_outlined), onPressed: () =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('本地书架')), body: LibraryPage(runtime: _runtime,
            onDownload: widget.onDownload, onPlayAlbum: widget.onPlayAlbum))))),
      IconButton(tooltip: '刷新收听列表', icon: const Icon(Icons.refresh), onPressed: _signedIn ? _refresh : null),
    ])),
    const TabBar(isScrollable: true, tabAlignment: TabAlignment.start,
      tabs: [Tab(text: '听更新'), Tab(text: '订阅'), Tab(text: '历史'), Tab(text: '下载')]),
    if (_acting) const LinearProgressIndicator(),
    Expanded(child: TabBarView(children: [
      _updatesTab(), _subscriptionsTab(), _historyTab(),
      DownloadPage(service: _runtime.downloads, onPause: _runtime.pauseDownload,
        onCancel: _runtime.cancelDownload, onStop: _runtime.player.stopTaskReference,
        onPauseAll: _runtime.pauseAllDownloads, onReacquire: _runtime.reacquireDownload,
        onRelocate: _runtime.relocateDownload),
    ])),
  ]));

  @override
  void dispose() {
    ++_accountEpoch;
    _runtime.removeListener(_runtimeChanged);
    _search.dispose();
    super.dispose();
  }
}

class _ListeningRecord {
  const _ListeningRecord(this.track, this.position, this.updatedAt);
  final Track track;
  final double position;
  final int updatedAt;
}
