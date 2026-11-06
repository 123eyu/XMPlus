import 'dart:io';

import 'package:flutter/material.dart';

import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import '../services/download_service.dart';
import 'catalogue_page.dart' show AlbumPlayback;
import 'player_panel.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({required this.runtime, required this.onDownload, required this.onPlayAlbum, super.key});
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

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try { await action(); }
    on XmlyException catch (error) { if (mounted) setState(() => _error = error.message); }
    catch (_) { if (mounted) setState(() => _error = '操作未完成，请重试'); }
    finally {
      if (mounted) setState(() { _busy = false; _fileChecks.clear(); });
    }
  }

  Future<bool> _confirm(String title) async => await showDialog<bool>(context: context,
    builder: (context) => AlertDialog(title: Text(title), actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
    ])) == true;

  bool _matches(Track track) => _query.isEmpty ||
      '${track.title} ${track.album} ${track.artist} ${track.id}'.toLowerCase().contains(_query.toLowerCase());

  Track? _track(Object? raw) {
    if (raw is! Map) return null;
    try { return Track.fromJson(Map<String, dynamic>.from(raw)); }
    on XmlyException { return null; }
    on FormatException { return null; }
  }

  Widget _empty(String text) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(text)));

  Widget _cover(Track track) => track.coverUrl == null ? const Icon(Icons.album_outlined) :
      Image.network(track.coverUrl.toString(), width: 48, height: 48, fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const Icon(Icons.album_outlined));

  Future<void> _play(Track track, {double? position}) => _run(() => position != null || track.albumId.isEmpty
      ? _runtime.player.playTrack(track, resumePosition: position)
      : widget.onPlayAlbum(track.albumId, track.id, track: track));

  Widget _actions(Track track, {double? position, VoidCallback? remove}) => Wrap(spacing: 2, children: [
    IconButton(tooltip: '播放', onPressed: _busy ? null : () => _play(track, position: position), icon: const Icon(Icons.play_arrow)),
    IconButton(tooltip: '加入播放队列', onPressed: _busy ? null : () => _run(() => _runtime.player.addToQueue(track)),
      icon: const Icon(Icons.playlist_add)),
    IconButton(tooltip: '下载', onPressed: _busy ? null : () => _run(() => widget.onDownload([track])), icon: const Icon(Icons.download_outlined)),
    if (remove != null) IconButton(tooltip: '移除', onPressed: _busy ? null : remove, icon: const Icon(Icons.delete_outline)),
  ]);

  Widget _downloaded(List<DownloadTask> tasks) {
    final filtered = tasks.where((task) => _matches(task.track)).toList();
    if (filtered.isEmpty) return _empty(_query.isEmpty ? '暂无已下载声音' : '没有匹配的声音');
    return ListView.builder(itemCount: filtered.length, itemBuilder: (context, index) {
      final task = filtered[index];
      return FutureBuilder<bool>(future: _fileChecks.putIfAbsent('${task.id}:${task.finalPath}',
          () => task.finalPath == null ? Future.value(false) : File(task.finalPath!).exists()),
        builder: (context, snapshot) {
          final exists = snapshot.data;
          return ListTile(leading: _cover(task.track), title: Text(task.track.title.isEmpty ? task.track.id : task.track.title),
            subtitle: Text(exists == false ? '文件已移动或删除' : task.track.album),
            trailing: Wrap(children: [
              if (exists == true) IconButton(tooltip: '播放本地文件', icon: const Icon(Icons.play_arrow),
                onPressed: _busy ? null : () => _run(() => _runtime.player.playLocal(task.id))),
              if (exists == false) TextButton.icon(icon: const Icon(Icons.download_outlined), label: const Text('重新下载'),
                onPressed: _busy ? null : () async {
                  if (await _confirm('重新下载此声音？')) await _run(() => _runtime.downloads.retry(task.id));
                }),
              IconButton(tooltip: '在线播放', icon: const Icon(Icons.cloud_outlined),
                onPressed: _busy ? null : () => _run(() => _runtime.player.playOnline(task.track))),
            ]));
        });
    });
  }

  Widget _favorites(Map library) {
    final values = library['favorites'] as Map? ?? const {};
    final tracks = values.values.map(_track).whereType<Track>().where(_matches).toList();
    if (tracks.isEmpty) return _empty(_query.isEmpty ? '暂无收藏' : '没有匹配的收藏');
    return ListView.builder(itemCount: tracks.length, itemBuilder: (context, index) {
      final track = tracks[index];
      return ListTile(leading: _cover(track), title: Text(track.title.isEmpty ? track.id : track.title), subtitle: Text(track.album),
        trailing: _actions(track, remove: () async {
          if (await _confirm('取消收藏此声音？')) await _run(() => _runtime.player.removeFavorite(track.id));
        }));
    });
  }

  Widget _history(Map history) {
    final positions = history['positions'] as Map? ?? const {};
    final entries = positions.entries.where((entry) => entry.value is Map).toList()
      ..sort((a, b) => ((b.value as Map)['updatedAt'] ?? '').toString().compareTo(((a.value as Map)['updatedAt'] ?? '').toString()));
    final filtered = entries.where((entry) {
      final record = entry.value as Map;
      final track = _track(record['track']);
      return track == null ? _query.isEmpty || entry.key.toString().contains(_query) : _matches(track);
    }).toList();
    if (filtered.isEmpty) return _empty(_query.isEmpty ? '暂无收听记录' : '没有匹配的记录');
    return ListView.builder(itemCount: filtered.length, itemBuilder: (context, index) {
      final entry = filtered[index];
      final record = entry.value as Map;
      final track = _track(record['track']);
      final position = record['position'] is num ? (record['position'] as num).toDouble() : 0.0;
      return ListTile(leading: track == null ? const Icon(Icons.history) : _cover(track),
        title: Text(track == null ? entry.key.toString() : track.title.isEmpty ? track.id : track.title),
        subtitle: Text('${track?.album ?? ''} · ${playbackTime(position)}'),
        trailing: track != null ? _actions(track, position: position) :
          (record['albumId'] as String? ?? '').isEmpty ? const Text('声音资料缺失') :
            TextButton(onPressed: _busy ? null : () => _run(() => widget.onPlayAlbum(record['albumId'] as String, entry.key.toString())),
              child: const Text('继续收听')));
    });
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
    return ListView.builder(itemCount: indices.length, itemBuilder: (context, index) {
      final originalIndex = indices[index];
      final record = bookmarks[originalIndex] as Map;
      final track = _track(record['track'])!;
      final position = record['position'] is num ? (record['position'] as num).toDouble() : 0.0;
      return ListTile(leading: const Icon(Icons.bookmark_outline), title: Text(track.title.isEmpty ? track.id : track.title),
        subtitle: Text('${track.album} · ${playbackTime(position)}'),
        trailing: _actions(track, position: position, remove: () async {
          if (await _confirm('删除此书签？')) await _run(() => _runtime.player.removeBookmark(originalIndex));
        }));
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _runtime, builder: (context, _) {
    final identity = _runtime.player.libraryIdentity;
    final library = (_runtime.storage.state['library'] as Map)[identity] as Map? ?? const {};
    final history = (_runtime.storage.state['history'] as Map)[identity] as Map? ?? const {};
    final completed = _runtime.downloads.tasks.where((task) => task.accountIdentity == identity && task.state == DownloadState.completed).toList();
    final account = (_runtime.storage.state['accounts'] as Map)[identity] as Map?;
    return DefaultTabController(length: 4, child: Column(children: [
      if (_busy) const LinearProgressIndicator(),
      if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, key: const ValueKey('libraryError'))),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
        Expanded(child: Text(identity == 'anonymous' ? '未登录书架' : '账号 ${account?['uid'] ?? ''} 的书架')),
        IconButton(tooltip: '刷新本地文件', onPressed: () => setState(_fileChecks.clear), icon: const Icon(Icons.refresh)),
        TextButton.icon(icon: const Icon(Icons.history), label: const Text('继续上次收听'),
          onPressed: _busy || history['lastTrackId'] == null ? null : () => _run(_runtime.player.continueListening)),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: TextField(
        key: const ValueKey('librarySearch'), decoration: const InputDecoration(labelText: '搜索书架', prefixIcon: Icon(Icons.search)),
        onChanged: (value) => setState(() => _query = value.trim()))),
      const TabBar(isScrollable: true, tabs: [Tab(text: '已下载'), Tab(text: '收藏'), Tab(text: '历史'), Tab(text: '书签')]),
      Expanded(child: TabBarView(children: [_downloaded(completed), _favorites(library), _history(history), _bookmarks(library)])),
    ]));
  });
}
