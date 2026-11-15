import '../models/xmly_models.dart';
import '../services/app_log.dart';
import 'xmly_client.dart';

class AnchorProfile {
  const AnchorProfile({
    required this.uid,
    required this.nickname,
    this.avatar,
    this.background,
    this.intro = '',
    this.verification = '',
    this.verified = false,
    this.level,
    this.location = '',
    this.fans,
    this.following,
    this.albums,
    this.tracks,
  });

  final String uid, nickname, intro, location, verification;
  final bool verified;
  final int? level;
  final Uri? avatar, background;
  final int? fans, following, albums, tracks;
}

class AnchorAlbum {
  const AnchorAlbum({required this.album, this.playCount, this.createdAt});
  final Album album;
  final int? playCount;
  final DateTime? createdAt;
}

class AnchorContentPage<T> {
  AnchorContentPage({
    required List<T> items,
    required this.page,
    required this.hasMore,
    this.pageSize = 20,
    this.total,
    this.reportedTotal,
  }) : items = List.unmodifiable(items) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::AnchorContentPage.new");
  }

  final List<T> items;
  final int page, pageSize;
  final bool hasMore;
  final int? total;
  final int? reportedTotal;
}

/// Public creator content uses no cookies; following belongs to its account.
class XmlyAnchor {
  XmlyAnchor(this.client) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.new");
  }

  final XmlyClient client;
  final Map<String, DateTime> _albumDates = {};
  static const pageSize = 20;
  static const _invalid = XmlyException('invalid_anchor', '主播资料暂时无法读取，请重试');

  static String _text(Object? value) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._text");

    return value is String ? value.trim() : '';
  }

  static int? _count(Object? value) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._count");

    if (value is String && RegExp(r'^[0-9]+$').hasMatch(value)) {
      value = int.tryParse(value);
    }
    if (value is num &&
        value.isFinite &&
        value >= 0 &&
        value == value.truncateToDouble())
      return value.toInt();
    return null;
  }

  static Uri? _image(Object? value) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._image");

    final text = _text(value);
    if (text.isEmpty ||
        text.length > 16384 ||
        RegExp(r'[\x00-\x20]').hasMatch(text)) {
      return null;
    }
    final normalized = text.startsWith('//')
        ? 'https:$text'
        : text.startsWith('storages/') ||
              RegExp(r'^group[0-9]+/').hasMatch(text)
        ? 'https://imagev2.xmcdn.com/$text'
        : text;
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.scheme == 'http' &&
            (uri.host == 'xmcdn.com' || uri.host.endsWith('.xmcdn.com'))
        ? uri.replace(scheme: 'https')
        : uri;
  }

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, dynamic> query, {
    bool pc = false,
  }) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._get");

    final response = await client.request(
      'GET',
      pc ? XmlyClient.pcOrigin : XmlyClient.searchOrigin,
      path,
      query: query,
      account: false,
      signed: false,
    );
    if (response['data'] is! Map<String, dynamic>) throw _invalid;
    return response['data'] as Map<String, dynamic>;
  }

  Future<String> albumAnchor(String albumId) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.albumAnchor");

    final id = xmlyIdentifier(albumId);
    final data = await _get('/revision/album/v1/simple', {'albumId': id});
    if ('${data['albumId']}' != id) throw _invalid;
    final main = xmlyMap(data['albumPageMainInfo']);
    final uid = xmlyPositive(main['anchorUid']);
    if (uid == null) throw _invalid;
    return xmlyIdentifier('$uid');
  }

  Future<String> trackAnchor(String trackId) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.trackAnchor");

    final id = xmlyIdentifier(trackId);
    final data = await _get('/revision/track/simple', {'trackId': id});
    final track = xmlyMap(data['trackInfo']);
    if ('${track['trackId']}' != id) throw _invalid;
    final uid = xmlyPositive(track['anchorUid']);
    if (uid == null) throw _invalid;
    return xmlyIdentifier('$uid');
  }

  Future<AnchorProfile> profile(String uid) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.profile");

    final id = xmlyIdentifier(uid);
    final data = await _get('/revision/user/basic', {'uid': id});
    if ('${data['uid']}' != id) throw _invalid;
    final nickname = _text(data['nickName']);
    if (nickname.isEmpty) throw _invalid;
    final location = <String>{_text(data['province']), _text(data['city'])}
      ..remove('');
    return AnchorProfile(
      uid: id,
      nickname: nickname,
      avatar: _image(data['cover']),
      background: _image(data['background']),
      intro: _text(
        data['description'] ?? data['personalSignature'] ?? data['intro'],
      ),
      verification: _text(data['personalDescription']),
      verified: (_count(data['logoType']) ?? 0) > 0,
      level: xmlyPositive(data['mvpGrade']),
      location: location.join(' · '),
      fans: _count(data['fansCount']),
      following: _count(data['followingCount']),
      albums: _count(data['albumsCount']),
      tracks: _count(data['tracksCount']),
    );
  }

  Future<bool> isFollowing(String uid) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.isFollowing");
    if (client.credentials == null) {
      throw const XmlyException('login_required', '请先登录后关注主播');
    }
    final id = xmlyIdentifier(uid);
    final response = await client.request(
      'GET',
      XmlyClient.searchOrigin,
      '/revision/user/basic',
      query: {'uid': id},
    );
    final data = xmlyMap(response['data']);
    final followed = xmlyMap(data['relation'])['isFollow'];
    if ('${data['uid']}' != id || followed is! bool) throw _invalid;
    return followed;
  }

  Future<void> setFollowing(String uid, {required bool following}) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.setFollowing");
    if (client.credentials == null) {
      throw const XmlyException('login_required', '请先登录后关注主播');
    }
    final id = xmlyIdentifier(uid);
    if (id == client.credentials!.uid) {
      throw const XmlyException('invalid_anchor', '不能关注自己');
    }
    await client.request(
      'POST',
      XmlyClient.searchOrigin,
      following
          ? '/revision/follow/setFollow'
          : '/revision/follow/cancelFollow',
      data: {'followingUid': id},
    );
  }

  Future<AnchorContentPage<AnchorAlbum>> albums(
    String uid, {
    int page = 1,
    int pageSize = 10,
  }) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.albums");

    final pc = pageSize == 10;
    return _content<AnchorAlbum>(
      uid,
      page,
      pc ? '/simple-revision-for-pc/user/pub' : '/revision/user/pub',
      'albumList',
      (row) {
        AppLog.instance.trace(
          "lib/api/xmly_anchor.dart::XmlyAnchor.albums.closure#1",
        );

        return AnchorAlbum(
          album: Album.fromApi({
            ...row,
            'albumId': xmlyIdentifier('${row['id'] ?? row['albumId'] ?? ''}'),
            'uid': row['anchorUid'] ?? row['uid'],
            'nickname': row['anchorNickName'],
            'cover_url': _image(row['coverPath'])?.toString(),
            'intro': row['description'],
            'tracks': _count(row['trackCount']) ?? 0,
          }),
          playCount: _count(row['playCount']),
        );
      },
      requestedSize: pageSize,
      filters: const {'orderType': 2},
      pc: pc,
    );
  }

  Future<AnchorContentPage<Track>> tracks(
    String uid, {
    int page = 1,
    int pageSize = XmlyAnchor.pageSize,
  }) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.tracks");

    if (page < 1 || page > 10000 || pageSize < 1 || pageSize > 100) {
      throw const XmlyException('invalid_page', '无法继续翻页，请刷新后重试');
    }
    final id = xmlyIdentifier(uid);
    final response = await client.request(
      'GET',
      XmlyClient.welfare,
      '/m-revision/common/anchor/queryAnchorTracksByPage',
      query: {'anchorId': id, 'page': page, 'pageSize': pageSize, 'asc': false},
      account: false,
    );
    final data = xmlyMap(response['data']);
    final returnedSize = _count(data['pageSize']);
    if (_count(data['page']) != page ||
        returnedSize == null ||
        returnedSize > pageSize) {
      throw const XmlyException('repeated_page', '列表分页未前进，请刷新后重试');
    }
    final rows = data['trackDetailInfos'];
    final reportedTotal = _count(data['totalCount']);
    if (rows is! List ||
        rows.length > pageSize ||
        (returnedSize != pageSize && returnedSize != rows.length) ||
        reportedTotal == null) {
      throw _invalid;
    }
    final total = reportedTotal > 5000 ? 5000 : reportedTotal;
    final items = <Track>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic>) throw _invalid;
      final info = xmlyMap(row['trackInfo']);
      final stats = xmlyMap(row['statCountInfo']);
      final number = xmlyPositive(info['id']);
      final createdTime = xmlyPositive(info['createdTime']);
      if (number == null ||
          '${row['id']}' != '$number' ||
          '${info['anchorId']}' != id ||
          createdTime == null ||
          createdTime > 8640000000000000 ||
          _text(info['title']).isEmpty) {
        throw _invalid;
      }
      items.add(
        Track.fromApi({
          ...info,
          'trackId': number,
          'uid': id,
          'cover_url': _mobileImage(info['cover'])?.toString(),
          // These public raw fields already survive Track serialization.
          'date': createdTime,
          'play': _count(stats['playCount']) ?? 0,
        }),
      );
    }
    return AnchorContentPage(
      items: items,
      page: page,
      pageSize: pageSize,
      total: total,
      reportedTotal: reportedTotal,
      hasMore: page * pageSize < total,
    );
  }

  static Uri? _mobileImage(Object? value) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._mobileImage");

    final text = _text(value);
    if (text.isEmpty) return null;
    if (text.startsWith('https://') ||
        text.startsWith('http://') ||
        text.startsWith('//')) {
      return _image(text);
    }
    if (!RegExp(r'^(?:group[0-9]+|storages)/').hasMatch(text) ||
        text.contains('\\') ||
        text.split('/').contains('..') ||
        RegExp(r'[\x00-\x20?#]').hasMatch(text)) {
      return null;
    }
    return _image('https://imagev2.xmcdn.com/$text');
  }

  Future<AnchorContentPage<AnchorAlbum>> allAlbums(
    String uid, {
    void Function(int, int?)? onProgress,
    bool withDates = false,
  }) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.allAlbums");

    final source = await _all(
      (page) {
        AppLog.instance.trace(
          "lib/api/xmly_anchor.dart::XmlyAnchor.allAlbums.closure#1",
        );
        return albums(uid, page: page, pageSize: 100);
      },
      (item) {
        AppLog.instance.trace(
          "lib/api/xmly_anchor.dart::XmlyAnchor.allAlbums.closure#2",
        );
        return item.album.id;
      },
      onProgress,
      allowFilteredItems: true,
    );
    return withDates ? _withAlbumDates(uid, source, onProgress) : source;
  }

  Future<AnchorContentPage<AnchorAlbum>> _withAlbumDates(
    String uid,
    AnchorContentPage<AnchorAlbum> source,
    void Function(int, int?)? onProgress,
  ) async {
    AppLog.instance.trace(
      "lib/api/xmly_anchor.dart::XmlyAnchor._withAlbumDates",
    );

    final id = xmlyIdentifier(uid);
    final enriched = List<AnchorAlbum?>.filled(source.items.length, null);
    var cursor = 0;
    var completed = 0;
    var failed = false;
    onProgress?.call(0, source.items.length);
    Future<void> worker() async {
      AppLog.instance.trace(
        "lib/api/xmly_anchor.dart::XmlyAnchor._withAlbumDates.worker",
      );

      try {
        while (!failed && cursor < source.items.length) {
          final index = cursor++;
          final item = source.items[index];
          final key = '$id:${item.album.id}';
          var date = item.createdAt ?? _albumDates[key];
          if (date == null) {
            final data = await _get('/revision/album/v1/simple', {
              'albumId': item.album.id,
            });
            final main = xmlyMap(data['albumPageMainInfo']);
            if ('${data['albumId']}' != item.album.id ||
                '${main['anchorUid']}' != id) {
              throw _invalid;
            }
            final value = _text(main['createDate']);
            if (!RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(value)) {
              throw _invalid;
            }
            date = DateTime.tryParse(value);
            if (date == null ||
                date.year != int.parse(value.substring(0, 4)) ||
                date.month != int.parse(value.substring(5, 7)) ||
                date.day != int.parse(value.substring(8, 10))) {
              throw _invalid;
            }
            _albumDates[key] = date;
          }
          enriched[index] = AnchorAlbum(
            album: item.album,
            playCount: item.playCount,
            createdAt: date,
          );
          onProgress?.call(++completed, source.items.length);
        }
      } catch (_) {
        failed = true;
        rethrow;
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
    final items = <AnchorAlbum>[];
    for (final item in enriched) {
      if (item == null) throw _invalid;
      items.add(item);
    }
    return AnchorContentPage(
      items: items,
      page: source.page,
      pageSize: source.pageSize,
      hasMore: false,
      total: source.total,
      reportedTotal: source.reportedTotal,
    );
  }

  Future<AnchorContentPage<Track>> allTracks(
    String uid, {
    void Function(int, int?)? onProgress,
  }) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.allTracks");

    return _all(
      (page) {
        AppLog.instance.trace(
          "lib/api/xmly_anchor.dart::XmlyAnchor.allTracks.closure#1",
        );
        return tracks(uid, page: page, pageSize: 100);
      },
      (item) {
        AppLog.instance.trace(
          "lib/api/xmly_anchor.dart::XmlyAnchor.allTracks.closure#2",
        );
        return item.id;
      },
      onProgress,
    );
  }

  Future<AnchorContentPage<T>> _all<T>(
    Future<AnchorContentPage<T>> Function(int) fetch,
    String Function(T) id,
    void Function(int, int?)? onProgress, {
    bool allowFilteredItems = false,
  }) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._all");

    final items = <T>[];
    final seen = <String>{};
    int? expectedTotal;
    int? reportedTotal;
    for (var page = 1; page <= 10000; page++) {
      final result = await fetch(page);
      expectedTotal ??= result.total;
      reportedTotal ??= result.reportedTotal;
      if (result.total != expectedTotal ||
          result.reportedTotal != reportedTotal) {
        throw const XmlyException('catalogue_changed', '列表已更新，请重新排序');
      }
      for (final item in result.items) {
        if (!seen.add(id(item))) {
          throw const XmlyException('repeated_page', '列表分页重复，请刷新后重试');
        }
        items.add(item);
      }
      onProgress?.call(items.length, expectedTotal);
      if (!result.hasMore) {
        // Public album pages can omit unavailable entries after calculating
        // their total and offsets. Keep paging through those holes, then use
        // the visible count. Other endpoints still require their complete total.
        if (expectedTotal != null &&
            (items.length > expectedTotal ||
                !allowFilteredItems && items.length != expectedTotal)) {
          throw const XmlyException('incomplete_catalogue', '列表尚未加载完整，请重试');
        }
        return AnchorContentPage(
          items: items,
          page: page,
          pageSize: result.pageSize,
          hasMore: false,
          total: items.length,
          reportedTotal: reportedTotal,
        );
      }
      if (result.items.isEmpty &&
          (!allowFilteredItems || expectedTotal == null)) {
        throw const XmlyException('repeated_page', '列表分页未前进，请刷新后重试');
      }
    }
    throw const XmlyException('invalid_page', '无法继续翻页，请刷新后重试');
  }

  Future<AnchorContentPage<AnchorProfile>> following(
    String uid, {
    int page = 1,
  }) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.following");

    return _content<AnchorProfile>(
      uid,
      page,
      '/revision/user/following',
      'followingsPageInfo',
      (row) {
        AppLog.instance.trace(
          "lib/api/xmly_anchor.dart::XmlyAnchor.following.closure#1",
        );

        final id = xmlyPositive(row['uid']);
        final nickname = _text(row['anchorNickName']);
        if (id == null || nickname.isEmpty) throw _invalid;
        return AnchorProfile(
          uid: xmlyIdentifier('$id'),
          nickname: nickname,
          avatar: _image(row['coverPath']),
          intro: _text(row['description']),
          verification: _text(row['ptitle']),
          verified: (_count(row['logoType']) ?? 0) > 0,
          fans: _count(row['followerCount']),
          following: _count(row['followingCount']),
          albums: _count(row['albumCount']),
          tracks: _count(row['trackCount']),
        );
      },
      requestedSize: 10,
      filters: const {'keyWord': ''},
    );
  }

  Future<AnchorContentPage<T>> _content<T>(
    String uid,
    int page,
    String path,
    String key,
    T Function(Map<String, dynamic>) decode, {
    int requestedSize = pageSize,
    int? maximumTotal,
    Map<String, dynamic> filters = const {},
    bool pc = false,
  }) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._content");

    if (page < 1 || page > 10000 || requestedSize < 1 || requestedSize > 100) {
      throw const XmlyException('invalid_page', '无法继续翻页，请刷新后重试');
    }
    final identifier = xmlyIdentifier(uid);
    final data = await _get(path, {
      ...filters,
      'uid': identifier,
      'page': page,
      'pageSize': requestedSize,
    }, pc: pc);
    if (data['uid'] != null && '${data['uid']}' != identifier) throw _invalid;
    final returnedPage = _count(data['page']);
    if ((pc || data['page'] != null) && returnedPage != page) {
      throw const XmlyException('repeated_page', '列表分页未前进，请刷新后重试');
    }
    final rows = data[key];
    if (rows is! List || rows.length > 100) throw _invalid;
    var total = _count(data['filterTotalCount']) ?? _count(data['totalCount']);
    final maximum = _count(data['maxCount']);
    if (maximum != null && (total == null || maximum < total)) total = maximum;
    final size = _count(data['pageSize']);
    final filteredAlbum = !pc && path == '/revision/user/pub';
    if ((pc && (total == null || size == null)) ||
        (data['pageSize'] != null && size == null) ||
        (size != null && size > 100) ||
        (size == 0 && (rows.isNotEmpty || total != 0 && !filteredAlbum)) ||
        (size != null && rows.length > size) ||
        (total != null && rows.length > total))
      throw _invalid;
    // PC endpoints report their actual fixed page stride. The website album
    // endpoint instead shrinks pageSize on partial/filtered pages while its
    // offsets keep using the requested size.
    final effectiveSize = pc && size != null && size > 0 ? size : requestedSize;
    final items = <T>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic>) throw _invalid;
      items.add(decode(row));
    }
    final reportedTotal = total;
    if (maximumTotal != null && total != null && total > maximumTotal) {
      total = maximumTotal;
    }
    return AnchorContentPage(
      items: items,
      page: page,
      pageSize: effectiveSize,
      total: total,
      reportedTotal: reportedTotal,
      hasMore: total != null
          ? page * effectiveSize < total
          : items.length >= effectiveSize,
    );
  }
}
