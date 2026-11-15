import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import 'catalogue_page.dart' show CoverImage;

class AlbumSimilarSection extends StatefulWidget {
  const AlbumSimilarSection({
    required this.client,
    required this.albumId,
    required this.onOpenAlbum,
    this.onOpenAnchor,
    super.key,
  });

  final XmlyClient client;
  final String albumId;
  final ValueChanged<String> onOpenAlbum;
  final VoidCallback? onOpenAnchor;

  @override
  State<AlbumSimilarSection> createState() {
    AppLog.instance.trace(
      "lib/pages/album_similar_section.dart::AlbumSimilarSection.createState",
    );
    return _AlbumSimilarSectionState();
  }
}

class _AlbumSimilarSectionState extends State<AlbumSimilarSection> {
  final _anchorScroll = ScrollController();
  AlbumSimilarData? _content;
  String? _error;
  int _request = 0;
  bool _busy = true;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState.initState",
    );
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AlbumSimilarSection oldWidget) {
    AppLog.instance.trace(
      "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState.didUpdateWidget",
    );
    super.didUpdateWidget(oldWidget);
    if (oldWidget.albumId != widget.albumId ||
        oldWidget.client != widget.client) {
      _load();
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState.dispose",
    );
    _anchorScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    AppLog.instance.trace(
      "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState._load",
    );
    final request = ++_request;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState._load.closure#1",
      );
      _busy = true;
      _content = null;
      _error = null;
    });
    try {
      final content = await XmlyExperience(widget.client)
          .albumSimilar(widget.albumId);
      if (!mounted || request != _request) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState._load.closure#2",
        );
        _content = content;
        _busy = false;
      });
      if (_anchorScroll.hasClients) _anchorScroll.jumpTo(0);
    } catch (error, stack) {
      if (!mounted || request != _request) return;
      final log = AppLog.instance;
      if (!log.errorWasRecorded(error)) {
        log.write(
          AppLogLevel.error,
          'album_similar',
          'Loading similar albums failed',
          error: error,
          stackTrace: stack,
          promptUser: true,
        );
      }
      setState(() {
        AppLog.instance.trace(
          "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState._load.closure#3",
        );
        _error = error is XmlyException ? error.message : '相似专辑加载失败，请重试';
        _busy = false;
      });
    }
  }

  Widget _heading(String title, {VoidCallback? onMore}) {
    AppLog.instance.trace(
      "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState._heading",
    );
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ),
          if (onMore != null)
            TextButton(onPressed: onMore, child: const Text('更多 ›')),
        ],
      ),
    );
  }

  Widget _album(Album album, double width) {
    AppLog.instance.trace(
      "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState._album",
    );
    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () {
          AppLog.instance.trace(
            "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState._album.closure#1",
          );
          return widget.onOpenAlbum(album.id);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverImage(uri: album.coverUrl, size: width),
            const SizedBox(height: 8),
            Text(
              album.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState.build",
    );
    if (_busy) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!),
              TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final content = _content;
    if (content == null) return const SizedBox.shrink();
    if (content.anchorAlbums.albums.isEmpty &&
        content.recommendations.albums.isEmpty) {
      return const Center(child: Text('暂无相似专辑'));
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: LayoutBuilder(
          builder: (context, constraints) {
            AppLog.instance.trace(
              "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState.build.closure#1",
            );
            const gap = 24.0;
            final width = math.max(0.0, constraints.maxWidth - 32);
            final scaler = MediaQuery.textScalerOf(context);
            final scale = math.max(1.0, scaler.scale(16) / 16);
            final columns = math.max(
              1,
              ((width + gap) / (104 * scale + gap)).floor(),
            );
            final coverWidth = (width - gap * (columns - 1)) / columns;
            final titleHeight = (scaler.scale(16) * 1.4 * 2).ceilToDouble();
            final extent = coverWidth + 8 + titleHeight;
            return CustomScrollView(
              key: ValueKey((widget.client, widget.albumId)),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  sliver: SliverMainAxisGroup(
                    slivers: [
                      if (content.anchorAlbums.albums.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: _heading(
                            content.anchorAlbums.title,
                            onMore: content.showAnchorMore
                                ? widget.onOpenAnchor
                                : null,
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: extent + 12,
                            child: Scrollbar(
                              controller: _anchorScroll,
                              child: ListView.separated(
                                controller: _anchorScroll,
                                scrollDirection: Axis.horizontal,
                                itemCount: content.anchorAlbums.albums.length,
                                separatorBuilder: (_, _) {
                                  AppLog.instance.trace(
                                    "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState.build.closure#1.closure#1",
                                  );
                                  return const SizedBox(width: gap);
                                },
                                itemBuilder: (context, index) {
                                  AppLog.instance.trace(
                                    "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState.build.closure#1.closure#2",
                                  );
                                  return SizedBox(
                                    width: coverWidth,
                                    child: _album(
                                      content.anchorAlbums.albums[index],
                                      coverWidth,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (content.recommendations.albums.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: _heading(content.recommendations.title),
                        ),
                        SliverGrid.builder(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: gap,
                                mainAxisSpacing: 20,
                                mainAxisExtent: extent,
                              ),
                          itemCount: content.recommendations.albums.length,
                          itemBuilder: (context, index) {
                            AppLog.instance.trace(
                              "lib/pages/album_similar_section.dart::_AlbumSimilarSectionState.build.closure#1.closure#3",
                            );
                            return _album(
                              content.recommendations.albums[index],
                              coverWidth,
                            );
                          },
                        ),
                      ],
                    ],
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
