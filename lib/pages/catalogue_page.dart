import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;

import 'package:flutter/material.dart';

import '../api/xmly_catalogue.dart';
import '../common/widgets/adaptive_text.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import '../services/download_service.dart';
import 'download_page.dart'
    show deleteDownloadedAudio, requestDownloads, setAlbumAutoDownload;
import 'media_settings_page.dart';
import 'playback_settings_page.dart';

typedef TrackDownload = Future<void> Function(List<Track> tracks);
typedef AlbumPlayback = Future<void> Function(
  String albumId,
  String trackId, {
  int? page,
  Track? track,
});

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({
    required this.runtime,
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;
  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  final _query = TextEditingController();
  String _kind = 'album';
  SearchPage? _result;
  String? _error;
  bool _loading = false;
  int _generation = 0;

  Future<void> _search([int page = 1]) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.runtime.client.search(
        _query.text,
        kind: _kind,
        page: page,
        pageSize: 30,
      );
      if (mounted && generation == _generation)
        setState(() {
          _result = result;
        });
    } catch (error) {
      if (mounted && generation == _generation)
        setState(() {
          _error = _safeError(error);
        });
    } finally {
      if (mounted && generation == _generation)
        setState(() {
          _loading = false;
        });
    }
  }

  void _openAlbum(String id) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AlbumPageView(
          runtime: widget.runtime,
          albumId: id,
          onDownload: widget.onDownload,
          onPlayAlbum: widget.onPlayAlbum,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Scrollbar(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(
                    MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _query,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          labelText: '搜索专辑或声音',
                          counterText: '',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onSubmitted: (_) => _search(),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButton<String>(
                              value: _kind,
                              isExpanded: true,
                              items: const [
                                DropdownMenuItem(
                                  value: 'album',
                                  child: Text('专辑'),
                                ),
                                DropdownMenuItem(
                                  value: 'track',
                                  child: Text('声音'),
                                ),
                              ],
                              onChanged: _loading
                                  ? null
                                  : (value) => setState(() {
                                      _kind = value!;
                                      _result = null;
                                    }),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton(
                            onPressed: _loading ? null : () => _search(),
                            child: const Text('搜索'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (_loading)
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
              if (_error != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!),
                  ),
                ),
              if (result == null)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('搜索专辑或声音')),
                )
              else if (result.kind == 'album')
                SliverList.builder(
                  itemCount: result.albums.length,
                  itemBuilder: (context, index) {
                    final album = result.albums[index];
                    return ListTile(
                      leading: MediaQuery.sizeOf(context).width < 320
                          ? null
                          : CoverImage(uri: album.coverUrl),
                      title: AdaptiveText(album.title),
                      subtitle: AdaptiveText(
                        '${album.artist} · ${album.total} 集',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openAlbum(album.id),
                    );
                  },
                )
              else
                SliverList.builder(
                  itemCount: result.tracks.length,
                  itemBuilder: (context, index) {
                    final track = result.tracks[index];
                    return ListTile(
                      leading: MediaQuery.sizeOf(context).width < 320
                          ? null
                          : CoverImage(uri: track.coverUrl),
                      title: AdaptiveText(track.title),
                      subtitle: AdaptiveText(
                        '${track.album} · ${_duration(track.duration)}',
                      ),
                      onTap: track.albumId.isEmpty
                          ? null
                          : () => _openAlbum(track.albumId),
                      trailing: IconButton(
                        tooltip: '下载',
                        icon: const Icon(Icons.download_outlined),
                        onPressed: widget.onDownload == null
                            ? null
                            : () => widget.onDownload!([track]),
                      ),
                    );
                  },
                ),
              if (result != null)
                SliverToBoxAdapter(
                  child: _Paging(
                    page: result.page,
                    total: result.total,
                    pageSize: result.pageSize,
                    busy: _loading,
                    onPage: _search,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AlbumPageView extends StatefulWidget {
  const AlbumPageView({
    required this.runtime,
    required this.albumId,
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final String albumId;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;
  @override
  State<AlbumPageView> createState() => _AlbumPageViewState();
}

class _AlbumPageViewState extends State<AlbumPageView> {
  final _search = TextEditingController();
  final _range = TextEditingController();
  final _selected = <String, Track>{};
  final _fileChecks = <String, Future<DownloadTask?>>{};
  List<DownloadTask> _observedDownloads = [];
  Object? _observedCache;
  Album? _album;
  List<Track> _visible = [];
  List<Track>? _complete;
  int _page = 1, _total = 0, _generation = 0;
  bool _busy = false, _autoBusy = false, _offline = false;
  bool _showSearch = false, _selectionMode = false, _cachedView = false;
  String? _error;
  String _filter = '';
  static const _pageSize = xmlyAlbumPageSize;

  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(_runtimeChanged);
    _restoreCache();
    _loadPage(1);
    _scanUpdates();
  }

  @override
  void dispose() {
    widget.runtime.removeListener(_runtimeChanged);
    _generation++;
    _search.dispose();
    _range.dispose();
    super.dispose();
  }

  void _runtimeChanged() {
    if (!mounted) return;
    final downloads = widget.runtime.downloads.tasks;
    final cached = widget.runtime.albumCache[widget.albumId];
    setState(() {
      if (!listEquals(downloads, _observedDownloads) ||
          !identical(cached, _observedCache)) {
        _observedDownloads = downloads;
        _observedCache = cached;
        _fileChecks.clear();
        if (_cachedView) _showCached(_page);
      }
    });
  }

  List<Track> _cachedTracks() {
    final cached = widget.runtime.albumCache[widget.albumId];
    final tracks = <String, Track>{
      for (final track in cached?.tracks ?? <Track>[]) track.id: track,
    };
    for (final task in widget.runtime.downloads.tasks) {
      if (task.track.albumId == widget.albumId) {
        tracks.putIfAbsent(task.track.id, () => task.track);
      }
    }
    return tracks.values.toList()..sort(
      (a, b) => (a.officialPosition ?? a.orderNo ?? 5001).compareTo(
        b.officialPosition ?? b.orderNo ?? 5001,
      ),
    );
  }

  void _restoreCache() {
    final cached = widget.runtime.albumCache[widget.albumId];
    final tracks = _cachedTracks();
    if (cached == null && tracks.isEmpty) return;
    _album =
        cached?.album ??
        Album(
          id: widget.albumId,
          title: tracks.first.album,
          artist: tracks.first.artist,
          coverUrl: tracks.first.coverUrl,
        );
    _showCached(1);
  }

  void _showCached(int page) {
    _cachedView = true;
    final tracks = _cachedTracks()
        .where(
          (track) => track.title.toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();
    _total = tracks.length;
    _page = page.clamp(
      1,
      ((_total + _pageSize - 1) ~/ _pageSize).clamp(1, 10000),
    );
    _visible = tracks.skip((_page - 1) * _pageSize).take(_pageSize).toList();
  }

  Future<DownloadTask?> _localDownload(Track track) async {
    final tasks = widget.runtime.downloads.tasks
        .where(
          (task) =>
              task.track.id == track.id &&
              task.state == DownloadState.completed,
        )
        .toList();
    tasks.sort(
      (a, b) =>
          (b.accountIdentity == widget.runtime.player.libraryIdentity ? 1 : 0)
              .compareTo(
                a.accountIdentity == widget.runtime.player.libraryIdentity
                    ? 1
                    : 0,
              ),
    );
    for (final task in tasks) {
      if (task.finalPath != null && await File(task.finalPath!).exists())
        return task;
    }
    return null;
  }

  void _select(Track track, bool selected) {
    if (selected) {
      _selected[track.id] = track;
    } else {
      _selected.remove(track.id);
    }
  }

  void _clearSelection() {
    _selected.clear();
    _range.clear();
    _selectionMode = false;
  }

  bool _favorite(Track track) {
    final library =
        (widget.runtime.storage.state['library']
                as Map?)?[widget.runtime.player.libraryIdentity]
            as Map?;
    return (library?['favorites'] as Map?)?.containsKey(track.id) == true;
  }

  void _scanUpdates() {
    for (final identity in widget.runtime.accounts.accountIds) {
      unawaited(
        widget.runtime.autoDownloads.scanAlbum(identity, widget.albumId),
      );
    }
  }

  Future<void> _autoDownload(String identity) async {
    setState(() {
      _autoBusy = true;
      _error = null;
    });
    try {
      await setAlbumAutoDownload(
        context,
        widget.runtime.autoDownloads,
        identity,
        widget.albumId,
        _album?.title ?? '',
      );
    } catch (error) {
      if (mounted) setState(() => _error = _safeError(error));
    } finally {
      if (mounted) setState(() => _autoBusy = false);
    }
  }

  Future<void> _loadPage(int page) async {
    if (_offline) {
      setState(() => _showCached(page));
      return;
    }
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_filter.isNotEmpty && _complete != null) {
        final filtered = _complete!
            .where(
              (track) =>
                  track.title.toLowerCase().contains(_filter.toLowerCase()),
            )
            .toList();
        if (mounted && generation == _generation) {
          setState(() {
            _page = page;
            _total = filtered.length;
            _visible = filtered
                .skip((page - 1) * _pageSize)
                .take(_pageSize)
                .toList();
          });
        }
      } else {
        final result = await widget.runtime.client.album(
          widget.albumId,
          page: page,
          pageSize: _pageSize,
        );
        try {
          await widget.runtime.albumCache.remember(result);
        } catch (_) {
          // Cache metadata and artwork are nonessential to the live request.
        }
        if (mounted && generation == _generation) {
          setState(() {
            _offline = false;
            _cachedView = false;
            _album = result.album;
            _page = page;
            _total = result.total;
            _visible = result.tracks;
          });
        }
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _restoreCache();
          _offline = _album != null;
          _error = _offline ? null : _safeError(error);
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<List<Track>> _all() async {
    if (_complete != null) return _complete!;
    if (_offline) {
      throw const XmlyException('offline_catalogue', '离线目录不完整，无法按完整专辑下载');
    }
    final tracks = await XmlyCatalogue(widget.runtime.client)
        .album(widget.albumId);
    _complete = tracks;
    return tracks;
  }

  Future<void> _filterAll() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_offline) {
        _filter = _search.text.trim();
        setState(() => _showCached(1));
        return;
      }
      if (_search.text.trim().isNotEmpty) await _all();
      _filter = _search.text.trim();
    } catch (error) {
      if (mounted) setState(() => _error = _safeError(error));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _loadPage(1);
  }

  Future<void> _download({bool all = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final tracks = all
          ? await _all()
          : _range.text.trim().isNotEmpty
          ? XmlyCatalogue.selectRange(await _all(), _range.text)
          : _selected.values.toList();
      if (tracks.isEmpty)
        throw const XmlyException('empty_selection', '请先选择声音或填写集数范围');
      if (!mounted) return;
      await requestDownloads(context, widget.runtime, tracks);
    } catch (error) {
      if (mounted) setState(() => _error = _safeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _play(Track track) async {
    final task = await _localDownload(track);
    if (!mounted) return;
    if (task != null) {
      await widget.runtime.player.playLocal(task.id);
      return;
    }
    if (_offline)
      throw const XmlyException('offline_playback', '此声音本地文件不存在，请重新下载后播放');
    if (widget.onPlayAlbum != null) {
      final position = track.officialPosition;
      await widget.onPlayAlbum!(
        widget.albumId,
        track.id,
        page: position == null
            ? (_filter.isEmpty ? _page : null)
            : (position - 1) ~/ _pageSize + 1,
        track: track,
      );
    } else {
      await widget.runtime.player.playAlbum(
        widget.albumId,
        track.id,
        track: track,
      );
    }
  }

  Future<void> _trackAction(Track track, String action) async {
    switch (action) {
      case 'play':
        await _play(track);
      case 'queue':
        await widget.runtime.player.addToQueue(track);
      case 'download':
        await requestDownloads(context, widget.runtime, [track]);
      case 'delete':
        final task = await _localDownload(track);
        if (mounted &&
            task != null &&
            await deleteDownloadedAudio(context, widget.runtime, task)) {
          _fileChecks.remove(track.id);
        }
      case 'favorite':
        await widget.runtime.player.toggleFavorite(track);
    }
    if (mounted) setState(() {});
  }

  Widget _menu(Track track) => FutureBuilder<DownloadTask?>(
    future: _fileChecks.putIfAbsent(track.id, () => _localDownload(track)),
    builder: (context, snapshot) => PopupMenuButton<String>(
      tooltip: '声音操作',
      enabled: !_busy,
      onSelected: (value) => unawaited(
        _trackAction(track, value).catchError((error) {
          if (mounted) setState(() => _error = _safeError(error));
        }),
      ),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'play', child: Text('播放')),
        const PopupMenuItem(value: 'queue', child: Text('加入播放队列')),
        if (snapshot.data == null)
          const PopupMenuItem(value: 'download', child: Text('下载'))
        else
          const PopupMenuItem(value: 'delete', child: Text('删除已下载文件')),
        PopupMenuItem(
          value: 'favorite',
          child: Text(_favorite(track) ? '取消收藏' : '收藏'),
        ),
      ],
    ),
  );

  void _albumAction(String action) {
    switch (action) {
      case 'refresh':
        _offline = false;
        _filter = '';
        _search.clear();
        _loadPage(1);
      case 'tags':
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AlbumTagsPage(
              runtime: widget.runtime,
              albumId: widget.albumId,
              albumTitle: _album?.title ?? '',
            ),
          ),
        );
      case 'settings':
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PlaybackSettingsPage(
              runtime: widget.runtime,
              albumId: widget.albumId,
              albumTitle: _album?.title,
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = _album;
    final identity = widget.runtime.accounts.primaryAccountId;
    final automatic = widget.runtime.autoDownloads;
    final compact = MediaQuery.sizeOf(context).width < 320;
    final canDownload = !_busy && !widget.runtime.accounts.admissionPaused;
    return Scaffold(
      appBar: AppBar(
        title: AdaptiveText(
          album?.title.isNotEmpty == true
              ? album!.title
              : '专辑 ${widget.albumId}',
        ),
        actions: [
          if (!compact && _offline)
            IconButton(
              tooltip: '刷新专辑',
              icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : () => _albumAction('refresh'),
            ),
          IconButton(
            tooltip: _showSearch ? '隐藏搜索' : '搜索本专辑',
            icon: Icon(_showSearch ? Icons.search_off : Icons.search),
            onPressed: () => setState(() => _showSearch = !_showSearch),
          ),
          if (compact)
            PopupMenuButton<String>(
              tooltip: '更多操作',
              onSelected: _albumAction,
              itemBuilder: (_) => [
                if (_offline)
                  PopupMenuItem(
                    value: 'refresh',
                    enabled: !_busy,
                    child: const Text('刷新专辑'),
                  ),
                const PopupMenuItem(value: 'tags', child: Text('专辑标签')),
                const PopupMenuItem(value: 'settings', child: Text('播放设置')),
              ],
            )
          else ...[
            IconButton(
              tooltip: '专辑标签',
              icon: const Icon(Icons.edit_note),
              onPressed: () => _albumAction('tags'),
            ),
            IconButton(
              tooltip: '播放设置',
              icon: const Icon(Icons.headphones_outlined),
              onPressed: () => _albumAction('settings'),
            ),
          ],
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Scrollbar(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        if (album != null)
                          Padding(
                            padding: EdgeInsets.all(compact ? 8 : 16),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!compact)
                                  CoverImage(
                                    uri:
                                        album.coverUrl ??
                                        (_visible.isEmpty
                                            ? null
                                            : _visible.first.coverUrl),
                                    localPath: widget
                                        .runtime
                                        .albumCache[widget.albumId]
                                        ?.coverPath,
                                    size: 88,
                                  ),
                                if (!compact) const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      AdaptiveText(
                                        album.title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge,
                                      ),
                                      AdaptiveText(
                                        '${album.artist} · ${album.total} 集',
                                      ),
                                      if (album.intro.isNotEmpty)
                                        Text(
                                          album.intro,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      if (_cachedView)
                                        const Text('离线缓存（仅显示已观察目录与已下载声音）'),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        SwitchListTile(
                          title: const Text('自动下载新声音'),
                          subtitle: Text(
                            identity == null
                                ? '登录后可开启'
                                : '仅下载开启后新增的声音，使用主账号正常扣时',
                          ),
                          value:
                              identity != null &&
                              automatic.enabled(identity, widget.albumId),
                          onChanged: identity == null || _autoBusy
                              ? null
                              : (_) => _autoDownload(identity),
                        ),
                        if (identity != null &&
                            automatic.errorFor(identity, widget.albumId) !=
                                null)
                          Padding(
                            padding: EdgeInsets.all(compact ? 8 : 16),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    automatic.errorFor(
                                      identity,
                                      widget.albumId,
                                    )!,
                                  ),
                                ),
                                TextButton(
                                  onPressed: _scanUpdates,
                                  child: const Text('重新检查'),
                                ),
                              ],
                            ),
                          ),
                        if (_showSearch)
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: compact ? 8 : 16,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _search,
                                    decoration: InputDecoration(
                                      labelText: _offline
                                          ? '搜索已缓存声音'
                                          : '搜索本专辑全部声音',
                                    ),
                                    onSubmitted: (_) => _filterAll(),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '搜索本专辑',
                                  onPressed: _busy ? null : _filterAll,
                                  icon: const Icon(Icons.search),
                                ),
                              ],
                            ),
                          ),
                        Padding(
                          padding: EdgeInsets.all(compact ? 8 : 16),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: canDownload
                                    ? () => _download(all: true)
                                    : null,
                                icon: const Icon(
                                  Icons.download_for_offline_outlined,
                                ),
                                label: const Text('下载整个专辑'),
                              ),
                              if (_selectionMode) ...[
                                SizedBox(
                                  width:
                                      (MediaQuery.sizeOf(context).width -
                                              (compact ? 16 : 32))
                                          .clamp(0.0, 240.0)
                                          .toDouble(),
                                  child: TextField(
                                    controller: _range,
                                    decoration: const InputDecoration(
                                      labelText: '集数范围',
                                      hintText: '1-1000 或 1,3,5-8',
                                    ),
                                  ),
                                ),
                                FilledButton(
                                  onPressed: canDownload
                                      ? () => _download()
                                      : null,
                                  child: Text('下载所选 (${_selected.length})'),
                                ),
                                TextButton(
                                  onPressed: () => setState(
                                    () => _selected.addEntries(
                                      _visible.map(
                                        (track) => MapEntry(track.id, track),
                                      ),
                                    ),
                                  ),
                                  child: const Text('选择本页'),
                                ),
                                TextButton(
                                  onPressed: () => setState(_clearSelection),
                                  child: const Text('清除选择'),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (_busy) const LinearProgressIndicator(),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SliverList.builder(
                    itemCount: _visible.length,
                    itemBuilder: (_, index) {
                      final track = _visible[index];
                      return ListTile(
                        leading: _selectionMode
                            ? Checkbox(
                                value: _selected.containsKey(track.id),
                                onChanged: (value) => setState(
                                  () => _select(track, value == true),
                                ),
                              )
                            : (compact
                                  ? null
                                  : CoverImage(
                                      uri: track.coverUrl ?? album?.coverUrl,
                                      localPath: widget
                                          .runtime
                                          .albumCache[widget.albumId]
                                          ?.coverPath,
                                    )),
                        title: AdaptiveText(track.title),
                        subtitle: Text(_duration(track.duration)),
                        trailing: _menu(track),
                        onLongPress: () => setState(() {
                          _selectionMode = true;
                          _selected[track.id] = track;
                        }),
                        onTap: _selectionMode
                            ? () => setState(
                                () => _select(
                                  track,
                                  !_selected.containsKey(track.id),
                                ),
                              )
                            : () => unawaited(
                                _play(track).catchError((error) {
                                  if (mounted)
                                    setState(() => _error = _safeError(error));
                                }),
                              ),
                      );
                    },
                  ),
                  SliverToBoxAdapter(
                    child: _Paging(
                      page: _page,
                      total: _total,
                      pageSize: _pageSize,
                      busy: _busy,
                      onPage: _loadPage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CoverImage extends StatelessWidget {
  const CoverImage({
    required this.uri,
    this.localPath,
    this.size = 52,
    super.key,
  });
  final String? localPath;
  final Uri? uri;
  final double size;
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 320) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size,
        height: size,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: localPath != null
              ? Image.file(
                  File(localPath!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(Icons.album_outlined),
                )
              : uri == null
              ? const Icon(Icons.album_outlined)
              : Image.network(
                  uri.toString(),
                  fit: BoxFit.cover,
                  frameBuilder: (_, child, frame, synchronous) =>
                      frame != null || synchronous
                      ? child
                      : const Icon(Icons.album_outlined),
                  errorBuilder: (_, _, _) => const Icon(Icons.album_outlined),
                ),
        ),
      ),
    );
  }
}

class _Paging extends StatelessWidget {
  const _Paging({
    required this.page,
    required this.total,
    required this.pageSize,
    required this.busy,
    required this.onPage,
  });
  final int page, total, pageSize;
  final bool busy;
  final Future<void> Function(int) onPage;

  Future<void> _jumpToPage(BuildContext context) async {
    final last = (total / pageSize).ceil().clamp(1, 10000);
    final form = GlobalKey<FormState>();
    var selected = page;
    final target = await showDialog<int>(
      context: context,
      builder: (context) {
        void submit() {
          if (!form.currentState!.validate()) return;
          form.currentState!.save();
          Navigator.of(context).pop(selected);
        }

        return AlertDialog(
          title: const Text('跳转页码'),
          content: Form(
            key: form,
            child: TextFormField(
              initialValue: '$page',
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '页码',
                helperText: '请输入 1–$last 页',
              ),
              validator: (value) {
                if (value == null || !RegExp(r'^[0-9]+$').hasMatch(value))
                  return '请输入数字页码';
                final number = int.tryParse(value);
                if (number == null || number < 1 || number > last)
                  return '页码须在 1–$last 之间';
                return null;
              },
              onSaved: (value) => selected = int.parse(value!),
              onFieldSubmitted: (_) => submit(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(onPressed: submit, child: const Text('跳转')),
          ],
        );
      },
    );
    if (target != null && context.mounted && !busy) await onPage(target);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        IconButton(
          tooltip: '上一页',
          onPressed: busy || page <= 1 ? null : () => onPage(page - 1),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: TextButton(
            onPressed: busy ? null : () => _jumpToPage(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AdaptiveText(
                  '第 $page / ${(total / pageSize).ceil().clamp(1, 10000)} 页',
                ),
                AdaptiveText(
                  '共 $total 项',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: '下一页',
          onPressed: busy || page * pageSize >= total
              ? null
              : () => onPage(page + 1),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  );
}

String _duration(double seconds) =>
    '${seconds ~/ 60}:${(seconds.toInt() % 60).toString().padLeft(2, '0')}';
String _safeError(Object error) =>
    error is XmlyException ? error.message : '请求未完成，请稍后重试';
