import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/xmly_discovery.dart';
import '../api/xmly_experience.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/app_tab_button.dart';
import '../common/widgets/content_paging.dart';
import '../common/widgets/local_panel.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'anchor_page.dart';
import 'catalogue_page.dart';
import 'home_album_section.dart';

void _recordFailure(Object error, StackTrace stack) {
  AppLog.instance.trace('lib/pages/discovery_browse_page.dart::_recordFailure');
  if (AppLog.instance.errorWasRecorded(error)) return;
  AppLog.instance.write(
    error is XmlyException ? AppLogLevel.warning : AppLogLevel.error,
    'discovery_browse',
    'Discovery content load failed',
    error: error,
    stackTrace: stack,
  );
}

String _errorText(Object error) {
  AppLog.instance.trace('lib/pages/discovery_browse_page.dart::_errorText');
  return error is XmlyException ? error.message : '暂时无法加载，请稍后重试';
}

void _openAlbum(
  BuildContext context,
  AppRuntime runtime,
  Album album,
  TrackDownload? onDownload,
  AlbumPlayback? onPlayAlbum,
) {
  AppLog.instance.trace('lib/pages/discovery_browse_page.dart::_openAlbum');
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_openAlbum.closure#1',
        );
        return AlbumPageView(
          runtime: runtime,
          albumId: album.id,
          onDownload: onDownload,
          onPlayAlbum: onPlayAlbum,
        );
      },
    ),
  );
}

class _BrowseScroll extends StatelessWidget {
  const _BrowseScroll({
    required this.slivers,
    required this.onRefresh,
    this.scrollKey,
  });
  final List<Widget> slivers;
  final Future<void> Function() onRefresh;
  final Key? scrollKey;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_BrowseScroll.build',
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_BrowseScroll.build.closure#1',
        );
        final edge = constraints.maxWidth < 700 ? 12.0 : 24.0;
        final inset = math.max(edge, (constraints.maxWidth - 960) / 2);
        return RefreshIndicator(
          onRefresh: onRefresh,
          child: CustomScrollView(
            key: scrollKey,
            primary: false,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 12, inset, 24),
                sliver: SliverMainAxisGroup(slivers: slivers),
              ),
            ],
          ),
        );
      },
    );
  }
}

Widget _loading(bool busy) {
  AppLog.instance.trace('lib/pages/discovery_browse_page.dart::_loading');
  return SliverToBoxAdapter(
    child: SizedBox(
      height: 4,
      child: busy
          ? const LinearProgressIndicator(semanticsLabel: '正在加载内容')
          : null,
    ),
  );
}

Widget _notice(String text, {VoidCallback? onRetry}) {
  AppLog.instance.trace('lib/pages/discovery_browse_page.dart::_notice');
  return SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Text(text, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ],
      ),
    ),
  );
}

Widget _heading(BuildContext context, String title, {Widget? trailing}) {
  AppLog.instance.trace('lib/pages/discovery_browse_page.dart::_heading');
  return SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          if (trailing != null) trailing,
        ],
      ),
    ),
  );
}

class DiscoveryCategoriesView extends StatefulWidget {
  const DiscoveryCategoriesView({
    required this.runtime,
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;

  @override
  State<DiscoveryCategoriesView> createState() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::DiscoveryCategoriesView.createState',
    );
    return _DiscoveryCategoriesViewState();
  }
}

class _DiscoveryCategoriesViewState extends State<DiscoveryCategoriesView> {
  List<CategoryGroup> _groups = const [];
  CategoryGroup? _group;
  DiscoveryPageResult<CategoryChannel>? _channels;
  int _generation = 0;
  Completer<void>? _cancel;
  bool _busy = false;
  String? _error;
  int _requestedPage = 1;

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.initState',
    );
    super.initState();
    _load(reloadGroups: true);
  }

  @override
  void didUpdateWidget(covariant DiscoveryCategoriesView oldWidget) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.didUpdateWidget',
    );
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) _load(reloadGroups: true);
  }

  Future<void> _load({
    bool reloadGroups = false,
    CategoryGroup? group,
    int page = 1,
  }) async {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState._load',
    );
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    final generation = ++_generation;
    final client = widget.runtime.client;
    final changedGroup = group != null && group.id != _group?.id;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState._load.closure#1',
      );
      if (group != null) _group = group;
      if (changedGroup) _channels = null;
      _busy = true;
      _error = null;
      _requestedPage = page;
    });
    try {
      await client.withReadPolicy(
        () async {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState._load.closure#2',
          );
          final api = XmlyDiscovery(client);
          if (reloadGroups || _groups.isEmpty) {
            final groups = await api.categoryGroups();
            if (!mounted || generation != _generation) return;
            CategoryGroup? selected;
            for (final candidate in groups) {
              if (candidate.id == _group?.id) selected = candidate;
            }
            setState(() {
              AppLog.instance.trace(
                'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState._load.closure#2.closure#1',
              );
              _groups = groups;
              _group = selected ?? (groups.isEmpty ? null : groups.first);
            });
          }
          final selected = _group;
          if (selected == null) return;
          final channels = await api.categoryChannels(selected.id, page: page);
          if (!mounted || generation != _generation) return;
          setState(() {
            AppLog.instance.trace(
              'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState._load.closure#2.closure#2',
            );
            _channels = channels;
          });
        },
        rateLimitRetries: 0,
        cancelled: cancel.future,
      );
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      _recordFailure(error, stack);
      setState(() {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState._load.closure#3',
        );
        _error = _errorText(error);
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState._load.closure#4',
          );
          _busy = false;
        });
      }
    }
  }

  void _open(CategoryChannel? channel) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState._open',
    );
    final group = _group;
    if (group == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState._open.closure#1',
          );
          return CategoryAlbumsPage(
            runtime: widget.runtime,
            group: group,
            channel: channel,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.dispose',
    );
    _generation++;
    _cancel?.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.build',
    );
    final channels = _channels;
    return _BrowseScroll(
      scrollKey: const PageStorageKey('discovery-categories'),
      onRefresh: () {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.build.closure#1',
        );
        return _load(reloadGroups: true, page: channels?.page ?? 1);
      },
      slivers: [
        _loading(_busy),
        if (_groups.isNotEmpty)
          SliverToBoxAdapter(
            child: AppTabStrip(
              children: [
                for (final group in _groups)
                  AppTabButton(
                    label: group.title,
                    selected: group.id == _group?.id,
                    onPressed: () {
                      AppLog.instance.trace(
                        'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.build.closure#2',
                      );
                      if (group.id != _group?.id) _load(group: group);
                    },
                  ),
              ],
            ),
          ),
        if (_group != null) ...[
          _heading(
            context,
            _group!.title,
            trailing: IconButton(
              tooltip: '刷新分类',
              onPressed: _busy
                  ? null
                  : () {
                      AppLog.instance.trace(
                        'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.build.closure#3',
                      );
                      _load(page: channels?.page ?? 1);
                    },
              icon: const Icon(Icons.refresh_rounded),
            ),
          ),
          SliverToBoxAdapter(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () {
                  AppLog.instance.trace(
                    'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.build.closure#4',
                  );
                  _open(null);
                },
                icon: const Icon(Icons.auto_awesome_outlined),
                label: Text('${_group!.title}精选'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
        if (_error != null)
          _notice(
            _error!,
            onRetry: _busy
                ? null
                : () {
                    AppLog.instance.trace(
                      'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.build.closure#5',
                    );
                    _load(reloadGroups: _groups.isEmpty, page: _requestedPage);
                  },
          ),
        if (channels != null && channels.items.isNotEmpty)
          SliverLayoutBuilder(
            builder: (context, constraints) {
              AppLog.instance.trace(
                'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.build.closure#6',
              );
              final scale = math.max(
                1.0,
                MediaQuery.textScalerOf(context).scale(14) / 14,
              );
              final columns = math.max(
                1,
                ((constraints.crossAxisExtent + 12) / (164 * scale + 12))
                    .floor(),
              );
              return SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  mainAxisExtent: math.max(80, 60 * scale),
                ),
                itemCount: channels.items.length,
                itemBuilder: (context, index) {
                  AppLog.instance.trace(
                    'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.build.closure#6.closure#1',
                  );
                  final channel = channels.items[index];
                  return Material(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () {
                        AppLog.instance.trace(
                          'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.build.closure#6.closure#1.closure#1',
                        );
                        _open(channel);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            if (channel.coverUrl != null) ...[
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: CoverImage(
                                  uri: channel.coverUrl,
                                  size: 40,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Text(
                                channel.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        if (!_busy &&
            _error == null &&
            (channels == null || channels.items.isEmpty))
          _notice('暂无内容'),
        if (channels != null)
          SliverToBoxAdapter(
            child: ContentPaging(
              page: channels.page,
              total: channels.total,
              pageSize: channels.pageSize,
              busy: _busy,
              onPage: (page) {
                AppLog.instance.trace(
                  'lib/pages/discovery_browse_page.dart::_DiscoveryCategoriesViewState.build.closure#7',
                );
                return _load(page: page);
              },
            ),
          ),
      ],
    );
  }
}

class CategoryAlbumsPage extends StatefulWidget {
  const CategoryAlbumsPage({
    required this.runtime,
    required this.group,
    this.channel,
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final CategoryGroup group;
  final CategoryChannel? channel;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;

  @override
  State<CategoryAlbumsPage> createState() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::CategoryAlbumsPage.createState',
    );
    return _CategoryAlbumsPageState();
  }
}

class _CategoryAlbumsPageState extends State<CategoryAlbumsPage> {
  CategoryChannelInfo? _info;
  String? _infoError;
  bool _infoBusy = false;
  int _infoGeneration = 0;
  Completer<void>? _infoCancel;
  Map<int, int> _metadata = {};
  DiscoveryPageResult<Album>? _albums;
  int _sort = 1;
  int _generation = 0;
  Completer<void>? _cancel;
  bool _busy = false;
  String? _error;
  int _requestedPage = 1;

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState.initState',
    );
    super.initState();
    _load();
    if (widget.channel != null) _loadInfo();
  }

  Future<void> _loadInfo() async {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._loadInfo',
    );
    final channel = widget.channel;
    if (channel == null) return;
    _infoCancel?.complete();
    final cancel = _infoCancel = Completer<void>();
    final generation = ++_infoGeneration;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._loadInfo.closure#1',
      );
      _infoBusy = true;
      _infoError = null;
    });
    try {
      final client = widget.runtime.client;
      final info = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._loadInfo.closure#2',
          );
          return XmlyDiscovery(client)
              .categoryInfo(channel.relationMetadataValueId);
        },
        rateLimitRetries: 0,
        cancelled: cancel.future,
      );
      if (!mounted || generation != _infoGeneration) return;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._loadInfo.closure#3',
        );
        _info = info;
      });
    } catch (error, stack) {
      if (!mounted || generation != _infoGeneration) return;
      _recordFailure(error, stack);
      setState(() {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._loadInfo.closure#4',
        );
        _infoError = _errorText(error);
      });
    } finally {
      if (mounted && generation == _infoGeneration) {
        setState(() {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._loadInfo.closure#5',
          );
          _infoBusy = false;
        });
      }
    }
  }

  Future<void> _load({int page = 1, bool clear = false}) async {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._load',
    );
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    final generation = ++_generation;
    final client = widget.runtime.client;
    final sort = _sort;
    final metadata = Map<int, int>.of(_metadata);
    setState(() {
      AppLog.instance.trace(
        'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._load.closure#1',
      );
      if (clear) _albums = null;
      _busy = true;
      _error = null;
      _requestedPage = page;
    });
    try {
      final result = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._load.closure#2',
          );
          return XmlyDiscovery(client).categoryAlbums(
            groupId: widget.group.id,
            metadataValueId: widget.channel?.relationMetadataValueId,
            page: page,
            sort: sort,
            metadata: metadata,
          );
        },
        rateLimitRetries: 0,
        cancelled: cancel.future,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._load.closure#3',
        );
        _albums = result;
      });
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      _recordFailure(error, stack);
      setState(() {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._load.closure#4',
        );
        _error = _errorText(error);
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._load.closure#5',
          );
          _busy = false;
        });
      }
    }
  }

  Future<void> _filters() async {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters',
    );
    final info = _info;
    if (info == null) return;
    var draft = Map<int, int>.of(_metadata);
    final result = await showLocalPanel<Map<int, int>>(
      context: context,
      title: '筛选',
      width: 620,
      builder: (panelContext) {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#1',
        );
        return StatefulBuilder(
          builder: (context, update) {
            AppLog.instance.trace(
              'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#1.closure#1',
            );
            return Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final dimension in info.reachableDimensions(
                        draft,
                      )) ...[
                        Text(
                          dimension.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ChoiceChip(
                              label: const Text('全部'),
                              selected: !draft.containsKey(dimension.id),
                              onSelected: (_) {
                                AppLog.instance.trace(
                                  'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#1.closure#1.closure#1',
                                );
                                update(() {
                                  AppLog.instance.trace(
                                    'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#1.closure#1.closure#1.closure#1',
                                  );
                                  draft = info.selectValue(
                                    draft,
                                    dimension.id,
                                    null,
                                  );
                                });
                              },
                              materialTapTargetSize:
                                  MaterialTapTargetSize.padded,
                            ),
                            for (final value in dimension.values)
                              ChoiceChip(
                                label: Text(value.title),
                                selected: draft[dimension.id] == value.id,
                                onSelected: (_) {
                                  AppLog.instance.trace(
                                    'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#1.closure#1.closure#2',
                                  );
                                  update(() {
                                    AppLog.instance.trace(
                                      'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#1.closure#1.closure#2.closure#1',
                                    );
                                    draft = info.selectValue(
                                      draft,
                                      dimension.id,
                                      value.id,
                                    );
                                  });
                                },
                                materialTapTargetSize:
                                    MaterialTapTargetSize.padded,
                              ),
                          ],
                        ),
                        const SizedBox(height: 24),
                      ],
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            AppLog.instance.trace(
                              'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#1.closure#1.closure#3',
                            );
                            update(() {
                              AppLog.instance.trace(
                                'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#1.closure#1.closure#3.closure#1',
                              );
                              draft = {};
                            });
                          },
                          child: const Text('重置'),
                        ),
                        OutlinedButton(
                          onPressed: () {
                            AppLog.instance.trace(
                              'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#1.closure#1.closure#4',
                            );
                            Navigator.of(panelContext).pop();
                          },
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () {
                            AppLog.instance.trace(
                              'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#1.closure#1.closure#5',
                            );
                            Navigator.of(panelContext)
                                .pop(info.pruneSelections(draft));
                          },
                          child: const Text('应用'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (!mounted || result == null) return;
    if (result.length == _metadata.length &&
        result.entries.every((entry) {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#2',
          );
          return _metadata[entry.key] == entry.value;
        }))
      return;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState._filters.closure#3',
      );
      _metadata = result;
    });
    await _load(clear: true);
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState.dispose',
    );
    _generation++;
    _infoGeneration++;
    _cancel?.complete();
    _infoCancel?.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState.build',
    );
    final albums = _albums;
    return Scaffold(
      appBar: AppHeader(
        title: Text(widget.channel?.title ?? '${widget.group.title}精选'),
      ),
      body: _BrowseScroll(
        scrollKey: const PageStorageKey('category-albums'),
        onRefresh: () {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState.build.closure#1',
          );
          return _load(page: albums?.page ?? 1);
        },
        slivers: [
          _heading(
            context,
            widget.channel == null
                ? '${widget.group.title}精选'
                : '${widget.group.title} · ${widget.channel!.title}',
          ),
          SliverToBoxAdapter(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final (sort, title) in const [
                  (1, '综合'),
                  (2, '最新'),
                  (3, '最多播放'),
                ])
                  ChoiceChip(
                    label: Text(title),
                    selected: _sort == sort,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    onSelected: (_) {
                      AppLog.instance.trace(
                        'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState.build.closure#2',
                      );
                      if (_sort == sort) return;
                      setState(() {
                        AppLog.instance.trace(
                          'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState.build.closure#2.closure#1',
                        );
                        _sort = sort;
                      });
                      _load(clear: true);
                    },
                  ),
                if (_info != null && _info!.dimensions.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: _filters,
                    icon: const Icon(Icons.tune_rounded),
                    label: Text(
                      _metadata.isEmpty ? '筛选' : '筛选 · ${_metadata.length}',
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                  ),
              ],
            ),
          ),
          if (_infoBusy)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(semanticsLabel: '正在加载筛选条件'),
              ),
            ),
          if (_infoError != null)
            _notice('筛选条件暂时无法加载', onRetry: _infoBusy ? null : _loadInfo),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          _loading(_busy),
          if (_error != null)
            _notice(
              _error!,
              onRetry: _busy
                  ? null
                  : () {
                      AppLog.instance.trace(
                        'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState.build.closure#3',
                      );
                      _load(page: _requestedPage);
                    },
            ),
          if (albums != null && albums.items.isNotEmpty)
            HomeAlbumSection(
              section: HomeSection(title: '', albums: albums.items),
              showHeading: false,
              onOpenAlbum: (album) {
                AppLog.instance.trace(
                  'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState.build.closure#4',
                );
                _openAlbum(
                  context,
                  widget.runtime,
                  album,
                  widget.onDownload,
                  widget.onPlayAlbum,
                );
              },
            ),
          if (!_busy &&
              _error == null &&
              (albums == null || albums.items.isEmpty))
            _notice('暂无内容'),
          if (albums != null)
            SliverToBoxAdapter(
              child: ContentPaging(
                page: albums.page,
                total: albums.total,
                pageSize: albums.pageSize,
                busy: _busy,
                onPage: (page) {
                  AppLog.instance.trace(
                    'lib/pages/discovery_browse_page.dart::_CategoryAlbumsPageState.build.closure#5',
                  );
                  return _load(page: page);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class DiscoveryRankingView extends StatefulWidget {
  const DiscoveryRankingView({
    required this.runtime,
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;

  @override
  State<DiscoveryRankingView> createState() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::DiscoveryRankingView.createState',
    );
    return _DiscoveryRankingViewState();
  }
}

class _DiscoveryRankingViewState extends State<DiscoveryRankingView> {
  List<RankCategory>? _categories;
  bool _busy = false;
  String? _error;
  int _generation = 0;
  Completer<void>? _cancel;

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_DiscoveryRankingViewState.initState',
    );
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DiscoveryRankingView oldWidget) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_DiscoveryRankingViewState.didUpdateWidget',
    );
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) _load();
  }

  Future<void> _load() async {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_DiscoveryRankingViewState._load',
    );
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    final generation = ++_generation;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/discovery_browse_page.dart::_DiscoveryRankingViewState._load.closure#1',
      );
      _busy = true;
      _error = null;
    });
    try {
      final client = widget.runtime.client;
      final categories = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_DiscoveryRankingViewState._load.closure#2',
          );
          return XmlyDiscovery(client).rankTabs();
        },
        rateLimitRetries: 0,
        cancelled: cancel.future,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_DiscoveryRankingViewState._load.closure#3',
        );
        _categories = categories;
      });
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      _recordFailure(error, stack);
      setState(() {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_DiscoveryRankingViewState._load.closure#4',
        );
        _error = _errorText(error);
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_DiscoveryRankingViewState._load.closure#5',
          );
          _busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_DiscoveryRankingViewState.dispose',
    );
    _generation++;
    _cancel?.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_DiscoveryRankingViewState.build',
    );
    final categories = _categories;
    if (categories != null &&
        categories.any((category) {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_DiscoveryRankingViewState.build.closure#1',
          );
          return category.tabs.isNotEmpty;
        })) {
      return _RankBrowser(
        runtime: widget.runtime,
        categories: categories,
        onDownload: widget.onDownload,
        onPlayAlbum: widget.onPlayAlbum,
        tabsBusy: _busy,
        tabsError: _error,
        reloadTabs: _load,
      );
    }
    return _BrowseScroll(
      onRefresh: _load,
      slivers: [
        _loading(_busy),
        if (_error != null) _notice(_error!, onRetry: _busy ? null : _load),
        if (!_busy && _error == null) _notice('暂无内容'),
      ],
    );
  }
}

class RankingPage extends StatelessWidget {
  const RankingPage({
    required this.runtime,
    required this.categories,
    required this.categoryId,
    required this.rankingId,
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final List<RankCategory> categories;
  final int categoryId, rankingId;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::RankingPage.build',
    );
    return Scaffold(
      appBar: AppHeader(title: const Text('排行榜')),
      body: _RankBrowser(
        runtime: runtime,
        categories: categories,
        initialCategoryId: categoryId,
        initialRankingId: rankingId,
        routed: true,
        onDownload: onDownload,
        onPlayAlbum: onPlayAlbum,
      ),
    );
  }
}

class _RankBrowser extends StatefulWidget {
  const _RankBrowser({
    required this.runtime,
    required this.categories,
    this.initialCategoryId,
    this.initialRankingId,
    this.routed = false,
    this.onDownload,
    this.onPlayAlbum,
    this.tabsBusy = false,
    this.tabsError,
    this.reloadTabs,
  });
  final AppRuntime runtime;
  final List<RankCategory> categories;
  final int? initialCategoryId, initialRankingId;
  final bool routed, tabsBusy;
  final String? tabsError;
  final Future<void> Function()? reloadTabs;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;

  @override
  State<_RankBrowser> createState() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankBrowser.createState',
    );
    return _RankBrowserState();
  }
}

class _RankBrowserState extends State<_RankBrowser> {
  late RankCategory _category;
  late RankTab _tab;
  List<RankBlock>? _blocks;
  bool _busy = false;
  String? _error;
  int _generation = 0;
  Completer<void>? _cancel;

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankBrowserState.initState',
    );
    super.initState();
    _selectInitial();
    _load();
  }

  void _selectInitial() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankBrowserState._selectInitial',
    );
    _category = widget.categories.firstWhere(
      (category) {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_RankBrowserState._selectInitial.closure#1',
        );
        return category.id == widget.initialCategoryId &&
            category.tabs.isNotEmpty;
      },
      orElse: () {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_RankBrowserState._selectInitial.closure#2',
        );
        return widget.categories.firstWhere((category) {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_RankBrowserState._selectInitial.closure#2.closure#1',
          );
          return category.tabs.isNotEmpty;
        });
      },
    );
    _tab = _category.tabs.firstWhere(
      (tab) {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_RankBrowserState._selectInitial.closure#3',
        );
        return tab.rankingId == widget.initialRankingId;
      },
      orElse: () {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_RankBrowserState._selectInitial.closure#4',
        );
        return _category.tabs.first;
      },
    );
  }

  @override
  void didUpdateWidget(covariant _RankBrowser oldWidget) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankBrowserState.didUpdateWidget',
    );
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.categories != widget.categories) {
      final oldId = _category.id;
      final oldRankingId = _tab.rankingId;
      RankCategory? selected;
      for (final category in widget.categories) {
        if (category.id == oldId && category.tabs.isNotEmpty)
          selected = category;
      }
      if (selected == null) {
        _selectInitial();
      } else {
        _category = selected;
        _tab = selected.tabs.firstWhere(
          (tab) {
            AppLog.instance.trace(
              'lib/pages/discovery_browse_page.dart::_RankBrowserState.didUpdateWidget.closure#1',
            );
            return tab.rankingId == oldRankingId;
          },
          orElse: () {
            AppLog.instance.trace(
              'lib/pages/discovery_browse_page.dart::_RankBrowserState.didUpdateWidget.closure#2',
            );
            return selected!.tabs.first;
          },
        );
      }
      _load(clear: _tab.rankingId != oldRankingId);
    }
  }

  Future<void> _load({bool clear = false}) async {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankBrowserState._load',
    );
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    final generation = ++_generation;
    final rankingId = _tab.rankingId;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/discovery_browse_page.dart::_RankBrowserState._load.closure#1',
      );
      if (clear) _blocks = null;
      _busy = true;
      _error = null;
    });
    try {
      final client = widget.runtime.client;
      final blocks = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_RankBrowserState._load.closure#2',
          );
          return XmlyDiscovery(client).rankElements(rankingId);
        },
        rateLimitRetries: 0,
        cancelled: cancel.future,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_RankBrowserState._load.closure#3',
        );
        _blocks = blocks;
      });
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      _recordFailure(error, stack);
      setState(() {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_RankBrowserState._load.closure#4',
        );
        _error = _errorText(error);
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_RankBrowserState._load.closure#5',
          );
          _busy = false;
        });
      }
    }
  }

  void _selectTab(RankTab tab) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankBrowserState._selectTab',
    );
    if (tab.rankingId == _tab.rankingId) return;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/discovery_browse_page.dart::_RankBrowserState._selectTab.closure#1',
      );
      _tab = tab;
    });
    _load(clear: true);
  }

  void _openRank() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankBrowserState._openRank',
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_RankBrowserState._openRank.closure#1',
          );
          return RankingPage(
            runtime: widget.runtime,
            categories: widget.categories,
            categoryId: _category.id,
            rankingId: _tab.rankingId,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  void _openAnchor(AnchorProfile anchor) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankBrowserState._openAnchor',
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            'lib/pages/discovery_browse_page.dart::_RankBrowserState._openAnchor.closure#1',
          );
          return AnchorPage(
            runtime: widget.runtime,
            uid: anchor.uid,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankBrowserState.dispose',
    );
    _generation++;
    _cancel?.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankBrowserState.build',
    );
    final blocks = _blocks;
    final firstTitle = blocks?.firstOrNull?.title ?? '';
    return _BrowseScroll(
      scrollKey: PageStorageKey(
        widget.routed ? 'rank-detail' : 'discovery-ranks',
      ),
      onRefresh: () {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_RankBrowserState.build.closure#1',
        );
        return _load();
      },
      slivers: [
        SliverToBoxAdapter(
          child: AppTabStrip(
            children: [
              for (final category in widget.categories)
                AppTabButton(
                  label: category.title,
                  selected: _category.id == category.id,
                  onPressed: category.tabs.isEmpty
                      ? null
                      : () {
                          AppLog.instance.trace(
                            'lib/pages/discovery_browse_page.dart::_RankBrowserState.build.closure#2',
                          );
                          if (category.id == _category.id) return;
                          setState(() {
                            AppLog.instance.trace(
                              'lib/pages/discovery_browse_page.dart::_RankBrowserState.build.closure#2.closure#1',
                            );
                            _category = category;
                            _tab = category.tabs.first;
                          });
                          _load(clear: true);
                        },
                ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: AppTabStrip(
            children: [
              for (final tab in _category.tabs)
                AppTabButton(
                  label: tab.title,
                  selected: _tab.rankingId == tab.rankingId,
                  onPressed: () {
                    AppLog.instance.trace(
                      'lib/pages/discovery_browse_page.dart::_RankBrowserState.build.closure#3',
                    );
                    _selectTab(tab);
                  },
                ),
            ],
          ),
        ),
        _heading(
          context,
          firstTitle.isEmpty ? _tab.title : firstTitle,
          trailing: widget.routed
              ? IconButton(
                  tooltip: '刷新榜单',
                  onPressed: _busy
                      ? null
                      : () {
                          AppLog.instance.trace(
                            'lib/pages/discovery_browse_page.dart::_RankBrowserState.build.closure#4',
                          );
                          _load();
                        },
                  icon: const Icon(Icons.refresh_rounded),
                )
              : TextButton.icon(
                  onPressed: _openRank,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('查看榜单'),
                ),
        ),
        _loading(_busy || widget.tabsBusy),
        if (widget.tabsError != null)
          _notice(
            widget.tabsError!,
            onRetry: widget.tabsBusy ? null : widget.reloadTabs,
          ),
        if (_error != null)
          _notice(
            _error!,
            onRetry: _busy
                ? null
                : () {
                    AppLog.instance.trace(
                      'lib/pages/discovery_browse_page.dart::_RankBrowserState.build.closure#5',
                    );
                    _load();
                  },
          ),
        if (blocks != null)
          for (final block in blocks) ...[
            if (block != blocks.first && block.title.isNotEmpty)
              _heading(context, block.title),
            if (block.contentType == 2 && block.albums.isNotEmpty)
              _RankAlbums(
                block: block,
                onOpen: (album) {
                  AppLog.instance.trace(
                    'lib/pages/discovery_browse_page.dart::_RankBrowserState.build.closure#6',
                  );
                  _openAlbum(
                    context,
                    widget.runtime,
                    album,
                    widget.onDownload,
                    widget.onPlayAlbum,
                  );
                },
              )
            else if (block.contentType == 3 && block.anchors.isNotEmpty)
              SliverList.builder(
                itemCount: block.anchors.length,
                itemBuilder: (context, index) {
                  AppLog.instance.trace(
                    'lib/pages/discovery_browse_page.dart::_RankBrowserState.build.closure#7',
                  );
                  final anchor = block.anchors[index];
                  return _RankAnchorRow(
                    anchor: anchor,
                    position: block.positions[anchor.uid],
                    onTap: () {
                      AppLog.instance.trace(
                        'lib/pages/discovery_browse_page.dart::_RankBrowserState.build.closure#7.closure#1',
                      );
                      _openAnchor(anchor);
                    },
                  );
                },
              )
            else
              _notice('暂无内容'),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        if (!_busy && _error == null && (blocks == null || blocks.isEmpty))
          _notice('暂无内容'),
      ],
    );
  }
}

class _RankAlbums extends StatelessWidget {
  const _RankAlbums({required this.block, required this.onOpen});
  final RankBlock block;
  final ValueChanged<Album> onOpen;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankAlbums.build',
    );
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        AppLog.instance.trace(
          'lib/pages/discovery_browse_page.dart::_RankAlbums.build.closure#1',
        );
        final scale = math.max(
          1.0,
          MediaQuery.textScalerOf(context).scale(14) / 14,
        );
        final columns = math.min(
          3,
          math.max(
            1,
            ((constraints.crossAxisExtent + 12) / (280 * scale + 12)).floor(),
          ),
        );
        return SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            mainAxisExtent: math.max(112, 106 * scale),
          ),
          itemCount: block.albums.length,
          itemBuilder: (context, index) {
            AppLog.instance.trace(
              'lib/pages/discovery_browse_page.dart::_RankAlbums.build.closure#1.closure#1',
            );
            final album = block.albums[index];
            final stats = block.stats[album.id];
            final position = block.positions[album.id];
            final colors = Theme.of(context).colorScheme;
            return Material(
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              color: colors.surfaceContainerLow,
              child: InkWell(
                onTap: () {
                  AppLog.instance.trace(
                    'lib/pages/discovery_browse_page.dart::_RankAlbums.build.closure#1.closure#1.closure#1',
                  );
                  onOpen(album);
                },
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      _RankPosition(position: position),
                      const SizedBox(width: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: CoverImage(uri: album.coverUrl, size: 56),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              album.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              album.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              [
                                if (stats?.playCount != null)
                                  '${_count(stats!.playCount!)}播放',
                                if (stats?.score != null)
                                  '${stats!.score!.toStringAsFixed(1)}分',
                                if (album.total > 0) '${album.total}集',
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _RankPosition extends StatelessWidget {
  const _RankPosition({required this.position});
  final int? position;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankPosition.build',
    );
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: MediaQuery.textScalerOf(context).scale(28),
      child: Text(
        position == null ? '' : '$position',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: position != null && position! <= 3
              ? colors.primary
              : colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _RankAnchorRow extends StatelessWidget {
  const _RankAnchorRow({
    required this.anchor,
    required this.position,
    required this.onTap,
  });
  final AnchorProfile anchor;
  final int? position;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/discovery_browse_page.dart::_RankAnchorRow.build',
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _RankPosition(position: position),
                const SizedBox(width: 12),
                ClipOval(child: CoverImage(uri: anchor.avatarUrl, size: 48)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        anchor.nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (anchor.fansCount != null)
                            '${_count(anchor.fansCount!)}粉丝',
                          if (anchor.tracksCount != null)
                            '${_count(anchor.tracksCount!)}声音',
                          if (anchor.albumsCount != null)
                            '${_count(anchor.albumsCount!)}专辑',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _count(int count) {
  AppLog.instance.trace('lib/pages/discovery_browse_page.dart::_count');
  if (count >= 100000000) return '${(count / 100000000).toStringAsFixed(1)}亿';
  if (count >= 10000) return '${(count / 10000).toStringAsFixed(1)}万';
  return '$count';
}
