import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xmly_flutter/api/xmly_client.dart';
import 'package:xmly_flutter/api/xmly_experience.dart';
import 'package:xmly_flutter/models/xmly_models.dart';

class _PlaypageTransport implements HttpClientAdapter {
  Map<String, dynamic> payload = {
    'ret': 0,
    'trackInfo': {'trackId': 100, 'likes': 14, 'likeCount': 3454},
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method != 'GET' ||
        options.uri.origin != XmlyClient.mobile ||
        !RegExp(r'^/fmobile-track/fmobile/track/playpage/100/ts-[0-9]+$')
            .hasMatch(options.uri.path)) {
      throw StateError('Unexpected offline request: ${options.uri}');
    }
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _PlaypageTransport transport;
  late XmlyClient client;
  late XmlyExperience experience;

  setUp(() {
    transport = _PlaypageTransport();
    client = XmlyClient(
      credentials: Credentials(
        token: '1&offline-token',
        deviceId: 'offline-device',
      ),
      dio: Dio()..httpClientAdapter = transport,
    );
    experience = XmlyExperience(client);
  });
  tearDown(() => client.close());

  test('playpage separates global favorites from likes and baseInfo', () async {
    transport.payload['baseInfo'] = {'likeCount': 0, 'likes': 999};
    transport.payload['totalCount'] = 888;
    (transport.payload['trackInfo'] as Map)['totalCount'] = 777;
    expect(await experience.trackCounts('xmly:100'), (
      likes: 14,
      favorites: 3454,
    ));

    transport.payload['trackInfo'] = {'trackId': 100, 'likes': 14};
    expect(await experience.trackCounts('100'), (likes: 14, favorites: null));
  });

  test('unknown and noninteger counts never become zero', () async {
    for (final value in <Object?>[null, -1, 0.5, 0.0, '0', true]) {
      transport.payload['trackInfo'] = {
        'trackId': 100,
        'likes': value,
        'likeCount': value,
        'totalCount': 777,
      };
      expect(await experience.trackCounts('100'), (
        likes: null,
        favorites: null,
      ), reason: 'Invalid count: $value');
    }
    transport.payload['trackInfo'] = {'trackId': 100};
    expect(await experience.trackCounts('100'), (likes: null, favorites: null));
    transport.payload['trackInfo'] = {
      'trackId': 100,
      'likes': 0,
      'likeCount': 0,
    };
    expect(await experience.trackCounts('100'), (likes: 0, favorites: 0));
  });

  test(
    'counts reject another track and require explicit API success',
    () async {
      transport.payload['trackInfo'] = {
        'trackId': 101,
        'likes': 14,
        'likeCount': 3454,
      };
      await expectLater(
        experience.trackCounts('100'),
        throwsA(
          isA<XmlyException>().having((e) => e.code, 'code', 'id_mismatch'),
        ),
      );
      transport.payload = {
        'trackInfo': {'trackId': 100, 'likes': 14, 'likeCount': 3454},
      };
      await expectLater(
        experience.trackCounts('100'),
        throwsA(isA<XmlyException>()),
      );
    },
  );
}
