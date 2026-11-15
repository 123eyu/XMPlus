import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import '../api/xmly_client.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/app_scrollbar.dart';
import '../models/xmly_models.dart';
import '../services/account_service.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import '../services/download_service.dart';
import 'download_page.dart'
    show DownloadPage, requestDownloads, requestAlbumDownloads;

class AlbumBulkDownloadPage extends StatefulWidget {
  const AlbumBulkDownloadPage({
    required this.runtime,
    required this.album,
    this.accountIdentity,
    super.key,
  });

  final AppRuntime runtime;
  final Album album;
  final String? accountIdentity;

  @override
  State<AlbumBulkDownloadPage> createState() => _AlbumBulkDownloadPageState();
}

class _AlbumBulkDownloadPageState extends State<AlbumBulkDownloadPage> {
  static const _pageSize = 200;
  static const _groupSize = _pageSize;
  static const _red = Color(0xfff14f50);
  final _scroll = ScrollController(keepScrollOffset: false);
  static const _centerKey = ValueKey('bulk-download-center');
  final _pages = <int, AlbumPage>{};
  final _requests = <int, Future<AlbumPage>>{};
  final _groups = <int, List<Track>>{};
  final _expanded = <int>{};
  final _groupHeaders = <(bool, int), GlobalKey>{};
  final _loadingGroups = <int>{};
  final _groupErrors = <int, String>{};
  bool _adjustingScroll = false;
  final _selected = <String, Track>{};
  final _selectedGroups = <int>{};
  final _excludedPositions = <int>{};
  Map<String, DownloadTask> _tasks = {};
  Map<String, String> _completedPaths = {};
  Map<String, int> _fileSizes = {};
  int _fileScan = 0;
  XmlyClient? _client;
  String _identity = 'anonymous', _clientKey = '';
  int _page = 1, _total = 0, _epoch = 0, _viewRequest = 0;
  int _firstPage = 1, _lastPage = 1;
  bool _loadingBefore = false, _loadingAfter = false;
  final _failedEdges = <int>{};
  bool? _retryBefore;
  bool _loading = false, _submitting = false, _pickerOpen = false;
  bool _initialPagePending = true;
  String? _error;

  bool get _blocked =>
      _submitting ||
      _loading ||
      _client == null ||
      widget.runtime.accounts.admissionPaused ||
      widget.runtime.closing ||
      widget.runtime.restoringBackup ||
      widget.runtime.restoreNeedsReload;

  XmlyClient _resolveClient() {
    final identity = widget.accountIdentity;
    if (identity == null) return widget.runtime.client;
    return identity == 'anonymous'
        ? widget.runtime.anonymous
        : widget.runtime.accounts.clientFor(identity);
  }

  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(_runtimeChanged);
    _bind();
  }

  @override
  void didUpdateWidget(covariant AlbumBulkDownloadPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.album.id != widget.album.id ||
        oldWidget.accountIdentity != widget.accountIdentity) {
      oldWidget.runtime.removeListener(_runtimeChanged);
      widget.runtime.addListener(_runtimeChanged);
      _bind();
    }
  }

  @override
  void dispose() {
    widget.runtime.removeListener(_runtimeChanged);
    _epoch++;
    _scroll.dispose();
    super.dispose();
  }

  void _bind({bool accountChanged = false}) {
    _epoch++;
    _viewRequest++;
    _pages.clear();
    _completedPaths = {};
    _fileSizes = {};
    _fileScan++;
    _requests.clear();
    _groups.clear();
    _selected.clear();
    _selectedGroups.clear();
    _excludedPositions.clear();
    _loadingGroups.clear();
    _groupErrors.clear();
    _expanded.clear();
    _groupHeaders.clear();
    _pickerOpen = false;
    _loading = false;
    _initialPagePending = true;
    _page = 1;
    _firstPage = _lastPage = 1;
    _loadingBefore = _loadingAfter = false;
    _failedEdges.clear();
    _retryBefore = null;
    _total = widget.album.total;
    _error = accountChanged ? '账号已变更，请重新选择下载声音' : null;
    try {
      _client = _resolveClient();
      _identity = _client!.identity;
      _clientKey = _client!.cacheIdentity;
      _refreshTasks();
    } catch (error, stack) {
      _client = null;
      _tasks = {};
      _error = _message(error);
      _record(error, stack);
    }
  }

  void _refreshTasks() {
    _tasks = {
      for (final task in widget.runtime.downloads.tasks)
        if (task.accountIdentity == _identity &&
            task.track.albumId == widget.album.id &&
            task.state != DownloadState.cancelled)
          task.track.id: task,
    };
    final paths = {
      for (final task in _tasks.values)
        if (task.state == DownloadState.completed &&
            !task.outputMissing &&
            !task.outputDeleted &&
            task.finalPath != null)
          task.track.id: task.finalPath!,
    };
    if (!mapEquals(paths, _completedPaths)) {
      _completedPaths = paths;
      unawaited(_readFileSizes(paths));
    }
  }

  Future<void> _readFileSizes(Map<String, String> paths) async {
    final scan = ++_fileScan, epoch = _epoch;
    final sizes = <String, int>{};
    for (final entry in paths.entries) {
      if (!mounted || epoch != _epoch || scan != _fileScan) return;
      try {
        final stat = await File(entry.value).stat();
        if (stat.type == FileSystemEntityType.file)
          sizes[entry.key] = stat.size;
      } on FileSystemException {
        // Unknown or missing local files have no size label, not a fake 0B.
      }
    }
    if (mounted && epoch == _epoch && scan == _fileScan) {
      setState(() => _fileSizes = sizes);
    }
  }

  void _runtimeChanged() {
    if (!mounted) return;
    try {
      final client = _resolveClient();
      if (!identical(client, _client) || client.cacheIdentity != _clientKey) {
        setState(() => _bind(accountChanged: true));
      } else {
        setState(_refreshTasks);
      }
    } catch (error, stack) {
      if (_client != null) {
        setState(() => _bind(accountChanged: true));
      } else if (_error == null) {
        _record(error, stack);
        setState(() => _error = _message(error));
      }
    }
  }

  int _position(Track track) => track.officialPosition ?? 0;

  Future<AlbumPage> _readPage(XmlyClient client, int page) async {
    final result = await client.album(
      widget.album.id,
      page: page,
      pageSize: _pageSize,
      ascending: true,
    );
    final first = (page - 1) * _pageSize + 1;
    final last = math.min(page * _pageSize, result.total);
    final positions = <int>{};
    final ids = <String>{};
    var previous = first - 1;
    if (result.album.id != widget.album.id ||
        result.page != page ||
        result.pageSize != _pageSize ||
        result.total < 0 ||
        result.tracks.length > math.max(0, last - first + 1)) {
      throw const XmlyException('incomplete_catalogue', '专辑分页不完整，请重试');
    }
    for (final track in result.tracks) {
      final position = _position(track);
      if (track.albumId != widget.album.id ||
          track.orderNo != position ||
          position <= previous ||
          position < first ||
          position > last ||
          !positions.add(position) ||
          !ids.add(track.id)) {
        throw const XmlyException('catalogue_changed', '声音序号不完整，请重试');
      }
      previous = position;
    }
    assert(positions.length == result.tracks.length);
    return result;
  }

  Future<AlbumPage> _fetchPage(int page) async {
    final cached = _pages[page];
    if (cached != null) return cached;
    final client = _client;
    if (client == null) {
      throw const XmlyException('account_changed', '账号已变更，请重试');
    }
    final epoch = _epoch;
    final pending = _requests.putIfAbsent(page, () => _readPage(client, page));
    try {
      final result = await pending;
      if (!mounted || epoch != _epoch) {
        throw const XmlyException('account_changed', '账号已变更，请重试');
      }
      if (!_pages.containsKey(page)) {
        final ids = result.tracks.map((track) => track.id).toSet();
        if (_pages.values.any(
          (loaded) =>
              loaded.total != result.total ||
              loaded.tracks.any((track) => ids.contains(track.id)),
        )) {
          throw const XmlyException('catalogue_changed', '专辑声音已变更，请重新选择');
        }
        _pages[page] = result;
        final tracks = result.tracks.toList()
          ..sort((a, b) => _position(a).compareTo(_position(b)));
        _groups[(page - 1) * _groupSize + 1] = tracks;
        for (final track in tracks) {
          if (_selected.containsKey(track.id)) _selected[track.id] = track;
        }
      }
      _total = result.total;
      return result;
    } finally {
      if (epoch == _epoch && identical(_requests[page], pending)) {
        _requests.remove(page);
      }
    }
  }

  Future<void> _loadPage(int page, {bool keepError = false}) async {
    if (_client == null) return;
    final epoch = _epoch, request = ++_viewRequest;
    setState(() {
      _page = _firstPage = _lastPage = page;
      _pickerOpen = false;
      _loading = true;
      _loadingBefore = _loadingAfter = false;
      _failedEdges.clear();
      _retryBefore = null;
      if (!keepError) _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    try {
      await _fetchPage(page);
      if (!mounted || epoch != _epoch || request != _viewRequest) return;
      setState(() => _loading = false);
    } catch (error, stack) {
      if (!mounted || epoch != _epoch || request != _viewRequest) return;
      _record(error, stack);
      setState(() {
        _loading = false;
        _error = _message(error);
      });
    }
  }

  Future<void> _loadAdjacent(bool before, {bool retry = false}) async {
    if (_blocked || (before ? _loadingBefore : _loadingAfter)) return;
    final page = before ? _firstPage - 1 : _lastPage + 1;
    if (page < 1 ||
        (page - 1) * _pageSize >= _total ||
        (!retry && _failedEdges.contains(page)))
      return;
    final epoch = _epoch, view = _viewRequest;
    setState(() {
      if (before) {
        _loadingBefore = true;
      } else {
        _loadingAfter = true;
      }
      _failedEdges.remove(page);
      if (retry) {
        _error = null;
        _retryBefore = null;
      }
    });
    try {
      await _fetchPage(page);
      if (!mounted || epoch != _epoch || view != _viewRequest) return;
      setState(() {
        if (before) {
          _firstPage = page;
        } else {
          _lastPage = page;
        }
      });
    } catch (error, stack) {
      if (!mounted || epoch != _epoch || view != _viewRequest) return;
      _record(error, stack);
      setState(() {
        _failedEdges.add(page);
        _retryBefore = before;
        _error = _message(error);
      });
    } finally {
      if (mounted && epoch == _epoch && view == _viewRequest) {
        setState(() {
          if (before) {
            _loadingBefore = false;
          } else {
            _loadingAfter = false;
          }
        });
      }
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || _blocked || _adjustingScroll) return false;
    final delta = switch (notification) {
      ScrollUpdateNotification() => notification.scrollDelta ?? 0,
      OverscrollNotification() => notification.overscroll,
      _ => 0.0,
    };
    if (delta < 0 && notification.metrics.extentBefore < 200) {
      unawaited(_loadAdjacent(true));
    } else if (delta > 0 && notification.metrics.extentAfter < 200) {
      unawaited(_loadAdjacent(false));
    }
    return false;
  }

  Widget _catalogueList({bool wide = false}) {
    return NotificationListener<ScrollNotification>(
      onNotification: wide ? null : _onScroll,
      child: AppScrollbar(
        controller: _scroll,
        child: CustomScrollView(
          key: ValueKey('$_epoch:$_viewRequest:$wide'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          center: wide ? null : _centerKey,
          slivers: [
            if (!wide)
              // Earlier pages grow upwards without shifting the anchor page.
              SliverList.builder(
                itemCount: _page - _firstPage,
                itemBuilder: (context, index) =>
                    _group((_page - index - 2) * _groupSize + 1),
              ),
            SliverList.builder(
              key: wide ? null : _centerKey,
              itemCount: wide
                  ? (_total + _groupSize - 1) ~/ _groupSize
                  : _lastPage - _page + 1,
              itemBuilder: (context, index) => _group(
                (wide ? index : _page + index - 1) * _groupSize + 1,
                wide: wide,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
          ],
        ),
      ),
    );
  }

  int _groupStart(int position) =>
      (position - 1) ~/ _groupSize * _groupSize + 1;

  int _groupCount(int start) =>
      _groups[start]?.length ??
      math.max(0, math.min(_groupSize, _total - start + 1));

  bool _isSelected(Track track) =>
      _selectedGroups.contains(_groupStart(_position(track)))
      ? !_excludedPositions.contains(_position(track))
      : _selected.containsKey(track.id);

  int _selectedInGroup(int start) {
    if (!_selectedGroups.contains(start)) {
      return _selected.values
          .where((track) => _groupStart(_position(track)) == start)
          .length;
    }
    final tracks = _groups[start];
    if (tracks != null) {
      return tracks
          .where((track) => !_excludedPositions.contains(_position(track)))
          .length;
    }
    return _groupCount(start) -
        _excludedPositions
            .where(
              (position) =>
                  position >= start && position < start + _groupCount(start),
            )
            .length;
  }

  int get _selectedCount =>
      _selectedGroups.fold<int>(
        0,
        (sum, start) => sum + _selectedInGroup(start),
      ) +
      _selected.values
          .where(
            (track) => !_selectedGroups.contains(_groupStart(_position(track))),
          )
          .length;

  void _toggleTrack(Track track) {
    if (_blocked) return;
    final position = _position(track);
    setState(() {
      if (_selectedGroups.contains(_groupStart(position))) {
        if (!_excludedPositions.add(position))
          _excludedPositions.remove(position);
      } else if (_selected.remove(track.id) == null) {
        _selected[track.id] = track;
      }
    });
  }

  void _toggleGroup(int start) {
    final count = _groupCount(start);
    if (_blocked || (count == 0 && !_selectedGroups.contains(start))) return;
    final selected = count == 0 || _selectedInGroup(start) == count;
    setState(() {
      _selected.removeWhere(
        (_, track) => _groupStart(_position(track)) == start,
      );
      _excludedPositions.removeWhere(
        (position) => _groupStart(position) == start,
      );
      if (selected) {
        _selectedGroups.remove(start);
      } else {
        _selectedGroups.add(start);
      }
    });
  }

  Future<void> _loadGroup(int start) async {
    final page = (start - 1) ~/ _pageSize + 1;
    if (_pages.containsKey(page) ||
        _loadingGroups.contains(start) ||
        _client == null)
      return;
    final epoch = _epoch;
    setState(() {
      _loadingGroups.add(start);
      _groupErrors.remove(start);
    });
    try {
      await _fetchPage(page);
    } catch (error, stack) {
      if (!mounted || epoch != _epoch) return;
      _record(error, stack);
      setState(() => _groupErrors[start] = _message(error));
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() => _loadingGroups.remove(start));
      }
    }
  }

  void _toggleExpanded(int start, {bool wide = false}) {
    final header = _groupHeaders[(wide, start)];
    final render = header?.currentContext?.findRenderObject();
    final top = render is RenderBox
        ? render.localToGlobal(Offset.zero).dy
        : null;
    final epoch = _epoch, view = _viewRequest;
    final viewport = _scroll.hasClients
        ? _scroll.position.viewportDimension
        : null;
    setState(() {
      if (!_expanded.add(start)) _expanded.remove(start);
    });
    if (_expanded.contains(start)) unawaited(_loadGroup(start));
    if (top == null) return;
    // Keep the tapped header anchored when either sliver direction changes size.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          epoch != _epoch ||
          view != _viewRequest ||
          !_scroll.hasClients ||
          _scroll.position.viewportDimension != viewport)
        return;
      final updated = header?.currentContext?.findRenderObject();
      if (updated is! RenderBox) return;
      final delta = updated.localToGlobal(Offset.zero).dy - top;
      if (delta.abs() < .5) return;
      _adjustingScroll = true;
      try {
        final position = _scroll.position;
        _scroll.jumpTo(
          (position.pixels + delta)
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble(),
        );
      } finally {
        _adjustingScroll = false;
      }
    });
  }

  Future<void> _chooseRange() async {
    if (_blocked || _total == 0) return;
    if (_selectedGroups.isNotEmpty || _selected.isNotEmpty) return _download();
    final epoch = _epoch;
    final start = TextEditingController(text: '${(_page - 1) * _pageSize + 1}');
    final end = TextEditingController(
      text: '${math.min(_page * _pageSize, _total)}',
    );
    final form = GlobalKey<FormState>();
    final range = await showDialog<({int start, int end})>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('下载选定范围声音'),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('按官方声音序号选择，包含起止集。也可返回列表勾选200集分段或单集。'),
              TextFormField(
                controller: start,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '起始集'),
                validator: (value) {
                  final number = int.tryParse(value?.trim() ?? '');
                  return number == null || number < 1 || number > _total
                      ? '请输入1到$_total之间的序号'
                      : null;
                },
              ),
              TextFormField(
                controller: end,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '结束集'),
                validator: (value) {
                  final first = int.tryParse(start.text.trim());
                  final last = int.tryParse(value?.trim() ?? '');
                  if (first == null ||
                      last == null ||
                      last < first ||
                      last > _total) {
                    return '结束集须不小于起始集且不超过$_total';
                  }
                  return last - first + 1 > 5000 ? '每批最多下载5000集' : null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, (
                  start: int.parse(start.text.trim()),
                  end: int.parse(end.text.trim()),
                ));
              }
            },
            child: const Text('下载此范围'),
          ),
        ],
      ),
    );
    start.dispose();
    end.dispose();
    if (range != null && mounted && epoch == _epoch) {
      await _download(range: range);
    }
  }

  Future<void> _download({
    bool wholeAlbum = false,
    ({int start, int end})? range,
  }) async {
    if (_blocked ||
        (!wholeAlbum &&
            range == null &&
            _selectedGroups.isEmpty &&
            _selected.isEmpty))
      return;
    final identity = _identity, epoch = _epoch, total = _total;
    final groups = _selectedGroups.toSet();
    final exclusions = _excludedPositions.toSet();
    final individuals = Map<String, Track>.of(_selected);
    final tracks = <Track>[];
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (wholeAlbum) {
        await requestAlbumDownloads(
          context,
          widget.runtime,
          widget.album.id,
          accountIdentity: identity,
        );
      } else {
        final pages = range != null
            ? <int>{
                for (
                  var page = (range.start - 1) ~/ _pageSize + 1;
                  page <= (range.end - 1) ~/ _pageSize + 1;
                  page++
                )
                  page,
              }
            : <int>{
                for (final start in groups) (start - 1) ~/ _pageSize + 1,
                for (final track in individuals.values)
                  (_position(track) - 1) ~/ _pageSize + 1,
              };
        final orderedPages = pages.toList()..sort();
        for (final page in orderedPages) {
          final result = await _fetchPage(page);
          if (!mounted || epoch != _epoch) return;
          if (result.total != total) {
            throw const XmlyException('catalogue_changed', '专辑声音已变更，请重新选择');
          }
          tracks.addAll(
            result.tracks.where((track) {
              final position = _position(track);
              if (range != null) {
                return position >= range.start && position <= range.end;
              }
              return groups.contains(_groupStart(position))
                  ? !exclusions.contains(position)
                  : individuals.containsKey(track.id) &&
                        _position(individuals[track.id]!) == position;
            }),
          );
        }
        final ids = tracks.map((track) => track.id).toSet();
        if (ids.length != tracks.length ||
            tracks.map(_position).toSet().length != tracks.length ||
            (range == null &&
                individuals.values.any((track) => !ids.contains(track.id)))) {
          throw const XmlyException('range_not_found', '部分声音序号不存在，请刷新后重试');
        }
        if (!mounted || epoch != _epoch) return;
        tracks.sort((a, b) => _position(a).compareTo(_position(b)));
        // Keep entitlement, quota, confirmation and deduplication in the
        // existing admission flow; catalogue flags are not authority.
        await requestDownloads(
          context,
          widget.runtime,
          tracks,
          accountIdentity: identity,
        );
      }
      if (!mounted || epoch != _epoch) return;
      setState(() {
        if (wholeAlbum || range == null) {
          _selected.clear();
          _selectedGroups.clear();
          _excludedPositions.clear();
        } else {
          for (final track in tracks) {
            _selected.remove(track.id);
          }
        }
        _refreshTasks();
      });
    } catch (error, stack) {
      if (!mounted || epoch != _epoch) return;
      _record(error, stack);
      setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _openDownloads() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: const AppHeader(title: Text('我的下载'), centerTitle: true),
          body: SafeArea(child: DownloadPage(runtime: widget.runtime)),
        ),
      ),
    );
  }

  int? _cachedBytes(Track track) {
    final task = _tasks[track.id];
    if (task == null || task.outputMissing || task.outputDeleted) return null;
    if (task.state == DownloadState.completed) return _fileSizes[track.id];
    return task.state == DownloadState.downloading && task.receivedBytes > 0
        ? task.receivedBytes
        : null;
  }

  Widget _cacheLabel(int bytes) {
    final value = bytes < 1024
        ? '${bytes}B'
        : bytes < 1024 * 1024
        ? '${(bytes / 1024).toStringAsFixed(1)}KB'
        : bytes < 1024 * 1024 * 1024
        ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB'
        : '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.folder_outlined, size: 14),
        const SizedBox(width: 3),
        Flexible(
          child: Text('已缓存 $value', style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  Widget _selection({
    required String label,
    required bool selected,
    bool partial = false,
    required VoidCallback? onPressed,
  }) {
    return Semantics(
      label: label,
      checked: selected,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        color: _red,
        icon: Icon(
          selected
              ? Icons.check_circle
              : partial
              ? Icons.remove_circle
              : Icons.radio_button_unchecked,
          color: selected || partial
              ? _red
              : Theme.of(context).colorScheme.outline.withValues(alpha: .55),
          size: 22,
        ),
      ),
    );
  }

  Widget _trackRow(Track track) {
    final selected = _isSelected(track);
    final cached = _cachedBytes(track);
    final task = _tasks[track.id];
    final downloaded =
        task?.state == DownloadState.completed &&
        task?.outputMissing == false &&
        task?.outputDeleted == false;
    final hint = downloaded
        ? '已下载'
        : task != null
        ? '已在下载列表中'
        : null;
    return InkWell(
      onTap: _blocked ? null : () => _toggleTrack(track),
      child: Padding(
        padding: const EdgeInsets.only(left: 24, right: 8, top: 8, bottom: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              SizedBox(
                width: 42,
                child: Text(
                  '${_position(track)}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.title.isEmpty ? '声音 ${track.number}' : track.title,
                    ),
                    if (cached != null || hint != null) ...[
                      const SizedBox(height: 5),
                      DefaultTextStyle.merge(
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            if (cached != null) _cacheLabel(cached),
                            if (hint != null) Text(hint),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _selection(
                label: '${selected ? '取消选择' : '选择'}第${_position(track)}集',
                selected: selected,
                onPressed: _blocked ? null : () => _toggleTrack(track),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _group(int start, {bool wide = false}) {
    final tracks = _groups[start] ?? const <Track>[];
    final end = math.min(start + _groupSize - 1, _total);
    final expanded = _expanded.contains(start);
    final count = _selectedInGroup(start);
    final selected =
        count == _groupCount(start) &&
        (count > 0 || _selectedGroups.contains(start));
    final cached = tracks.fold<int>(
      0,
      (sum, track) => sum + (_cachedBytes(track) ?? 0),
    );
    final title = '第${start}集 – 第${end}集';
    final inlineCache =
        MediaQuery.sizeOf(context).width >= 400 &&
        MediaQuery.textScalerOf(context).scale(17) <= 22;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          key: _groupHeaders.putIfAbsent((wide, start), GlobalKey.new),
          constraints: const BoxConstraints(minHeight: 68),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: _blocked
                      ? null
                      : () => _toggleExpanded(start, wide: wide),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 22,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          expanded ? Icons.expand_more : Icons.chevron_right,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(title, style: const TextStyle(fontSize: 17)),
                              if (cached > 0 && !inlineCache) ...[
                                const SizedBox(height: 5),
                                DefaultTextStyle.merge(
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outline,
                                  ),
                                  child: _cacheLabel(cached),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (cached > 0 && inlineCache)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 128),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    child: _cacheLabel(cached),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _selection(
                  label: '${selected ? '取消选择' : '选择'}$title',
                  selected: selected,
                  partial: count > 0 && !selected,
                  onPressed: _blocked ? null : () => _toggleGroup(start),
                ),
              ),
            ],
          ),
        ),
        Divider(
          height: 1,
          indent: 46,
          color: Theme.of(context).dividerColor.withValues(alpha: .12),
        ),
        if (expanded) ...[
          if (_loadingGroups.contains(start))
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_groupErrors[start] case final error?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(child: Text(error)),
                  TextButton(
                    onPressed: _blocked ? null : () => _loadGroup(start),
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          else
            ...tracks.map(_trackRow),
        ],
      ],
    );
  }

  Widget _rangeGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final columns = (constraints.maxWidth / (90 * scale)).floor().clamp(
          1,
          4,
        );
        return AppScrollbar(
          child: GridView.builder(
            primary: false,
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              mainAxisExtent: math.max(36, 20 * scale + 16),
            ),
            itemCount: (_total + _pageSize - 1) ~/ _pageSize,
            itemBuilder: (context, index) {
              final page = index + 1;
              final active = page == _page;
              return TextButton(
                onPressed: _blocked ? null : () => _loadPage(page),
                style: TextButton.styleFrom(
                  foregroundColor: active
                      ? _red
                      : Theme.of(context).colorScheme.onSurface,
                  backgroundColor: active
                      ? _red.withValues(alpha: .09)
                      : Theme.of(context).colorScheme.surfaceContainerLow,
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                  ),
                ),
                child: Text(
                  '${index * _pageSize + 1}–${math.min(page * _pageSize, _total)}',
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _rangePicker(double availableHeight) {
    return Align(
      alignment: Alignment.topCenter,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: availableHeight * .68),
          child: _rangeGrid(),
        ),
      ),
    );
  }

  Widget _footer({bool wide = false}) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              OutlinedButton(
                onPressed: _blocked || _total == 0
                    ? null
                    : () => _download(wholeAlbum: true),
                child: const Text('下载整个专辑', textAlign: TextAlign.center),
              )
            else
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: _openDownloads,
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.onSurface,
                    ),
                    child: const Text('我的下载'),
                  ),
                  TextButton(
                    onPressed: _blocked || _total == 0
                        ? null
                        : () => _download(wholeAlbum: true),
                    child: const Text('下载整个专辑'),
                  ),
                ],
              ),
            if (wide) const SizedBox(height: 10),
            FilledButton(
              onPressed: _blocked || _total == 0 ? null : _chooseRange,
              style: FilledButton.styleFrom(
                backgroundColor: _red,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _red.withValues(alpha: .30),
                disabledForegroundColor: Colors.white,
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                shape: const StadiumBorder(),
              ),
              child: _submitting
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      _selectedCount == 0
                          ? '下载选定范围声音'
                          : '下载选定范围声音（$_selectedCount）',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rangeButton() {
    final first = (_firstPage - 1) * _pageSize + 1;
    final end = math.min(_lastPage * _pageSize, _total);
    return TextButton(
      onPressed: _blocked || _total == 0
          ? null
          : () => setState(() => _pickerOpen = !_pickerOpen),
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.outline,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(_total == 0 ? '选集' : '选集（$first–$end）')),
          Icon(_pickerOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down),
        ],
      ),
    );
  }

  Widget _errorBanner() {
    if (_error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          TextButton(
            onPressed:
                _submitting ||
                    _loading ||
                    widget.runtime.accounts.admissionPaused
                ? null
                : () {
                    if (_client == null) {
                      setState(() => _bind());
                    } else if (_retryBefore != null) {
                      _loadAdjacent(_retryBefore!, retry: true);
                    } else {
                      _loadPage(_page);
                    }
                  },
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _catalogueBody({bool wide = false}) {
    return Column(
      children: [
        SizedBox(
          height: 2,
          child: _loadingBefore || _loadingAfter
              ? const LinearProgressIndicator(minHeight: 2)
              : null,
        ),
        Expanded(
          child: wide && _total > 0
              ? _catalogueList(wide: true)
              : _loading
              ? const Center(child: CircularProgressIndicator())
              : !_pages.containsKey(_page)
              ? const Center(child: Text('尚未加载声音列表'))
              : _total == 0
              ? const Center(child: Text('此专辑暂无声音'))
              : _catalogueList(),
        ),
        if (!wide) _footer(),
      ],
    );
  }

  Widget _wideRail() {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        primary: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
                    child: Text(
                      '共$_total集',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      '已选择 $_selectedCount 集',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _openDownloads,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('我的下载'),
                  ),
                  _errorBanner(),
                ],
              ),
              _footer(wide: true),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: const AppHeader(title: Text('批量下载'), centerTitle: true),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >= 720 &&
              MediaQuery.orientationOf(context) == Orientation.landscape;
          if (!wide && _initialPagePending && _client != null) {
            _initialPagePending = false;
            if (!_pages.containsKey(_page)) {
              final epoch = _epoch;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && epoch == _epoch) {
                  unawaited(_loadPage(_page, keepError: _error != null));
                }
              });
            }
          }
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 1280 : 960),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _catalogueBody(wide: true)),
                        const VerticalDivider(width: 1),
                        SizedBox(width: 260, child: _wideRail()),
                      ],
                    )
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '共$_total集',
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outline,
                                  ),
                                ),
                              ),
                              Flexible(child: _rangeButton()),
                            ],
                          ),
                        ),
                        Divider(
                          height: 1,
                          color: Theme.of(context).dividerColor
                              .withValues(alpha: .12),
                        ),
                        _errorBanner(),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) => Stack(
                              children: [
                                _catalogueBody(),
                                if (_pickerOpen) ...[
                                  Positioned.fill(
                                    child: ModalBarrier(
                                      color: Colors.black.withValues(
                                        alpha: .68,
                                      ),
                                      dismissible: true,
                                      onDismiss: () =>
                                          setState(() => _pickerOpen = false),
                                      semanticsLabel: '关闭选集范围',
                                    ),
                                  ),
                                  _rangePicker(constraints.maxHeight),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }

  String _message(Object error) => switch (error) {
    XmlyException() => error.message,
    AccountException() => error.message,
    _ => '请求未完成，请稍后重试',
  };

  void _record(Object error, StackTrace stack) {
    if (AppLog.instance.errorWasRecorded(error)) return;
    AppLog.instance.write(
      error is XmlyException || error is AccountException
          ? AppLogLevel.warning
          : AppLogLevel.error,
      'album_bulk_download',
      'Bulk download action failed',
      error: error,
      stackTrace: stack,
    );
  }
}
