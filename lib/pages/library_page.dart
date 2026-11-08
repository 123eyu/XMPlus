import 'dart:io';

import 'package:flutter/material.dart';

import '../common/widgets/adaptive_text.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import '../services/download_service.dart';
import 'catalogue_page.dart' show AlbumPlayback, CoverImage;
import 'player_panel.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    required this.runtime,
    required this.onDownload,
    required this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final Future<void> Function(List<Track>) onDownload;
  final AlbumPlayback onPlayAlbum;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _query = '';
  String? _error;
  bool _busy = false;
  final Map<String, Future<bool>> _fileChecks = {};
  AppRuntime get _runtime => widget.runtime;
  bool get compact => MediaQuery.sizeOf(context).width < 320;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on XmlyException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请重试');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _fileChecks.clear();
        });
    }
  }

  Future<bool> _confirm(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ==
      true;

  bool _matches(Track track) =>
      _query.isEmpty ||
      '${track.title} ${track.album} ${track.artist} ${track.id}'
          .toLowerCase()
          .contains(_query.toLowerCase());

  Track? _track(Object? raw) {
    if (raw is! Map) return null;
    try {
      return Track.fromJson(Map<String, dynamic>.from(raw));
    } on XmlyException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Widget _empty(String text) => Center(
    child: Padding(padding: const EdgeInsets.all(24), child: Text(text)),
  );

  Widget _cover(Track track) => CoverImage(uri: track.coverUrl, size: 48);

  Future<void> _play(Track track, {double? position}) => _run(
    () => position != null || track.albumId.isEmpty
        ? _runtime.player.playTrack(track, resumePosition: position)
        : widget.onPlayAlbum(track.albumId, track.id, track: track),
  );

  Widget _actions(Track track, {double? position, VoidCallback? remove}) =>
      PopupMenuButton<String>(
        tooltip: '声音操作',
        enabled: !_busy,
        onSelected: (value) {
          switch (value) {
            case 'play':
              _play(track, position: position);
              break;
            case 'queue':
              _run(() => _runtime.player.addToQueue(track));
              break;
            case 'download':
              _run(() => widget.onDownload([track]));
              break;
            case 'remove':
              remove?.call();
              break;
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'play', child: Text('播放')),
          const PopupMenuItem(value: 'queue', child: Text('加入播放队列')),
          const PopupMenuItem(value: 'download', child: Text('下载')),
          if (remove != null)
            const PopupMenuItem(value: 'remove', child: Text('移除')),
        ],
      );

  Widget _downloaded(List<DownloadTask> tasks) {
    final filtered = tasks.where((task) => _matches(task.track)).toList();
    if (filtered.isEmpty) return _empty(_query.isEmpty ? '暂无已下载声音' : '没有匹配的声音');
    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final task = filtered[index];
        return FutureBuilder<bool>(
          future: _fileChecks.putIfAbsent(
            '${task.id}:${task.finalPath}',
            () => task.finalPath == null
                ? Future.value(false)
                : File(task.finalPath!).exists(),
          ),
          builder: (context, snapshot) {
            final exists = snapshot.data;
            return ListTile(
              leading: compact ? null : _cover(task.track),
              title: AdaptiveText(
                task.track.title.isEmpty ? task.track.id : task.track.title,
              ),
              subtitle: exists == false
                  ? const Text('文件已移动或删除')
                  : AdaptiveText(task.track.album),
              onTap: _busy
                  ? null
                  : exists == true
                  ? () => _run(() => _runtime.player.playLocal(task.id))
                  : exists == false
                  ? () => _run(() => _runtime.player.playTrack(task.track))
                  : null,
              trailing: exists == true
                  ? IconButton(
                      tooltip: '播放本地文件',
                      icon: const Icon(Icons.play_arrow),
                      onPressed: _busy
                          ? null
                          : () =>
                                _run(() => _runtime.player.playLocal(task.id)),
                    )
                  : exists == false
                  ? PopupMenuButton<String>(
                      tooltip: '声音操作',
                      enabled: !_busy,
                      onSelected: (value) async {
                        if (value == 'play')
                          await _run(
                            () => _runtime.player.playTrack(task.track),
                          );
                        if (value == 'retry' && await _confirm('重新下载此声音？')) {
                          await _run(() => _runtime.downloads.retry(task.id));
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'play', child: Text('播放（优先缓存）')),
                        PopupMenuItem(value: 'retry', child: Text('重新下载')),
                      ],
                    )
                  : null,
            );
          },
        );
      },
    );
  }

  Widget _favorites(Map library) {
    final values = library['favorites'] as Map? ?? const {};
    final tracks = values.values
        .map(_track)
        .whereType<Track>()
        .where(_matches)
        .toList();
    if (tracks.isEmpty) return _empty(_query.isEmpty ? '暂无收藏' : '没有匹配的收藏');
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        return ListTile(
          leading: compact ? null : _cover(track),
          title: AdaptiveText(track.title.isEmpty ? track.id : track.title),
          subtitle: AdaptiveText(track.album),
          onTap: _busy ? null : () => _play(track),
          trailing: _actions(
            track,
            remove: () async {
              if (await _confirm('取消收藏此声音？'))
                await _run(() => _runtime.player.removeFavorite(track.id));
            },
          ),
        );
      },
    );
  }

  Widget _history(Map history) {
    final positions = history['positions'] as Map? ?? const {};
    final entries =
        positions.entries.where((entry) => entry.value is Map).toList()..sort(
          (a, b) => ((b.value as Map)['updatedAt'] ?? '').toString().compareTo(
            ((a.value as Map)['updatedAt'] ?? '').toString(),
          ),
        );
    final filtered = entries.where((entry) {
      final record = entry.value as Map;
      final track = _track(record['track']);
      return track == null
          ? _query.isEmpty || entry.key.toString().contains(_query)
          : _matches(track);
    }).toList();
    if (filtered.isEmpty) return _empty(_query.isEmpty ? '暂无收听记录' : '没有匹配的记录');
    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final entry = filtered[index];
        final record = entry.value as Map;
        final track = _track(record['track']);
        final position = record['position'] is num
            ? (record['position'] as num).toDouble()
            : 0.0;
        return ListTile(
          leading: compact
              ? null
              : (track == null ? const Icon(Icons.history) : _cover(track)),
          title: AdaptiveText(
            track == null
                ? entry.key.toString()
                : track.title.isEmpty
                ? track.id
                : track.title,
          ),
          subtitle: track == null
              ? Text('${playbackTime(position)} · 声音资料缺失')
              : AdaptiveText('${track.album} · ${playbackTime(position)}'),
          onTap: _busy || track == null
              ? null
              : () => _play(track, position: position),
          trailing: track != null
              ? _actions(track, position: position)
              : (record['albumId'] as String? ?? '').isEmpty
              ? null
              : IconButton(
                  tooltip: '继续收听',
                  icon: const Icon(Icons.play_arrow),
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => widget.onPlayAlbum(
                            record['albumId'] as String,
                            entry.key.toString(),
                          ),
                        ),
                ),
        );
      },
    );
  }

  Widget _bookmarks(Map library) {
    final bookmarks = library['bookmarks'] as List? ?? const [];
    final indices = <int>[];
    for (var i = 0; i < bookmarks.length; i++) {
      final record = bookmarks[i];
      if (record is Map) {
        final track = _track(record['track']);
        if (track != null && _matches(track)) indices.add(i);
      }
    }
    if (indices.isEmpty) return _empty(_query.isEmpty ? '暂无书签' : '没有匹配的书签');
    return ListView.builder(
      itemCount: indices.length,
      itemBuilder: (context, index) {
        final originalIndex = indices[index];
        final record = bookmarks[originalIndex] as Map;
        final track = _track(record['track'])!;
        final position = record['position'] is num
            ? (record['position'] as num).toDouble()
            : 0.0;
        return ListTile(
          leading: compact ? null : const Icon(Icons.bookmark_outline),
          title: AdaptiveText(track.title.isEmpty ? track.id : track.title),
          subtitle: AdaptiveText('${track.album} · ${playbackTime(position)}'),
          onTap: _busy ? null : () => _play(track, position: position),
          trailing: _actions(
            track,
            position: position,
            remove: () async {
              if (await _confirm('删除此书签？'))
                await _run(() => _runtime.player.removeBookmark(originalIndex));
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _runtime,
    builder: (context, _) {
      final identity = _runtime.player.libraryIdentity;
      final library =
          (_runtime.storage.state['library'] as Map)[identity] as Map? ??
          const {};
      final history =
          (_runtime.storage.state['history'] as Map)[identity] as Map? ??
          const {};
      final completed = _runtime.downloads.tasks
          .where(
            (task) =>
                task.accountIdentity == identity &&
                task.state == DownloadState.completed,
          )
          .toList();
      final account =
          (_runtime.storage.state['accounts'] as Map)[identity] as Map?;
      return DefaultTabController(
        length: 4,
        child: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: NestedScrollView(
                headerSliverBuilder: (context, innerBoxIsScrolled) => [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        if (_busy) const LinearProgressIndicator(),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              _error!,
                              key: const ValueKey('libraryError'),
                            ),
                          ),
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: compact ? 8 : 16,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: AdaptiveText(
                                  identity == 'anonymous'
                                      ? '未登录书架'
                                      : '账号 ${account?['uid'] ?? ''} 的书架',
                                ),
                              ),
                              IconButton(
                                tooltip: '刷新本地文件',
                                onPressed: () => setState(_fileChecks.clear),
                                icon: const Icon(Icons.refresh),
                              ),
                              IconButton(
                                icon: const Icon(Icons.history),
                                tooltip: '继续上次收听',
                                onPressed:
                                    _busy || history['lastTrackId'] == null
                                    ? null
                                    : () => _run(
                                        _runtime.player.continueListening,
                                      ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: compact ? 8 : 16,
                            vertical: 8,
                          ),
                          child: TextField(
                            key: const ValueKey('librarySearch'),
                            decoration: const InputDecoration(
                              labelText: '搜索书架',
                              prefixIcon: Icon(Icons.search),
                            ),
                            onChanged: (value) =>
                                setState(() => _query = value.trim()),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SliverToBoxAdapter(
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [
                        Tab(text: '已下载'),
                        Tab(text: '收藏'),
                        Tab(text: '历史'),
                        Tab(text: '书签'),
                      ],
                    ),
                  ),
                ],
                body: TabBarView(
                  children: [
                    _downloaded(completed),
                    _favorites(library),
                    _history(history),
                    _bookmarks(library),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
