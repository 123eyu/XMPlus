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
    this.onDownload,
    this.onPlayAlbum,
    super.key,
  });

  final AppRuntime runtime;
  final String albumId, albumTitle;
  final TrackDownload? onDownload;
  final AlbumPlayback? onPlayAlbum;

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
  bool _busy = false, _failed = false;

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
          return XmlyComments(client).loadAlbumReviews(albumId, page: page);
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
      appBar: AppHeader(
        title: const Text('专辑评价'),
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
                          if (widget.albumTitle.isNotEmpty) ...[
                            Text(
                              widget.albumTitle,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 16),
                          ],
                          if (result != null) ...[
                            _ReviewOverview(result: result),
                            const SizedBox(height: 24),
                          ],
                          if (_failed)
                            _ReviewFailure(
                              onRetry: () {
                                AppLog.instance.trace(
                                  'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.build.closure#2.closure#1',
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
                              'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.build.closure#2.closure#2',
                            );
                            final review = result.comments[index];
                            return _ReviewContent(
                              key: ValueKey('${widget.albumId}:${review.id}'),
                              author: review.author,
                              uid: review.uid,
                              avatarUrl: review.avatarUrl,
                              createdAt: review.createdAt,
                              content: review.content,
                              onAuthor: _openAuthor,
                              action: TextButton.icon(
                                onPressed: () {
                                  AppLog.instance.trace(
                                    'lib/pages/album_reviews_page.dart::_AlbumReviewsPageState.build.closure#2.closure#2.closure#1',
                                  );
                                  unawaited(_openReplies(review));
                                },
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                ),
                                icon: const Icon(
                                  Icons.chat_bubble_outline,
                                  size: 18,
                                ),
                                label: Text(
                                  review.replyCount > 0
                                      ? '${review.replyCount} 条回复'
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
      'lib/pages/album_reviews_page.dart::_ReviewOverview.build',
    );
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 24,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (result.albumScore != null)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.albumScore!.toStringAsFixed(1),
                    style: theme.textTheme.headlineLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const Text('专辑总分'),
                ],
              ),
            if (result.allCommentsCount != null)
              Text('${result.allCommentsCount} 条评价'),
            if (result.albumValidScoreNum != null)
              Text('${result.albumValidScoreNum} 人评分'),
            if (result.albumScore == null &&
                result.allCommentsCount == null &&
                result.albumValidScoreNum == null)
              const Text('专辑评价'),
          ],
        ),
      ),
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
  });
  final String author, uid, createdAt, content, parentAuthor;
  final Uri? avatarUrl;
  final Future<void> Function(String) onAuthor;
  final Widget? action;

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
      'lib/pages/album_reviews_page.dart::_ReviewContentState.build',
    );
    final theme = Theme.of(context);
    final long = widget.content.runes.length > 360;
    final content = long && !_expanded
        ? '${String.fromCharCodes(widget.content.runes.take(360))}…'
        : widget.content;
    final author = widget.author.isEmpty ? '听友' : widget.author;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              button: widget.uid.isNotEmpty,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: widget.uid.isEmpty
                    ? null
                    : () {
                        AppLog.instance.trace(
                          'lib/pages/album_reviews_page.dart::_ReviewContentState.build.closure#1',
                        );
                        unawaited(widget.onAuthor(widget.uid));
                      },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      ClipOval(
                        child: SizedBox.square(
                          dimension: 36,
                          child: widget.avatarUrl == null
                              ? const Icon(
                                  Icons.account_circle_outlined,
                                  size: 36,
                                )
                              : Image(
                                  image: LoggedNetworkImage(
                                    widget.avatarUrl.toString(),
                                  ),
                                  fit: BoxFit.cover,
                                  excludeFromSemantics: true,
                                  errorBuilder: (context, error, stack) {
                                    AppLog.instance.trace(
                                      'lib/pages/album_reviews_page.dart::_ReviewContentState.build.closure#2',
                                    );
                                    return const Icon(
                                      Icons.account_circle_outlined,
                                      size: 36,
                                    );
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: widget.uid.isEmpty
                                    ? null
                                    : theme.colorScheme.primary,
                              ),
                            ),
                            Text(
                              widget.createdAt,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (widget.parentAuthor.isNotEmpty) ...[
              Text(
                '回复 ${widget.parentAuthor}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
            ],
            CommentText(content, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (long)
                  TextButton(
                    onPressed: () {
                      AppLog.instance.trace(
                        'lib/pages/album_reviews_page.dart::_ReviewContentState.build.closure#3',
                      );
                      setState(() {
                        AppLog.instance.trace(
                          'lib/pages/album_reviews_page.dart::_ReviewContentState.build.closure#3.closure#1',
                        );
                        _expanded = !_expanded;
                      });
                    },
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    child: Text(_expanded ? '收起' : '展开全文'),
                  ),
                IconButton(
                  tooltip: '复制全文',
                  onPressed: _copy,
                  icon: const Icon(Icons.copy_outlined, size: 18),
                ),
                if (widget.action != null) widget.action!,
              ],
            ),
          ],
        ),
      ),
    );
  }
}
