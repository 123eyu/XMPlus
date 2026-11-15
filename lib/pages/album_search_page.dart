import 'dart:async';

import 'package:flutter/material.dart';

import '../api/xmly_client.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/app_scrollbar.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart' show CoverImage, TrackDownload;
import 'download_page.dart' show requestDownloads;

class AlbumSearchPage extends StatefulWidget {
  const AlbumSearchPage({
    required this.runtime,
    required this.album,
    this.accountIdentity,
    this.onDownload,
    super.key,
  });

  final AppRuntime runtime;
  final Album album;
  final String? accountIdentity;
  final TrackDownload? onDownload;

  @override
  State<AlbumSearchPage> createState() {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::AlbumSearchPage.createState",
    );
    return _AlbumSearchPageState();
  }
}

class _AlbumSearchPageState extends State<AlbumSearchPage> {
  static const _pageSize = 10;
  final _query = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _tracks = <Track>[];
  Timer? _debounce;
  Completer<void>? _cancelled;
  late XmlyClient _observedClient;
  late String _observedKey;
  String _lastInput = '', _submitted = '';
  String? _error, _workingTrack;
  bool _composing = false, _loading = false, _hasMore = false;
  int _generation = 0, _page = 0, _failedPage = 1;

  XmlyClient get _client {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._client.get",
    );
    final identity = widget.accountIdentity;
    if (identity == null) return widget.runtime.client;
    return widget.runtime.accounts.accountIds.contains(identity)
        ? widget.runtime.accounts.clientFor(identity)
        : widget.runtime.anonymous;
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState.initState",
    );
    super.initState();
    _observedClient = _client;
    _observedKey = _client.cacheIdentity;
    widget.runtime.addListener(_runtimeChanged);
    _query.addListener(_queryChanged);
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void didUpdateWidget(covariant AlbumSearchPage oldWidget) {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState.didUpdateWidget",
    );
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_runtimeChanged);
      widget.runtime.addListener(_runtimeChanged);
    }
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.album.id != widget.album.id ||
        oldWidget.accountIdentity != widget.accountIdentity) {
      _observedClient = _client;
      _observedKey = _client.cacheIdentity;
      if (oldWidget.album.id != widget.album.id) _query.clear();
      _queryChanged(force: true);
    }
  }

  void _cancel() {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._cancel",
    );
    _debounce?.cancel();
    _debounce = null;
    _cancelled?.complete();
    _cancelled = null;
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState.dispose",
    );
    _generation++;
    _cancel();
    widget.runtime.removeListener(_runtimeChanged);
    _query.removeListener(_queryChanged);
    _query.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _runtimeChanged() {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._runtimeChanged",
    );
    if (!mounted) return;
    final client = _client;
    if (identical(client, _observedClient) &&
        client.cacheIdentity == _observedKey)
      return;
    _observedClient = client;
    _observedKey = client.cacheIdentity;
    _queryChanged(force: true);
  }

  void _queryChanged({bool force = false}) {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._queryChanged",
    );
    if (!mounted) return;
    final value = _query.value;
    final composing = value.composing.isValid && !value.composing.isCollapsed;
    if (!force && value.text == _lastInput && composing == _composing) return;
    _lastInput = value.text;
    _composing = composing;
    _generation++;
    _cancel();
    setState(() {
      AppLog.instance.trace(
        "lib/pages/album_search_page.dart::_AlbumSearchPageState._queryChanged.closure#1",
      );
      _tracks.clear();
      _submitted = '';
      _page = 0;
      _loading = false;
      _hasMore = false;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (!composing && value.text.trim().isNotEmpty) {
      _debounce = Timer(const Duration(milliseconds: 350), _submit);
    }
  }

  void _submit() {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._submit",
    );
    _debounce?.cancel();
    _debounce = null;
    final value = _query.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    final query = value.text.trim();
    if (query.isEmpty || _loading || (_submitted == query && _page > 0)) return;
    if (value.text.length > 200) {
      setState(() {
        AppLog.instance.trace(
          "lib/pages/album_search_page.dart::_AlbumSearchPageState._submit.closure#1",
        );
        _error = '搜索词请控制在200字以内';
      });
      return;
    }
    _submitted = query;
    unawaited(_load(1));
  }

  bool _active(XmlyClient client, String key, int generation, String albumId) {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._active",
    );
    return mounted &&
        generation == _generation &&
        widget.album.id == albumId &&
        identical(client, _client) &&
        key == _client.cacheIdentity;
  }

  Future<void> _load(int page) async {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._load",
    );
    if (_loading || _submitted.isEmpty || _composing) return;
    final generation = _generation, albumId = widget.album.id;
    final client = _client, key = client.cacheIdentity, query = _submitted;
    final cancelled = _cancelled = Completer<void>();
    setState(() {
      AppLog.instance.trace(
        "lib/pages/album_search_page.dart::_AlbumSearchPageState._load.closure#1",
      );
      _loading = true;
      _error = null;
      _failedPage = page;
    });
    try {
      final result = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            "lib/pages/album_search_page.dart::_AlbumSearchPageState._load.closure#2",
          );
          return client.searchAlbum(
            albumId,
            query,
            page: page,
            pageSize: _pageSize,
          );
        },
        rateLimitRetries: 0,
        cancelled: cancelled.future,
      );
      if (!_active(client, key, generation, albumId)) return;
      final known = _tracks.map((track) {
        AppLog.instance.trace(
          "lib/pages/album_search_page.dart::_AlbumSearchPageState._load.closure#3",
        );
        return track.id;
      }).toSet();
      final totalPages = result.totalPages;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/album_search_page.dart::_AlbumSearchPageState._load.closure#4",
        );
        _tracks.addAll(
          result.tracks.where((track) {
            AppLog.instance.trace(
              "lib/pages/album_search_page.dart::_AlbumSearchPageState._load.closure#4.closure#1",
            );
            return known.add(track.id);
          }),
        );
        _page = result.page;
        _hasMore =
            result.tracks.isNotEmpty &&
            (totalPages == null
                ? result.page * result.pageSize < result.total
                : result.page < totalPages);
      });
    } catch (error, stack) {
      if (!_active(client, key, generation, albumId)) return;
      if (!AppLog.instance.errorWasRecorded(error)) {
        AppLog.instance.write(
          AppLogLevel.warning,
          'album_search',
          'Album search failed',
          error: error,
          stackTrace: stack,
          promptUser: false,
        );
      }
      setState(() {
        AppLog.instance.trace(
          "lib/pages/album_search_page.dart::_AlbumSearchPageState._load.closure#5",
        );
        _error = error is XmlyException ? error.message : '搜索暂时不可用，请重试';
      });
    } finally {
      if (identical(_cancelled, cancelled)) _cancelled = null;
      if (_active(client, key, generation, albumId)) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/album_search_page.dart::_AlbumSearchPageState._load.closure#6",
          );
          _loading = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          AppLog.instance.trace(
            "lib/pages/album_search_page.dart::_AlbumSearchPageState._load.closure#7",
          );
          if (_active(client, key, generation, albumId)) _maybeLoadMore();
        });
      }
    }
  }

  void _maybeLoadMore() {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._maybeLoadMore",
    );
    if (!_scroll.hasClients ||
        _loading ||
        !_hasMore ||
        _error != null ||
        _composing)
      return;
    if (_scroll.position.extentAfter < 300) unawaited(_load(_page + 1));
  }

  Future<void> _act(Track track, String action) async {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._act",
    );
    if (_workingTrack != null) return;
    final client = _client, key = client.cacheIdentity;
    final generation = _generation, albumId = widget.album.id;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/album_search_page.dart::_AlbumSearchPageState._act.closure#1",
      );
      _workingTrack = track.id;
    });
    try {
      switch (action) {
        case 'play':
          final player = widget.runtime.player;
          if (player.current?.id == track.id &&
              player.playbackIdentity == client.identity &&
              player.sourceKind.isNotEmpty) {
            if (!player.playing) await player.resume();
          } else {
            await player.playAlbum(
              albumId,
              track.id,
              track: track,
              accountIdentity: client.identity,
            );
          }
        case 'download':
          if (widget.onDownload != null && widget.accountIdentity == null) {
            await widget.onDownload!([track]);
          } else {
            await requestDownloads(context, widget.runtime, [
              track,
            ], accountIdentity: client.identity);
          }
        case 'next':
          await widget.runtime.player.playNext(
            track,
            accountIdentity: client.identity,
          );
        case 'queue':
          await widget.runtime.player.addToQueue(
            track,
            accountIdentity: client.identity,
          );
      }
    } catch (error, stack) {
      if (!AppLog.instance.errorWasRecorded(error)) {
        AppLog.instance.write(
          AppLogLevel.warning,
          'album_search',
          'Search result action failed',
          error: error,
          stackTrace: stack,
          promptUser: false,
        );
      }
      if (_active(client, key, generation, albumId)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error is XmlyException ? error.message : '操作失败，请重试'),
          ),
        );
      }
    } finally {
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/album_search_page.dart::_AlbumSearchPageState._act.closure#2",
          );
          _workingTrack = null;
        });
    }
  }

  String _count(Object? value) {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._count",
    );
    if (value is! int || value < 0) return '';
    return value >= 10000 ? '${(value / 10000).toStringAsFixed(1)}万' : '$value';
  }

  String _duration(double value) {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._duration",
    );
    final seconds = value.toInt();
    final minutes = seconds ~/ 60;
    return '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String _date(Object? value) {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._date",
    );
    if (value is! int || value <= 0 || value > 8640000000000000) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(value);
    final elapsed = DateTime.now().difference(date);
    if (!elapsed.isNegative) {
      if (elapsed.inMinutes < 1) return '刚刚';
      if (elapsed.inHours < 1) return '${elapsed.inMinutes}分钟前';
      if (elapsed.inDays < 1) return '${elapsed.inHours}小时前';
      if (elapsed.inDays < 7) return '${elapsed.inDays}天前';
    }
    return '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Widget _metric(IconData icon, String value) {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._metric",
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: Colors.grey),
        const SizedBox(width: 3),
        Text(value, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  Widget _tile(Track track) {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._tile",
    );
    final date = _date(track.raw['date']);
    final plays = _count(track.raw['play']);
    final comments = _count(track.raw['count_comment']);
    return InkWell(
      onTap: _workingTrack == null
          ? () {
              AppLog.instance.trace(
                "lib/pages/album_search_page.dart::_AlbumSearchPageState._tile.closure#1",
              );
              _act(track, 'play');
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ClipOval(
                    child: CoverImage(
                      uri: track.coverUrl ?? widget.album.coverUrl,
                      size: 42,
                    ),
                  ),
                  const Icon(
                    Icons.play_arrow_rounded,
                    size: 23,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Container(
                padding: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context).dividerColor
                          .withValues(alpha: .15),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 4,
                          child: Text(
                            track.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17),
                          ),
                        ),
                        if (date.isNotEmpty)
                          Flexible(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8, top: 2),
                              child: Text(
                                date,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      track.album.isEmpty ? widget.album.title : track.album,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 6,
                            children: [
                              if (plays.isNotEmpty)
                                _metric(Icons.play_arrow_outlined, plays),
                              _metric(
                                Icons.schedule,
                                _duration(track.duration),
                              ),
                              if (comments.isNotEmpty)
                                _metric(Icons.chat_bubble_outline, comments),
                            ],
                          ),
                        ),
                        if (_workingTrack == track.id)
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        else
                          PopupMenuButton<String>(
                            tooltip: '声音操作',
                            enabled: _workingTrack == null,
                            onSelected: (action) {
                              AppLog.instance.trace(
                                "lib/pages/album_search_page.dart::_AlbumSearchPageState._tile.closure#2",
                              );
                              _act(track, action);
                            },
                            itemBuilder: (_) {
                              AppLog.instance.trace(
                                "lib/pages/album_search_page.dart::_AlbumSearchPageState._tile.closure#3",
                              );
                              return const [
                                PopupMenuItem(
                                  value: 'download',
                                  child: Text('下载声音'),
                                ),
                                PopupMenuItem(
                                  value: 'next',
                                  child: Text('下一首播放'),
                                ),
                                PopupMenuItem(
                                  value: 'queue',
                                  child: Text('加入播放队列'),
                                ),
                              ];
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tail() {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState._tail",
    );
    if (_loading)
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    if (_error != null)
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(_error!, textAlign: TextAlign.center),
            if (_submitted.isNotEmpty)
              TextButton(
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/pages/album_search_page.dart::_AlbumSearchPageState._tail.closure#1",
                  );
                  _load(_failedPage);
                },
                child: const Text('重试'),
              ),
          ],
        ),
      );
    if (_submitted.isNotEmpty && _tracks.isEmpty)
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: Text('没有找到相关声音')),
      );
    if (_hasMore)
      return TextButton(
        onPressed: () {
          AppLog.instance.trace(
            "lib/pages/album_search_page.dart::_AlbumSearchPageState._tail.closure#2",
          );
          _load(_page + 1);
        },
        child: const Text('加载更多'),
      );
    return const SizedBox(height: 24);
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/album_search_page.dart::_AlbumSearchPageState.build",
    );
    return Scaffold(
      appBar: AppHeader(
        toolbarHeight: 64,
        title: TextField(
          controller: _query,
          focusNode: _focus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          maxLength: 200,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            hintText: '搜索该专辑内的声音',
            counterText: '',
            filled: true,
            fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(30),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(30),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(30),
              borderSide: BorderSide.none,
            ),
            suffixIcon: _query.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除搜索',
                    onPressed: _query.clear,
                    icon: const Icon(Icons.close, size: 18),
                  ),
          ),
          onSubmitted: (_) {
            AppLog.instance.trace(
              "lib/pages/album_search_page.dart::_AlbumSearchPageState.build.closure#1",
            );
            return _submit();
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              AppLog.instance.trace(
                "lib/pages/album_search_page.dart::_AlbumSearchPageState.build.closure#2",
              );
              Navigator.of(context).maybePop();
            },
            child: const Text('取消'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: AppScrollbar(
              controller: _scroll,
              child: ListView.builder(
                controller: _scroll,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: _tracks.length + 1,
                itemBuilder: (_, index) {
                  AppLog.instance.trace(
                    "lib/pages/album_search_page.dart::_AlbumSearchPageState.build.closure#3",
                  );
                  return index == _tracks.length
                      ? _tail()
                      : _tile(_tracks[index]);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
