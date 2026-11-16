import '../models/xmly_models.dart';
import 'xmly_client.dart';
import '../services/app_log.dart';

class TrackComment {
  const TrackComment({
    required this.id,
    required this.author,
    required this.content,
    required this.createdAt,
    required this.likes,
    required this.replyCount,
    this.parentAuthor = '',
    this.uid = '',
    this.avatarUrl,
    this.liked = false,
  });

  final String id, author, content, createdAt, parentAuthor, uid;
  final Uri? avatarUrl;
  final int likes, replyCount;
  final bool liked;

  TrackComment withLike(bool value) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::TrackComment.withLike');
    return TrackComment(
      id: id,
      author: author,
      content: content,
      createdAt: createdAt,
      likes:
          (likes +
                  (value == liked
                      ? 0
                      : value
                      ? 1
                      : -1))
              .clamp(0, 0x7fffffff),
      replyCount: replyCount,
      parentAuthor: parentAuthor,
      uid: uid,
      avatarUrl: avatarUrl,
      liked: value,
    );
  }
}

class TrackCommentPage {
  TrackCommentPage({
    required List<TrackComment> comments,
    required this.total,
    required this.hasMore,
  }) : comments = List.unmodifiable(comments) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::TrackCommentPage.new');
  }
  final List<TrackComment> comments;
  final int total;
  final bool hasMore;
}

class AlbumReviewBadge {
  const AlbumReviewBadge({
    required this.icon,
    required this.label,
    required this.aspectRatio,
    this.darkIcon,
  });

  final Uri icon;
  final Uri? darkIcon;
  final String label;
  final double aspectRatio;
}

class AlbumReview {
  const AlbumReview({
    required this.id,
    required this.author,
    required this.content,
    required this.createdAt,
    required this.replyCount,
    this.uid = '',
    this.avatarUrl,
    this.likes,
    this.region = '',
    this.highQuality = false,
    this.badges = const [],
    this.previewReply,
  });

  factory AlbumReview.fromApi(Map<String, dynamic> row) {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::AlbumReview.factory:fromApi',
    );
    if (row['content'] is! String || row['createdAt'] is! int) {
      throw XmlyComments._invalid;
    }
    final id = xmlyIdentifier('${row['commentId'] ?? ''}');
    final replies = row['replies'];
    if (replies != null && replies is! List) throw XmlyComments._invalid;
    AlbumReviewReply? preview;
    if (replies is List && replies.isNotEmpty) {
      if (replies.first is! Map) throw XmlyComments._invalid;
      final reply = xmlyMap(replies.first);
      // The reply-list endpoint's RootComment embeds only a reference, not a
      // renderable preview. Full previews still require all reply fields.
      if (reply.length == 2 &&
          reply.containsKey('replyId') &&
          reply['unFollowAnchor'] is bool) {
        xmlyIdentifier('${reply['replyId'] ?? ''}');
      } else {
        preview = AlbumReviewReply.fromApi(reply, commentId: id);
      }
    }
    return AlbumReview(
      id: id,
      uid: XmlyComments._reviewUid(row['uid']),
      author: XmlyComments._text(row['nickname']),
      content: row['content'] as String,
      createdAt: XmlyComments._createdAt(row['createdAt']),
      replyCount: XmlyComments._count(row['replyCount'] ?? 0),
      avatarUrl: XmlyComments._avatar(row['smallHeader']),
      likes: row['likes'] == null ? null : XmlyComments._count(row['likes']),
      region: XmlyComments._text(row['region']),
      highQuality: row['isHighQuality'] == true,
      badges: XmlyComments._reviewBadges(row['userTags']),
      previewReply: preview,
    );
  }

  final String id, author, content, createdAt, uid;
  final Uri? avatarUrl;
  final int replyCount;
  final int? likes;
  final String region;
  final bool highQuality;
  final List<AlbumReviewBadge> badges;
  final AlbumReviewReply? previewReply;
}

class AlbumReviewPage {
  AlbumReviewPage({
    required List<AlbumReview> comments,
    required this.page,
    required this.pageSize,
    required this.maxPageId,
    required this.total,
    this.albumScore,
    this.allCommentsCount,
    this.albumValidScoreNum,
    this.recommendationScore,
    this.recommendationLabel = '',
    this.recommendationCount,
    this.recommendedRatio,
    this.neutralRatio,
    this.notRecommendedRatio,
  }) : comments = List.unmodifiable(comments) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::AlbumReviewPage.new');
  }

  factory AlbumReviewPage.fromApi(
    Map<String, dynamic> data, {
    required int page,
  }) {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::AlbumReviewPage.factory:fromApi',
    );
    final pagination = xmlyMap(data['comments']);
    XmlyComments._reviewPagination(pagination, page, 20);
    final comments = <AlbumReview>[];
    final ids = <String>{};
    void append(Object? raw) {
      AppLog.instance.trace(
        'lib/api/xmly_comments.dart::AlbumReviewPage.factory:fromApi.append',
      );
      if (raw is! Map) throw XmlyComments._invalid;
      final review = AlbumReview.fromApi(xmlyMap(raw));
      if (ids.add(review.id)) comments.add(review);
    }

    if (page == 1 && data['ToppedComment'] != null) {
      append(data['ToppedComment']);
    }
    for (final raw in pagination['list'] as List) {
      append(raw);
    }
    final score = data['albumScore'];
    if (score != null && (score is! num || !score.isFinite || score < 0)) {
      throw XmlyComments._invalid;
    }
    final rawSummary = data['recScoreSummary'];
    if (rawSummary != null && rawSummary is! Map) throw XmlyComments._invalid;
    final summary = xmlyMap(rawSummary);
    final rawDiagram = summary['diagram'];
    if (rawDiagram != null && rawDiagram is! Map) throw XmlyComments._invalid;
    final diagram = xmlyMap(rawDiagram);
    return AlbumReviewPage(
      comments: comments,
      page: page,
      pageSize: pagination['pageSize'] as int,
      maxPageId: pagination['maxPageId'] as int,
      total: pagination['totalCount'] as int,
      albumScore: (score as num?)?.toDouble(),
      allCommentsCount: data['allCommentsCount'] == null
          ? null
          : XmlyComments._count(data['allCommentsCount']),
      albumValidScoreNum: data['albumValidScoreNum'] == null
          ? null
          : XmlyComments._count(data['albumValidScoreNum']),
      recommendationScore: XmlyComments._ratio(summary['score']),
      recommendationLabel: XmlyComments._text(summary['label']),
      recommendationCount: summary['totalNum'] == null
          ? null
          : XmlyComments._count(summary['totalNum']),
      recommendedRatio: XmlyComments._ratio(diagram['1']),
      neutralRatio: XmlyComments._ratio(diagram['2']),
      notRecommendedRatio: XmlyComments._ratio(diagram['3']),
    );
  }

  final List<AlbumReview> comments;
  final int page, pageSize, maxPageId, total;
  final double? albumScore;
  final int? allCommentsCount, albumValidScoreNum;
  final double? recommendationScore,
      recommendedRatio,
      neutralRatio,
      notRecommendedRatio;
  final String recommendationLabel;
  final int? recommendationCount;
  bool get hasMore {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::AlbumReviewPage.hasMore.get',
    );
    return page < maxPageId;
  }
}

class AlbumReviewReply {
  const AlbumReviewReply({
    required this.id,
    required this.commentId,
    required this.author,
    required this.content,
    required this.createdAt,
    this.uid = '',
    this.avatarUrl,
    this.parentReplyId = '',
    this.parentReplyNickName = '',
    this.likes,
    this.region = '',
    this.badges = const [],
  });

  factory AlbumReviewReply.fromApi(
    Map<String, dynamic> row, {
    required String commentId,
  }) {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::AlbumReviewReply.factory:fromApi',
    );
    final rootId = xmlyIdentifier(commentId);
    if (xmlyIdentifier('${row['commentId'] ?? ''}') != rootId ||
        row['content'] is! String ||
        row['createdAt'] is! int) {
      throw XmlyComments._invalid;
    }
    return AlbumReviewReply(
      id: xmlyIdentifier('${row['replyId'] ?? ''}'),
      commentId: rootId,
      uid: XmlyComments._reviewUid(row['uid']),
      author: XmlyComments._text(row['nickname']),
      content: row['content'] as String,
      createdAt: XmlyComments._createdAt(row['createdAt']),
      avatarUrl: XmlyComments._avatar(row['smallHeader']),
      parentReplyId: XmlyComments._reviewUid(row['parentReplyId']),
      parentReplyNickName: XmlyComments._text(row['parentReplyNickName']),
      likes: row['likes'] == null ? null : XmlyComments._count(row['likes']),
      region: XmlyComments._text(row['region']),
      badges: XmlyComments._reviewBadges(row['userTags']),
    );
  }

  final String id, commentId, author, content, createdAt, uid;
  final String parentReplyId, parentReplyNickName;
  final Uri? avatarUrl;
  final int? likes;
  final String region;
  final List<AlbumReviewBadge> badges;
}

class AlbumReviewRepliesPage {
  AlbumReviewRepliesPage({
    required this.root,
    required List<AlbumReviewReply> replies,
    required this.page,
    required this.pageSize,
    required this.maxPageId,
    required this.total,
  }) : replies = List.unmodifiable(replies) {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::AlbumReviewRepliesPage.new',
    );
  }

  factory AlbumReviewRepliesPage.fromApi(
    Map<String, dynamic> data, {
    required String commentId,
    required int page,
  }) {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::AlbumReviewRepliesPage.factory:fromApi',
    );
    final rootId = xmlyIdentifier(commentId);
    AlbumReview? root;
    if (data['RootComment'] != null) {
      if (data['RootComment'] is! Map) throw XmlyComments._invalid;
      root = AlbumReview.fromApi(xmlyMap(data['RootComment']));
      if (root.id != rootId) throw XmlyComments._invalid;
    }
    final pagination = xmlyMap(data['commentReplys']);
    XmlyComments._reviewPagination(pagination, page, 20);
    final replies = <AlbumReviewReply>[];
    final ids = <String>{};
    for (final raw in pagination['list'] as List) {
      if (raw is! Map) throw XmlyComments._invalid;
      final reply = AlbumReviewReply.fromApi(xmlyMap(raw), commentId: rootId);
      if (ids.add(reply.id)) replies.add(reply);
    }
    return AlbumReviewRepliesPage(
      root: root,
      replies: replies,
      page: page,
      pageSize: pagination['pageSize'] as int,
      maxPageId: pagination['maxPageId'] as int,
      total: pagination['totalCount'] as int,
    );
  }

  final AlbumReview? root;
  final List<AlbumReviewReply> replies;
  final int page, pageSize, maxPageId, total;
  bool get hasMore {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::AlbumReviewRepliesPage.hasMore.get',
    );
    return page < maxPageId;
  }
}

class XmlyComments {
  XmlyComments(this.client) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments.new');
  }
  final XmlyClient client;
  static const _invalid = XmlyException('invalid_comments', '评论列表格式无效，请重试');

  static String _reviewUid(Object? value) {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::XmlyComments._reviewUid',
    );
    return value == null || value == 0 || value == '0'
        ? ''
        : xmlyIdentifier('$value');
  }

  static double? _ratio(Object? value) {
    AppLog.instance.trace("lib/api/xmly_comments.dart::XmlyComments._ratio");
    if (value == null) return null;
    if (value is! num || !value.isFinite || value < 0 || value > 1) {
      throw _invalid;
    }
    return value.toDouble();
  }

  static List<AlbumReviewBadge> _reviewBadges(Object? value) {
    AppLog.instance.trace(
      "lib/api/xmly_comments.dart::XmlyComments._reviewBadges",
    );
    if (value is! List) return const [];
    final badges = <AlbumReviewBadge>[];
    for (final raw in value) {
      if (raw is! Map) continue;
      final icon = _avatar(raw['icon']);
      final width = raw['width'], height = raw['height'];
      if (icon == null ||
          width is! num ||
          height is! num ||
          !width.isFinite ||
          !height.isFinite ||
          width <= 0 ||
          height <= 0) {
        continue;
      }
      final extra = xmlyMap(raw['extra']);
      final level = extra['level'];
      badges.add(
        AlbumReviewBadge(
          icon: icon,
          darkIcon: _avatar(raw['darkIcon']),
          aspectRatio: (width / height).clamp(0.5, 5.0).toDouble(),
          label: raw['businessName'] == 'grade' && level is int && level > 0
              ? '等级 $level'
              : raw['businessName'] == 'vip'
              ? '会员标识'
              : '用户标识',
        ),
      );
    }
    return List.unmodifiable(badges);
  }

  static void _reviewPagination(
    Map<String, dynamic> data,
    int page,
    int requestedSize,
  ) {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::XmlyComments._reviewPagination',
    );
    final pageId = _count(data['pageId']);
    final size = _count(data['pageSize']);
    final pages = _count(data['maxPageId']);
    _count(data['totalCount']);
    final list = data['list'];
    // A page past the current maxPageId is returned with the requested pageId
    // and an empty list. Preserve those bounds rather than inventing a page.
    if (pageId != page ||
        size < 1 ||
        size > requestedSize ||
        list is! List ||
        list.length > size ||
        (pages > 0 && page > pages && list.isNotEmpty)) {
      throw XmlyException(
        'invalid_comments',
        _invalid.message,
        diagnostics: {
          'requestedPage': page,
          'requestedSize': requestedSize,
          for (final key in [
            'pageId',
            'pageSize',
            'maxPageId',
            'totalCount',
            'list',
          ])
            key: _diagnosticField(
              data[key],
              present: data.containsKey(key),
              includeNumber: true,
            ),
        },
      );
    }
  }

  Future<AlbumReviewPage> loadAlbumReviews(
    String albumId, {
    int page = 1,
    bool newest = false,
  }) async {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::XmlyComments.loadAlbumReviews',
    );
    if (page < 1 || page > 10000) throw _invalid;
    final response = await client.request(
      'GET',
      XmlyClient.mobile,
      '/album-comment-mobile/album/comment/list/query/${DateTime.now().millisecondsSinceEpoch}',
      query: {
        'albumId': xmlyIdentifier(albumId),
        'pageId': page,
        'pageSize': 20,
        'order': newest ? 'time-desc' : 'content-score-desc',
      },
      account: false,
      signed: false,
    );
    if (response['data'] is! Map) throw _invalid;
    return AlbumReviewPage.fromApi(xmlyMap(response['data']), page: page);
  }

  Future<AlbumReviewRepliesPage> loadAlbumReviewReplies(
    String albumId,
    String commentId, {
    int page = 1,
  }) async {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::XmlyComments.loadAlbumReviewReplies',
    );
    if (page < 1 || page > 10000) throw _invalid;
    final rootId = xmlyIdentifier(commentId);
    final response = await client.request(
      'GET',
      XmlyClient.mobile,
      '/album-comment-mobile/ipad/album/comment/reply/list/query/${DateTime.now().millisecondsSinceEpoch}',
      query: {
        'albumId': xmlyIdentifier(albumId),
        'commentId': rootId,
        'pageId': page,
        'pageSize': 20,
      },
      account: false,
      signed: false,
    );
    if (response['data'] is! Map) throw _invalid;
    return AlbumReviewRepliesPage.fromApi(
      xmlyMap(response['data']),
      commentId: rootId,
      page: page,
    );
  }

  static int _count(Object? value) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments._count');
    if (value is! int || value < 0) throw _invalid;
    return value;
  }

  static String _text(Object? value) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments._text');
    return value is String ? value : '';
  }

  static Uri? _avatar(Object? value) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments._avatar');
    if (value is! String || value.length > 16384) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !(uri.host == 'xmcdn.com' || uri.host.endsWith('.xmcdn.com')) ||
        uri.hasPort)
      return null;
    return uri.replace(scheme: 'https');
  }

  static String _createdAt(Object? value) {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::XmlyComments._createdAt',
    );
    if (value is! int) return _text(value);
    if (value < 0 || value > 8640000000000000) throw _invalid;
    final date = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
    String two(int part) {
      AppLog.instance.trace(
        'lib/api/xmly_comments.dart::XmlyComments._createdAt.two',
      );
      return '$part'.padLeft(2, '0');
    }

    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  static Map<String, Object?> _diagnosticField(
    Object? value, {
    required bool present,
    bool includeNumber = false,
  }) {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::XmlyComments._diagnosticField',
    );
    final length = value is String
        ? value.length
        : value is List
        ? value.length
        : null;
    return {
      'present': present,
      'type': switch (value) {
        null => 'null',
        bool() => 'bool',
        int() => 'int',
        double() => 'double',
        String() => 'string',
        List() => 'list',
        Map() => 'map',
        _ => 'other',
      },
      if (length != null) 'length': length > 1000000 ? 1000000 : length,
      if (length != null && length > 1000000) 'lengthCapped': true,
      if (includeNumber && value is num)
        if (value.isFinite && value >= -1000000 && value <= 1000000)
          'value': value
        else
          'numberOutOfRange': true,
    };
  }

  Future<TrackCommentPage> load(
    String trackId, {
    int page = 1,
    String? commentId,
  }) async {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments.load');
    if (page < 1 || page > 250) {
      throw const XmlyException('comment_limit', '最多读取 5000 条评论，请刷新后查看');
    }
    final replies = commentId != null;
    final number = xmlyIdentifier(trackId);
    final response = await client.request(
      'GET',
      replies ? XmlyClient.searchOrigin : XmlyClient.mobile,
      replies
          ? '/revision/comment/queryReplies'
          : '/comment-mobile/v1/track/comment/${DateTime.now().millisecondsSinceEpoch}',
      query: replies
          ? {
              'trackId': number,
              'commentId': xmlyIdentifier(commentId),
              'page': page,
              'pageSize': 20,
            }
          : {
              'trackId': number,
              'pageId': page,
              'pageSize': 20,
              'hotPageId': 1,
              'hotPageSize': 0,
              'order': 0,
              'showVersion': 1,
              'source': 2,
            },
      // Only the official mobile endpoint may receive this client's credentials.
      account: !replies && client.accountAvailable,
    );
    final containerKey = replies ? 'data' : 'comment';
    final listKey = replies ? 'replies' : 'list';
    final container = response[containerKey];
    var reason = container is Map ? 'page_invalid' : 'container_type';
    var rowIndex = -1;
    Object? rowValue;
    bool? duplicateId, trackIdMatches;
    try {
      final data = xmlyMap(container);
      final currentPage = _count(data[replies ? 'currentPage' : 'pageId']);
      if (currentPage != page) {
        reason = 'page_mismatch';
        throw _invalid;
      }
      reason = 'total_invalid';
      final total = _count(data[replies ? 'totalComment' : 'totalCount']);
      reason = 'pages_invalid';
      final pages = _count(data[replies ? 'totalPage' : 'maxPageId']);
      final raw = data[listKey];
      if (raw is! List) {
        reason = 'list_type';
        throw _invalid;
      }
      if (raw.length > 20) {
        reason = 'list_too_long';
        throw _invalid;
      }
      final comments = <TrackComment>[];
      final ids = <String>{};
      for (final value in raw) {
        rowIndex++;
        rowValue = value;
        duplicateId = null;
        trackIdMatches = null;
        reason = value is Map ? 'row_id_invalid' : 'row_type';
        final row = xmlyMap(value);
        final id = xmlyIdentifier('${row['id'] ?? ''}');
        duplicateId = !ids.add(id);
        if (duplicateId) {
          reason = 'row_id_duplicate';
          throw _invalid;
        }
        if (row['content'] is! String) {
          reason = 'row_content_type';
          throw _invalid;
        }
        if (row['trackId'] != null) {
          reason = 'row_track_id_invalid';
          trackIdMatches = xmlyIdentifier('${row['trackId']}') == number;
          if (!trackIdMatches) {
            reason = 'row_track_id_mismatch';
            throw _invalid;
          }
        }
        reason = 'row_uid_invalid';
        final uid = row['uid'] == null ? '' : xmlyIdentifier('${row['uid']}');
        final author = _text(row['nickname']);
        reason = 'row_created_at_invalid';
        final createdAt = _createdAt(row[replies ? 'createAt' : 'createdAt']);
        reason = 'row_likes_invalid';
        final likes = _count(row['likes'] ?? 0);
        reason = 'row_reply_count_invalid';
        final replyCount = _count(row['replyCount'] ?? 0);
        comments.add(
          TrackComment(
            id: id,
            uid: uid,
            author: author,
            content: row['content'] as String,
            createdAt: createdAt,
            likes: likes,
            replyCount: replyCount,
            parentAuthor: _text(row['parentNickname']),
            avatarUrl: _avatar(row['smallHeader']),
            liked: row['liked'] == true || row['likeStatus'] == 1,
          ),
        );
      }
      return TrackCommentPage(
        comments: comments,
        total: total,
        hasMore: page < pages,
      );
    } on XmlyException catch (error, stack) {
      // Only fixed schema fields are described; never copy response values/keys.
      final data = container is Map ? container : const <Object?, Object?>{};
      final row = rowValue is Map ? rowValue : const <Object?, Object?>{};
      final comments = <String, Object?>{
        'source': replies ? 'replies' : 'main',
        'method': 'GET',
        'endpoint': replies
            ? '/revision/comment/queryReplies'
            : '/comment-mobile/v1/track/comment/{timestamp}',
        'httpStatus': 200,
        'ret': _diagnosticField(
          response['ret'],
          present: response.containsKey('ret'),
          includeNumber: true,
        ),
        'requestedPage': page,
        'pageSize': 20,
        'reason': reason,
        'containerKey': containerKey,
        'container': _diagnosticField(
          container,
          present: response.containsKey(containerKey),
        ),
        'pagination': {
          for (final key
              in replies
                  ? const ['currentPage', 'totalPage', 'totalComment']
                  : const [
                      'pageId',
                      'maxPageId',
                      'totalCount',
                      'pageSize',
                      'topCount',
                    ])
            key: _diagnosticField(
              data[key],
              present: data.containsKey(key),
              includeNumber: true,
            ),
        },
        'listKey': listKey,
        'list': _diagnosticField(
          data[listKey],
          present: data.containsKey(listKey),
        ),
        if (rowIndex >= 0) ...{
          'rowIndex': rowIndex,
          'row': {
            ..._diagnosticField(rowValue, present: true),
            for (final key in [
              'id',
              'content',
              'trackId',
              'uid',
              replies ? 'createAt' : 'createdAt',
              'likes',
              'replyCount',
            ])
              key: _diagnosticField(row[key], present: row.containsKey(key)),
            if (duplicateId != null) 'duplicateId': duplicateId,
            if (trackIdMatches != null) 'trackIdMatches': trackIdMatches,
          },
        },
      };
      Error.throwWithStackTrace(
        XmlyException(
          error.code,
          error.message,
          retryAfter: error.retryAfter,
          definitive: error.definitive,
          fingerprint: error.fingerprint,
          diagnostics: {...?error.diagnostics, 'comments': comments},
        ),
        stack,
      );
    }
  }

  Future<void> create(String trackId, String content) async {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments.create');
    final context = client.context();
    if (content.trim().isEmpty) {
      throw const XmlyException('empty_comment', '请输入评论内容', definitive: true);
    }
    // The captured create token is the normal login token after its UID prefix.
    await client.request(
      'POST',
      XmlyClient.mobile,
      '/comment-mobile/v1/create',
      data: {
        'uid': context['uid'],
        'token': context['token'],
        'setTop': 'false',
        'topExpireTime': '0',
        'trackId': xmlyIdentifier(trackId),
        'startTime': '0',
        'synchaos': '0',
        'endTime': '0',
        'content': content.trim(),
      },
      form: true,
    );
  }

  String _requireUid() {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::XmlyComments._requireUid',
    );
    return client.context()['uid']!;
  }

  Future<void> setLiked(
    String trackId,
    TrackComment comment, {
    required bool liked,
  }) async {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments.setLiked');
    final uid = _requireUid();
    await client.request(
      'POST',
      XmlyClient.mobile,
      '/comment-mobile/like',
      data: {
        'uid': uid,
        'islike': '$liked',
        'trackId': xmlyIdentifier(trackId),
        'commentId': xmlyIdentifier(comment.id),
        'device': 'android',
      },
      form: true,
    );
  }

  Future<void> delete(String trackId, TrackComment comment) async {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments.delete');
    if (comment.uid.isEmpty || comment.uid != _requireUid()) {
      throw const XmlyException(
        'permission_denied',
        '只能删除当前账号自己的评论',
        definitive: true,
      );
    }
    await client.request(
      'POST',
      XmlyClient.mobile,
      '/mobile/comment/delete/${DateTime.now().millisecondsSinceEpoch}',
      data: {
        'trackId': xmlyIdentifier(trackId),
        'commentId': xmlyIdentifier(comment.id),
        'device': 'android',
      },
      form: true,
    );
  }
}
