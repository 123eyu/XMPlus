import 'dart:async';

import 'package:flutter/material.dart';

import '../api/xmly_catalogue.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import 'download_page.dart' show setAlbumAutoDownload;
import 'media_settings_page.dart';
import 'playback_settings_page.dart';

typedef TrackDownload = Future<void> Function(List<Track> tracks);
typedef AlbumPlayback = Future<void> Function(String albumId, String trackId, {int? page, Track? track});

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({required this.runtime, this.onDownload, this.onPlayAlbum, super.key});
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
    setState(() { _loading = true; _error = null; });
    try {
      final result = await widget.runtime.client.search(_query.text, kind: _kind, page: page, pageSize: 30);
      if (mounted && generation == _generation) setState(() { _result = result; });
    } catch (error) {
      if (mounted && generation == _generation) setState(() { _error = _safeError(error); });
    } finally {
      if (mounted && generation == _generation) setState(() { _loading = false; });
    }
  }

  void _openAlbum(String id) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumPageView(
      runtime: widget.runtime, albumId: id, onDownload: widget.onDownload, onPlayAlbum: widget.onPlayAlbum,
    )));
  }

  @override
  void dispose() { _generation++; _query.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Column(children: [
      Padding(padding: const EdgeInsets.all(16), child: Row(children: [
        DropdownButton<String>(value: _kind, items: const [
          DropdownMenuItem(value: 'album', child: Text('专辑')),
          DropdownMenuItem(value: 'track', child: Text('声音')),
        ], onChanged: _loading ? null : (value) => setState(() { _kind = value!; _result = null; })),
        const SizedBox(width: 12),
        Expanded(child: TextField(controller: _query, maxLength: 200,
          decoration: const InputDecoration(labelText: '搜索', counterText: '', border: OutlineInputBorder()),
          onSubmitted: (_) => _search())),
        const SizedBox(width: 12),
        FilledButton(onPressed: _loading ? null : () => _search(), child: const Text('搜索')),
      ])),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
      Expanded(child: result == null
        ? const Center(child: Text('搜索专辑或声音'))
        : result.kind == 'album'
          ? Scrollbar(child: ListView.builder(itemCount: result.albums.length, itemBuilder: (_, index) {
              final album = result.albums[index];
              return ListTile(leading: CoverImage(uri: album.coverUrl), title: Text(album.title),
                subtitle: Text('${album.artist} · ${album.total} 集'), trailing: const Icon(Icons.chevron_right),
                onTap: () => _openAlbum(album.id));
            }))
          : Scrollbar(child: ListView.builder(itemCount: result.tracks.length, itemBuilder: (_, index) {
              final track = result.tracks[index];
              return ListTile(leading: CoverImage(uri: track.coverUrl), title: Text(track.title),
                subtitle: Text('${track.album} · ${_duration(track.duration)}'),
                onTap: track.albumId.isEmpty ? null : () => _openAlbum(track.albumId),
                trailing: IconButton(tooltip: '下载', icon: const Icon(Icons.download_outlined),
                  onPressed: widget.onDownload == null ? null : () => widget.onDownload!([track])));
            }))),
      if (result != null) _Paging(page: result.page, total: result.total, pageSize: result.pageSize,
        busy: _loading, onPage: _search),
    ]);
  }
}

class AlbumPageView extends StatefulWidget {
  const AlbumPageView({required this.runtime, required this.albumId, this.onDownload, this.onPlayAlbum, super.key});
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
  final _selected = <String>{};
  Album? _album;
  List<Track> _visible = [];
  List<Track>? _complete;
  int _page = 1, _total = 0, _generation = 0;
  bool _busy = false;
  bool _autoBusy = false;
  String? _error;
  String _filter = '';
  static const _pageSize = xmlyAlbumPageSize;

  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(_runtimeChanged);
    _loadPage(1);
    _scanUpdates();
  }
  @override
  void dispose() {
    widget.runtime.removeListener(_runtimeChanged);
    _generation++; _search.dispose(); _range.dispose(); super.dispose();
  }

  void _runtimeChanged() { if (mounted) setState(() {}); }

  void _scanUpdates() {
    for (final identity in widget.runtime.accounts.accountIds) {
      unawaited(widget.runtime.autoDownloads.scanAlbum(identity, widget.albumId));
    }
  }

  Future<void> _autoDownload(String identity) async {
    setState(() { _autoBusy = true; _error = null; });
    try {
      await setAlbumAutoDownload(context, widget.runtime.autoDownloads, identity,
          widget.albumId, _album?.title ?? '');
    } catch (error) {
      if (mounted) setState(() { _error = _safeError(error); });
    } finally {
      if (mounted) setState(() { _autoBusy = false; });
    }
  }

  Future<void> _loadPage(int page) async {
    final generation = ++_generation;
    setState(() { _busy = true; _error = null; });
    try {
      if (_filter.isNotEmpty && _complete != null) {
        final filtered = _complete!.where((track) => track.title.toLowerCase().contains(_filter.toLowerCase())).toList();
        if (mounted && generation == _generation) setState(() {
          _page = page; _total = filtered.length;
          _visible = filtered.skip((page - 1) * _pageSize).take(_pageSize).toList();
        });
      } else {
        final result = await widget.runtime.client.album(widget.albumId, page: page, pageSize: _pageSize);
        if (mounted && generation == _generation) setState(() {
          _album = result.album; _page = page; _total = result.total; _visible = result.tracks;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) setState(() { _error = _safeError(error); });
    } finally {
      if (mounted && generation == _generation) setState(() { _busy = false; });
    }
  }

  Future<List<Track>> _all() async => _complete ??= await XmlyCatalogue(widget.runtime.client).album(widget.albumId);

  Future<void> _filterAll() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      if (_search.text.trim().isNotEmpty) await _all();
      _filter = _search.text.trim();
    } catch (error) {
      if (mounted) setState(() { _error = _safeError(error); });
      return;
    } finally {
      if (mounted) setState(() { _busy = false; });
    }
    if (mounted) await _loadPage(1);
  }

  Future<void> _download({bool all = false}) async {
    if (_busy || widget.onDownload == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      final tracks = await _all();
      final chosen = all ? tracks : _range.text.trim().isNotEmpty
          ? XmlyCatalogue.selectRange(tracks, _range.text)
          : tracks.where((track) => _selected.contains(track.id)).toList();
      if (chosen.isEmpty) throw const XmlyException('empty_selection', '请先选择声音或填写集数范围');
      if (mounted) await widget.onDownload!(chosen);
    } catch (error) {
      if (mounted) setState(() { _error = _safeError(error); });
    } finally {
      if (mounted) setState(() { _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = _album;
    final identity = widget.runtime.accounts.primaryAccountId;
    final automatic = widget.runtime.autoDownloads;
    return Scaffold(appBar: AppBar(title: Text(album?.title.isNotEmpty == true ? album!.title : '专辑 ${widget.albumId}'), actions: [
      IconButton(tooltip: '专辑标签', icon: const Icon(Icons.edit_note), onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => AlbumTagsPage(runtime: widget.runtime, albumId: widget.albumId, albumTitle: album?.title ?? '')))),
      IconButton(tooltip: '播放设置', icon: const Icon(Icons.headphones_outlined), onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => PlaybackSettingsPage(runtime: widget.runtime, albumId: widget.albumId, albumTitle: album?.title)))), 
    ]),
      body: Column(children: [
        if (album != null) Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          CoverImage(uri: album.coverUrl ?? (_visible.isEmpty ? null : _visible.first.coverUrl), size: 88),
          const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(album.title, style: Theme.of(context).textTheme.titleLarge),
            Text('${album.artist} · ${album.total} 集'),
            if (album.intro.isNotEmpty) Text(album.intro, maxLines: 3, overflow: TextOverflow.ellipsis),
          ])),
        ])),
        SwitchListTile(title: const Text('自动下载新声音'),
          subtitle: Text(identity == null ? '登录后可开启' : '仅下载开启后新增的声音，使用主账号正常扣时'),
          value: identity != null && automatic.enabled(identity, widget.albumId),
          onChanged: identity == null || _autoBusy ? null : (_) => _autoDownload(identity)),
        if (identity != null && automatic.errorFor(identity, widget.albumId) != null)
          ListTile(title: Text(automatic.errorFor(identity, widget.albumId)!),
            trailing: TextButton(onPressed: _scanUpdates, child: const Text('重新检查'))),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
          Expanded(child: TextField(controller: _search, decoration: const InputDecoration(labelText: '搜索本专辑全部声音'), onSubmitted: (_) => _filterAll())),
          TextButton(onPressed: _busy ? null : _filterAll, child: const Text('搜索')),
        ])),
        Padding(padding: const EdgeInsets.all(16), child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 220, child: TextField(controller: _range, decoration: const InputDecoration(labelText: '集数范围', hintText: '1-1000 或 1,3,5-8', border: OutlineInputBorder()))),
          FilledButton(onPressed: _busy || widget.onDownload == null ? null : () => _download(), child: Text('下载所选 (${_selected.length})')),
          OutlinedButton(onPressed: _busy || widget.onDownload == null ? null : () => _download(all: true), child: const Text('下载整个专辑')),
          TextButton(onPressed: _busy ? null : () => setState(() { _selected.addAll(_visible.map((track) => track.id)); }), child: const Text('选择本页')),
          TextButton(onPressed: () => setState(_selected.clear), child: const Text('清除选择')),
        ])),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        Expanded(child: Scrollbar(child: ListView.builder(itemCount: _visible.length, itemBuilder: (_, index) {
          final track = _visible[index];
          return CheckboxListTile(value: _selected.contains(track.id),
            onChanged: (selected) => setState(() { selected == true ? _selected.add(track.id) : _selected.remove(track.id); }),
            title: Text(track.title), subtitle: Text('${_duration(track.duration)}${track.isPaid == true ? ' · 需核验权限' : ''}'),
            secondary: IconButton(tooltip: '播放', icon: const Icon(Icons.play_arrow),
              onPressed: widget.onPlayAlbum == null ? null : () => widget.onPlayAlbum!(widget.albumId, track.id,
                page: _filter.isEmpty ? _page : track.officialPosition == null ? null : (track.officialPosition! - 1) ~/ _pageSize + 1,
                track: track)));
        }))),
        _Paging(page: _page, total: _total, pageSize: _pageSize, busy: _busy, onPage: _loadPage),
      ]));
  }
}

class CoverImage extends StatelessWidget {
  const CoverImage({required this.uri, this.size = 52, super.key});
  final Uri? uri;
  final double size;
  @override
  Widget build(BuildContext context) => ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(
    width: size, height: size, child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: uri == null ? const Icon(Icons.album_outlined) : Image.network(uri.toString(),
        fit: BoxFit.cover, frameBuilder: (_, child, frame, synchronous) => frame != null || synchronous
          ? child : const Icon(Icons.album_outlined),
        errorBuilder: (_, _, _) => const Icon(Icons.album_outlined)))));
}

class _Paging extends StatelessWidget {
  const _Paging({required this.page, required this.total, required this.pageSize, required this.busy, required this.onPage});
  final int page, total, pageSize;
  final bool busy;
  final Future<void> Function(int) onPage;

  Future<void> _jumpToPage(BuildContext context) async {
    final last = (total / pageSize).ceil().clamp(1, 10000);
    final form = GlobalKey<FormState>();
    var selected = page;
    final target = await showDialog<int>(context: context, builder: (context) {
      void submit() {
        if (!form.currentState!.validate()) return;
        form.currentState!.save();
        Navigator.of(context).pop(selected);
      }
      return AlertDialog(title: const Text('跳转页码'), content: Form(key: form,
        child: TextFormField(initialValue: '$page', autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: '页码', helperText: '请输入 1–$last 页'),
          validator: (value) {
            if (value == null || !RegExp(r'^[0-9]+$').hasMatch(value)) return '请输入数字页码';
            final number = int.tryParse(value);
            if (number == null || number < 1 || number > last) return '页码须在 1–$last 之间';
            return null;
          },
          onSaved: (value) => selected = int.parse(value!),
          onFieldSubmitted: (_) => submit())), actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: submit, child: const Text('跳转')),
      ]);
    });
    if (target != null && context.mounted && !busy) await onPage(target);
  }
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(12), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
    IconButton(tooltip: '上一页', onPressed: busy || page <= 1 ? null : () => onPage(page - 1), icon: const Icon(Icons.chevron_left)),
    TextButton(onPressed: busy ? null : () => _jumpToPage(context),
      child: Text('第 $page / ${(total / pageSize).ceil().clamp(1, 10000)} 页 · 共 $total 项')),
    IconButton(tooltip: '下一页', onPressed: busy || page * pageSize >= total ? null : () => onPage(page + 1), icon: const Icon(Icons.chevron_right)),
  ]));
}

String _duration(double seconds) => '${seconds ~/ 60}:${(seconds.toInt() % 60).toString().padLeft(2, '0')}';
String _safeError(Object error) => error is XmlyException ? error.message : '请求未完成，请稍后重试';
