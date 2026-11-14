import 'dart:convert';

import '../models/xmly_models.dart';
import 'xmly_client.dart';
import '../services/app_log.dart';
import 'xmly_experience.dart' show HomeAlbumStats;
import 'xmly_anchor.dart' show AnchorProfile;

const _invalid = XmlyException('invalid_discovery', '喜马拉雅返回的内容格式无效');

Map<String, dynamic> _object(Object? value) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_object');
  if (value is! Map<String, dynamic>) throw _invalid;
  return value;
}

List<Map<String, dynamic>> _rows(Object? value, {int maximum = 1000}) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_rows');
  if (value is! List || value.length > maximum) throw _invalid;
  return [for (final item in value) _object(item)];
}

String _text(Object? value) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_text');
  return value is String ? value : '';
}

int? _integer(Object? value) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_integer');
  if (value is String && RegExp(r'^-?[0-9]+$').hasMatch(value)) {
    return int.tryParse(value);
  }
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return null;
}

int? _count(Object? value) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_count');
  final number = _integer(value);
  return number != null && number >= 0 ? number : null;
}

int _positive(Object? value) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_positive');
  final number = _integer(value);
  if (number == null || number <= 0) throw _invalid;
  return number;
}

String _id(Object? value) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_id');
  final text = value is int || value is String ? '$value' : '';
  if (!RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(text)) throw _invalid;
  return text;
}

String? _coverPath(Object? value) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_coverPath');
  if (value is! String ||
      value.length > 16384 ||
      RegExp(r'[\x00-\x20]').hasMatch(value)) {
    return null;
  }
  if (value.startsWith('//')) return 'https:$value';
  if (value.startsWith('storages/') ||
      RegExp(r'^group[0-9]+/').hasMatch(value)) {
    return 'https://imagev2.xmcdn.com/$value';
  }
  return value;
}

Uri? _avatar(Object? value) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_avatar');
  final normalized = _coverPath(value);
  if (normalized == null) return null;
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.scheme == 'http' &&
          (uri.host == 'xmcdn.com' || uri.host.endsWith('.xmcdn.com'))
      ? uri.replace(scheme: 'https')
      : uri;
}

void _pageInput(int page) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_pageInput');
  if (page < 1 || page > 10000) {
    throw const XmlyException(
      'invalid_page',
      '页码范围为 1..10000',
      definitive: true,
    );
  }
}

void _positiveInput(int value) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_positiveInput');
  xmlyIdentifier('$value');
}

class DiscoveryPageResult<T> {
  DiscoveryPageResult({
    required List<T> items,
    required this.page,
    required this.pageSize,
    required this.total,
  }) : items = List.unmodifiable(items) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::DiscoveryPageResult.new',
    );
  }

  final List<T> items;
  final int page, pageSize, total;
  int get maxPage {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::DiscoveryPageResult.maxPage.get',
    );
    return total == 0 ? 1 : (total + pageSize - 1) ~/ pageSize;
  }

  bool get hasMore {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::DiscoveryPageResult.hasMore.get',
    );
    return page < maxPage;
  }
}

DiscoveryPageResult<T> _page<T>(
  Map<String, dynamic> data, {
  required String listKey,
  required T Function(Map<String, dynamic>) parse,
  required int expectedPage,
  String pageKey = 'page',
  String totalKey = 'totalCount',
}) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_page');
  final page = _positive(data[pageKey]);
  final size = _count(data['pageSize']);
  final total = _count(data[totalKey]);
  if (total == null ||
      size == null ||
      (size == 0 && total != 0) ||
      page != expectedPage) {
    throw _invalid;
  }
  final rows = _rows(data[listKey]);
  if (rows.length > size || rows.length > total) throw _invalid;
  return DiscoveryPageResult(
    items: rows.map(parse).toList(),
    page: page,
    // Empty PC album pages report zero; paging controls need a positive divisor.
    pageSize: size == 0 ? 1 : size,
    total: total,
  );
}

class HotWord {
  const HotWord({required this.word, required this.displayWord});
  final String word, displayWord;

  factory HotWord.fromApi(Map<String, dynamic> data) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::HotWord.factory:fromApi',
    );
    final word = _text(data['word']);
    final display = _text(data['display_word']);
    if (word.trim().isEmpty) throw _invalid;
    return HotWord(word: word, displayWord: display.isEmpty ? word : display);
  }
}

class CatalogueLocationHint {
  const CatalogueLocationHint({
    required this.albumId,
    required this.trackId,
    required this.page,
    required this.pageSize,
    required this.sort,
    required this.indexInList,
  });

  final String albumId, trackId;
  final int page, pageSize, sort, indexInList;
  int get absoluteOffset {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::CatalogueLocationHint.absoluteOffset.get',
    );
    return (page - 1) * pageSize + indexInList;
  }

  factory CatalogueLocationHint.fromApi(
    Map<String, dynamic> data, {
    required String albumId,
    required String trackId,
    required int sort,
  }) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::CatalogueLocationHint.factory:fromApi',
    );
    final album = xmlyIdentifier(albumId);
    final track = xmlyIdentifier(trackId);
    final page = _positive(data['pageNum']);
    final size = _positive(data['pageSize']);
    final actualSort = _integer(data['sort']);
    if (_id(data['albumId']) != album ||
        actualSort != sort ||
        (sort != 0 && sort != 1)) {
      throw _invalid;
    }
    final rows = _rows(data['tracksAudioPlay']);
    if (rows.length > size) throw _invalid;
    var offset = -1;
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      if (_id(row['trackId']) != track) continue;
      if (offset >= 0 || _id(row['albumId']) != album) throw _invalid;
      offset = index;
    }
    if (offset < 0) throw _invalid;
    return CatalogueLocationHint(
      albumId: album,
      trackId: track,
      page: page,
      pageSize: size,
      sort: sort,
      indexInList: offset,
    );
  }
}

class CategoryChannel {
  const CategoryChannel({
    required this.channelId,
    required this.title,
    required this.relationMetadataValueId,
    this.coverUrl,
  });

  final int channelId, relationMetadataValueId;
  final String title;
  final Uri? coverUrl;

  factory CategoryChannel.fromApi(Map<String, dynamic> data) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::CategoryChannel.factory:fromApi',
    );
    return CategoryChannel(
      channelId: _positive(data['channelId']),
      title: _text(data['channelName']),
      relationMetadataValueId: _positive(data['relationMetadataValueId']),
      coverUrl: _avatar(data['coverPath']),
    );
  }
}

class CategoryGroup {
  CategoryGroup({
    required this.id,
    required this.title,
    required List<CategoryChannel> channels,
  }) : channels = List.unmodifiable(channels) {
    AppLog.instance.trace('lib/api/xmly_discovery.dart::CategoryGroup.new');
  }

  final int id;
  final String title;
  final List<CategoryChannel> channels;

  factory CategoryGroup.fromApi(Map<String, dynamic> data) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::CategoryGroup.factory:fromApi',
    );
    return CategoryGroup(
      id: _positive(data['id']),
      title: _text(data['name']),
      channels: _rows(data['channels']).map(CategoryChannel.fromApi).toList(),
    );
  }
}

class CategoryDimension {
  CategoryDimension({
    required this.id,
    required this.title,
    required List<CategoryValue> values,
  }) : values = List.unmodifiable(values) {
    AppLog.instance.trace('lib/api/xmly_discovery.dart::CategoryDimension.new');
  }

  final int id;
  final String title;
  final List<CategoryValue> values;

  factory CategoryDimension.fromApi(Map<String, dynamic> data) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::CategoryDimension.factory:fromApi',
    );
    return _dimension(data, 0);
  }
}

class CategoryValue {
  CategoryValue({
    required this.id,
    required this.title,
    required List<CategoryDimension> dimensions,
  }) : dimensions = List.unmodifiable(dimensions) {
    AppLog.instance.trace('lib/api/xmly_discovery.dart::CategoryValue.new');
  }

  final int id;
  final String title;
  final List<CategoryDimension> dimensions;
}

String _metadataTitle(Map<String, dynamic> data) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_metadataTitle');
  final display = _text(data['displayName']);
  return display.isNotEmpty ? display : _text(data['name']);
}

CategoryDimension _dimension(Map<String, dynamic> data, int depth) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_dimension');
  final id = _integer(data['id']);
  if (depth > 32 || id == null || (id != -1 && id <= 0)) throw _invalid;
  final values = <CategoryValue>[];
  final seen = <int>{};
  for (final row in _rows(data['metadataValues'])) {
    final valueId = _positive(row['id']);
    if (!seen.add(valueId)) throw _invalid;
    final dimensions = <CategoryDimension>[];
    final dimensionIds = <int>{};
    if (row.containsKey('metadataValues')) {
      for (final child in _rows(row['metadataValues'])) {
        final dimension = _dimension(child, depth + 1);
        if (!dimensionIds.add(dimension.id)) throw _invalid;
        dimensions.add(dimension);
      }
    }
    values.add(
      CategoryValue(
        id: valueId,
        title: _metadataTitle(row),
        dimensions: dimensions,
      ),
    );
  }
  return CategoryDimension(id: id, title: _metadataTitle(data), values: values);
}

class CategoryChannelInfo {
  CategoryChannelInfo({
    required this.channel,
    required List<CategoryDimension> dimensions,
  }) : dimensions = List.unmodifiable(dimensions) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::CategoryChannelInfo.new',
    );
  }

  final CategoryChannel channel;
  final List<CategoryDimension> dimensions;

  factory CategoryChannelInfo.fromApi(Map<String, dynamic> data) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::CategoryChannelInfo.factory:fromApi',
    );
    return CategoryChannelInfo(
      channel: CategoryChannel.fromApi(_object(data['topInfo'])),
      dimensions: _rows(data['metadata'])
          .map(CategoryDimension.fromApi)
          .toList(),
    );
  }

  List<CategoryDimension> reachableDimensions(Map<int, int> selections) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::CategoryChannelInfo.reachableDimensions',
    );
    final result = <CategoryDimension>[];
    void visit(List<CategoryDimension> nodes) {
      AppLog.instance.trace(
        'lib/api/xmly_discovery.dart::CategoryChannelInfo.reachableDimensions.visit',
      );
      for (final dimension in nodes) {
        result.add(dimension);
        for (final value in dimension.values) {
          if (selections[dimension.id] == value.id) visit(value.dimensions);
        }
      }
    }

    visit(dimensions);
    return List.unmodifiable(result);
  }

  Map<int, int> pruneSelections(Map<int, int> selections) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::CategoryChannelInfo.pruneSelections',
    );
    final result = <int, int>{};
    for (final dimension in reachableDimensions(selections)) {
      final selected = selections[dimension.id];
      for (final value in dimension.values) {
        if (value.id == selected) result[dimension.id] = value.id;
      }
    }
    return result;
  }

  Map<int, int> selectValue(
    Map<int, int> selections,
    int dimensionId,
    int? valueId,
  ) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::CategoryChannelInfo.selectValue',
    );
    CategoryDimension? target;
    for (final dimension in reachableDimensions(selections)) {
      if (dimension.id == dimensionId) target = dimension;
    }
    if (target == null) throw _invalid;
    if (valueId != null) {
      var valid = false;
      for (final value in target.values) {
        if (value.id == valueId) valid = true;
      }
      if (!valid) throw _invalid;
    }
    if (selections[dimensionId] == valueId) return pruneSelections(selections);
    final result = Map<int, int>.of(selections);
    void clearDescendants(List<CategoryDimension> nodes) {
      AppLog.instance.trace(
        'lib/api/xmly_discovery.dart::CategoryChannelInfo.selectValue.clearDescendants',
      );
      for (final dimension in nodes) {
        result.remove(dimension.id);
        for (final value in dimension.values) {
          clearDescendants(value.dimensions);
        }
      }
    }

    for (final value in target.values) {
      if (value.id == selections[dimensionId])
        clearDescendants(value.dimensions);
    }
    if (valueId == null) {
      result.remove(dimensionId);
    } else {
      result[dimensionId] = valueId;
    }
    return pruneSelections(result);
  }
}

class RankTab {
  const RankTab({
    required this.id,
    required this.rankingId,
    required this.title,
  });
  final int id, rankingId;
  final String title;

  factory RankTab.fromApi(Map<String, dynamic> data) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::RankTab.factory:fromApi',
    );
    return RankTab(
      id: _positive(data['id']),
      rankingId: _positive(data['rankingId']),
      title: _text(data['name']),
    );
  }
}

List<Map<String, dynamic>> _positioned(Object? value) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_positioned');
  final indexed = _rows(value).indexed.toList();
  indexed.sort((a, b) {
    AppLog.instance.trace('lib/api/xmly_discovery.dart::_positioned.closure#1');
    final order = (_count(a.$2['position']) ?? a.$1).compareTo(
      _count(b.$2['position']) ?? b.$1,
    );
    return order == 0 ? a.$1.compareTo(b.$1) : order;
  });
  return [for (final entry in indexed) entry.$2];
}

class RankCategory {
  RankCategory({
    required this.id,
    required this.title,
    required List<RankTab> tabs,
  }) : tabs = List.unmodifiable(tabs) {
    AppLog.instance.trace('lib/api/xmly_discovery.dart::RankCategory.new');
  }

  final int id;
  final String title;
  final List<RankTab> tabs;

  factory RankCategory.fromApi(Map<String, dynamic> data) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::RankCategory.factory:fromApi',
    );
    return RankCategory(
      id: _positive(data['id']),
      title: _text(data['name']),
      tabs: _positioned(data['tabWraps']).map(RankTab.fromApi).toList(),
    );
  }
}

double? _score(Object? value) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_score');
  final score = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value)
      : null;
  return score != null && score.isFinite ? score : null;
}

class RankBlock {
  RankBlock({
    required this.rankingId,
    required this.title,
    required this.contentType,
    required List<Album> albums,
    required List<AnchorProfile> anchors,
    required Map<String, HomeAlbumStats> stats,
    required Map<String, int> positions,
  }) : albums = List.unmodifiable(albums),
       anchors = List.unmodifiable(anchors),
       stats = Map.unmodifiable(stats),
       positions = Map.unmodifiable(positions) {
    AppLog.instance.trace('lib/api/xmly_discovery.dart::RankBlock.new');
  }

  final int rankingId, contentType;
  final String title;
  final List<Album> albums;
  final List<AnchorProfile> anchors;
  final Map<String, HomeAlbumStats> stats;
  final Map<String, int> positions;

  factory RankBlock.fromApi(Map<String, dynamic> data) {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::RankBlock.factory:fromApi',
    );
    final type = _count(data['contentType']);
    if (type == null) throw _invalid;
    final positions = <String, int>{};
    final albums = <Album>[];
    final anchors = <AnchorProfile>[];
    final stats = <String, HomeAlbumStats>{};
    if (type == 2 || type == 3) {
      final ids = data['ids'];
      if (ids is! List || ids.length > 1000) throw _invalid;
      for (var index = 0; index < ids.length; index++) {
        final id = _id(ids[index]);
        if (positions.containsKey(id)) throw _invalid;
        positions[id] = index + 1;
      }
      final seen = <String>{};
      for (final row in _rows(data[type == 2 ? 'albums' : 'anchors'])) {
        final id = _id(row['id']);
        if (!positions.containsKey(id) || !seen.add(id)) throw _invalid;
        if (type == 2) {
          albums.add(
            Album.fromApi({
              'id': id,
              'title': _text(row['albumTitle']),
              'cover_url': _coverPath(row['cover']),
              'nickname': _text(row['anchorName']),
              'tracks': _count(row['trackCount']) ?? 0,
              'intro': _text(row['description']),
            }),
          );
          stats[id] = HomeAlbumStats(
            score: _score(row['albumScore']),
            playCount: _count(row['playCount']),
          );
        } else {
          anchors.add(
            AnchorProfile(
              uid: id,
              nickname: _text(row['anchorName']),
              avatar: _avatar(row['cover']),
              intro: _text(row['personalDescription']),
              fans: _count(row['fansCount']),
              albums: _count(row['albumCount']),
              tracks: _count(row['trackCount']),
            ),
          );
        }
      }
    }
    return RankBlock(
      rankingId: _positive(data['rankId']),
      title: _text(data['title']),
      contentType: type,
      albums: albums,
      anchors: anchors,
      stats: stats,
      positions: positions,
    );
  }
}

Album _categoryAlbum(Map<String, dynamic> row) {
  AppLog.instance.trace('lib/api/xmly_discovery.dart::_categoryAlbum');
  return Album.fromApi({
    'albumId': _id(row['albumId']),
    'title': _text(row['albumTitle']),
    'nickname': _text(row['albumUserNickName']),
    'tracks': _count(row['albumTrackCount']) ?? 0,
    'cover_url': _coverPath(row['albumCoverPath']),
    'intro': _text(row['intro']),
  });
}

class XmlyDiscovery {
  XmlyDiscovery(this.client) {
    AppLog.instance.trace('lib/api/xmly_discovery.dart::XmlyDiscovery.new');
  }
  final XmlyClient client;

  Future<List<CategoryGroup>> categoryGroups() async {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::XmlyDiscovery.categoryGroups',
    );
    final response = await client.request(
      'GET',
      XmlyClient.pcOrigin,
      '/simple-revision-for-pc/metadata/v2/group/all',
      query: {'includeChannels': true},
      account: false,
      signed: false,
    );
    return List.unmodifiable(
      _rows(_object(response['data'])['groups']).map(CategoryGroup.fromApi),
    );
  }

  Future<DiscoveryPageResult<CategoryChannel>> categoryChannels(
    int groupId, {
    int page = 1,
  }) async {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::XmlyDiscovery.categoryChannels',
    );
    _positiveInput(groupId);
    _pageInput(page);
    final response = await client.request(
      'GET',
      XmlyClient.pcOrigin,
      '/simple-revision-for-pc/metadata/v2/group/channels',
      query: {'groupId': groupId, 'pageId': page},
      account: false,
      signed: false,
    );
    return _page(
      _object(response['data']),
      listKey: 'channels',
      pageKey: 'pageId',
      parse: CategoryChannel.fromApi,
      expectedPage: page,
    );
  }

  Future<CategoryChannelInfo> categoryInfo(
    int channelRelationMetadataId,
  ) async {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::XmlyDiscovery.categoryInfo',
    );
    _positiveInput(channelRelationMetadataId);
    final response = await client.request(
      'GET',
      XmlyClient.pcOrigin,
      '/simple-revision-for-pc/metadata/v2/channel/info',
      query: {'channelRelationMetadataId': channelRelationMetadataId},
      account: false,
      signed: false,
    );
    final info = CategoryChannelInfo.fromApi(_object(response['data']));
    if (info.channel.relationMetadataValueId != channelRelationMetadataId)
      throw _invalid;
    return info;
  }

  Future<DiscoveryPageResult<Album>> categoryAlbums({
    required int groupId,
    int? metadataValueId,
    int page = 1,
    int sort = 1,
    Map<int, int> metadata = const {},
  }) async {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::XmlyDiscovery.categoryAlbums',
    );
    _positiveInput(groupId);
    _pageInput(page);
    if (metadataValueId != null) _positiveInput(metadataValueId);
    if (sort < 1 || sort > 3) {
      throw const XmlyException('invalid_sort', '排序方式无效', definitive: true);
    }
    for (final entry in metadata.entries) {
      if (entry.key != -1) _positiveInput(entry.key);
      _positiveInput(entry.value);
    }
    final response = await client.request(
      'GET',
      XmlyClient.pcOrigin,
      '/simple-revision-for-pc/metadata/v2/channel/albums',
      query: {
        'groupId': groupId,
        'pageNum': page,
        'pageSize': 60,
        'sort': sort,
        if (metadataValueId != null) 'metadataValueId': metadataValueId,
        if (metadata.isNotEmpty)
          'metadata': jsonEncode({
            for (final entry in metadata.entries) '${entry.key}': entry.value,
          }),
      },
      account: false,
      signed: false,
    );
    return _page(
      _object(response['data']),
      listKey: 'albums',
      pageKey: 'pageNum',
      totalKey: 'total',
      parse: _categoryAlbum,
      expectedPage: page,
    );
  }

  Future<List<RankCategory>> rankTabs() async {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::XmlyDiscovery.rankTabs',
    );
    final response = await client.request(
      'GET',
      XmlyClient.pcOrigin,
      '/simple-revision-for-pc/rank/v4/rankTabs',
      query: {'sceneId': 1},
      account: false,
      signed: false,
    );
    return List.unmodifiable(
      _positioned(_object(response['data'])['tabLists'])
          .map(RankCategory.fromApi),
    );
  }

  Future<List<RankBlock>> rankElements(int rankingId) async {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::XmlyDiscovery.rankElements',
    );
    _positiveInput(rankingId);
    final response = await client.request(
      'GET',
      XmlyClient.pcOrigin,
      '/simple-revision-for-pc/rank/v4/element',
      query: {'rankingId': rankingId},
      account: false,
      signed: false,
    );
    return List.unmodifiable(
      _rows(_object(response['data'])['rankList']).map(RankBlock.fromApi),
    );
  }

  Future<List<HotWord>> hotWords() async {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::XmlyDiscovery.hotWords',
    );
    final response = await client.request(
      'GET',
      XmlyClient.hotWordsOrigin,
      '/hotWordBillboard/list/2.0',
      query: {'categoryId': -1, 'size': 20},
      account: false,
      signed: false,
    );
    return List.unmodifiable(
      _rows(response['hotWordResultList'], maximum: 20).map(HotWord.fromApi),
    );
  }

  Future<CatalogueLocationHint> locateTrack({
    required String albumId,
    required String trackId,
    int sort = 0,
  }) async {
    AppLog.instance.trace(
      'lib/api/xmly_discovery.dart::XmlyDiscovery.locateTrack',
    );
    final album = xmlyIdentifier(albumId);
    final track = xmlyIdentifier(trackId);
    if (sort != 0 && sort != 1) {
      throw const XmlyException('invalid_sort', '排序方式无效', definitive: true);
    }
    final response = await client.request(
      'GET',
      XmlyClient.pcOrigin,
      '/simple-revision-for-pc/play/v1/show',
      query: {'id': track, 'sort': sort, 'size': 30, 'ptype': 1},
      account: false,
      signed: false,
    );
    return CatalogueLocationHint.fromApi(
      _object(response['data']),
      albumId: album,
      trackId: track,
      sort: sort,
    );
  }
}
