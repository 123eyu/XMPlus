import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/xmly_client.dart';
import '../api/xmly_comments.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/content_paging.dart';
import '../common/widgets/local_panel.dart';
import '../common/widgets/logged_network_image.dart';
import '../models/xmly_models.dart' show XmlyException;
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'anchor_page.dart';
import 'catalogue_page.dart' show AlbumPlayback, TrackDownload;
import 'comment_text.dart';

// The overview count is unrelated to this list's server pagination. Keep the
// pager within maxPageId even when a response's totalCount is inconsistent.
int _pagingTotal(int total, int size, int last) {
  AppLog.instance.trace('lib/pages/album_reviews_page.dart::_pagingTotal');
  if (last == 0) return 0;
  return total.clamp((last - 1) * size + 1, last * size);
}

void _recordReviewError(Object error, StackTrace stack) {
  AppLog.instance.trace(
    'lib/pages/album_reviews_page.dart::_recordReviewError',
  );
  if (AppLog.instance.errorWasRecorded(error)) return;
  AppLog.instance.write(
    AppLogLevel.warning,
    'album_reviews_page',
    'Read-only reviews request failed',
    error: error,
    stackTrace: stack,
    promptUser: false,
  );
}

class AlbumReviewsPage extends StatefulWidget {
  const AlbumReviewsPage({
    required this.runtime,
    required this.albumId,
    this.albumTitle = '',
    this.accountIdentity,
    this.onDownload,
    this.onPlayAlbum,
    this.bottomBar,
    this.embedded = false,
    super.key,
  });

  final AppRuntime runtime;
  final String albumId, albumTitle;
  final String? accountIdentity;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;
  final Widget? bottomBar;
  final bool embedded;

  @override
  State<AlbumReviewsPage> createState() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::AlbumReviewsPage.createState',
    );
    return _AlbumReviewsPageState();
  }
}

class _AlbumReviewsPageState extends State<AlbumReviewsPage> {
  final _scroll = ScrollController();
  AlbumReviewPage? _result;
  late XmlyClient _client;
  Completer<void>? _cancelled, _panelCancelled;
  int _generation = 0, _failedPage = 1;
  bool _busy = false, _failed = false, _newest = false;

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.initState',
    );
    super.initState();
    _client = widget.runtime.client;
    widget.runtime.addListener(_runtimeChanged);
    unawaited(_load(1));
  }

  @override
  void didUpdateWidget(covariant AlbumReviewsPage oldWidget) {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.didUpdateWidget',
    );
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_runtimeChanged);
      widget.runtime.addListener(_runtimeChanged);
    }
    if (oldWidget.albumId != widget.albumId ||
        oldWidget.runtime != widget.runtime) {
      _reset();
    }
  }

  void _runtimeChanged() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._runtimeChanged',
    );
    if (!identical(_client, widget.runtime.client)) _reset();
  }

  void _reset() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._reset',
    );
    _generation++;
    _cancelled?.complete();
    _cancelled = null;
    _panelCancelled?.complete();
    _panelCancelled = null;
    _client = widget.runtime.client;
    _result = null;
    unawaited(_load(1));
  }

  Future<void> _load(int page) async {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._load',
    );
    final generation = ++_generation;
    _cancelled?.complete();
    final cancelled = _cancelled = Completer<void>();
    final client = _client, albumId = widget.albumId;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._load.closure#1',
      );
      _busy = true;
      _failed = false;
      _failedPage = page;
    });
    try {
      final result = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._load.closure#2',
          );
          return XmlyComments(client)
              .loadAlbumReviews(albumId, page: page, newest: _newest);
        },
        rateLimitRetries: 4,
        cancelled: cancelled.future,
      );
      if (!mounted ||
          generation != _generation ||
          albumId != widget.albumId ||
          !identical(client, widget.runtime.client))
        return;
      final changedPage = _result?.page != result.page;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._load.closure#3',
        );
        _result = result;
      });
      if (changedPage && _scroll.hasClients) _scroll.jumpTo(0);
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      _recordReviewError(error, stack);
      setState(() {
        AppLog.instance.trace(
          'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._load.closure#4',
        );
        _failed = true;
      });
    } finally {
      if (identical(_cancelled, cancelled)) _cancelled = null;
      if (mounted && generation == _generation) {
        setState(() {
          AppLog.instance.trace(
            'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._load.closure#5',
          );
          _busy = false;
        });
      }
    }
  }

  Future<void> _openAuthor(String uid) async {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._openAuthor',
    );
    if (uid.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) {
          AppLog.instance.trace(
            'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._openAuthor.closure#1',
          );
          return AnchorPage(
            runtime: widget.runtime,
            uid: uid,
            accountIdentity: widget.accountIdentity,
            onDownload: widget.onDownload,
            onPlayAlbum: widget.onPlayAlbum,
          );
        },
      ),
    );
  }

  Future<void> _openReplies(AlbumReview review) async {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._openReplies',
    );
    _panelCancelled?.complete();
    final cancelled = _panelCancelled = Completer<void>();
    final runtime = widget.runtime, albumId = widget.albumId;
    try {
      await showLocalPanel<void>(
        context: context,
        title: '评价回复',
        width: 760,
        height: 780,
        builder: (context) {
          AppLog.instance.trace(
            'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState._openReplies.closure#1',
          );
          return _ReviewReplies(
            runtime: runtime,
            albumId: albumId,
            review: review,
            invalidated: cancelled.future,
            onAuthor: _openAuthor,
          );
        },
      );
    } finally {
      if (!cancelled.isCompleted) cancelled.complete();
      if (identical(_panelCancelled, cancelled)) _panelCancelled = null;
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.dispose',
    );
    _generation++;
    _cancelled?.complete();
    _panelCancelled?.complete();
    widget.runtime.removeListener(_runtimeChanged);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.build',
    );
    final result = _result;
    return Scaffold(
      bottomNavigationBar: widget.bottomBar,
      appBar: widget.embedded
          ? null
          : AppHeader(
              title: Text(
                widget.albumTitle.isEmpty ? '专辑评价' : widget.albumTitle,
              ),
              actions: [
                IconButton(
                  tooltip: '刷新',
                  onPressed: _busy
                      ? null
                      : () {
                          AppLog.instance.trace(
                            'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.build.closure#1',
                          );
                          unawaited(_load(result?.page ?? 1));
                        },
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: LayoutBuilder(
              builder: (context, constraints) {
                AppLog.instance.trace(
                  'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.build.closure#2',
                );
                final padding = constraints.maxWidth < 600 ? 12.0 : 24.0;
                return CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 4,
                        child: _busy
                            ? const LinearProgressIndicator(
                                semanticsLabel: '正在加载评价',
                              )
                            : null,
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.all(padding),
                      sliver: SliverList.list(
                        children: [
                          if (result != null) ...[
                            _ReviewOverview(result: result),
                            const SizedBox(height: 24),
                            Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 24,
                              runSpacing: 8,
                              children: [
                                Text(
                                  '全部 ${result.allCommentsCount ?? result.total}',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                Wrap(
                                  spacing: 4,
                                  children: [
                                    for (final newest in [false, true])
                                      TextButton(
                                        onPressed: _busy || _newest == newest
                                            ? null
                                            : () {
                                                AppLog.instance.trace(
                                                  "lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.build.closure#2.closure#1",
                                                );
                                                setState(() {
                                                  AppLog.instance.trace(
                                                    "lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.build.closure#2.closure#1.closure#1",
                                                  );
                                                  _newest = newest;
                                                  _result = null;
                                                });
                                                unawaited(_load(1));
                                              },
                                        style: TextButton.styleFrom(
                                          foregroundColor: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                          disabledForegroundColor: Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                          textStyle: TextStyle(
                                            fontWeight: _newest == newest
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                          ),
                                        ),
                                        child: Semantics(
                                          selected: _newest == newest,
                                          child: Text(newest ? '最新' : '综合'),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                          if (_failed)
                            _ReviewFailure(
                              onRetry: () {
                                AppLog.instance.trace(
                                  "lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.build.closure#2.closure#2",
                                );
                                return _load(_failedPage);
                              },
                            ),
                          if (!_busy &&
                              !_failed &&
                              (result?.comments.isEmpty ?? false))
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(child: Text('暂无内容')),
                            ),
                        ],
                      ),
                    ),
                    if (result != null)
                      SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: padding),
                        sliver: SliverList.builder(
                          itemCount: result.comments.length,
                          itemBuilder: (context, index) {
                            AppLog.instance.trace(
                              "lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.build.closure#2.closure#3",
                            );
                            final review = result.comments[index];
                            return _ReviewContent(
                              key: ValueKey('${widget.albumId}:${review.id}'),
                              author: review.author,
                              uid: review.uid,
                              avatarUrl: review.avatarUrl,
                              createdAt: review.createdAt,
                              content: review.content,
                              likes: review.likes,
                              region: review.region,
                              highQuality: review.highQuality,
                              badges: review.badges,
                              previewReply: review.previewReply,
                              onAuthor: _openAuthor,
                              action: TextButton.icon(
                                onPressed: () {
                                  AppLog.instance.trace(
                                    "lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.build.closure#2.closure#3.closure#1",
                                  );
                                  unawaited(_openReplies(review));
                                },
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                ),
                                icon: const Icon(Icons.expand_more, size: 18),
                                label: Text(
                                  review.replyCount > 0
                                      ? '共${review.replyCount}条回复'
                                      : '查看回复',
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    if (result != null && result.maxPageId > 0)
                      SliverToBoxAdapter(
                        child: ContentPaging(
                          page: result.page,
                          total: _pagingTotal(
                            result.total,
                            result.pageSize,
                            result.maxPageId,
                          ),
                          pageSize: result.pageSize,
                          busy: _busy,
                          onPage: _load,
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ReviewOverview extends StatelessWidget {
  const _ReviewOverview({required this.result});
  final AlbumReviewPage result;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/album_reviews_page.dart::_ReviewOverview.build",
    );
    final theme = Theme.of(context);
    final score = result.recommendationScore;
    final hasSummary =
        score != null ||
        result.recommendationLabel.isNotEmpty ||
        result.recommendationCount != null;
    final description = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (result.recommendationLabel.isNotEmpty)
          Text(
            result.recommendationLabel,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.brightness == Brightness.dark
                  ? Colors.amber.shade300
                  : Colors.amber.shade800,
              fontWeight: FontWeight.w700,
            ),
          ),
        if (result.recommendationCount != null) ...[
          const SizedBox(height: 8),
          Text(
            '${result.recommendationCount}人点评',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    final ratios = [
      ('推荐', result.recommendedRatio),
      ('一般', result.neutralRatio),
      ('不行', result.notRecommendedRatio),
    ];
    final distribution = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (label, value) in ratios)
          if (value != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Semantics(
                label: '$label ${(value * 100).round()}%',
                child: ExcludeSemantics(
                  child: Row(
                    children: [
                      SizedBox(
                        width: MediaQuery.textScalerOf(context).scale(40),
                        child: Text(
                          label,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: value,
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(6),
                          color: theme.colorScheme.outline,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (score != null) ...[
          Text(
            '推荐值 ${(score * 100).round()}%',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 24),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            AppLog.instance.trace(
              "lib/pages/album_reviews_page.dart::_ReviewOverview.build.closure#1",
            );
            if (constraints.maxWidth < 340 ||
                MediaQuery.textScalerOf(context).scale(16) > 22) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  description,
                  if (hasSummary) const SizedBox(height: 16),
                  distribution,
                ],
              );
            }
            return Row(
              children: [
                if (hasSummary) ...[
                  Expanded(flex: 2, child: description),
                  const SizedBox(width: 24),
                ],
                Expanded(flex: 3, child: distribution),
              ],
            );
          },
        ),
        if (!hasSummary &&
            ratios.every((entry) {
              AppLog.instance.trace(
                "lib/pages/album_reviews_page.dart::_ReviewOverview.build.closure#2",
              );
              return entry.$2 == null;
            }))
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              if (result.albumScore != null)
                Text('专辑评分 ${result.albumScore!.toStringAsFixed(1)}'),
              if (result.albumValidScoreNum != null)
                Text('${result.albumValidScoreNum}人评分'),
            ],
          ),
        const SizedBox(height: 24),
        const Divider(height: 1),
      ],
    );
  }
}

class _ReviewReplies extends StatefulWidget {
  const _ReviewReplies({
    required this.runtime,
    required this.albumId,
    required this.review,
    required this.invalidated,
    required this.onAuthor,
  });
  final AppRuntime runtime;
  final String albumId;
  final AlbumReview review;
  final Future<void> invalidated;
  final Future<void> Function(String) onAuthor;

  @override
  State<_ReviewReplies> createState() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewReplies.createState',
    );
    return _ReviewRepliesState();
  }
}

class _ReviewRepliesState extends State<_ReviewReplies> {
  final _scroll = ScrollController();
  AlbumReviewRepliesPage? _result;
  Completer<void>? _cancelled;
  late XmlyClient _client;
  int _generation = 0, _failedPage = 1;
  bool _busy = false, _failed = false, _invalidated = false;

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewRepliesState.initState',
    );
    super.initState();
    _client = widget.runtime.client;
    widget.runtime.addListener(_runtimeChanged);
    _watchInvalidation();
    unawaited(_load(1));
  }

  void _watchInvalidation() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewRepliesState._watchInvalidation',
    );
    final invalidated = widget.invalidated;
    unawaited(
      invalidated.then((_) {
        AppLog.instance.trace(
          'lib/pages/album_reviews_page.dart::_ReviewRepliesState._watchInvalidation.closure#1',
        );
        if (mounted && identical(invalidated, widget.invalidated))
          _invalidate();
      }),
    );
  }

  void _invalidate() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewRepliesState._invalidate',
    );
    _generation++;
    _cancelled?.complete();
    _cancelled = null;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/album_reviews_page.dart::_ReviewRepliesState._invalidate.closure#1',
      );
      _invalidated = true;
      _busy = false;
      _result = null;
    });
  }

  void _runtimeChanged() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewRepliesState._runtimeChanged',
    );
    if (!identical(_client, widget.runtime.client)) _invalidate();
  }

  @override
  void didUpdateWidget(covariant _ReviewReplies oldWidget) {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewRepliesState.didUpdateWidget',
    );
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_runtimeChanged);
      widget.runtime.addListener(_runtimeChanged);
    }
    if (oldWidget.albumId != widget.albumId ||
        oldWidget.review.id != widget.review.id ||
        oldWidget.runtime != widget.runtime ||
        oldWidget.invalidated != widget.invalidated) {
      _generation++;
      _cancelled?.complete();
      _cancelled = null;
      _client = widget.runtime.client;
      _result = null;
      _invalidated = false;
      _watchInvalidation();
      unawaited(_load(1));
    }
  }

  Future<void> _load(int page) async {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewRepliesState._load',
    );
    if (_invalidated) return;
    final generation = ++_generation;
    _cancelled?.complete();
    final cancelled = _cancelled = Completer<void>();
    final client = _client, albumId = widget.albumId, rootId = widget.review.id;
    setState(() {
      AppLog.instance.trace(
        'lib/pages/album_reviews_page.dart::_ReviewRepliesState._load.closure#1',
      );
      _busy = true;
      _failed = false;
      _failedPage = page;
    });
    try {
      final result = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            'lib/pages/album_reviews_page.dart::_ReviewRepliesState._load.closure#2',
          );
          return XmlyComments(client)
              .loadAlbumReviewReplies(albumId, rootId, page: page);
        },
        rateLimitRetries: 4,
        cancelled: cancelled.future,
      );
      if (!mounted ||
          generation != _generation ||
          _invalidated ||
          widget.albumId != albumId ||
          widget.review.id != rootId ||
          !identical(client, widget.runtime.client))
        return;
      if ((result.root != null && result.root!.id != rootId) ||
          result.replies.any((reply) {
            AppLog.instance.trace(
              'lib/pages/album_reviews_page.dart::_ReviewRepliesState._load.closure#3',
            );
            return reply.commentId != rootId;
          })) {
        throw const XmlyException('invalid_reviews', '暂时无法加载回复');
      }
      final changedPage = _result?.page != result.page;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/album_reviews_page.dart::_ReviewRepliesState._load.closure#4',
        );
        _result = result;
      });
      if (changedPage && _scroll.hasClients) _scroll.jumpTo(0);
    } catch (error, stack) {
      if (!mounted || generation != _generation || _invalidated) return;
      _recordReviewError(error, stack);
      setState(() {
        AppLog.instance.trace(
          'lib/pages/album_reviews_page.dart::_ReviewRepliesState._load.closure#5',
        );
        _failed = true;
      });
    } finally {
      if (identical(_cancelled, cancelled)) _cancelled = null;
      if (mounted && generation == _generation) {
        setState(() {
          AppLog.instance.trace(
            'lib/pages/album_reviews_page.dart::_ReviewRepliesState._load.closure#6',
          );
          _busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewRepliesState.dispose',
    );
    _generation++;
    _cancelled?.complete();
    widget.runtime.removeListener(_runtimeChanged);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewRepliesState.build',
    );
    if (_invalidated) return const Center(child: Text('请关闭后重新打开回复'));
    final result = _result;
    final root = result?.root ?? widget.review;
    return Column(
      children: [
        SizedBox(
          height: 4,
          child: _busy
              ? const LinearProgressIndicator(semanticsLabel: '正在加载回复')
              : null,
        ),
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
            children: [
              Text('原评价', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              _ReviewContent(
                key: ValueKey('root:${root.id}'),
                author: root.author,
                uid: root.uid,
                avatarUrl: root.avatarUrl,
                createdAt: root.createdAt,
                content: root.content,
                likes: root.likes,
                region: root.region,
                highQuality: root.highQuality,
                badges: root.badges,
                onAuthor: widget.onAuthor,
              ),
              const SizedBox(height: 16),
              Text(
                '回复${result == null ? '' : ' · ${result.total}'}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              if (_failed)
                _ReviewFailure(
                  onRetry: () {
                    AppLog.instance.trace(
                      'lib/pages/album_reviews_page.dart::_ReviewRepliesState.build.closure#1',
                    );
                    return _load(_failedPage);
                  },
                ),
              if (!_busy && !_failed && (result?.replies.isEmpty ?? false))
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('暂无内容')),
                ),
              if (result != null) ...[
                for (final reply in result.replies)
                  _ReviewContent(
                    key: ValueKey('reply:${reply.id}'),
                    author: reply.author,
                    uid: reply.uid,
                    avatarUrl: reply.avatarUrl,
                    createdAt: reply.createdAt,
                    content: reply.content,
                    likes: reply.likes,
                    region: reply.region,
                    badges: reply.badges,
                    parentAuthor: reply.parentReplyNickName,
                    onAuthor: widget.onAuthor,
                  ),
                if (result.maxPageId > 0)
                  ContentPaging(
                    page: result.page,
                    total: _pagingTotal(
                      result.total,
                      result.pageSize,
                      result.maxPageId,
                    ),
                    pageSize: result.pageSize,
                    busy: _busy,
                    onPage: _load,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ReviewFailure extends StatelessWidget {
  const _ReviewFailure({required this.onRetry});
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewFailure.build',
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('暂时无法加载，请重试'),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class _ReviewContent extends StatefulWidget {
  const _ReviewContent({
    super.key,
    required this.author,
    required this.uid,
    required this.avatarUrl,
    required this.createdAt,
    required this.content,
    required this.onAuthor,
    this.parentAuthor = '',
    this.action,
    this.likes,
    this.region = '',
    this.highQuality = false,
    this.badges = const [],
    this.previewReply,
    this.compact = false,
  });
  final String author, uid, createdAt, content, parentAuthor;
  final Uri? avatarUrl;
  final Future<void> Function(String) onAuthor;
  final Widget? action;
  final int? likes;
  final String region;
  final bool highQuality, compact;
  final List<AlbumReviewBadge> badges;
  final AlbumReviewReply? previewReply;

  @override
  State<_ReviewContent> createState() {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewContent.createState',
    );
    return _ReviewContentState();
  }
}

class _ReviewContentState extends State<_ReviewContent> {
  bool _expanded = false;

  Future<void> _copy() async {
    AppLog.instance.trace(
      'lib/pages/album_reviews_page.dart::_ReviewContentState._copy',
    );
    await Clipboard.setData(ClipboardData(text: widget.content));
    if (mounted)
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('已复制')));
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/album_reviews_page.dart::_ReviewContentState.build",
    );
    final theme = Theme.of(context);
    final long = widget.content.runes.length > 360;
    final content = long && !_expanded
        ? '${String.fromCharCodes(widget.content.runes.take(360))}…'
        : widget.content;
    final author = widget.author.isEmpty ? '听友' : widget.author;
    final muted = theme.colorScheme.onSurfaceVariant;
    final surface = theme.colorScheme.surfaceContainerLow;
    final preview = widget.previewReply;
    final avatarSize = widget.compact ? 28.0 : 40.0;
    final badgeHeight = MediaQuery.textScalerOf(context)
        .scale(16)
        .clamp(16.0, 24.0)
        .toDouble();
    void openAuthor() {
      AppLog.instance.trace(
        "lib/pages/album_reviews_page.dart::_ReviewContentState.build.openAuthor",
      );
      unawaited(widget.onAuthor(widget.uid));
    }

    return Padding(
      padding: EdgeInsets.only(bottom: widget.compact ? 0 : 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: '${author}的主页',
            button: widget.uid.isNotEmpty,
            child: InkWell(
              onTap: widget.uid.isEmpty ? null : openAuthor,
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                width: widget.compact ? 32 : 48,
                height: 48,
                child: Center(
                  child: ClipOval(
                    child: SizedBox.square(
                      dimension: avatarSize,
                      child: widget.avatarUrl == null
                          ? Icon(
                              Icons.account_circle_outlined,
                              size: avatarSize,
                              color: muted,
                            )
                          : Image(
                              image: LoggedNetworkImage(
                                widget.avatarUrl.toString(),
                              ),
                              fit: BoxFit.cover,
                              excludeFromSemantics: true,
                              errorBuilder: (context, error, stack) {
                                AppLog.instance.trace(
                                  "lib/pages/album_reviews_page.dart::_ReviewContentState.build.closure#1",
                                );
                                return Icon(
                                  Icons.account_circle_outlined,
                                  size: avatarSize,
                                  color: muted,
                                );
                              },
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: widget.uid.isEmpty ? null : openAuthor,
                  borderRadius: BorderRadius.circular(6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            author,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: muted,
                            ),
                          ),
                          for (final badge in widget.badges)
                            Image(
                              image: LoggedNetworkImage(
                                (theme.brightness == Brightness.dark
                                        ? badge.darkIcon ?? badge.icon
                                        : badge.icon)
                                    .toString(),
                              ),
                              width: badgeHeight * badge.aspectRatio,
                              height: badgeHeight,
                              fit: BoxFit.contain,
                              semanticLabel: badge.label,
                              errorBuilder: (context, error, stack) {
                                AppLog.instance.trace(
                                  "lib/pages/album_reviews_page.dart::_ReviewContentState.build.closure#2",
                                );
                                return const SizedBox.shrink();
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (widget.parentAuthor.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '回复 ${widget.parentAuthor}',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                Container(
                  width: double.infinity,
                  padding: widget.compact
                      ? EdgeInsets.zero
                      : const EdgeInsets.all(12),
                  decoration: widget.compact
                      ? null
                      : BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(8),
                        ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.highQuality) ...[
                        Text(
                          '优质评价',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.brightness == Brightness.dark
                                ? Colors.orange.shade200
                                : Colors.brown.shade400,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      CommentText(
                        content,
                        style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                      ),
                      if (long)
                        TextButton(
                          onPressed: () {
                            AppLog.instance.trace(
                              "lib/pages/album_reviews_page.dart::_ReviewContentState.build.closure#3",
                            );
                            return setState(() {
                              AppLog.instance.trace(
                                "lib/pages/album_reviews_page.dart::_ReviewContentState.build.closure#3.closure#1",
                              );
                              _expanded = !_expanded;
                            });
                          },
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          child: Text(_expanded ? '收起' : '展开全文'),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      [
                        widget.createdAt.split(' ').first,
                        if (widget.region.isNotEmpty) widget.region,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    if (widget.likes != null)
                      Semantics(
                        label: '${widget.likes}人赞同',
                        child: ExcludeSemantics(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.thumb_up_outlined,
                                size: 18,
                                color: muted,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${widget.likes}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: '复制全文',
                      onPressed: _copy,
                      icon: Icon(Icons.copy_outlined, size: 16, color: muted),
                    ),
                  ],
                ),
                if (preview != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ReviewContent(
                          key: ValueKey('preview:${preview.id}'),
                          author: preview.author,
                          uid: preview.uid,
                          avatarUrl: preview.avatarUrl,
                          createdAt: preview.createdAt,
                          content: preview.content,
                          region: preview.region,
                          likes: preview.likes,
                          badges: preview.badges,
                          parentAuthor: preview.parentReplyNickName,
                          onAuthor: widget.onAuthor,
                          compact: true,
                        ),
                        if (widget.action != null) widget.action!,
                      ],
                    ),
                  )
                else if (widget.action != null)
                  widget.action!,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
