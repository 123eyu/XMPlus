import 'dart:async';

import 'package:flutter/material.dart';

import '../api/xmly_discovery.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/app_tab_button.dart';
import '../common/widgets/content_paging.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart';

class AnchorPage extends StatefulWidget {
  const AnchorPage({
    required this.runtime,
    required this.uid,
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final String uid;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;

  @override
  State<AnchorPage> createState() {
    AppLog.instance.trace('lib/pages/anchor_page.dart::AnchorPage.createState');
    return _AnchorPageState();
  }
}

class _AnchorPageState extends State<AnchorPage> {
  AnchorProfile? _profile;
  DiscoveryPageResult<Album>? _albums;
  DiscoveryPageResult<Track>? _tracks;
  String? _profileError;
  bool _profileBusy = false, _expanded = false;
  int _profileGeneration = 0, _tab = 0;
  Completer<void>? _profileCancelled;
  final _busy = [false, false];
  final _errors = <String?>[null, null];
  final _generations = [0, 0];
  final _requestedPages = [1, 1];
  final _cancelled = <Completer<void>?>[null, null];
  final _scrolls = [ScrollController(), ScrollController()];

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState.initState',
    );
    super.initState();
    _loadProfile();
    _loadWorks(0);
  }

  @override
  void didUpdateWidget(covariant AnchorPage oldWidget) {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState.didUpdateWidget',
    );
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid == widget.uid &&
        identical(oldWidget.runtime, widget.runtime))
      return;
    _profile = null;
    _albums = null;
    _tracks = null;
    _expanded = false;
    _loadProfile();
    for (var tab = 0; tab < 2; tab++) {
      _generations[tab]++;
      _cancelled[tab]?.complete();
      _cancelled[tab] = null;
      _busy[tab] = false;
      _errors[tab] = null;
    }
    _loadWorks(_tab);
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState.dispose',
    );
    _profileGeneration++;
    _profileCancelled?.complete();
    for (var tab = 0; tab < 2; tab++) {
      _generations[tab]++;
      _cancelled[tab]?.complete();
      _scrolls[tab].dispose();
    }
    super.dispose();
  }

  Future<void> _loadProfile() async {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState._loadProfile',
    );
    final generation = ++_profileGeneration;
    _profileCancelled?.complete();
    final cancelled = _profileCancelled = Completer<void>();
    setState(() {
      AppLog.instance.trace(
        'lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#1',
      );
      _profileBusy = true;
      _profileError = null;
    });
    final client = widget.runtime.client;
    try {
      final profile = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            'lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#2',
          );
          return XmlyDiscovery(client).anchorProfile(widget.uid);
        },
        rateLimitRetries: 4,
        cancelled: cancelled.future,
      );
      if (!mounted || generation != _profileGeneration) return;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#3',
        );
        _profile = profile;
      });
    } catch (error, stack) {
      if (!mounted || generation != _profileGeneration) return;
      _recordError('Anchor profile unavailable', error, stack);
      setState(() {
        AppLog.instance.trace(
          'lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#4',
        );
        _profileError = _message(error);
      });
    } finally {
      if (identical(_profileCancelled, cancelled)) _profileCancelled = null;
      if (mounted && generation == _profileGeneration)
        setState(() {
          AppLog.instance.trace(
            'lib/pages/anchor_page.dart::_AnchorPageState._loadProfile.closure#5',
          );
          _profileBusy = false;
        });
    }
  }

  Future<void> _loadWorks(int tab, {int page = 1}) async {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState._loadWorks',
    );
    final generation = ++_generations[tab];
    _requestedPages[tab] = page;
    _cancelled[tab]?.complete();
    final cancelled = _cancelled[tab] = Completer<void>();
    setState(() {
      AppLog.instance.trace(
        'lib/pages/anchor_page.dart::_AnchorPageState._loadWorks.closure#1',
      );
      _busy[tab] = true;
      _errors[tab] = null;
    });
    final client = widget.runtime.client;
    final discovery = XmlyDiscovery(client);
    try {
      final result = await client.withReadPolicy(
        () async {
          AppLog.instance.trace(
            'lib/pages/anchor_page.dart::_AnchorPageState._loadWorks.closure#2',
          );
          if (tab == 0)
            return await discovery.anchorAlbums(widget.uid, page: page);
          return await discovery.anchorTracks(widget.uid, page: page);
        },
        rateLimitRetries: 4,
        cancelled: cancelled.future,
      );
      if (!mounted || generation != _generations[tab]) return;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/anchor_page.dart::_AnchorPageState._loadWorks.closure#3',
        );
        if (tab == 0) {
          _albums = result as DiscoveryPageResult<Album>;
        } else {
          _tracks = result as DiscoveryPageResult<Track>;
        }
      });
      if (_scrolls[tab].hasClients) _scrolls[tab].jumpTo(0);
    } catch (error, stack) {
      if (!mounted || generation != _generations[tab]) return;
      _recordError('Anchor works unavailable', error, stack);
      setState(() {
        AppLog.instance.trace(
          'lib/pages/anchor_page.dart::_AnchorPageState._loadWorks.closure#4',
        );
        _errors[tab] = _message(error);
      });
    } finally {
      if (identical(_cancelled[tab], cancelled)) _cancelled[tab] = null;
      if (mounted && generation == _generations[tab])
        setState(() {
          AppLog.instance.trace(
            'lib/pages/anchor_page.dart::_AnchorPageState._loadWorks.closure#5',
          );
          _busy[tab] = false;
        });
    }
  }

  void _selectTab(int tab) {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState._selectTab',
    );
    setState(() {
      AppLog.instance.trace(
        'lib/pages/anchor_page.dart::_AnchorPageState._selectTab.closure#1',
      );
      _tab = tab;
    });
    if (!_busy[tab] &&
        _errors[tab] == null &&
        (tab == 0 ? _albums == null : _tracks == null)) {
      _loadWorks(tab);
    }
  }

  void _openAlbum(String albumId, {Track? track}) {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState._openAlbum',
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            'lib/pages/anchor_page.dart::_AnchorPageState._openAlbum.closure#1',
          );
          return AlbumPageView(
            runtime: widget.runtime,
            albumId: albumId,
            initialTrack: track,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  Future<void> _play(Track track) async {
    AppLog.instance.trace('lib/pages/anchor_page.dart::_AnchorPageState._play');
    try {
      await (widget.onPlayAlbum ?? widget.runtime.player.playAlbum)(
        track.albumId,
        track.id,
        track: track,
      );
    } catch (error, stack) {
      _recordError('Anchor playback failed', error, stack);
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_message(error))));
    }
  }

  Widget _profileHeader() {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState._profileHeader',
    );
    final profile = _profile;
    final size = MediaQuery.sizeOf(context).width >= 700 ? 88.0 : 64.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_profileBusy)
          const LinearProgressIndicator(semanticsLabel: '正在加载主播资料'),
        if (profile != null) ...[
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipOval(
                child: CoverImage(uri: profile.avatarUrl, size: size),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.nickname,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        if (profile.fansCount != null)
                          Text('${profile.fansCount} 粉丝'),
                        if (profile.albumsCount != null)
                          Text('${profile.albumsCount} 专辑'),
                        if (profile.tracksCount != null)
                          Text('${profile.tracksCount} 声音'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (profile.description.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              profile.description,
              maxLines: _expanded ? null : 3,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            TextButton(
              onPressed: () {
                AppLog.instance.trace(
                  'lib/pages/anchor_page.dart::_AnchorPageState._profileHeader.closure#1',
                );
                setState(() {
                  AppLog.instance.trace(
                    'lib/pages/anchor_page.dart::_AnchorPageState._profileHeader.closure#1.closure#1',
                  );
                  _expanded = !_expanded;
                });
              },
              child: Text(_expanded ? '收起简介' : '展开简介'),
            ),
          ],
        ],
        if (_profileError != null) ...[
          Text(_profileError!),
          TextButton(
            onPressed: _profileBusy ? null : _loadProfile,
            child: const Text('重试资料'),
          ),
        ],
        const SizedBox(height: 24),
        AppTabStrip(
          children: [
            AppTabButton(
              label: '专辑',
              selected: _tab == 0,
              onPressed: () {
                AppLog.instance.trace(
                  'lib/pages/anchor_page.dart::_AnchorPageState._profileHeader.closure#2',
                );
                _selectTab(0);
              },
            ),
            AppTabButton(
              label: '声音',
              selected: _tab == 1,
              onPressed: () {
                AppLog.instance.trace(
                  'lib/pages/anchor_page.dart::_AnchorPageState._profileHeader.closure#3',
                );
                _selectTab(1);
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _works(int tab) {
    AppLog.instance.trace(
      'lib/pages/anchor_page.dart::_AnchorPageState._works',
    );
    final result = tab == 0 ? _albums : _tracks;
    final count = result?.items.length ?? 0;
    return Scrollbar(
      controller: _scrolls[tab],
      child: CustomScrollView(
        controller: _scrolls[tab],
        slivers: [
          SliverToBoxAdapter(child: _profileHeader()),
          if (_busy[tab])
            const SliverToBoxAdapter(
              child: LinearProgressIndicator(semanticsLabel: '正在加载作品'),
            ),
          if (_errors[tab] != null)
            SliverToBoxAdapter(
              child: Column(
                children: [
                  Text(_errors[tab]!),
                  TextButton(
                    onPressed: _busy[tab]
                        ? null
                        : () {
                            AppLog.instance.trace(
                              'lib/pages/anchor_page.dart::_AnchorPageState._works.closure#1',
                            );
                            _loadWorks(tab, page: _requestedPages[tab]);
                          },
                    child: const Text('重试作品'),
                  ),
                ],
              ),
            ),
          if (result != null && count == 0)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('暂无内容')),
              ),
            ),
          SliverList.builder(
            itemCount: count,
            itemBuilder: (context, index) {
              AppLog.instance.trace(
                'lib/pages/anchor_page.dart::_AnchorPageState._works.closure#2',
              );
              if (tab == 0) {
                final album = _albums!.items[index];
                return ListTile(
                  minTileHeight: 72,
                  contentPadding: EdgeInsets.zero,
                  leading: CoverImage(uri: album.coverUrl, size: 48),
                  title: AdaptiveText(album.title),
                  subtitle: AdaptiveText('${album.artist} · ${album.total} 集'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    AppLog.instance.trace(
                      'lib/pages/anchor_page.dart::_AnchorPageState._works.closure#2.closure#1',
                    );
                    _openAlbum(album.id);
                  },
                );
              }
              final track = _tracks!.items[index];
              return ListTile(
                minTileHeight: 72,
                contentPadding: EdgeInsets.zero,
                leading: CoverImage(uri: track.coverUrl, size: 48),
                title: AdaptiveText(track.title),
                subtitle: AdaptiveText(
                  '${track.album} · ${track.duration ~/ 60}:${(track.duration.toInt() % 60).toString().padLeft(2, '0')}',
                ),
                onTap: () {
                  AppLog.instance.trace(
                    'lib/pages/anchor_page.dart::_AnchorPageState._works.closure#2.closure#2',
                  );
                  _openAlbum(track.albumId, track: track);
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '播放此集',
                      onPressed: () {
                        AppLog.instance.trace(
                          'lib/pages/anchor_page.dart::_AnchorPageState._works.closure#2.closure#3',
                        );
                        _play(track);
                      },
                      icon: const Icon(Icons.play_arrow),
                    ),
                    if (widget.onDownload != null)
                      IconButton(
                        tooltip: '下载',
                        onPressed: () async {
                          AppLog.instance.trace(
                            'lib/pages/anchor_page.dart::_AnchorPageState._works.closure#2.closure#4',
                          );
                          try {
                            await widget.onDownload!([track]);
                          } catch (error, stack) {
                            _recordError(
                              'Anchor download failed',
                              error,
                              stack,
                            );
                            if (mounted)
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(content: Text(_message(error))),
                              );
                          }
                        },
                        icon: const Icon(Icons.download_outlined),
                      ),
                  ],
                ),
              );
            },
          ),
          if (result != null)
            SliverToBoxAdapter(
              child: ContentPaging(
                page: result.page,
                total: result.total,
                pageSize: result.pageSize,
                busy: _busy[tab],
                onPage: (page) {
                  AppLog.instance.trace(
                    'lib/pages/anchor_page.dart::_AnchorPageState._works.closure#3',
                  );
                  return _loadWorks(tab, page: page);
                },
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace('lib/pages/anchor_page.dart::_AnchorPageState.build');
    final padding = MediaQuery.sizeOf(context).width < 700 ? 12.0 : 24.0;
    return Scaffold(
      appBar: AppHeader(title: Text(_profile?.nickname ?? '主播')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: padding),
              child: Stack(
                children: [
                  for (var tab = 0; tab < 2; tab++)
                    Offstage(
                      offstage: _tab != tab,
                      child: TickerMode(
                        enabled: _tab == tab,
                        child: _works(tab),
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

String _message(Object error) {
  AppLog.instance.trace('lib/pages/anchor_page.dart::_message');
  return error is XmlyException ? error.message : '暂时无法加载，请重试';
}

void _recordError(String operation, Object error, StackTrace stack) {
  AppLog.instance.trace('lib/pages/anchor_page.dart::_recordError');
  if (AppLog.instance.errorWasRecorded(error)) return;
  AppLog.instance.write(
    AppLogLevel.warning,
    'anchor_page',
    operation,
    error: error,
    stackTrace: stack,
  );
}
