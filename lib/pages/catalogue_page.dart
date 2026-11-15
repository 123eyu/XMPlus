import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../common/widgets/app_scrollbar.dart';
import '../api/xmly_catalogue.dart';
import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../api/xmly_discovery.dart';
import '../common/widgets/content_paging.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/logged_network_image.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/local_panel.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import '../services/download_service.dart';
import 'album_introduction.dart';
import 'anchor_page.dart';
import 'download_page.dart'
    show
        deleteDownloadedAudio,
        requestAlbumDownloads,
        requestDownloads,
        setAlbumAutoDownload;
import 'media_settings_page.dart';
import 'playback_settings_page.dart';
import 'album_reviews_page.dart';

void _recordCatalogueError(
  String operation,
  Object error,
  StackTrace stack, {
  bool recoverable = false,
}) {
  AppLog.instance.trace("lib/pages/catalogue_page.dart::_recordCatalogueError");

  final log = AppLog.instance;
  if (log.errorWasRecorded(error)) return;
  final expected =
      error is XmlyException &&
      const {
        'client_closed',
        'request_cancelled',
        'cancelled',
        'download_stopped',
        'stopped',
        'closed',
        'login_required',
        'login_expired',
        'auth_required',
        'account_changed',
        'account_mismatch',
        'missing_account',
        'confirmation_required',
        'confirmation_changed',
        'insufficient_quota',
        'usage_uncertain',
        'rate_limited',
        'rejected',
        'permission_denied',
        'queue_full',
        'catalogue_limit',
        'invalid_id',
        'invalid_page',
        'invalid_episode',
        'invalid_range',
        'range_not_found',
        'ambiguous_episode',
        'episode_not_found',
        'empty_selection',
        'offline_catalogue',
        'offline_playback',
        'catalogue_changed',
        'track_position_missing',
        'batch_too_large',
        'task_busy',
        'original_account_required',
      }.contains(error.code);
  log.write(
    recoverable || expected ? AppLogLevel.warning : AppLogLevel.error,
    'catalogue_page',
    operation,
    data: error is XmlyException ? error.diagnostics : null,
    error: error,
    stackTrace: stack,
    promptUser: !recoverable && !expected,
  );
}

typedef TrackDownload = Future<void> Function(List<Track> tracks);
typedef AlbumPlayback = Future<void> Function(
  String albumId,
  String trackId, {
  int? page,
  Track? track,
});

int? _trackOrdinal(Track track) {
  AppLog.instance.trace("lib/pages/catalogue_page.dart::_trackOrdinal");
  return track.officialPosition ?? xmlyPositive(track.orderNo);
}

List<int> catalogueHintPages(
  CatalogueLocationHint hint, {
  required String albumId,
  required String trackId,
  required int total,
  int pageSize = xmlyAlbumPageSize,
}) {
  AppLog.instance.trace('lib/pages/catalogue_page.dart::catalogueHintPages');
  try {
    if (xmlyIdentifier(hint.albumId) != xmlyIdentifier(albumId) ||
        xmlyIdentifier(hint.trackId) != xmlyIdentifier(trackId))
      return const [];
  } on XmlyException {
    return const [];
  }
  if (hint.sort != 0 ||
      hint.page < 1 ||
      hint.pageSize < 1 ||
      hint.indexInList < 0 ||
      hint.indexInList >= hint.pageSize ||
      total < 1 ||
      pageSize < 1)
    return const [];
  final offset = hint.absoluteOffset;
  if (offset < 0 || offset >= total) return const [];
  return {
    offset ~/ pageSize + 1,
    (total - 1 - offset) ~/ pageSize + 1,
  }.toList();
}

bool cataloguePageContainsTarget(
  AlbumPage page,
  String albumId,
  String trackId,
) {
  AppLog.instance.trace(
    'lib/pages/catalogue_page.dart::cataloguePageContainsTarget',
  );
  return page.album.id == albumId &&
      page.tracks.any((track) {
        AppLog.instance.trace(
          'lib/pages/catalogue_page.dart::cataloguePageContainsTarget.closure#1',
        );
        return track.id == trackId && track.albumId == albumId;
      });
}

Future<AlbumPage> locateCatalogueTarget({
  required XmlyClient client,
  required String albumId,
  required Track target,
  required bool ascending,
  required bool Function() isCurrent,
}) async {
  AppLog.instance.trace('lib/pages/catalogue_page.dart::locateCatalogueTarget');
  const missing = XmlyException(
    'track_position_missing',
    '无法确定这集在专辑中的位置，请重新定位',
  );
  void check() {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::locateCatalogueTarget.check',
    );
    if (!isCurrent()) throw const XmlyException('request_cancelled', '请求已取消');
  }

  final pages = <int, AlbumPage>{};
  Future<AlbumPage> read(int page) async {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::locateCatalogueTarget.read',
    );
    check();
    final cached = pages[page];
    if (cached != null) return cached;
    final result = await client.album(
      albumId,
      page: page,
      pageSize: xmlyAlbumPageSize,
      ascending: ascending,
    );
    check();
    if (result.album.id != albumId || result.page != page) throw missing;
    pages[page] = result;
    return result;
  }

  Future<AlbumPage?> ordinalPage(Track track) async {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::locateCatalogueTarget.ordinalPage',
    );
    final ordinal = _trackOrdinal(track);
    if (track.id != target.id ||
        track.albumId != albumId ||
        ordinal == null ||
        ordinal > 5000)
      return null;
    var result = await read((ordinal - 1) ~/ xmlyAlbumPageSize + 1);
    if (ordinal > result.total) return null;
    if (!ascending)
      result = await read((result.total - ordinal) ~/ xmlyAlbumPageSize + 1);
    return cataloguePageContainsTarget(result, albumId, target.id)
        ? result
        : null;
  }

  check();
  if (target.albumId != albumId) throw missing;
  if (_trackOrdinal(target) != null) {
    final result = await ordinalPage(target);
    if (result != null) return result;
  } else {
    try {
      final hint = await XmlyDiscovery(client)
          .locateTrack(albumId: albumId, trackId: target.id);
      check();
      final first = await read(1);
      for (final page in catalogueHintPages(
        hint,
        albumId: albumId,
        trackId: target.id,
        total: first.total,
      )) {
        final result = await read(page);
        if (cataloguePageContainsTarget(result, albumId, target.id))
          return result;
      }
    } catch (error, stack) {
      check();
      _recordCatalogueError(
        'Track location hint unavailable',
        error,
        stack,
        recoverable: true,
      );
    }
  }
  check();
  final track = await client.track(target.id);
  check();
  final result = await ordinalPage(track);
  if (result == null) throw missing;
  return result;
}

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
  State<DiscoveryPage> createState() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::DiscoveryPage.createState",
    );
    return _DiscoveryPageState();
  }
}

class _DiscoveryPageState extends State<DiscoveryPage>
    with SingleTickerProviderStateMixin {
  static const _kinds = ['all', 'album', 'track', 'user'];
  static const _labels = ['全部', '专辑', '声音', '主播'];
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  final _scroll = ScrollController();
  late final _tabs = TabController(length: _kinds.length, vsync: this);
  String _kind = 'all';
  SearchPage? _result;
  String? _resultQuery, _submittedQuery, _error;
  bool _loading = false;
  int _generation = 0, _playRequest = 0, _requestedPage = 1;
  Completer<void>? _searchCancelled, _hotCancelled;
  List<HotWord> _hotWords = const [];
  bool _showHotWords = true, _hotAttempted = false;
  int _hotGeneration = 0;

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::_DiscoveryPageState.initState',
    );
    super.initState();
    _showHotWords = widget.runtime.showHotWords;
    widget.runtime.addListener(_runtimeChanged);
    _query.addListener(_queryChanged);
    _loadHotWords();
  }

  @override
  void didUpdateWidget(covariant DiscoveryPage oldWidget) {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::_DiscoveryPageState.didUpdateWidget',
    );
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.runtime, widget.runtime)) return;
    oldWidget.runtime.removeListener(_runtimeChanged);
    widget.runtime.addListener(_runtimeChanged);
    _generation++;
    _searchCancelled?.complete();
    _searchCancelled = null;
    _hotGeneration++;
    _hotCancelled?.complete();
    _hotCancelled = null;
    _showHotWords = widget.runtime.showHotWords;
    _hotWords = const [];
    _hotAttempted = false;
    _loading = false;
    _result = null;
    _resultQuery = null;
    _error = null;
    _loadHotWords();
  }

  void _runtimeChanged() {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::_DiscoveryPageState._runtimeChanged',
    );
    final enabled = widget.runtime.showHotWords;
    if (!mounted || enabled == _showHotWords) return;
    _hotGeneration++;
    _hotCancelled?.complete();
    _hotCancelled = null;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/catalogue_page.dart::_DiscoveryPageState._runtimeChanged.closure#1',
      );
      _showHotWords = enabled;
      _hotWords = const [];
      _hotAttempted = false;
    });
    if (enabled) _loadHotWords();
  }

  void _queryChanged() {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::_DiscoveryPageState._queryChanged',
    );
    if (!mounted) return;
    if (_query.text.trim().isEmpty) {
      _generation++;
      _searchCancelled?.complete();
      _searchCancelled = null;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/catalogue_page.dart::_DiscoveryPageState._queryChanged.closure#1',
        );
        _result = null;
        _resultQuery = null;
        _submittedQuery = null;
        _error = null;
        _loading = false;
      });
      _loadHotWords();
    } else {
      setState(() {
        AppLog.instance.trace(
          'lib/pages/catalogue_page.dart::_DiscoveryPageState._queryChanged.closure#2',
        );
      });
    }
  }

  Future<void> _loadHotWords() async {
    AppLog.instance.trace(
      'lib/pages/catalogue_page.dart::_DiscoveryPageState._loadHotWords',
    );
    if (!mounted ||
        !widget.runtime.showHotWords ||
        !_showHotWords ||
        _query.text.trim().isNotEmpty ||
        _hotAttempted)
      return;
    _hotAttempted = true;
    final generation = ++_hotGeneration;
    final cancelled = _hotCancelled = Completer<void>();
    final client = widget.runtime.anonymous;
    try {
      final words = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            'lib/pages/catalogue_page.dart::_DiscoveryPageState._loadHotWords.closure#1',
          );
          if (!mounted ||
              !widget.runtime.showHotWords ||
              generation != _hotGeneration) {
            throw const XmlyException('request_cancelled', '请求已取消');
          }
          return XmlyDiscovery(client).hotWords();
        },
        rateLimitRetries: 4,
        cancelled: cancelled.future,
      );
      if (!mounted ||
          generation != _hotGeneration ||
          !widget.runtime.showHotWords)
        return;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/catalogue_page.dart::_DiscoveryPageState._loadHotWords.closure#2',
        );
        _hotWords = words;
      });
    } catch (error, stack) {
      if (mounted &&
          generation == _hotGeneration &&
          widget.runtime.showHotWords) {
        _recordCatalogueError(
          'Hot words unavailable',
          error,
          stack,
          recoverable: true,
        );
      }
    } finally {
      if (identical(_hotCancelled, cancelled)) _hotCancelled = null;
    }
  }

  Future<void> _search({int page = 1, String? query}) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._search",
    );

    final rawQuery = query ?? _query.text;
    final submitted = rawQuery.trim();
    final generation = ++_generation;
    _searchCancelled?.complete();
    _searchCancelled = null;
    if (submitted.isEmpty || rawQuery.length > 200) {
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#1",
        );

        _loading = false;
        _error = '请输入 1～200 字的关键词';
        _result = null;
        _resultQuery = null;
        _submittedQuery = null;
        _requestedPage = 1;
      });
      _queryFocus.requestFocus();
      return;
    }
    final cancelled = _searchCancelled = Completer<void>();
    final kind = _kind;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#2",
      );

      _loading = true;
      _error = null;
      _submittedQuery = submitted;
      _requestedPage = page;
      if (_resultQuery != submitted || _result?.kind != kind) _result = null;
    });
    try {
      final client = widget.runtime.anonymous;
      final result = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#3",
          );
          return client.search(submitted, kind: kind, page: page, pageSize: 30);
        },
        rateLimitRetries: 0,
        cancelled: cancelled.future,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#4",
        );

        _result = result;
        _resultQuery = submitted;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#5",
        );

        if (mounted && generation == _generation && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.minScrollExtent);
        }
      });
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      _recordCatalogueError('Search failed', error, stack);
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#6",
        );
        _error = _safeError(error);
      });
    } finally {
      if (mounted && generation == _generation) {
        _searchCancelled = null;
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_DiscoveryPageState._search.closure#7",
          );
          _loading = false;
        });
      }
    }
  }

  void _selectKind(int index) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._selectKind",
    );

    if (_kind == _kinds[index]) return;
    ++_generation;
    _searchCancelled?.complete();
    _searchCancelled = null;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_DiscoveryPageState._selectKind.closure#1",
      );

      _kind = _kinds[index];
      _result = null;
      _error = null;
      _loading = false;
      _tabs.animateTo(index);
    });
    final query = _submittedQuery ?? _query.text.trim();
    if (query.isNotEmpty) unawaited(_search(query: query));
  }

  void _clear() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._clear",
    );

    ++_generation;
    _searchCancelled?.complete();
    _searchCancelled = null;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_DiscoveryPageState._clear.closure#1",
      );

      _query.clear();
      _result = null;
      _resultQuery = null;
      _submittedQuery = null;
      _error = null;
      _loading = false;
    });
    _queryFocus.requestFocus();
  }

  void _openAlbum(String id, {Track? target}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._openAlbum",
    );

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_DiscoveryPageState._openAlbum.closure#1",
          );
          return AlbumPageView(
            runtime: widget.runtime,
            albumId: id,
            initialTrack: target,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  Future<void> _playResult(Track track) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._playResult",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_DiscoveryPageState._playResult.closure#1",
      );

      final request = ++_playRequest;
      try {
        if (track.albumId.isEmpty) {
          await widget.runtime.player.playTrack(track);
        } else {
          final ordinal = _trackOrdinal(track);
          await (widget.onPlayAlbum ?? widget.runtime.player.playAlbum)(
            track.albumId,
            track.id,
            page: ordinal == null
                ? null
                : (ordinal - 1) ~/ xmlyAlbumPageSize + 1,
            track: track,
          );
        }
      } catch (error, stack) {
        _recordCatalogueError('Playback failed', error, stack);
        if (mounted && request == _playRequest) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(_safeError(error))));
        }
      }
    });
  }

  void _openAnchor(AnchorSearchResult anchor) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._openAnchor",
    );

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_DiscoveryPageState._openAnchor.closure#1",
          );
          return AnchorPage(
            runtime: widget.runtime,
            uid: anchor.uid,
            initialName: anchor.nickname,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  Future<void> _trackAction(String action, Track track) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackAction",
    );

    if (action == 'album') {
      _openAlbum(track.albumId, target: track);
      return;
    }
    try {
      await widget.onDownload?.call([track]);
    } catch (error, stack) {
      _recordCatalogueError('Download request failed', error, stack);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_safeError(error))));
      }
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState.dispose",
    );

    _generation++;
    widget.runtime.removeListener(_runtimeChanged);
    _query.removeListener(_queryChanged);
    _hotGeneration++;
    _hotCancelled?.complete();
    _searchCancelled?.complete();
    _playRequest++;
    _query.dispose();
    _queryFocus.dispose();
    _scroll.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Widget _header(double padding) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._header",
    );

    final colors = Theme.of(context).colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(28),
      borderSide: BorderSide.none,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(padding, 12, padding, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: TextField(
              key: const ValueKey('catalogueSearchField'),
              controller: _query,
              focusNode: _queryFocus,
              autofocus: true,
              maxLength: 200,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索专辑、声音、主播',
                hintStyle: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 14,
                ),
                counterText: '',
                filled: true,
                fillColor: colors.surfaceContainerHighest.withValues(alpha: .6),
                border: border,
                enabledBorder: border,
                focusedBorder: border.copyWith(
                  borderSide: BorderSide(
                    color: colors.primary.withValues(alpha: .45),
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                prefixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: () {
                    AppLog.instance.trace(
                      "lib/pages/catalogue_page.dart::_DiscoveryPageState._header.closure#1",
                    );
                    unawaited(_search());
                  },
                  icon: const Icon(Icons.search_rounded, size: 22),
                ),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        onPressed: _clear,
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
              ),
              onChanged: (_) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_DiscoveryPageState._header.closure#2",
                );

                setState(() {
                  AppLog.instance.trace(
                    "lib/pages/catalogue_page.dart::_DiscoveryPageState._header.closure#2.closure#1",
                  );
                });
              },
              onSubmitted: (_) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_DiscoveryPageState._header.closure#3",
                );
                unawaited(_search());
              },
            ),
          ),
          const SizedBox(height: 20),
          TabBar(
            key: const ValueKey('searchCategoryTabs'),
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            labelPadding: const EdgeInsets.symmetric(horizontal: 16),
            labelColor: colors.primary,
            unselectedLabelColor: colors.onSurface,
            labelStyle: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
            indicator: UnderlineTabIndicator(
              borderSide: BorderSide(color: colors.primary, width: 3),
              insets: const EdgeInsets.symmetric(horizontal: 8),
              borderRadius: BorderRadius.circular(3),
            ),
            onTap: _selectKind,
            tabs: [
              for (var i = 0; i < _labels.length; i++)
                Tab(key: ValueKey('searchTab-${_kinds[i]}'), text: _labels[i]),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(String title, String kind, int count, int visible) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._section",
    );

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            if (_kind == 'all' && count > visible)
              TextButton(
                key: ValueKey('searchMore-$kind'),
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/pages/catalogue_page.dart::_DiscoveryPageState._section.closure#1",
                  );
                  return _selectKind(_kinds.indexOf(kind));
                },
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant,
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text('更多'), Icon(Icons.chevron_right, size: 18)],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _countLabel(int count) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._countLabel",
    );

    if (count >= 100000000) return '${(count / 100000000).toStringAsFixed(1)}亿';
    if (count >= 10000) return '${(count / 10000).toStringAsFixed(1)}万';
    return '$count';
  }

  Widget _albumCard(Album album, double width) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._albumCard",
    );

    final colors = Theme.of(context).colorScheme;
    final plays = xmlyPositive(album.raw['play']);
    final vip = const [1, 2].contains(album.raw['vipType']);
    final paid = album.raw['is_paid'] == true || album.raw['isPaid'] == true;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: ValueKey('searchAlbum-${album.id}'),
        onTap: () {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_DiscoveryPageState._albumCard.closure#1",
          );
          return _openAlbum(album.id);
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  CoverImage(uri: album.coverUrl, size: width - 8),
                  if (plays != null)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .6),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.play_arrow_rounded,
                                size: 14,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                _countLabel(plays),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text.rich(
                TextSpan(
                  children: [
                    if (vip || paid)
                      TextSpan(
                        text: vip ? 'VIP  ' : '付费  ',
                        style: TextStyle(
                          color: colors.tertiary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    TextSpan(text: album.title),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurface,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _trackTile(Track track) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackTile",
    );

    final narrow =
        MediaQuery.sizeOf(context).width < 420 ||
        MediaQuery.textScalerOf(context).scale(14) > 22;
    return ListTile(
      key: ValueKey('searchTrack-${track.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      leading: narrow ? null : CoverImage(uri: track.coverUrl, size: 48),
      title: Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${track.album} · ${_duration(track.duration)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackTile.closure#1",
        );
        if (track.albumId.isNotEmpty) {
          _openAlbum(track.albumId, target: track);
        } else {
          unawaited(_playResult(track));
        }
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!narrow)
            IconButton(
              tooltip: '播放此集',
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackTile.closure#2",
                );
                unawaited(_playResult(track));
              },
            ),
          if (track.albumId.isNotEmpty || widget.onDownload != null)
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (action) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackTile.closure#3",
                );
                unawaited(_trackAction(action, track));
              },
              itemBuilder: (_) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_DiscoveryPageState._trackTile.closure#4",
                );
                return [
                  if (track.albumId.isNotEmpty)
                    const PopupMenuItem(value: 'album', child: Text('查看专辑并定位')),
                  if (widget.onDownload != null)
                    const PopupMenuItem(value: 'download', child: Text('下载')),
                ];
              },
            ),
        ],
      ),
    );
  }

  Widget _anchorTile(AnchorSearchResult anchor) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState._anchorTile",
    );

    final colors = Theme.of(context).colorScheme;
    final counts = [
      if (anchor.albumsCount != null) '${anchor.albumsCount} 张专辑',
      if (anchor.tracksCount != null) '${anchor.tracksCount} 声音',
      if (anchor.followersCount != null)
        '${_countLabel(anchor.followersCount!)} 粉丝',
    ];
    final subtitle = [
      if (counts.isNotEmpty) counts.join(' · '),
      if (anchor.description.isNotEmpty) anchor.description,
    ].join('\n');
    return ListTile(
      key: ValueKey('searchAnchor-${anchor.uid}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      leading: ClipOval(child: CoverImage(uri: anchor.avatarUrl, size: 48)),
      title: Row(
        children: [
          Flexible(
            child: Text(
              anchor.nickname,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (anchor.isVerified)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(
                Icons.verified_rounded,
                color: colors.primary,
                size: 16,
              ),
            ),
        ],
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: () {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_DiscoveryPageState._anchorTile.closure#1",
        );
        return _openAnchor(anchor);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_DiscoveryPageState.build",
    );

    final result = _result;
    final empty =
        result != null &&
        result.albums.isEmpty &&
        result.tracks.isEmpty &&
        result.anchors.isEmpty;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: LayoutBuilder(
          builder: (context, constraints) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1",
            );

            final padding = constraints.maxWidth < 600 ? 16.0 : 28.0;
            final width = constraints.maxWidth - padding * 2;
            final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
            final gap = width < 600 ? 12.0 : 24.0;
            final columns = width < 600
                ? (width >= 280 && scale < 1.5 ? 2 : 1)
                : ((width + gap) / (220 * scale.clamp(1, 1.4) + gap))
                      .floor()
                      .clamp(2, 5);
            final cardWidth = (width - gap * (columns - 1)) / columns;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(padding),
                SizedBox(
                  height: 2,
                  child: _loading
                      ? const LinearProgressIndicator(minHeight: 2)
                      : null,
                ),
                Expanded(
                  child: AppScrollbar(
                    controller: _scroll,
                    child: CustomScrollView(
                      controller: _scroll,
                      scrollBehavior: ScrollConfiguration.of(context)
                          .copyWith(scrollbars: false),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      slivers: [
                        if (_showHotWords &&
                            widget.runtime.showHotWords &&
                            _query.text.trim().isEmpty &&
                            _hotWords.isNotEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(padding),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '热搜',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      for (final word in _hotWords)
                                        ActionChip(
                                          label: Text(word.displayWord),
                                          onPressed: () {
                                            AppLog.instance.trace(
                                              'lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#1',
                                            );
                                            _query.text = word.word;
                                            unawaited(
                                              _search(query: word.word),
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (_error != null)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(padding),
                              child: Wrap(
                                spacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(_error!),
                                  TextButton(
                                    onPressed: _loading
                                        ? null
                                        : () {
                                            AppLog.instance.trace(
                                              "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#2",
                                            );
                                            unawaited(
                                              _search(
                                                page: _requestedPage,
                                                query: _submittedQuery,
                                              ),
                                            );
                                          },
                                    child: const Text('重试'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (!_loading &&
                            _error == null &&
                            (result == null || empty))
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Text(
                                result == null ? '搜索你想听的内容' : '没有找到相关内容',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        if (result != null && !empty)
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              padding,
                              0,
                              padding,
                              24,
                            ),
                            sliver: SliverMainAxisGroup(
                              slivers: [
                                if (result.anchors.isNotEmpty) ...[
                                  _section(
                                    '主播',
                                    'user',
                                    result.totals['user'] ?? result.total,
                                    result.anchors.length,
                                  ),
                                  SliverList.builder(
                                    itemCount: result.anchors.length,
                                    itemBuilder: (_, index) {
                                      AppLog.instance.trace(
                                        "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#3",
                                      );
                                      return _anchorTile(result.anchors[index]);
                                    },
                                  ),
                                ],
                                if (result.albums.isNotEmpty) ...[
                                  _section(
                                    '专辑',
                                    'album',
                                    result.totals['album'] ?? result.total,
                                    result.albums.length,
                                  ),
                                  SliverGrid.builder(
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: columns,
                                          crossAxisSpacing: gap,
                                          mainAxisSpacing: 20,
                                          mainAxisExtent:
                                              cardWidth + 12 + 44 * scale,
                                        ),
                                    itemCount: result.albums.length,
                                    itemBuilder: (_, index) {
                                      AppLog.instance.trace(
                                        "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#4",
                                      );
                                      return _albumCard(
                                        result.albums[index],
                                        cardWidth,
                                      );
                                    },
                                  ),
                                ],
                                if (result.tracks.isNotEmpty) ...[
                                  _section(
                                    '声音',
                                    'track',
                                    result.totals['track'] ?? result.total,
                                    result.tracks.length,
                                  ),
                                  SliverList.builder(
                                    itemCount: result.tracks.length,
                                    itemBuilder: (_, index) {
                                      AppLog.instance.trace(
                                        "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#5",
                                      );
                                      return _trackTile(result.tracks[index]);
                                    },
                                  ),
                                ],
                                if (_kind != 'all')
                                  SliverToBoxAdapter(
                                    child: ContentPaging(
                                      page: result.page,
                                      total: result.total,
                                      pageSize: result.pageSize,
                                      busy: _loading,
                                      onPage: (page) {
                                        AppLog.instance.trace(
                                          "lib/pages/catalogue_page.dart::_DiscoveryPageState.build.closure#1.closure#6",
                                        );
                                        return _search(
                                          page: page,
                                          query: _resultQuery,
                                        );
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class AlbumPageView extends StatefulWidget {
  const AlbumPageView({
    required this.runtime,
    required this.albumId,
    this.initialTrack,
    this.accountIdentity,
    this.onDownload,
    this.onPlayAlbum,
    this.inPanel = false,
    super.key,
  });
  final AppRuntime runtime;
  final String albumId;
  final String? accountIdentity;
  final Track? initialTrack;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;
  final bool inPanel;
  @override
  State<AlbumPageView> createState() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::AlbumPageView.createState",
    );
    return _AlbumPageViewState();
  }
}

class _AlbumPageViewState extends State<AlbumPageView> {
  final _albumScroll = ScrollController();
  final _headerKey = GlobalKey();
  String? _targetWarning;
  final _search = TextEditingController();
  final _range = TextEditingController();
  final _selected = <String, Track>{};
  List<DownloadTask> _observedDownloads = [];
  Set<String> _downloaded = {};
  Object? _observedCache;
  Album? _album;
  List<Track> _visible = [];
  List<Track>? _complete;
  int _page = 1, _total = 0, _generation = 0;
  Completer<void>? _catalogueCancelled;
  bool _busy = false, _autoBusy = false, _offline = false;
  bool _showSearch = false, _selectionMode = false, _cachedView = false;
  String? _error;
  String _filter = '';
  XmlyClient? _libraryClient;
  String? _libraryKey, _subscriptionError;
  int _libraryRevision = -1, _subscriptionRequest = 0, _accountEpoch = 0;
  bool? _subscribed;
  bool _subscriptionBusy = false, _favoriteBusy = false;
  bool _subscriptionMutating = false;
  bool _ascending = true;
  static const _pageSize = xmlyAlbumPageSize;

  XmlyClient get _client {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._client.get",
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
      "lib/pages/catalogue_page.dart::_AlbumPageViewState.initState",
    );

    super.initState();
    _ascending =
        (widget.runtime.storage.state['settings']
            as Map)['catalogueAscending'] !=
        false;
    widget.runtime.addListener(_runtimeChanged);
    _downloaded = _completedTrackIds();
    _restoreCache();
    _loadPage(1, target: widget.initialTrack);
    _scanUpdates();
    _loadSubscription();
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState.dispose",
    );

    widget.runtime.removeListener(_runtimeChanged);
    _generation++;
    _cancelCatalogue();
    _search.dispose();
    _range.dispose();
    _albumScroll.dispose();
    super.dispose();
  }

  void _runtimeChanged() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._runtimeChanged",
    );

    if (!mounted) return;
    final client = _client;
    final accountChanged =
        !identical(client, _libraryClient) ||
        client.cacheIdentity != _libraryKey;
    if (accountChanged) _accountEpoch++;
    final libraryChanged = widget.runtime.libraryRevision != _libraryRevision;
    _libraryRevision = widget.runtime.libraryRevision;
    final downloads = widget.runtime.downloads.tasks;
    final cached = widget.runtime.albumCache[widget.albumId];
    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._runtimeChanged.closure#1",
      );

      if (accountChanged) {
        _complete = null;
        _offline = false;
        _filter = '';
        _search.clear();
        _clearSelection();
      }
      if (!listEquals(downloads, _observedDownloads) ||
          !identical(cached, _observedCache)) {
        _observedDownloads = downloads;
        _observedCache = cached;
        _downloaded = _completedTrackIds();
        _selected.removeWhere((id, _) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._runtimeChanged.closure#1.closure#1",
          );
          return _downloaded.contains(id);
        });
        if (_cachedView) _showCached(_page);
      }
    });
    if (accountChanged || (libraryChanged && !_subscriptionMutating)) {
      _loadSubscription();
    }
    if (accountChanged) _loadPage(1, target: widget.initialTrack);
  }

  void _cancelCatalogue() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._cancelCatalogue",
    );

    _catalogueCancelled?.complete();
    _catalogueCancelled = null;
  }

  Future<T> _readCatalogue<T>(
    XmlyClient client,
    Future<T> Function() read,
  ) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._readCatalogue",
    );

    _cancelCatalogue();
    final cancelled = _catalogueCancelled = Completer<void>();
    try {
      return await client.withReadPolicy(
        read,
        rateLimitRetries: 4,
        cancelled: cancelled.future,
      );
    } finally {
      if (identical(_catalogueCancelled, cancelled)) {
        _catalogueCancelled = null;
      }
    }
  }

  List<Track> _cachedTracks() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._cachedTracks",
    );

    final cached = widget.runtime.albumCache[widget.albumId];
    final tracks = <String, Track>{
      for (final track in cached?.tracks ?? <Track>[]) track.id: track,
    };
    for (final task in widget.runtime.downloads.tasks) {
      if (task.track.albumId == widget.albumId) {
        tracks.putIfAbsent(task.track.id, () {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._cachedTracks.closure#1",
          );
          return task.track;
        });
      }
    }
    return tracks.values.toList()..sort((a, b) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._cachedTracks.closure#2",
      );
      return (a.officialPosition ?? a.orderNo ?? 5001).compareTo(
        b.officialPosition ?? b.orderNo ?? 5001,
      );
    });
  }

  void _restoreCache({int page = 1}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._restoreCache",
    );

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
    _showCached(page, orderedTracks: _orderedForDisplay(tracks));
  }

  void _showCached(int page, {List<Track>? orderedTracks}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._showCached",
    );

    _cachedView = true;
    final ordered = orderedTracks ?? _orderedForDisplay(_cachedTracks());
    final filter = _filter.toLowerCase();
    final tracks = filter.isEmpty
        ? ordered
        : ordered.where((track) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._showCached.closure#1",
            );
            return track.title.toLowerCase().contains(filter);
          }).toList();
    _total = tracks.length;
    _page = page.clamp(
      1,
      ((_total + _pageSize - 1) ~/ _pageSize).clamp(1, 10000),
    );
    _visible = tracks.skip((_page - 1) * _pageSize).take(_pageSize).toList();
  }

  Future<DownloadTask?> _localDownload(Track track) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._localDownload",
    );

    final tasks = widget.runtime.downloads.tasks.where((task) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._localDownload.closure#1",
      );
      return task.track.id == track.id && task.state == DownloadState.completed;
    }).toList();
    tasks.sort((a, b) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._localDownload.closure#2",
      );
      return (b.accountIdentity == widget.runtime.player.libraryIdentity
              ? 1
              : 0)
          .compareTo(
            a.accountIdentity == widget.runtime.player.libraryIdentity ? 1 : 0,
          );
    });
    for (final task in tasks) {
      if (task.finalPath != null && await File(task.finalPath!).exists())
        return task;
    }
    return null;
  }

  Set<String> _completedTrackIds() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._completedTrackIds",
    );
    return {
      for (final task in widget.runtime.downloads.tasks)
        if (task.state == DownloadState.completed) task.track.id,
    };
  }

  void _select(Track track, bool selected) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._select",
    );

    if (selected && !_downloaded.contains(track.id)) {
      _selected[track.id] = track;
    } else {
      _selected.remove(track.id);
    }
  }

  void _clearSelection() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._clearSelection",
    );

    _selected.clear();
    _range.clear();
    _selectionMode = false;
  }

  bool _sameAccount(XmlyClient client, String key) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._sameAccount",
    );
    return mounted &&
        identical(client, _client) &&
        key == _client.cacheIdentity;
  }

  Future<void> _loadSubscription() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription.closure#1",
      );

      final client = _client, key = _client.cacheIdentity;
      final request = ++_subscriptionRequest;
      _libraryClient = client;
      _libraryKey = key;
      _libraryRevision = widget.runtime.libraryRevision;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription.closure#1.closure#1",
        );

        _subscribed = null;
        _subscriptionError = null;
        _subscriptionBusy = client.accountAvailable;
        _subscriptionMutating = false;
      });
      if (!client.accountAvailable) return;
      try {
        final subscribed = await XmlyExperience(client)
            .isSubscribed(widget.albumId);
        if (_sameAccount(client, key) && request == _subscriptionRequest) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription.closure#1.closure#2",
            );
            _subscribed = subscribed;
          });
        }
      } catch (error, stack) {
        _recordCatalogueError('Subscription status failed', error, stack);
        if (_sameAccount(client, key) && request == _subscriptionRequest) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription.closure#1.closure#3",
            );
            _subscriptionError = _safeError(error);
          });
        }
      } finally {
        if (_sameAccount(client, key) && request == _subscriptionRequest) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadSubscription.closure#1.closure#4",
            );
            _subscriptionBusy = false;
          });
        }
      }
    });
  }

  Future<void> _changeSubscription() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1",
      );

      if (_subscriptionBusy) return;
      final client = _client, key = _client.cacheIdentity;
      if (!client.accountAvailable) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#1",
          );
          _subscriptionError = '请先登录后订阅专辑';
        });
        return;
      }
      final subscribed = _subscribed;
      if (subscribed == null) return _loadSubscription();
      final desired = !subscribed, request = ++_subscriptionRequest;
      var attempted = false;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#2",
        );

        _subscriptionBusy = true;
        _subscriptionMutating = true;
        _subscriptionError = null;
      });
      try {
        await widget.runtime.accounts.runWithAccount(client.identity, (
          admitted,
        ) async {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#3",
          );

          if (!_sameAccount(client, key) || !identical(admitted, client)) {
            throw const XmlyException('account_changed', '账号已变更，请重试');
          }
          attempted = true;
          await XmlyExperience(client)
              .setSubscribed(widget.albumId, subscribed: desired);
        });
        widget.runtime.libraryChanged();
        if (_sameAccount(client, key) && request == _subscriptionRequest) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#4",
            );
            _subscribed = desired;
          });
        }
      } catch (error, stack) {
        _recordCatalogueError('Subscription change failed', error, stack);
        if (attempted) widget.runtime.libraryChanged();
        if (!_sameAccount(client, key) || request != _subscriptionRequest)
          return;
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#5",
          );

          _subscribed = null;
          _subscriptionError = _safeError(error);
        });
        try {
          final value = await XmlyExperience(client)
              .isSubscribed(widget.albumId);
          if (_sameAccount(client, key) && request == _subscriptionRequest) {
            setState(() {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#6",
              );
              _subscribed = value;
            });
          }
        } catch (error, stack) {
          _recordCatalogueError(
            'Subscription reconciliation failed',
            error,
            stack,
            recoverable: true,
          );
          // Keep the unknown state and offer an explicit status retry.
        }
      } finally {
        if (_sameAccount(client, key) && request == _subscriptionRequest) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._changeSubscription.closure#1.closure#7",
            );

            _subscriptionBusy = false;
            _subscriptionMutating = false;
          });
        }
      }
    });
  }

  String get _subscriptionLabel {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._subscriptionLabel.get",
    );
    return _subscriptionBusy
        ? '正在读取订阅状态'
        : !_client.accountAvailable
        ? '订阅（需登录）'
        : _subscribed == null
        ? '重试订阅状态'
        : _subscribed!
        ? '取消订阅'
        : '订阅专辑';
  }

  void _scanUpdates() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._scanUpdates",
    );

    for (final identity in widget.runtime.accounts.accountIds) {
      unawaited(
        widget.runtime.autoDownloads.scanAlbum(identity, widget.albumId),
      );
    }
  }

  Future<void> _autoDownload(String identity) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._autoDownload",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._autoDownload.closure#1",
      );

      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._autoDownload.closure#1.closure#1",
        );

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
      } catch (error, stack) {
        _recordCatalogueError(
          'Automatic download setting failed',
          error,
          stack,
        );
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._autoDownload.closure#1.closure#2",
            );
            _error = _safeError(error);
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._autoDownload.closure#1.closure#3",
            );
            _autoBusy = false;
          });
      }
    });
  }

  double get _trackExtent {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._trackExtent.get",
    );
    final scaler = MediaQuery.textScalerOf(context);
    return (scaler.scale(16) * 1.5 + scaler.scale(14) * 1.5 + 12).clamp(
      64.0,
      double.infinity,
    );
  }

  void _revealTarget(Track target, int generation) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._revealTarget",
    );

    final index = _visible.indexWhere((track) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._revealTarget.closure#1",
      );
      return track.id == target.id && track.albumId == widget.albumId;
    });
    if (index < 0) {
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._revealTarget.closure#2",
        );
        _targetWarning = '当前目录没有找到这集，目标信息已保留，可重新定位。';
      });
      return;
    }
    setState(() {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._revealTarget.closure#3",
      );
      _targetWarning = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._revealTarget.closure#4",
      );

      if (!mounted || generation != _generation || !_albumScroll.hasClients)
        return;
      final header = _headerKey.currentContext?.findRenderObject();
      if (header is! RenderBox || !header.hasSize) return;
      final offset = header.size.height + index * _trackExtent;
      _albumScroll.jumpTo(
        offset.clamp(
          _albumScroll.position.minScrollExtent,
          _albumScroll.position.maxScrollExtent,
        ),
      );
    });
  }

  Future<void> _loadPage(int page, {Track? target}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1",
      );

      final generation = ++_generation;
      _cancelCatalogue();
      if (target != null) {
        final available = _complete != null
            ? _orderedForDisplay(_complete!)
            : (_cachedView || _offline)
            ? _orderedForDisplay(_cachedTracks())
            : null;
        if (available != null) {
          final filter = _filter.toLowerCase();
          final tracks = filter.isEmpty
              ? available
              : available.where((track) {
                  AppLog.instance.trace(
                    'lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#1',
                  );
                  return track.title.toLowerCase().contains(filter);
                }).toList();
          final index = tracks.indexWhere((track) {
            AppLog.instance.trace(
              'lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#2',
            );
            return track.id == target.id && track.albumId == widget.albumId;
          });
          if (index >= 0) {
            setState(() {
              AppLog.instance.trace(
                'lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#3',
              );
              _page = index ~/ _pageSize + 1;
              _total = tracks.length;
              _visible = tracks
                  .skip((_page - 1) * _pageSize)
                  .take(_pageSize)
                  .toList();
              _busy = false;
              _error = null;
            });
            _revealTarget(target, generation);
            return;
          }
        }
      }
      if (_offline) {
        final tracks = _orderedForDisplay(_cachedTracks());
        if (target != null) {
          final index = tracks.indexWhere((track) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#4",
            );
            return track.id == target.id && track.albumId == widget.albumId;
          });
          if (index >= 0) page = index ~/ _pageSize + 1;
        }
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#5",
          );
          _showCached(page, orderedTracks: tracks);
        });
        if (target != null) _revealTarget(target, _generation);
        return;
      }
      final client = _client, key = _client.cacheIdentity;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#6",
        );

        _busy = true;
        _error = null;
      });
      try {
        if (_filter.isNotEmpty && _complete != null) {
          final filter = _filter.toLowerCase();
          final filtered = _orderedForDisplay(_complete!).where((track) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#7",
            );
            return track.title.toLowerCase().contains(filter);
          }).toList();
          if (mounted && generation == _generation) {
            setState(() {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#8",
              );

              _page = page;
              _total = filtered.length;
              _visible = filtered
                  .skip((page - 1) * _pageSize)
                  .take(_pageSize)
                  .toList();
            });
            if (target != null) _revealTarget(target, generation);
          }
        } else {
          final result = await _readCatalogue(client, () {
            AppLog.instance.trace(
              'lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#9',
            );
            if (target != null)
              return locateCatalogueTarget(
                client: client,
                albumId: widget.albumId,
                target: target,
                ascending: _ascending,
                isCurrent: () {
                  AppLog.instance.trace(
                    'lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#9.closure#1',
                  );
                  return _sameAccount(client, key) && generation == _generation;
                },
              );
            return client.album(
              widget.albumId,
              page: page,
              pageSize: _pageSize,
              ascending: _ascending,
            );
          });
          if (!_sameAccount(client, key) || generation != _generation) return;
          if (_sameAccount(client, key) && generation == _generation) {
            setState(() {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#10",
              );

              _offline = false;
              _cachedView = false;
              _complete = null;
              _album = result.album;
              _page = result.page;
              _total = result.total;
              _visible = result.tracks;
            });
            if (target != null) _revealTarget(target, generation);
            unawaited(_rememberPage(result));
          }
        }
      } catch (error, stack) {
        _recordCatalogueError('Catalogue load failed', error, stack);
        if (_sameAccount(client, key) && generation == _generation) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#11",
            );

            if (target == null || _album == null) {
              _restoreCache(page: page);
              _offline = _album != null;
            }
            _error = _album == null ? _safeError(error) : null;
            if (target != null) _targetWarning = '暂时无法定位这集，目标信息已保留，请重新定位。';
          });
          if (_offline && target != null) {
            final index = _orderedForDisplay(_cachedTracks()).indexWhere((
              track,
            ) {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#12",
              );
              return track.id == target.id && track.albumId == widget.albumId;
            });
            if (index >= 0) {
              setState(() {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#13",
                );
                _showCached(index ~/ _pageSize + 1);
              });
              _revealTarget(target, generation);
            }
          }
        }
      } finally {
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._loadPage.closure#1.closure#14",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _rememberPage(AlbumPage page) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._rememberPage",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._rememberPage.closure#1",
      );

      try {
        await widget.runtime.albumCache.remember(page);
      } catch (error, stack) {
        _recordCatalogueError(
          'Catalogue cache failed',
          error,
          stack,
          recoverable: true,
        );
        // Optional cache failures never delay or replace the live catalogue.
      }
    });
  }

  List<Track> _orderedForDisplay(List<Track> tracks) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._orderedForDisplay",
    );
    return _ascending ? tracks : tracks.reversed.toList();
  }

  Future<void> _setOrder(bool ascending) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1",
      );

      if (_busy || _ascending == ascending) return;
      final epoch = _accountEpoch;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        await widget.runtime.storage.transaction((state) {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1.closure#2",
          );

          (state['settings'] as Map)['catalogueAscending'] = ascending;
        });
        if (!mounted) return;
        setState(() {
          AppLog.instance.trace(
            "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1.closure#3",
          );

          _ascending = ascending;
          _selected.clear();
        });
        await _loadPage(1);
        if (mounted && _albumScroll.hasClients) {
          _albumScroll.jumpTo(_albumScroll.position.minScrollExtent);
        }
      } catch (error, stack) {
        _recordCatalogueError('Catalogue order failed', error, stack);
        if (mounted && epoch == _accountEpoch)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1.closure#4",
            );
            _error = '目录排序保存失败，请重试';
          });
      } finally {
        if (mounted && epoch == _accountEpoch)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._setOrder.closure#1.closure#5",
            );
            _busy = false;
          });
      }
    });
  }

  List<PopupMenuEntry<String>> _orderMenu() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._orderMenu",
    );
    return [
      CheckedPopupMenuItem(
        value: 'ascending',
        checked: _ascending,
        enabled: !_busy,
        child: const Text('正序（最早在前）'),
      ),
      CheckedPopupMenuItem(
        value: 'descending',
        checked: !_ascending,
        enabled: !_busy,
        child: const Text('倒序（最新在前）'),
      ),
    ];
  }

  Widget _orderControl() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._orderControl",
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text('声音 ($_total)')),
          Tooltip(
            message: _ascending ? '切换为最新在前' : '切换为最早在前',
            child: TextButton.icon(
              key: const ValueKey('albumOrderToggle'),
              onPressed: _busy
                  ? null
                  : () {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_AlbumPageViewState._orderControl.closure#1",
                      );
                      _setOrder(!_ascending);
                    },
              icon: const Icon(Icons.swap_vert_rounded, size: 20),
              label: Text(_ascending ? '正序' : '倒序'),
            ),
          ),
        ],
      ),
    );
  }

  Future<List<Track>> _all() async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._all",
    );

    if (_complete != null) return _complete!;
    if (_offline) {
      throw const XmlyException('offline_catalogue', '离线目录不完整，无法按完整专辑下载');
    }
    final generation = _generation, client = _client;
    final identity = client.cacheIdentity;
    final tracks = await _readCatalogue(client, () {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._all.closure#1",
      );
      return XmlyCatalogue(client).album(widget.albumId);
    });
    if (!mounted ||
        generation != _generation ||
        !identical(client, _client) ||
        identity != _client.cacheIdentity) {
      throw const XmlyException('catalogue_changed', '专辑目录已变化，请重新操作');
    }
    _complete = tracks;
    return tracks;
  }

  Future<void> _filterAll() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll.closure#1",
      );

      if (_busy) return;
      final generation = _generation;
      final filter = _search.text.trim();
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        if (_offline) {
          _filter = filter;
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll.closure#1.closure#2",
            );
            _showCached(1);
          });
          return;
        }
        if (filter.isNotEmpty) await _all();
        if (!mounted || generation != _generation) return;
        _filter = filter;
      } catch (error, stack) {
        _recordCatalogueError('Catalogue filtering failed', error, stack);
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll.closure#1.closure#3",
            );
            _error = _safeError(error);
          });
        return;
      } finally {
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._filterAll.closure#1.closure#4",
            );
            _busy = false;
          });
      }
      if (mounted && generation == _generation) await _loadPage(1);
    });
  }

  Future<void> _download({bool all = false}) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._download",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._download.closure#1",
      );

      if (_busy) return;
      final generation = _generation;
      final range = _range.text.trim();
      final selected = _selected.values.toList();
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._download.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        if (all) {
          await requestAlbumDownloads(
            context,
            widget.runtime,
            widget.albumId,
            accountIdentity: widget.accountIdentity,
          );
          return;
        }
        final requested = range.isNotEmpty
            ? XmlyCatalogue.selectRange(await _all(), range)
            : selected;
        if (requested.isEmpty)
          throw const XmlyException('empty_selection', '请选择未下载的声音或填写集数范围');
        if (!mounted) return;
        // Preparation checks completed files before deduplicating their tasks.
        await requestDownloads(
          context,
          widget.runtime,
          requested,
          accountIdentity: widget.accountIdentity,
        );
      } catch (error, stack) {
        _recordCatalogueError('Download request failed', error, stack);
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._download.closure#1.closure#2",
            );
            _error = _safeError(error);
          });
      } finally {
        if (mounted && generation == _generation)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._download.closure#1.closure#3",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _play(Track track) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._play",
    );

    if (_offline) {
      final task = await _localDownload(track);
      if (!mounted) return;
      if (task == null)
        throw const XmlyException('offline_playback', '此声音本地文件不存在，请重新下载后播放');
      await widget.runtime.player.playLocal(task.id);
      return;
    }
    if (widget.onPlayAlbum != null && widget.accountIdentity == null) {
      final position = track.officialPosition;
      await widget.onPlayAlbum!(
        widget.albumId,
        track.id,
        page: position == null
            ? (_filter.isEmpty && _ascending ? _page : null)
            : (position - 1) ~/ _pageSize + 1,
        track: track,
      );
    } else {
      await widget.runtime.player.playAlbum(
        widget.albumId,
        track.id,
        track: track,
        accountIdentity: widget.accountIdentity,
      );
    }
  }

  Future<void> _trackAction(Track track, String action) async {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._trackAction",
    );

    switch (action) {
      case 'play':
        await _play(track);
      case 'queue':
        await widget.runtime.player.addToQueue(
          track,
          accountIdentity: widget.accountIdentity,
        );
      case 'next':
        await widget.runtime.player.playNext(
          track,
          accountIdentity: widget.accountIdentity,
        );
      case 'download':
        final task = await _localDownload(track);
        if (mounted && task == null)
          await requestDownloads(context, widget.runtime, [
            track,
          ], accountIdentity: widget.accountIdentity);
      case 'delete':
        final task = await _localDownload(track);
        if (mounted && task != null) {
          await deleteDownloadedAudio(context, widget.runtime, task);
        }
    }
    if (mounted)
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._trackAction.closure#1",
        );
      });
  }

  Widget _menu(Track track) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._menu",
    );
    return Builder(
      builder: (menuContext) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._menu.closure#1",
        );
        return IconButton(
          tooltip: '声音操作',
          icon: const Icon(Icons.more_vert),
          onPressed: _busy || _favoriteBusy
              ? null
              : () {
                  AppLog.instance.trace(
                    "lib/pages/catalogue_page.dart::_AlbumPageViewState._menu.closure#1.closure#1",
                  );
                  _openTrackMenu(menuContext, track);
                },
        );
      },
    );
  }

  Future<void> _openTrackMenu(BuildContext menuContext, Track track) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1",
      );

      final client = _client, key = _client.cacheIdentity;
      final epoch = _accountEpoch;
      bool current() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.current",
        );
        return _sameAccount(client, key) && epoch == _accountEpoch;
      }

      final anchor = menuContext.findRenderObject()! as RenderBox;
      final overlay =
          Overlay.of(menuContext).context.findRenderObject()! as RenderBox;
      final position = RelativeRect.fromRect(
        Rect.fromPoints(
          anchor.localToGlobal(Offset.zero, ancestor: overlay),
          anchor.localToGlobal(
            anchor.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      );
      setState(() {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#1",
        );
        _favoriteBusy = true;
      });
      try {
        final task = await _localDownload(track);
        if (!current()) return;
        final action = await showMenu<String>(
          context: context,
          position: position,
          items: [
            const PopupMenuItem(value: 'play', child: Text('播放')),
            const PopupMenuItem(value: 'queue', child: Text('加入播放队列')),
            const PopupMenuItem(value: 'next', child: Text('下一集播放')),
            if (task != null)
              const PopupMenuItem(value: 'delete', child: Text('删除已下载文件'))
            else
              const PopupMenuItem(value: 'download', child: Text('下载')),
            if (client.accountAvailable)
              _FavoriteMenuItem(client: client, trackId: track.id)
            else
              const PopupMenuItem(value: 'favorite', child: Text('收藏（需登录）')),
          ],
        );
        if (!current() || action == null) return;
        if (action == 'retryFavorite') {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#2",
            );
            _favoriteBusy = false;
          });
          if (menuContext.mounted) await _openTrackMenu(menuContext, track);
          return;
        }
        if (action != 'favorite' && action != 'unfavorite') {
          await _trackAction(track, action);
          return;
        }
        if (!client.accountAvailable) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#3",
            );
            _error = '请先登录后收藏声音';
          });
          return;
        }
        final desired = action == 'favorite';
        var attempted = false;
        try {
          await widget.runtime.accounts.runWithAccount(client.identity, (
            admitted,
          ) async {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#4",
            );

            if (!current() || !identical(admitted, client)) {
              throw const XmlyException('account_changed', '账号已变更，请重试');
            }
            attempted = true;
            await XmlyExperience(client).setFavorite(track, favorite: desired);
          });
          widget.runtime.libraryChanged();
        } catch (error, stack) {
          _recordCatalogueError('Favorite change failed', error, stack);
          if (attempted) widget.runtime.libraryChanged();
          if (!current()) return;
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#5",
            );
            _error = _safeError(error);
          });
          // Reconcile an uncertain write without replaying the mutation.
          if (attempted) {
            try {
              await XmlyExperience(client).isFavorite(track.id);
            } catch (error, stack) {
              _recordCatalogueError(
                'Favorite reconciliation failed',
                error,
                stack,
                recoverable: true,
              );
            }
          }
        }
      } catch (error, stack) {
        _recordCatalogueError('Track action failed', error, stack);
        if (current())
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#6",
            );
            _error = _safeError(error);
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._openTrackMenu.closure#1.closure#7",
            );
            _favoriteBusy = false;
          });
      }
    });
  }

  void _albumAction(String action) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumAction",
    );

    switch (action) {
      case 'ascending':
        _setOrder(true);
      case 'descending':
        _setOrder(false);
      case 'refresh':
        _offline = false;
        _complete = null;
        _filter = '';
        _search.clear();
        _loadPage(1);
      case 'tags':
        showLocalPanel<void>(
          context: context,
          title: '专辑标签',
          builder: (_) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState._albumAction.closure#1",
            );
            return AlbumTagsPage(
              runtime: widget.runtime,
              albumId: widget.albumId,
              albumTitle: _album?.title ?? '',
              embedded: true,
            );
          },
        );
      case 'settings':
        showQuickPlaybackSettings(
          context,
          widget.runtime,
          albumId: widget.albumId,
          albumTitle: _album?.title,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_AlbumPageViewState.build",
    );

    final album = _album;
    final anchorUid = album?.anchorUid;
    final artist = album?.artist.trim() ?? '';
    final identity = widget.runtime.accounts.primaryAccountId;
    final automatic = widget.runtime.autoDownloads;
    final compact =
        MediaQuery.sizeOf(context).width < (usesWindowHeader ? 640 : 320);
    final canDownload = !_busy && !widget.runtime.accounts.admissionPaused;
    return Scaffold(
      appBar: AppHeader(
        windowControls: !widget.inPanel,
        leading: widget.inPanel
            ? IconButton(
                tooltip: '收起专辑',
                onPressed: () {
                  AppLog.instance.trace(
                    "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#1",
                  );
                  Navigator.of(context).maybePop();
                },
                icon: const Icon(Icons.close_rounded),
              )
            : null,
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
              onPressed: _busy
                  ? null
                  : () {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#2",
                      );
                      _albumAction('refresh');
                    },
            ),
          IconButton(
            tooltip: _showSearch ? '隐藏搜索' : '搜索本专辑',
            icon: Icon(_showSearch ? Icons.search_off : Icons.search),
            onPressed: () {
              AppLog.instance.trace(
                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#3",
              );
              setState(() {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#3.closure#1",
                );
                _showSearch = !_showSearch;
              });
            },
          ),
          if (compact)
            PopupMenuButton<String>(
              tooltip: '更多操作',
              offset: const Offset(0, 12),
              onSelected: _albumAction,
              itemBuilder: (_) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#4",
                );
                return [
                  ..._orderMenu(),
                  const PopupMenuDivider(),
                  if (_offline)
                    PopupMenuItem(
                      value: 'refresh',
                      enabled: !_busy,
                      child: const Text('刷新专辑'),
                    ),
                  const PopupMenuItem(value: 'tags', child: Text('专辑标签')),
                  const PopupMenuItem(value: 'settings', child: Text('播放设置')),
                ];
              },
            )
          else ...[
            PopupMenuButton<String>(
              tooltip: '目录排序：${_ascending ? "最早在前" : "最新在前"}',
              offset: const Offset(0, 12),
              icon: const Icon(Icons.sort),
              onSelected: _albumAction,
              itemBuilder: (_) {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#5",
                );
                return _orderMenu();
              },
            ),
            IconButton(
              tooltip: '专辑标签',
              icon: const Icon(Icons.edit_note),
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#6",
                );
                _albumAction('tags');
              },
            ),
            IconButton(
              tooltip: '播放设置',
              icon: const Icon(Icons.headphones_outlined),
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#7",
                );
                _albumAction('settings');
              },
            ),
          ],
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            AppLog.instance.trace(
              "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8",
            );

            final padding = EdgeInsets.symmetric(
              horizontal: ((constraints.maxWidth - 960) / 2).clamp(
                0.0,
                double.infinity,
              ),
            );
            return AppScrollbar(
              controller: _albumScroll,
              child: CustomScrollView(
                controller: _albumScroll,
                scrollBehavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                slivers:
                    [
                      SliverToBoxAdapter(
                        child: Column(
                          key: _headerKey,
                          children: [
                            if (widget.initialTrack case final target?)
                              ListTile(
                                title: AdaptiveText('搜索目标：${target.title}'),
                                subtitle: _targetWarning == null
                                    ? null
                                    : Text(_targetWarning!),
                                trailing: TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () {
                                          AppLog.instance.trace(
                                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#1",
                                          );

                                          _filter = '';
                                          _search.clear();
                                          _loadPage(1, target: target);
                                        },
                                  child: const Text('重新定位'),
                                ),
                              ),
                            if (album != null)
                              Padding(
                                padding: EdgeInsets.all(compact ? 8 : 12),
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
                                        size: 72,
                                        downloaded: widget
                                            .runtime
                                            .downloads
                                            .tasks
                                            .any((task) {
                                              AppLog.instance.trace(
                                                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#2",
                                              );
                                              return task.track.albumId ==
                                                      widget.albumId &&
                                                  task.state ==
                                                      DownloadState.completed;
                                            }),
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
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (anchorUid != null ||
                                                  artist.isNotEmpty)
                                                Flexible(
                                                  child: Tooltip(
                                                    message: artist.isEmpty
                                                        ? '查看主播'
                                                        : artist,
                                                    child: TextButton.icon(
                                                      key: const ValueKey(
                                                        'albumAnchorLink',
                                                      ),
                                                      style:
                                                          TextButton.styleFrom(
                                                            minimumSize:
                                                                const Size(
                                                                  48,
                                                                  48,
                                                                ),
                                                          ),
                                                      onPressed: () {
                                                        AppLog.instance.trace(
                                                          'lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#3',
                                                        );
                                                        Navigator.of(
                                                          context,
                                                        ).push(
                                                          MaterialPageRoute<
                                                            void
                                                          >(
                                                            settings:
                                                                const RouteSettings(
                                                                  name: AnchorPage
                                                                      .routeName,
                                                                ),
                                                            builder: (_) {
                                                              AppLog.instance
                                                                  .trace(
                                                                    'lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#3.closure#1',
                                                                  );
                                                              return AnchorPage(
                                                                runtime: widget
                                                                    .runtime,
                                                                uid: anchorUid,
                                                                accountIdentity:
                                                                    widget
                                                                        .accountIdentity,
                                                                albumId:
                                                                    album.id,
                                                                initialName:
                                                                    artist,
                                                                onDownload: widget
                                                                    .onDownload,
                                                                onPlayAlbum: widget
                                                                    .onPlayAlbum,
                                                              );
                                                            },
                                                          ),
                                                        );
                                                      },
                                                      icon: ClipOval(
                                                        child: CoverImage(
                                                          uri: album
                                                              .anchorAvatarUrl,
                                                          size: 24,
                                                        ),
                                                      ),
                                                      label: Text(
                                                        artist.isEmpty
                                                            ? '主播'
                                                            : artist,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              if (anchorUid != null ||
                                                  artist.isNotEmpty)
                                                const SizedBox(width: 8),
                                              Text('${album.total} 集'),
                                            ],
                                          ),
                                          AlbumIntroduction(
                                            text: album.intro,
                                            client: widget.runtime.anonymous,
                                            albumId: album.id,
                                            subscriptionAction: TextButton.icon(
                                              onPressed: _subscriptionBusy
                                                  ? null
                                                  : _changeSubscription,
                                              icon: Icon(
                                                _subscribed == true
                                                    ? Icons.check_circle_outline
                                                    : Icons.add_circle_outline,
                                              ),
                                              label: Text(_subscriptionLabel),
                                            ),
                                            onOpenAlbum: (recommended) {
                                              AppLog.instance.trace(
                                                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#4",
                                              );

                                              Navigator.of(context).push(
                                                MaterialPageRoute<void>(
                                                  builder: (_) {
                                                    AppLog.instance.trace(
                                                      "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#4.closure#1",
                                                    );
                                                    return AlbumPageView(
                                                      runtime: widget.runtime,
                                                      albumId: recommended.id,
                                                      onDownload:
                                                          widget.onDownload,
                                                      onPlayAlbum:
                                                          widget.onPlayAlbum,
                                                    );
                                                  },
                                                ),
                                              );
                                            },
                                          ),
                                          if (_cachedView)
                                            const Text('离线缓存（仅显示已观察目录与已下载声音）'),
                                          if (_subscriptionError != null)
                                            Text(
                                              _subscriptionError!,
                                              style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error,
                                              ),
                                            ),
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
                                  : (_) {
                                      AppLog.instance.trace(
                                        "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#5",
                                      );
                                      _autoDownload(identity);
                                    },
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
                                        onSubmitted: (_) {
                                          AppLog.instance.trace(
                                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#6",
                                          );
                                          _filterAll();
                                        },
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
                                    onPressed: () {
                                      AppLog.instance.trace(
                                        'lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#7',
                                      );
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) {
                                            AppLog.instance.trace(
                                              'lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#7.closure#1',
                                            );
                                            return AlbumReviewsPage(
                                              runtime: widget.runtime,
                                              albumId: widget.albumId,
                                              accountIdentity:
                                                  widget.accountIdentity,
                                              albumTitle: _album?.title ?? '',
                                              onDownload: widget.onDownload,
                                              onPlayAlbum: widget.onPlayAlbum,
                                            );
                                          },
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.reviews_outlined),
                                    label: const Text('评价'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () {
                                      AppLog.instance.trace(
                                        "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#8",
                                      );
                                      setState(() {
                                        AppLog.instance.trace(
                                          "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#8.closure#1",
                                        );

                                        if (_selectionMode) {
                                          _clearSelection();
                                        } else {
                                          _selectionMode = true;
                                        }
                                      });
                                    },
                                    icon: Icon(
                                      _selectionMode
                                          ? Icons.close
                                          : Icons.checklist,
                                    ),
                                    label: Text(
                                      _selectionMode ? '退出下载模式' : '进入下载模式',
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: canDownload
                                        ? () {
                                            AppLog.instance.trace(
                                              "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#9",
                                            );
                                            _download(all: true);
                                          }
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
                                          ? () {
                                              AppLog.instance.trace(
                                                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#10",
                                              );
                                              _download();
                                            }
                                          : null,
                                      child: Text('下载所选 (${_selected.length})'),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        AppLog.instance.trace(
                                          "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#11",
                                        );
                                        setState(() {
                                          AppLog.instance.trace(
                                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#11.closure#1",
                                          );

                                          for (final track in _visible) {
                                            _select(track, true);
                                          }
                                        });
                                      },
                                      child: const Text('选择本页'),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        AppLog.instance.trace(
                                          "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#12",
                                        );
                                        setState(_clearSelection);
                                      },
                                      child: const Text('清除选择'),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            _orderControl(),
                            if (_busy) const LinearProgressIndicator(),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  children: [
                                    Text(
                                      _error!,
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                      ),
                                    ),
                                    if (_album == null) ...[
                                      const SizedBox(height: 8),
                                      TextButton.icon(
                                        onPressed: _busy
                                            ? null
                                            : () {
                                                AppLog.instance.trace(
                                                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#13",
                                                );
                                                _loadPage(_page);
                                              },
                                        icon: const Icon(Icons.refresh_rounded),
                                        label: const Text('重新加载专辑'),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      SliverFixedExtentList.builder(
                        itemExtent: _trackExtent,
                        itemCount: _visible.length,
                        itemBuilder: (_, index) {
                          AppLog.instance.trace(
                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#14",
                          );

                          final track = _visible[index];
                          final downloaded = _downloaded.contains(track.id);
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            minTileHeight: _trackExtent,
                            minVerticalPadding: 4,
                            horizontalTitleGap: 12,
                            selected:
                                track.id == widget.initialTrack?.id &&
                                track.albumId == widget.albumId &&
                                _targetWarning == null,
                            leading: _selectionMode
                                ? Checkbox(
                                    value: _selected.containsKey(track.id),
                                    onChanged: downloaded
                                        ? null
                                        : (value) {
                                            AppLog.instance.trace(
                                              "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#14.closure#1",
                                            );
                                            setState(() {
                                              AppLog.instance.trace(
                                                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#14.closure#1.closure#1",
                                              );
                                              _select(track, value == true);
                                            });
                                          },
                                  )
                                : (compact
                                      ? null
                                      : CoverImage(
                                          size: 48,
                                          uri:
                                              track.coverUrl ?? album?.coverUrl,
                                          downloaded: downloaded,
                                          localPath: widget
                                              .runtime
                                              .albumCache[widget.albumId]
                                              ?.coverPath,
                                        )),
                            title: AdaptiveText(track.title),
                            subtitle: Text(
                              '${_duration(track.duration)}${downloaded ? ' · 已下载' : ''}',
                            ),
                            trailing: _menu(track),
                            onLongPress: () {
                              AppLog.instance.trace(
                                "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#14.closure#2",
                              );
                              setState(() {
                                AppLog.instance.trace(
                                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#14.closure#2.closure#1",
                                );

                                _selectionMode = true;
                                _select(track, true);
                              });
                            },
                            onTap: _selectionMode
                                ? downloaded
                                      ? null
                                      : () {
                                          AppLog.instance.trace(
                                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#14.closure#3",
                                          );
                                          setState(() {
                                            AppLog.instance.trace(
                                              "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#14.closure#3.closure#1",
                                            );
                                            _select(
                                              track,
                                              !_selected.containsKey(track.id),
                                            );
                                          });
                                        }
                                : () {
                                    AppLog.instance.trace(
                                      "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#14.closure#4",
                                    );
                                    unawaited(
                                      AppLog.instance.runWithErrorScope(
                                        () async {
                                          AppLog.instance.trace(
                                            "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#14.closure#4.closure#1",
                                          );

                                          try {
                                            await _play(track);
                                          } catch (error, stack) {
                                            _recordCatalogueError(
                                              'Playback failed',
                                              error,
                                              stack,
                                            );
                                            if (mounted)
                                              setState(() {
                                                AppLog.instance.trace(
                                                  "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#14.closure#4.closure#1.closure#1",
                                                );
                                                _error = _safeError(error);
                                              });
                                          }
                                        },
                                      ),
                                    );
                                  },
                          );
                        },
                      ),
                      if (_album != null)
                        SliverToBoxAdapter(
                          child: ContentPaging(
                            page: _page,
                            total: _total,
                            pageSize: _pageSize,
                            busy: _busy,
                            onPage: _loadPage,
                          ),
                        ),
                    ].map((sliver) {
                      AppLog.instance.trace(
                        "lib/pages/catalogue_page.dart::_AlbumPageViewState.build.closure#8.closure#15",
                      );
                      return SliverPadding(padding: padding, sliver: sliver);
                    }).toList(),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FavoriteMenuItem extends PopupMenuEntry<String> {
  const _FavoriteMenuItem({required this.client, required this.trackId});

  final XmlyClient client;
  final String trackId;

  @override
  double get height {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItem.height.get",
    );
    return kMinInteractiveDimension;
  }

  @override
  bool represents(String? value) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItem.represents",
    );
    return const {'favorite', 'unfavorite', 'retryFavorite'}.contains(value);
  }

  @override
  State<_FavoriteMenuItem> createState() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItem.createState",
    );
    return _FavoriteMenuItemState();
  }
}

class _FavoriteMenuItemState extends State<_FavoriteMenuItem> {
  late final Future<bool> _favorite;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItemState.initState",
    );

    super.initState();
    _favorite = _loadFavorite();
  }

  Future<bool> _loadFavorite() {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItemState._loadFavorite",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/catalogue_page.dart::_FavoriteMenuItemState._loadFavorite.closure#1",
      );

      try {
        return await XmlyExperience(widget.client).isFavorite(widget.trackId);
      } catch (error, stack) {
        _recordCatalogueError('Favorite menu status failed', error, stack);
        rethrow;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/catalogue_page.dart::_FavoriteMenuItemState.build",
    );
    return FutureBuilder<bool>(
      future: _favorite,
      builder: (context, snapshot) {
        AppLog.instance.trace(
          "lib/pages/catalogue_page.dart::_FavoriteMenuItemState.build.closure#1",
        );

        final ready = snapshot.connectionState == ConnectionState.done;
        return PopupMenuItem<String>(
          enabled: ready,
          value: snapshot.hasError
              ? 'retryFavorite'
              : snapshot.data == true
              ? 'unfavorite'
              : 'favorite',
          child: Text(
            !ready
                ? '正在读取收藏状态…'
                : snapshot.hasError
                ? '重试收藏状态'
                : snapshot.data == true
                ? '取消收藏'
                : '收藏',
          ),
        );
      },
    );
  }
}

class CoverImage extends StatelessWidget {
  const CoverImage({
    required this.uri,
    this.localPath,
    this.size = 52,
    this.downloaded = false,
    super.key,
  });
  final String? localPath;
  final Uri? uri;
  final double size;
  final bool downloaded;
  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/catalogue_page.dart::CoverImage.build");

    if (MediaQuery.sizeOf(context).width < 320) return const SizedBox.shrink();
    return Stack(
      children: [
        ClipRRect(
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
                      errorBuilder: (_, error, stack) {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::CoverImage.build.closure#1",
                        );

                        _recordCatalogueError(
                          'Cached cover load failed',
                          error,
                          stack ?? StackTrace.current,
                          recoverable: true,
                        );
                        return const Icon(Icons.album_outlined);
                      },
                    )
                  : uri == null
                  ? const Icon(Icons.album_outlined)
                  : Image(
                      image: LoggedNetworkImage(uri.toString()),
                      fit: BoxFit.cover,
                      frameBuilder: (_, child, frame, synchronous) {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::CoverImage.build.closure#2",
                        );
                        return frame != null || synchronous
                            ? child
                            : const Icon(Icons.album_outlined);
                      },
                      errorBuilder: (_, _, _) {
                        AppLog.instance.trace(
                          "lib/pages/catalogue_page.dart::CoverImage.build.closure#3",
                        );
                        return const Icon(Icons.album_outlined);
                      },
                    ),
            ),
          ),
        ),
        if (downloaded)
          Positioned(
            right: 2,
            bottom: 2,
            child: Tooltip(
              message: '已下载',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.surface,
                ),
                child: Icon(
                  Icons.check_circle,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String _duration(double seconds) {
  AppLog.instance.trace("lib/pages/catalogue_page.dart::_duration");
  return '${seconds ~/ 60}:${(seconds.toInt() % 60).toString().padLeft(2, '0')}';
}

String _safeError(Object error) {
  AppLog.instance.trace("lib/pages/catalogue_page.dart::_safeError");
  return error is XmlyException ? error.message : '请求未完成，请稍后重试';
}
