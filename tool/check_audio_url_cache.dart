// Run from the repository root: dart run tool/check_audio_url_cache.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart' as aes;

import '../lib/api/xmly_client.dart';
import '../lib/api/xmly_crypto.dart';
import '../lib/models/xmly_models.dart';

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void _counts(_Endpoints wire, int info, int quota, String scenario) {
  _expect(
    wire.info == info && wire.quota == quota,
    '$scenario: expected info/quota $info/$quota, got ${wire.info}/${wire.quota}',
  );
}

void _audio(
  ResolvedAudio value,
  Uri uri, {
  bool paid = false,
  String quality = 'mp3_64',
}) {
  _expect(value.uri == uri, 'Resolved URI does not match the expected lease');
  _expect(value.actualQuality == quality, 'Resolved quality changed');
  _expect(value.requiresReward == paid, 'Reward accounting flag changed');
  _expect(value.track.number == (paid ? '202' : '101'), 'Wrong track returned');
  _expect(
    value.track.title == (paid ? 'Paid sample' : 'Free sample'),
    'Authorized track metadata was not restored',
  );
  _expect(
    value.track.isPaid == paid && value.track.isAuthorized == true,
    'Track authorization flags changed',
  );
}

Future<void> _quotaDenied(Future<ResolvedAudio> result) async {
  try {
    await result;
  } on XmlyException catch (error) {
    _expect(error.code == 'insufficient_quota', 'Unexpected quota error code');
    return;
  }
  throw StateError('A cached paid track bypassed insufficient quota');
}

// Only these three real client endpoints exist here. Unexpected requests fail
// closed; no default adapter, socket, real account, or media download is used.
class _Endpoints implements HttpClientAdapter {
  int info = 0, quota = 0, balance = 120;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _expect(
      options.uri.origin == XmlyClient.mobile,
      'Unexpected request origin',
    );
    final path = options.uri.path;
    late final Map<String, dynamic> response;
    if (options.method == 'POST' &&
        path == '/lite-mobile/audi/func/v1/config') {
      quota++;
      final cipher = aes.Encrypter(
        aes.AES(
          aes.Key(Uint8List.fromList(XmlyCrypto.durationKey)),
          mode: aes.AESMode.ecb,
          padding: 'PKCS7',
        ),
      );
      final stamp = DateTime.now().millisecondsSinceEpoch;
      String field(String value) => cipher.encrypt('$value|$stamp').base64;
      response = {
        'ret': 0,
        'data': {
          'newDevice': field('false'),
          'availableListenDuration': field('$balance'),
        },
      };
    } else {
      late final String id;
      var rewarded = false;
      final signed =
          options.method == 'POST' &&
          path == '/fmobile-track/fmobile/track/v2/baseInfo';
      if (signed) {
        _expect(
          options.headers['Cookie'] is String &&
              options.headers['x-tk'] is String,
          'Signed authorization headers missing',
        );
        final body = options.data as Map;
        final params = jsonDecode(
          XmlyCrypto.decrypt(body['data'] as String, XmlyCrypto.playKey),
        ) as Map;
        id = params['trackId'] as String;
        rewarded = params.containsKey('a1');
        if (rewarded) {
          _expect(
            params['a1'] == '$balance' && params['a3'] == '0',
            'Reward authorization did not use current quota',
          );
        }
      } else {
        _expect(
          options.method == 'GET' && path == '/mobile/track/101',
          'Unexpected endpoint or method',
        );
        _expect(
          !options.headers.containsKey('Cookie'),
          'Anonymous request unexpectedly contains credentials',
        );
        id = '101';
      }
      _expect(id == '101' || id == '202', 'Unexpected test track');
      info++;
      final paid = id == '202';
      final track = <String, dynamic>{
        'trackId': id,
        'title': paid ? 'Paid sample' : 'Free sample',
        'duration': 90,
        'isPaid': paid,
        'isAuthorized': !paid || rewarded,
        if (!paid || rewarded) ...{
          'playUrl64': 'https://audio.xmcdn.com/$id/64-$info.mp3',
          'playUrl32': 'https://audio.xmcdn.com/$id/32-$info.mp3',
        },
      };
      response = signed
          ? {
              'ret': 0,
              'data': XmlyCrypto.encrypt({
                'trackInfo': track,
              }, XmlyCrypto.playKey),
            }
          : {'ret': 0, ...track};
    }
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> main() async {
  final tempRoot = await Directory('Temp').create(recursive: true);
  final directory = await tempRoot.createTemp('check_audio_url_cache_');
  final clients = <XmlyClient>[];
  try {
    // Random synthetic material isolates the namespace; no credentials are read
    // from storage, the environment, or the real application.
    final random = Random.secure();
    String nonce() =>
        List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join();
    final credentials = Credentials(
      token: '900000001&${nonce()}',
      deviceId: nonce(),
    );
    ({XmlyClient client, _Endpoints wire}) open({
      bool anonymous = false,
      String? cacheDirectory,
    }) {
      final wire = _Endpoints();
      final dio = Dio()..httpClientAdapter = wire;
      final client = XmlyClient(
        credentials: anonymous ? null : credentials,
        dio: dio,
        urlCacheDirectory: cacheDirectory ?? directory.path,
      );
      clients.add(client);
      return (client: client, wire: wire);
    }

    var session = open();
    final first = await session.client.resolve('101', preferCached: true);
    _audio(first, Uri.parse('https://audio.xmcdn.com/101/64-1.mp3'));
    _counts(session.wire, 1, 0, 'First online authorization');
    final unverified = await session.client.resolve('101', preferCached: true);
    _audio(unverified, first.uri);
    _counts(session.wire, 2, 0, 'Unverified URL must reauthorize');
    print('PASS first resolve and unverified URL cannot fast-hit');

    final final64 = Uri.parse('https://audio.xmcdn.com/verified/free-64.mp3');
    unverified.rememberFinalUri(final64);
    _audio(await session.client.resolve('101', preferCached: true), final64);
    _counts(session.wire, 2, 0, 'Verified free cache hit');
    await session.client.flushUrlCache();
    session.client.close();
    session = open();
    _audio(await session.client.resolve('101', preferCached: true), final64);
    _counts(session.wire, 0, 0, 'Free cache hit after restart');
    print(
      'PASS rememberFinalUri and persisted metadata skip info after restart',
    );

    final paid = await session.client.resolve('202', preferCached: true);
    _audio(paid, Uri.parse('https://audio.xmcdn.com/202/64-2.mp3'), paid: true);
    _counts(session.wire, 2, 1, 'Paid authorization with quota');
    final finalPaid = Uri.parse('https://audio.xmcdn.com/verified/paid-64.mp3');
    paid.rememberFinalUri(finalPaid);
    _audio(
      await session.client.resolve('202', preferCached: true),
      finalPaid,
      paid: true,
    );
    _counts(session.wire, 2, 2, 'Paid cache still queries quota');
    await session.client.flushUrlCache();
    session.client.close();
    session = open();
    _audio(
      await session.client.resolve('202', preferCached: true),
      finalPaid,
      paid: true,
    );
    _counts(session.wire, 0, 1, 'Paid cache after restart');
    session.wire.balance = 0;
    await _quotaDenied(session.client.resolve('202', preferCached: true));
    _counts(session.wire, 0, 2, 'Paid cached lease rejects empty quota');
    session.wire.balance = 120;
    print(
      'PASS paid requiresReward survives restart and empty quota is rejected',
    );

    final low = await session.client.resolve(
      '101',
      preferCached: true,
      quality: 'mp3_32',
    );
    _audio(
      low,
      Uri.parse('https://audio.xmcdn.com/101/32-1.mp3'),
      quality: 'mp3_32',
    );
    _counts(session.wire, 1, 2, 'Different quality requires online info');
    final final32 = Uri.parse('https://audio.xmcdn.com/verified/free-32.mp3');
    low.rememberFinalUri(final32);
    _audio(
      await session.client.resolve(
        '101',
        preferCached: true,
        quality: 'mp3_64',
      ),
      final64,
    );
    _audio(
      await session.client.resolve(
        '101',
        preferCached: true,
        quality: 'mp3_32',
      ),
      final32,
      quality: 'mp3_32',
    );
    _counts(session.wire, 1, 2, 'Explicit quality caches stay isolated');
    print('PASS explicit quality does not reuse another quality lease');

    final forced = await session.client.resolve(
      '101',
      preferCached: true,
      force: true,
    );
    _audio(forced, Uri.parse('https://audio.xmcdn.com/101/64-2.mp3'));
    _counts(session.wire, 2, 2, 'Force refresh');
    forced.rememberFinalUri(final64);
    final invalid = await session.client.resolve('101', preferCached: true);
    _counts(
      session.wire,
      2,
      2,
      'Force result becomes cacheable after validation',
    );
    invalid.invalidateCachedUri();
    final refreshed = await session.client.resolve('101', preferCached: true);
    _audio(refreshed, Uri.parse('https://audio.xmcdn.com/101/64-3.mp3'));
    _counts(session.wire, 3, 2, 'Invalidated lease refresh');
    refreshed.rememberFinalUri(
      Uri.parse('https://audio.xmcdn.com/expired.mp3?expires=1000000001'),
    );
    _audio(
      await session.client.resolve('101', preferCached: true),
      Uri.parse('https://audio.xmcdn.com/101/64-4.mp3'),
    );
    _counts(session.wire, 4, 2, 'Expired lease refresh');
    print('PASS force, invalidation, and expiry fall back to online info');

    var anonymous = open(anonymous: true);
    final free = await anonymous.client.resolve('101', preferCached: true);
    _audio(free, Uri.parse('https://audio.xmcdn.com/101/64-1.mp3'));
    free.rememberFinalUri(final64);
    _audio(await anonymous.client.resolve('101', preferCached: true), final64);
    _counts(anonymous.wire, 1, 0, 'Anonymous free cache hit');
    await anonymous.client.flushUrlCache();
    anonymous.client.close();
    anonymous = open(anonymous: true);
    _audio(await anonymous.client.resolve('101', preferCached: true), final64);
    _counts(anonymous.wire, 0, 0, 'Anonymous cache after restart');
    print('PASS anonymous free cache hits in memory and after restart');

    final legacy = await Directory('${directory.path}/legacy').create();
    for (var slot = 0; slot < 2; slot++) {
      await File('${legacy.path}/urls.${credentials.cacheIdentity}.$slot.json')
          .writeAsString(
            jsonEncode({
              'version': 1,
              'namespace': credentials.cacheIdentity,
              'revision': slot + 1,
              'entries': [
                {
                  'track': '202',
                  'quality': 'mp3_64',
                  'uri': 'https://audio.xmcdn.com/legacy-$slot.mp3',
                  'deadline': null,
                },
              ],
            }),
          );
    }
    final old = open(cacheDirectory: legacy.path);
    old.wire.balance = 0;
    await _quotaDenied(old.client.resolve('202', preferCached: true));
    _counts(old.wire, 1, 1, 'Legacy metadata cannot bypass authorization');
    old.wire.balance = 120;
    _audio(
      await old.client.resolve('202', preferCached: true),
      Uri.parse('https://audio.xmcdn.com/legacy-1.mp3'),
      paid: true,
    );
    _counts(
      old.wire,
      3,
      2,
      'Legacy newest slot only reused after online authorization',
    );
    print('PASS legacy V1 dual slots without metadata safely reauthorize');
    print(
      'All audio URL cache checks passed (offline, synthetic credentials).',
    );
  } finally {
    for (final client in clients) {
      client.close();
      await client.flushUrlCache();
    }
    await directory.delete(recursive: true);
  }
}
