import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/widgets/app_scrollbar.dart';
import '../api/xmly_anchor.dart';
import '../api/xmly_client.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/content_paging.dart';
import '../common/widgets/app_tab_button.dart';
import '../common/widgets/logged_network_image.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart';
import 'download_page.dart' show requestDownloads;

class AnchorPage extends StatefulWidget {
  const AnchorPage({
    required this.runtime,
    this.uid,
    this.albumId,
    this.trackId,
    this.initialName = '',
    this.accountIdentity,
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  }) : assert(uid != null || albumId != null || trackId != null);

  static const routeName = '/anchor';
  final AppRuntime runtime;
  final String? uid, albumId, trackId;
  final String? accountIdentity;
  final String initialName;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;

  @override
  State<AnchorPage> createState() {
    AppLog.instance.trace("lib/pages/anchor_page.dart::AnchorPage.createState");

    return _AnchorPageState();
  }
}

enum _AnchorOrder { defaultOrder, latest, oldest, popular }

class _AnchorListing<T> {
  _AnchorListing({required this.pageSize}) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorListing.new");
  }

  List<T> items = [], source = [];
  int page = 0, requestedPage = 1, pageSize;
  int? total, reportedTotal, sourceReportedTotal;
  _AnchorOrder order = _AnchorOrder.defaultOrder;
  Completer<void>? cancelled;
  int request = 0, loaded = 0;
  int? loadingTotal;
  bool busy = false,
      sourceReady = false,
      refreshNeeded = false,
      datesReady = false;
  String? error;

  void cancel() {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorListing.cancel");
    request++;
    cancelled?.complete();
    cancelled = null;
    busy = false;
  }
}

class _AnchorPageState extends State<AnchorPage>
    with SingleTickerProviderStateMixin {
  final _scrolls = [ScrollController(), ScrollController()];
  ScrollController get _scroll {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState._scroll.get',
    );
    return _scrolls[_selected];
  }

  late final TabController _tabs;
  Completer<void> _cancelled = Completer<void>();
  int _generation = 0, _selected = 0, _playRequest = 0;
  String? _uid, _resolveError, _profileError;
  AnchorProfile? _profile;
  bool _resolving = true, _profileBusy = false;
  bool _expanded = false;
  XmlyClient? _followClient;
  String? _followKey, _followError;
  bool? _following;
  bool _followBusy = false, _followMutating = false;
  int _followRequest = 0, _libraryRevision = -1;
  _AnchorListing<AnchorAlbum> _albums = _AnchorListing(pageSize: 10);
  _AnchorListing<Track> _tracks = _AnchorListing(pageSize: 20);

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState.initState",
    );

    super.initState();
    _tabs = TabController(length: 2, vsync: this)..addListener(_selectTab);
    widget.runtime.addListener(_runtimeChanged);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant AnchorPage oldWidget) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_runtimeChanged);
      widget.runtime.addListener(_runtimeChanged);
    }
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.accountIdentity != widget.accountIdentity ||
        oldWidget.uid != widget.uid ||
        oldWidget.albumId != widget.albumId ||
        oldWidget.trackId != widget.trackId) {
      _refresh();
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState.dispose",
    );

    _generation++;
    _playRequest++;
    _followRequest++;
    widget.runtime.removeListener(_runtimeChanged);
    _cancelled.complete();
    _albums.cancel();
    _tracks.cancel();
    _tabs.dispose();
    for (final scroll in _scrolls) {
      scroll.dispose();
    }
    super.dispose();
  }

  bool _current(int generation) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._current",
    );

    return mounted && generation == _generation;
  }

  Future<T> _read<T>(
    Future<T> Function(XmlyAnchor) action, {
    Future<void>? cancelled,
  }) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorPageState._read");

    final client = widget.runtime.anonymous;
    return client.withReadPolicy(
      () {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._read.closure#1",
        );
        return action(XmlyAnchor(client));
      },
      rateLimitRetries: 0,
      cancelled: cancelled == null
          ? _cancelled.future
          : Future.any([_cancelled.future, cancelled]),
    );
  }

  void _record(String operation, Object error, StackTrace stack) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._record",
    );

    if (AppLog.instance.errorWasRecorded(error)) return;
    AppLog.instance.write(
      AppLogLevel.error,
      'anchor_page',
      operation,
      error: error,
      stackTrace: stack,
      promptUser: false,
    );
  }

  Future<void> _refresh() async {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._refresh",
    );

    final generation = ++_generation;
    _albums.cancel();
    _tracks.cancel();
    _cancelled.complete();
    _cancelled = Completer<void>();
    _playRequest++;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._refresh.closure#1",
      );

      _uid = null;
      _profile = null;
      _resolveError = _profileError = null;
      _resolving = true;
      _profileBusy = false;
      _expanded = false;
      _albums = _AnchorListing(pageSize: 10)..order = _albums.order;
      _tracks = _AnchorListing(pageSize: 20)..order = _tracks.order;
      _followRequest++;
      _following = null;
      _followError = null;
      _followBusy = _followMutating = false;
    });
    try {
      final uid = widget.uid != null
          ? xmlyIdentifier(widget.uid!)
          : await _read((api) {
              AppLog.instance.trace(
                "lib/pages/anchor_page.dart::_AnchorPageState._refresh.closure#2",
              );

              if (widget.trackId != null)
                return api.trackAnchor(widget.trackId!);
              return api.albumAnchor(widget.albumId!);
            });
      if (!_current(generation)) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._refresh.closure#3",
        );
        _uid = uid;
        _resolving = false;
      });
      await Future.wait([_loadProfile(), _loadSelected(), _loadFollowing()]);
    } catch (error, stack) {
      if (!_current(generation)) return;
      _record('Resolving anchor failed', error, stack);
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._refresh.closure#4",
        );

        _resolving = _profileBusy = false;
        _resolveError = '主播资料加载失败';
      });
    }
  }

  Future<void> _reload() async {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._reload",
    );
    if (_uid == null) return _refresh();
    if (_selected == 0) {
      _albums.cancel();
      _albums.source = [];
      _albums.sourceReady = _albums.datesReady = false;
    } else {
      _tracks.cancel();
      _tracks.source = [];
      _tracks.sourceReady = _tracks.datesReady = false;
    }
    await Future.wait([
      _loadProfile(),
      _loadSelected(page: 1),
      _loadFollowing(),
    ]);
  }

  Future<void> _loadProfile() async {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile",
    );

    final generation = _generation;
    final uid = _uid;
    if (uid == null || _profileBusy) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#1",
      );
      _profileBusy = true;
      _profileError = null;
    });
    try {
      final profile = await _read((api) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#2",
        );
        return api.profile(uid);
      });
      if (!_current(generation)) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#3",
        );
        _profile = profile;
      });
    } catch (error, stack) {
      if (!_current(generation)) return;
      _record('Loading anchor profile failed', error, stack);
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#4",
        );
        _profileError = '主播资料加载失败';
      });
    } finally {
      if (_current(generation))
        setState(() {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#5",
          );
          _profileBusy = false;
        });
    }
  }

  Future<void> _loadSelected({int? page}) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected",
    );

    if (_selected == 0) {
      return _load<AnchorAlbum>(
        _albums,
        (api, uid, page) {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected.closure#1",
          );
          return api.albums(uid, page: page);
        },
        (album) {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected.closure#2",
          );
          return album.album.id;
        },
        (api, uid, progress) {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected.closure#3",
          );
          return api.allAlbums(
            uid,
            withDates:
                _albums.order == _AnchorOrder.latest ||
                _albums.order == _AnchorOrder.oldest,
            onProgress: progress,
          );
        },
        (item) {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected.closure#4",
          );
          return item.playCount ?? 0;
        },
        page: page ?? _albums.requestedPage,
      );
    }
    return _load<Track>(
      _tracks,
      (api, uid, page) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected.closure#5",
        );
        return api.tracks(uid, page: page);
      },
      (track) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected.closure#6",
        );
        return track.id;
      },
      (api, uid, progress) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadSelected.closure#7",
        );
        return api.allTracks(uid, onProgress: progress);
      },
      _trackPlays,
      page: page ?? _tracks.requestedPage,
    );
  }

  int _trackPlays(Track track) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._trackPlays",
    );

    return xmlyPositive(track.raw['play']) ?? 0;
  }

  String _trackDescription(Track track) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._trackDescription",
    );

    final timestamp = xmlyPositive(track.raw['date']);
    final date = timestamp == null
        ? ''
        : DateTime.fromMillisecondsSinceEpoch(timestamp)
              .toIso8601String()
              .substring(0, 10);
    return [
      if (track.album.isNotEmpty) track.album,
      if (date.isNotEmpty) date,
      '${track.duration ~/ 60}:${(track.duration.toInt() % 60).toString().padLeft(2, '0')}',
      '${_count(_trackPlays(track))} 次播放',
    ].join(' · ');
  }

  int? _createdAt(Object? item) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._createdAt",
    );

    return switch (item) {
      AnchorAlbum() => item.createdAt?.millisecondsSinceEpoch,
      Track() => xmlyPositive(item.raw['date']),
      _ => null,
    };
  }

  bool _hasDate(Object? item) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._hasDate",
    );

    return _createdAt(item) != null;
  }

  List<T> _ordered<T>(_AnchorListing<T> listing, int Function(T) plays) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._ordered",
    );

    switch (listing.order) {
      case _AnchorOrder.defaultOrder:
        return List.of(listing.source);
      case _AnchorOrder.latest:
      case _AnchorOrder.oldest:
      case _AnchorOrder.popular:
        final ranked = listing.source.asMap().entries.toList();
        ranked.sort((a, b) {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._ordered.closure#1",
          );

          final int result;
          if (listing.order == _AnchorOrder.popular) {
            result = plays(b.value).compareTo(plays(a.value));
          } else {
            final aDate = _createdAt(a.value), bDate = _createdAt(b.value);
            result = aDate == null
                ? (bDate == null ? 0 : 1)
                : bDate == null
                ? -1
                : listing.order == _AnchorOrder.latest
                ? bDate.compareTo(aDate)
                : aDate.compareTo(bDate);
          }
          return result == 0 ? a.key.compareTo(b.key) : result;
        });
        return ranked.map((entry) {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._ordered.closure#2",
          );
          return entry.value;
        }).toList();
    }
  }

  void _setListingOrder<T>(_AnchorListing<T> listing, _AnchorOrder order) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._setListingOrder",
    );
    if (listing.order == order) return;
    listing.cancel();
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._setListingOrder.closure#1",
      );
      listing.order = order;
      listing.requestedPage = 1;
      listing.error = null;
      listing.items = [];
    });
    unawaited(_loadSelected(page: 1));
  }

  void _showSourcePage<T>(
    _AnchorListing<T> listing,
    int Function(T) plays,
    int page,
  ) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._showSourcePage",
    );
    final ordered = _ordered(listing, plays);
    final last = math.max(1, (ordered.length / listing.pageSize).ceil());
    final target = page.clamp(1, last).toInt();
    listing.items = ordered
        .skip((target - 1) * listing.pageSize)
        .take(listing.pageSize)
        .toList();
    listing.page = listing.requestedPage = target;
    listing.total = ordered.length;
    listing.reportedTotal = listing.sourceReportedTotal;
  }

  Widget _orderControls() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._orderControls",
    );

    final order = _selected == 0 ? _albums.order : _tracks.order;
    return AppTabStrip(
      children: [
        for (final entry in const {
          _AnchorOrder.defaultOrder: '默认',
          _AnchorOrder.latest: '最新',
          _AnchorOrder.oldest: '最早',
          _AnchorOrder.popular: '最多播放',
        }.entries)
          AppTabButton(
            key: ValueKey('anchorOrder-${entry.key.name}'),
            label: entry.value,
            selected: order == entry.key,
            onPressed: () {
              AppLog.instance.trace(
                "lib/pages/anchor_page.dart::_AnchorPageState._orderControls.closure#1",
              );

              if (_selected == 0) {
                _setListingOrder(_albums, entry.key);
              } else {
                _setListingOrder(_tracks, entry.key);
              }
            },
          ),
      ],
    );
  }

  Future<void> _load<T>(
    _AnchorListing<T> listing,
    Future<AnchorContentPage<T>> Function(XmlyAnchor, String, int) fetch,
    String Function(T) id,
    Future<AnchorContentPage<T>> Function(
      XmlyAnchor,
      String,
      void Function(int, int?),
    )
    fetchAll,
    int Function(T) plays, {
    required int page,
  }) async {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorPageState._load");
    final generation = _generation;
    final uid = _uid;
    if (uid == null || page < 1) return;
    listing.cancel();
    final request = listing.request;
    final complete = listing.order != _AnchorOrder.defaultOrder;
    final timeOrder =
        listing.order == _AnchorOrder.latest ||
        listing.order == _AnchorOrder.oldest;
    final scroll = identical(listing, _albums) ? _scrolls[0] : _scrolls[1];
    if (complete && listing.sourceReady && (!timeOrder || listing.datesReady)) {
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#1",
        );
        listing.error = null;
        listing.refreshNeeded = false;
        _showSourcePage(listing, plays, page);
      });
      if (scroll.hasClients) scroll.jumpTo(0);
      return;
    }
    final cancelled = listing.cancelled = Completer<void>();
    bool active() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._load.active",
      );
      return _current(generation) && listing.request == request;
    }

    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#2",
      );
      listing.requestedPage = page;
      listing.busy = true;
      listing.error = null;
      listing.refreshNeeded = false;
      listing.loaded = 0;
      listing.loadingTotal = listing.total;
    });
    try {
      final next = await _read((api) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#3",
        );
        if (complete) {
          return fetchAll(api, uid, (loaded, total) {
            AppLog.instance.trace(
              "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#3.closure#1",
            );
            if (!active()) return;
            setState(() {
              AppLog.instance.trace(
                "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#3.closure#1.closure#1",
              );
              listing.loaded = loaded;
              listing.loadingTotal = total;
            });
          });
        }
        return fetch(api, uid, page);
      }, cancelled: cancelled.future);
      if (!active()) return;
      final seen = <String>{};
      for (final item in next.items) {
        if (!seen.add(id(item))) {
          throw const XmlyException('repeated_page', '列表分页重复，请刷新后重试');
        }
      }
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#4",
        );
        listing.reportedTotal = next.reportedTotal;
        if (complete) {
          listing.source = next.items;
          listing.sourceReportedTotal = next.reportedTotal;
          listing.sourceReady = true;
          listing.datesReady = listing.source.every(_hasDate);
          _showSourcePage(listing, plays, page);
        } else {
          if (listing.sourceReady &&
              next.reportedTotal != listing.sourceReportedTotal) {
            listing.source = [];
            listing.sourceReady = listing.datesReady = false;
          }
          listing.items = next.items;
          listing.page = next.page;
          listing.pageSize = next.pageSize;
          listing.total = next.total;
        }
      });
      if (scroll.hasClients) scroll.jumpTo(0);
    } catch (error, stack) {
      if (!active()) return;
      _record('Loading anchor content failed', error, stack);
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#5",
        );
        listing.refreshNeeded =
            error is XmlyException && error.code == 'repeated_page';
        listing.error = error is XmlyException ? error.message : '列表加载失败';
      });
    } finally {
      if (identical(listing.cancelled, cancelled)) listing.cancelled = null;
      if (active()) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._load.closure#6",
          );
          listing.busy = false;
        });
      }
    }
  }

  void _selectTab() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._selectTab",
    );

    if (_tabs.index == _selected) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._selectTab.closure#1",
      );
      _selected = _tabs.index;
    });
    final loaded = _selected == 0 ? _albums.page : _tracks.page;
    final busy = _selected == 0 ? _albums.busy : _tracks.busy;
    if (loaded == 0 && !busy) _loadSelected();
  }

  void _openAlbum(String albumId, {Track? track}) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._openAlbum",
    );

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._openAlbum.closure#1",
          );

          return AlbumPageView(
            runtime: widget.runtime,
            albumId: albumId,
            initialTrack: track,
            accountIdentity: widget.accountIdentity,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  Future<void> _play(Track track) async {
    AppLog.instance.trace('lib/pages/anchor_page.dart::_AnchorPageState._play');
    final request = ++_playRequest;
    try {
      if (track.albumId.isEmpty) {
        await widget.runtime.player.playTrack(
          track,
          accountIdentity: widget.accountIdentity,
        );
      } else if (widget.onPlayAlbum != null && widget.accountIdentity == null) {
        await widget.onPlayAlbum!(track.albumId, track.id, track: track);
      } else {
        await widget.runtime.player.playAlbum(
          track.albumId,
          track.id,
          track: track,
          accountIdentity: widget.accountIdentity,
        );
      }
    } catch (error, stack) {
      _record('Playing anchor track failed', error, stack);
      if (mounted && request == _playRequest) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('暂时无法播放，请重试')));
      }
    }
  }

  Future<void> _download(Track track) async {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState._download',
    );
    final generation = _generation;
    try {
      if (widget.onDownload != null && widget.accountIdentity == null) {
        await widget.onDownload!([track]);
      } else {
        await requestDownloads(context, widget.runtime, [
          track,
        ], accountIdentity: widget.accountIdentity);
      }
    } catch (error, stack) {
      _record('Downloading anchor track failed', error, stack);
      if (_current(generation)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('暂时无法下载，请重试')));
      }
    }
  }

  String _count(int value) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._count",
    );

    if (value >= 100000000) return '${(value / 100000000).toStringAsFixed(1)}亿';
    if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
    return '$value';
  }

  XmlyClient get _primaryClient {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._primaryClient.get",
    );

    final accounts = widget.runtime.accounts;
    final identity = accounts.primaryAccountId;
    return identity != null && accounts.accountIds.contains(identity)
        ? accounts.clientFor(identity)
        : widget.runtime.anonymous;
  }

  bool _sameFollow(XmlyClient client, String key, String uid, int request) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._sameFollow",
    );

    return mounted &&
        request == _followRequest &&
        _uid == uid &&
        identical(client, _primaryClient) &&
        client.cacheIdentity == key;
  }

  void _runtimeChanged() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._runtimeChanged",
    );

    if (!mounted || _uid == null) return;
    final client = _primaryClient;
    final accountChanged =
        !identical(client, _followClient) || client.cacheIdentity != _followKey;
    final libraryChanged = widget.runtime.libraryRevision != _libraryRevision;
    if (accountChanged) {
      unawaited(_refresh());
    } else if (libraryChanged && !_followMutating) {
      unawaited(_loadFollowing());
    }
  }

  Future<void> _loadFollowing() async {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._loadFollowing",
    );

    final uid = _uid;
    if (uid == null) return;
    final client = _primaryClient, key = _primaryClient.cacheIdentity;
    final request = ++_followRequest;
    _followClient = client;
    _followKey = key;
    _libraryRevision = widget.runtime.libraryRevision;
    final canRead = client.accountAvailable && client.credentials!.uid != uid;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._loadFollowing.closure#1",
      );

      _following = null;
      _followError = null;
      _followBusy = canRead;
      _followMutating = false;
    });
    if (!canRead) return;
    try {
      final followed = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._loadFollowing.closure#2",
          );
          return XmlyAnchor(client).isFollowing(uid);
        },
        rateLimitRetries: 0,
        cancelled: _cancelled.future,
      );
      if (_sameFollow(client, key, uid, request)) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._loadFollowing.closure#3",
          );
          _following = followed;
        });
      }
    } catch (error, stack) {
      if (!_sameFollow(client, key, uid, request)) return;
      _record('Loading following status failed', error, stack);
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._loadFollowing.closure#4",
        );

        _followError = error is XmlyException ? error.message : '关注状态加载失败，请重试';
      });
    } finally {
      if (_sameFollow(client, key, uid, request)) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._loadFollowing.closure#5",
          );
          _followBusy = false;
        });
      }
    }
  }

  Future<void> _changeFollowing() async {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._changeFollowing",
    );

    final uid = _uid;
    if (_followBusy || uid == null) return;
    final runtime = widget.runtime;
    final client = _primaryClient, key = _primaryClient.cacheIdentity;
    if (!client.accountAvailable) {
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._changeFollowing.closure#1",
        );
        _followError = '请先登录主账号后关注主播';
      });
      return;
    }
    if (_following == null ||
        !identical(client, _followClient) ||
        key != _followKey) {
      return _loadFollowing();
    }
    final desired = !_following!, request = ++_followRequest;
    var attempted = false;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/anchor_page.dart::_AnchorPageState._changeFollowing.closure#2",
      );

      _followBusy = _followMutating = true;
      _followError = null;
    });
    try {
      await runtime.accounts.runWithAccount(client.identity, (admitted) async {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._changeFollowing.closure#3",
        );

        if (!_sameFollow(client, key, uid, request) ||
            !identical(client, admitted)) {
          throw const XmlyException('account_changed', '主账号已变更，请重试');
        }
        attempted = true;
        await XmlyAnchor(admitted).setFollowing(uid, following: desired);
      });
      runtime.libraryChanged();
      if (_sameFollow(client, key, uid, request)) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._changeFollowing.closure#4",
          );
          _following = desired;
        });
      }
    } catch (error, stack) {
      _record('Changing following failed', error, stack);
      if (attempted) runtime.libraryChanged();
      if (!_sameFollow(client, key, uid, request)) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._changeFollowing.closure#5",
        );

        _following = null;
        _followError = error is XmlyException ? error.message : '关注操作未完成，请重试';
      });
      // Reconcile uncertain writes with a read; never replay a follow request.
      if (attempted) {
        try {
          final followed = await XmlyAnchor(client).isFollowing(uid);
          if (_sameFollow(client, key, uid, request)) {
            setState(() {
              AppLog.instance.trace(
                "lib/pages/anchor_page.dart::_AnchorPageState._changeFollowing.closure#6",
              );

              _following = followed;
              if (followed == desired) _followError = null;
            });
          }
        } catch (error, stack) {
          _record('Reconciling following failed', error, stack);
        }
      }
    } finally {
      if (_sameFollow(client, key, uid, request)) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/anchor_page.dart::_AnchorPageState._changeFollowing.closure#7",
          );
          _followBusy = _followMutating = false;
        });
      }
    }
  }

  Widget _followButton() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._followButton",
    );

    final client = _primaryClient;
    if (client.credentials?.uid == _uid) return const SizedBox.shrink();
    return Tooltip(
      message: _following == true ? '使用主账号取消关注' : '使用主账号关注主播',
      child: OutlinedButton.icon(
        key: const ValueKey('anchorFollow'),
        onPressed: _followBusy ? null : _changeFollowing,
        icon: _followBusy
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(_following == true ? Icons.check : Icons.add, size: 18),
        label: Text(
          !client.accountAvailable
              ? '登录后关注'
              : _following == true
              ? '已关注'
              : _following == null && _followError != null
              ? '重试关注状态'
              : '关注',
        ),
      ),
    );
  }

  Widget _avatar(double size) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._avatar",
    );

    final colors = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Icon(
        Icons.person_outline,
        size: size * .45,
        color: colors.onSurfaceVariant,
      ),
    );
    final uri = _profile?.avatar;
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: uri == null
            ? fallback
            : Image(
                image: LoggedNetworkImage(uri.toString()),
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                errorBuilder: (_, __, ___) {
                  AppLog.instance.trace(
                    "lib/pages/anchor_page.dart::_AnchorPageState._avatar.closure#1",
                  );
                  return fallback;
                },
              ),
      ),
    );
  }

  Widget _stat(int value, String label) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorPageState._stat");

    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: _count(value),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: '  $label',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statistics() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._statistics",
    );

    final profile = _profile;
    return Wrap(
      spacing: 24,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (profile?.following case final count?) _stat(count, '关注'),
        if (profile?.fans case final count?) _stat(count, '粉丝'),
      ],
    );
  }

  Widget _description() {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState._description',
    );
    final profile = _profile;
    if (profile == null) return const SizedBox.shrink();
    final text = [
      if (profile.verification.isNotEmpty)
        profile.verified
            ? '认证信息：${profile.verification}'
            : profile.verification,
      if (profile.intro.isNotEmpty) profile.intro,
      if (profile.location.isNotEmpty) profile.location,
    ].toSet().join('\n');
    if (text.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          maxLines: _expanded ? null : 3,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        TextButton(
          onPressed: () {
            AppLog.instance.trace(
              'lib/pages/anchor_page.dart::_AnchorPageState._description.closure#1',
            );
            setState(() {
              AppLog.instance.trace(
                'lib/pages/anchor_page.dart::_AnchorPageState._description.closure#1.closure#1',
              );
              _expanded = !_expanded;
            });
          },
          child: Text(_expanded ? '收起简介' : '展开简介'),
        ),
      ],
    );
  }

  Widget _header() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._header",
    );

    final profile = _profile;
    final theme = Theme.of(context);
    final name =
        profile?.nickname ??
        (widget.initialName.isEmpty ? '主播' : widget.initialName);
    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._header.closure#1",
        );

        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final wide = constraints.maxWidth >= 640 * scale;
        final badges = <Widget>[
          if (profile?.verified == true)
            Icon(
              Icons.verified_rounded,
              size: 20,
              color: theme.colorScheme.primary,
              semanticLabel: '已认证',
            ),
          if (profile?.level case final level?)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer.withValues(
                  alpha: .6,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Lv$level',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ];
        return Padding(
          padding: EdgeInsets.symmetric(vertical: wide ? 24 : 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (profile?.background case final background?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: SizedBox(
                      height: wide ? 180 : 120,
                      width: double.infinity,
                      child: Image(
                        image: LoggedNetworkImage(background.toString()),
                        fit: BoxFit.cover,
                        excludeFromSemantics: true,
                        errorBuilder: (_, __, ___) {
                          AppLog.instance.trace(
                            'lib/pages/anchor_page.dart::_AnchorPageState._header.closure#1.closure#1',
                          );
                          return ColoredBox(
                            color: theme.colorScheme.surfaceContainerHighest,
                          );
                        },
                      ),
                    ),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _avatar(wide ? 112 : 80),
                  SizedBox(width: wide ? 28 : 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontSize: wide ? 28 : 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (badges.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: badges,
                            ),
                          ),
                        if (wide) ...[
                          const SizedBox(height: 12),
                          _statistics(),
                          const SizedBox(height: 12),
                          _description(),
                        ],
                        if (!wide && profile != null) ...[
                          const SizedBox(height: 8),
                          _followButton(),
                        ],
                      ],
                    ),
                  ),
                  if (wide && profile != null) ...[
                    const SizedBox(width: 24),
                    _followButton(),
                  ],
                ],
              ),
              if (!wide) ...[
                const SizedBox(height: 16),
                _statistics(),
                const SizedBox(height: 10),
                _description(),
              ],
              if (_profileBusy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (_profileError != null) _retry(_profileError!, _loadProfile),
              if (_followError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _followError!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _retry(
    String message,
    Future<void> Function() action, {
    String label = '重试',
  }) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._retry",
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          TextButton(onPressed: action, child: Text(label)),
        ],
      ),
    );
  }

  Widget _footer<T>(_AnchorListing<T> listing, String empty) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._footer",
    );
    return Column(
      children: [
        if (listing.busy) ...[
          const LinearProgressIndicator(semanticsLabel: '正在加载作品'),
          if (listing.order != _AnchorOrder.defaultOrder)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '正在排序 ${listing.loaded}'
                '${listing.loadingTotal == null ? "" : " / ${listing.loadingTotal}"}',
              ),
            ),
        ],
        if (listing.error != null)
          _retry(
            listing.error!,
            listing.refreshNeeded ? _refresh : _loadSelected,
            label: listing.refreshNeeded ? '刷新' : '重试',
          ),
        if (!listing.busy && listing.page > 0 && listing.items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: Text(empty)),
          ),
        if (listing.page > 0 && listing.total != null)
          ContentPaging(
            page: listing.page,
            total: listing.total!,
            pageSize: listing.pageSize,
            busy: listing.busy,
            onPage: (page) {
              AppLog.instance.trace(
                "lib/pages/anchor_page.dart::_AnchorPageState._footer.closure#1",
              );
              return _loadSelected(page: page);
            },
          ),
      ],
    );
  }

  Widget _albumList() {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorPageState._albumList",
    );

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          "lib/pages/anchor_page.dart::_AnchorPageState._albumList.closure#1",
        );

        final scaler = MediaQuery.textScalerOf(context);
        final scale = math.max(1.0, scaler.scale(16) / 16);
        final width = constraints.crossAxisExtent;
        final columns = width >= 880 * scale ? 2 : 1;
        final coverSize = width >= 640 ? 112.0 : 88.0;
        final titleSize = width >= 640 ? 18.0 : 16.0;
        final textHeight =
            (scaler.scale(titleSize) * 1.4).ceilToDouble() * 2 +
            (scaler.scale(14) * 1.5).ceilToDouble() +
            (scaler.scale(12) * 1.4).ceilToDouble() +
            20;
        return SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 28,
            mainAxisSpacing: width >= 640 ? 18 : 10,
            mainAxisExtent: math.max(coverSize, textHeight) + 16,
          ),
          itemCount: _albums.items.length,
          itemBuilder: (context, index) {
            AppLog.instance.trace(
              "lib/pages/anchor_page.dart::_AnchorPageState._albumList.closure#1.closure#1",
            );

            final item = _albums.items[index];
            return _AnchorAlbumCard(
              key: ValueKey(item.album.id),
              item: item,
              coverSize: coverSize,
              titleSize: titleSize,
              onTap: () {
                AppLog.instance.trace(
                  "lib/pages/anchor_page.dart::_AnchorPageState._albumList.closure#1.closure#1.closure#1",
                );
                _openAlbum(item.album.id);
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorPageState.build");

    final theme = Theme.of(context);
    final albumCount = _albums.total ?? _profile?.albums;
    final trackCount = _tracks.total ?? _profile?.tracks;
    final tabHeight = math.max(
      56.0,
      MediaQuery.textScalerOf(context).scale(18) * 1.4 + 20,
    );
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppHeader(
        title: const Text('主播'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1440),
            child: LayoutBuilder(
              builder: (context, constraints) {
                AppLog.instance.trace(
                  "lib/pages/anchor_page.dart::_AnchorPageState.build.closure#1",
                );

                final padding = constraints.maxWidth >= 800 ? 32.0 : 16.0;
                return RefreshIndicator(
                  onRefresh: _reload,
                  child: AppScrollbar(
                    controller: _scroll,
                    child: CustomScrollView(
                      key: PageStorageKey('anchor-works-$_selected'),
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (_resolving)
                          const SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (_resolveError != null)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: _retry(_resolveError!, _refresh),
                            ),
                          )
                        else ...[
                          SliverPadding(
                            padding: EdgeInsets.symmetric(horizontal: padding),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                children: [
                                  _header(),
                                  Divider(
                                    height: 1,
                                    color: theme.colorScheme.outlineVariant
                                        .withValues(alpha: .6),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: EdgeInsets.symmetric(horizontal: padding),
                            sliver: SliverPersistentHeader(
                              pinned: true,
                              delegate: _AnchorTabs(
                                color: theme.colorScheme.surface,
                                height: tabHeight,
                                tabs: TabBar(
                                  controller: _tabs,
                                  isScrollable: true,
                                  tabAlignment: TabAlignment.start,
                                  dividerColor: Colors.transparent,
                                  indicatorSize: TabBarIndicatorSize.label,
                                  labelPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  labelStyle: theme.textTheme.titleMedium
                                      ?.copyWith(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                      ),
                                  unselectedLabelStyle: theme
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w500,
                                      ),
                                  tabs: [
                                    Tab(
                                      height: tabHeight,
                                      text: albumCount == null
                                          ? '专辑'
                                          : '专辑 ($albumCount)',
                                    ),
                                    Tab(
                                      height: tabHeight,
                                      text: trackCount == null
                                          ? '声音'
                                          : '声音 ($trackCount)',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: EdgeInsets.symmetric(horizontal: padding),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _orderControls(),
                                  if (_selected == 1 &&
                                      (_tracks.reportedTotal ?? 0) >
                                          (_tracks.total ?? 0))
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        '仅可查看前 ${_tracks.total} 条声音，排序限于这些内容',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (_selected == 0) ...[
                            if (_albums.items.isNotEmpty)
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  padding - 8,
                                  12,
                                  padding - 8,
                                  0,
                                ),
                                sliver: _albumList(),
                              ),
                            SliverToBoxAdapter(
                              child: _footer(_albums, '暂无公开专辑'),
                            ),
                          ] else ...[
                            SliverPadding(
                              padding: EdgeInsets.symmetric(
                                horizontal: padding - 8,
                              ),
                              sliver: SliverList.builder(
                                itemCount: _tracks.items.length,
                                itemBuilder: (context, index) {
                                  AppLog.instance.trace(
                                    "lib/pages/anchor_page.dart::_AnchorPageState.build.closure#1.closure#1",
                                  );

                                  final track = _tracks.items[index];
                                  return ListTile(
                                    key: ValueKey(track.id),
                                    leading: CoverImage(
                                      uri: track.coverUrl,
                                      size: 48,
                                    ),
                                    title: Text(
                                      track.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: AdaptiveText(
                                      _trackDescription(track),
                                    ),
                                    onTap: track.albumId.isEmpty
                                        ? null
                                        : () {
                                            AppLog.instance.trace(
                                              'lib/pages/anchor_page.dart::_AnchorPageState.build.closure#1.closure#1.closure#1',
                                            );
                                            _openAlbum(
                                              track.albumId,
                                              track: track,
                                            );
                                          },
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: '播放',
                                          onPressed: () {
                                            AppLog.instance.trace(
                                              'lib/pages/anchor_page.dart::_AnchorPageState.build.closure#1.closure#1.closure#2',
                                            );
                                            unawaited(_play(track));
                                          },
                                          icon: const Icon(Icons.play_arrow),
                                        ),
                                        IconButton(
                                          tooltip: '下载',
                                          onPressed: () {
                                            AppLog.instance.trace(
                                              'lib/pages/anchor_page.dart::_AnchorPageState.build.closure#1.closure#1.closure#3',
                                            );
                                            unawaited(_download(track));
                                          },
                                          icon: const Icon(
                                            Icons.download_outlined,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                            SliverToBoxAdapter(
                              child: _footer(_tracks, '暂无公开声音'),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AnchorTabs extends SliverPersistentHeaderDelegate {
  _AnchorTabs({required this.tabs, required this.color, required this.height}) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorTabs.new");
  }
  final TabBar tabs;
  final Color color;
  final double height;

  @override
  double get minExtent {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorTabs.minExtent.get",
    );
    return height;
  }

  @override
  double get maxExtent {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorTabs.maxExtent.get",
    );
    return height;
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorTabs.build");

    return Material(
      color: color,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: tabs,
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _AnchorTabs oldDelegate) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorTabs.shouldRebuild",
    );

    return tabs != oldDelegate.tabs ||
        color != oldDelegate.color ||
        height != oldDelegate.height;
  }
}

class _AnchorAlbumCard extends StatelessWidget {
  const _AnchorAlbumCard({
    required this.item,
    required this.coverSize,
    required this.titleSize,
    required this.onTap,
    super.key,
  });
  final AnchorAlbum item;
  final double coverSize, titleSize;
  final VoidCallback onTap;

  Widget _metric(
    BuildContext context,
    IconData icon,
    String value,
    String label,
  ) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorAlbumCard._metric",
    );

    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color.withValues(alpha: .7)),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: color, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/anchor_page.dart::_AnchorAlbumCard._cover",
    );

    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: coverSize + 8,
      height: coverSize,
      child: Stack(
        children: [
          Positioned(
            right: 0,
            top: coverSize * .1,
            bottom: coverSize * .1,
            child: Container(
              width: coverSize * .8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xff272727),
                border: Border.all(color: const Color(0xff4b4b4b), width: 2),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                  color: colors.shadow.withValues(alpha: .06),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CoverImage(uri: item.album.coverUrl, size: coverSize),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace("lib/pages/anchor_page.dart::_AnchorAlbumCard.build");

    final theme = Theme.of(context);
    final album = item.album;
    final plays = item.playCount;
    final count = plays == null
        ? null
        : plays >= 100000000
        ? '${(plays / 100000000).toStringAsFixed(2)}亿'
        : plays >= 10000
        ? '${(plays / 10000).toStringAsFixed(1)}万'
        : '$plays';
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(context),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      album.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: titleSize,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        if (item.createdAt case final date?)
                          date.toIso8601String().substring(0, 10),
                        if (album.intro.isNotEmpty) album.intro,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 14,
                        height: 1.5,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        if (count != null) ...[
                          Flexible(
                            child: _metric(
                              context,
                              Icons.play_arrow_outlined,
                              count,
                              '$plays 次播放',
                            ),
                          ),
                          const SizedBox(width: 18),
                        ],
                        Flexible(
                          child: _metric(
                            context,
                            Icons.graphic_eq_rounded,
                            '${album.total}',
                            '${album.total} 集',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
