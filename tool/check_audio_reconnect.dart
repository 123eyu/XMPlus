// Run from the repository root: dart run tool/check_audio_reconnect.dart
// Real loopback TCP/HTTP; only this process redirects an allowlisted media host.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../lib/models/xmly_models.dart';
import '../lib/services/audio_cache.dart';

void expect(bool value, String message) {
  if (!value) throw StateError(message);
}

final payload = Uint8List(AudioCache.blockSize * 2 + 301)
  ..setRange(0, 3, [73, 68, 51]);

class LocalConnections extends HttpOverrides {
  final int port;
  int clients = 0;
  LocalConnections(this.port);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    return super.createHttpClient(context)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, proxyHost, proxyPort) {
        expect(uri.host == 'fixture.xmcdn.com', 'Unexpected upstream host');
        expect(uri.scheme == 'http', 'Fixture unexpectedly requested TLS');
        return Socket.startConnect(InternetAddress.loopbackIPv4, port);
      };
  }
}

class Wire {
  final ServerSocket server;
  final String scenario;
  final starts = <int>[];
  final sockets = <Socket>{};
  final firstCut = Completer<void>();
  final failed = Completer<void>();
  Wire(this.server, this.scenario);

  void recordError(Object error, StackTrace stack) {
    final cancellationScenario =
        scenario.startsWith('overlap') ||
        scenario.startsWith('cancel') ||
        scenario == 'changed' ||
        scenario == 'bad-range';
    final disconnected =
        error is SocketException &&
        const {
          32,
          54,
          103,
          104,
          10053,
          10054,
        }.contains(error.osError?.errorCode);
    if (cancellationScenario && disconnected) return;
    if (!failed.isCompleted) failed.completeError(error, stack);
  }

  static Future<Wire> start(String scenario) async {
    final wire = Wire(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      scenario,
    );
    wire.server.listen((socket) {
      wire.sockets.add(socket);
      // A client's deliberate cancel can fail both flush and Socket.done.
      // Observe both, but only allow disconnect OS errors in cancel scenarios.
      unawaited(socket.done.then<void>((_) {}, onError: wire.recordError));
      unawaited(
        wire.serve(socket).then<void>((_) {}, onError: wire.recordError),
      );
    });
    return wire;
  }

  Future<void> serve(Socket socket) async {
    var headers = '';
    var handled = false;
    final received = Completer<String>();
    final subscription = socket.listen(
      (bytes) {
        if (handled) return;
        headers += String.fromCharCodes(bytes);
        if (headers.contains('\r\n\r\n')) {
          handled = true;
          received.complete(headers);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!received.isCompleted)
          received.completeError(error, stack);
        else
          recordError(error, stack);
      },
      onDone: () {
        if (!received.isCompleted)
          received.completeError(StateError('No headers'));
      },
    );
    try {
      final request = await received.future;
      final match = RegExp(
        r'range: bytes=(\d+)-(\d+)',
        caseSensitive: false,
      ).firstMatch(request);
      expect(match != null, 'Producer omitted its Range header');
      final start = int.parse(match![1]!);
      final end = min(int.parse(match[2]!), payload.length - 1);
      starts.add(start);
      final attempt = starts.length;
      if (scenario == '429' || scenario == '403') {
        socket.write(
          'HTTP/1.1 $scenario Rejected\r\n'
          'Content-Length: 0\r\nRetry-After: 17\r\nConnection: close\r\n\r\n',
        );
        await socket.flush();
        return;
      }
      final sequential = scenario == 'sequential' || scenario == 'changed';
      final first = sequential ? 0 : start;
      final last = sequential ? payload.length - 1 : end;
      final etag = scenario == 'changed' && attempt > 1 ? 'v2' : 'v1';
      final rangeFirst = scenario == 'bad-range' ? start + 1 : start;
      socket.write(
        'HTTP/1.1 ${sequential ? '200 OK' : '206 Partial Content'}\r\n'
        'Content-Type: audio/mpeg\r\nContent-Length: ${last - first + 1}\r\n'
        '${sequential ? '' : 'Content-Range: bytes $rangeFirst-$last/${payload.length}\r\n'}'
        'ETag: "$etag"\r\nConnection: close\r\n\r\n',
      );
      final cut =
          scenario.startsWith('cancel') ||
          scenario == 'exhausted' ||
          (scenario == 'range' &&
              start == AudioCache.blockSize &&
              attempt < 4) ||
          (sequential && attempt == 1);
      final count = cut
          ? (sequential ? AudioCache.blockSize + 137 : 137)
          : last - first + 1;
      socket.add(Uint8List.sublistView(payload, first, first + count));
      await socket.flush();
      if (cut && !firstCut.isCompleted) firstCut.complete();
    } finally {
      await subscription.cancel();
      socket.destroy();
      sockets.remove(socket);
    }
  }

  Future<void> close() async {
    await server.close();
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
  }
}

Future<void> scenario(
  String name,
  Future<void> Function(AudioCache, Wire, LocalConnections) check, {
  Future<void> Function()? checkpoint,
  Future<ResolvedAudio> Function(bool Function())? refresh,
}) async {
  final wire = await Wire.start(name);
  final overrides = LocalConnections(wire.server.port);
  final directory = await Directory.systemTemp.createTemp('audio-reconnect-');
  AudioCache? cache;
  try {
    await HttpOverrides.runWithHttpOverrides(() async {
      cache = await AudioCache.open(
        directory: directory.path,
        audio: ResolvedAudio(
          uri: Uri.parse('http://fixture.xmcdn.com/sample.mp3'),
          requiresReward: false,
          track: Track(id: '1'),
          actualQuality: 'mp3_64',
          accountIdentity: 'local-fixture',
          expiresAt: null,
          cacheFinalUri: (_) => null,
          invalidateCachedUri: () {},
        ),
        checkpoint: checkpoint,
        refresh: refresh,
      );
      await Future.any<void>([
        check(cache!, wire, overrides),
        wire.failed.future,
      ]).timeout(const Duration(seconds: 20));
    }, overrides);
    stdout.writeln('PASS $name');
  } finally {
    await cache?.close();
    await wire.close();
    await directory.delete(recursive: true);
  }
}

Future<void> sameBytes(AudioCache cache) async {
  var offset = 0;
  await for (final chunk in cache.stream(0, payload.length)) {
    for (final byte in chunk) {
      expect(byte == payload[offset++], 'Cache stream mixed source bytes');
    }
  }
  expect(offset == payload.length, 'Cache stream silently ended early');
}

Future<Object> failure(Future<void> Function() operation) async {
  try {
    await operation();
  } catch (error) {
    return error;
  }
  throw StateError('Expected failure, got success');
}

Future<void> overlapCancellation() async {
  late AudioCache activeCache;
  late StreamSubscription<List<int>> original;
  Future<void>? cancellation;
  final replacement = Completer<void>();
  final overlap = Completer<void>();
  final heldCheckpoint = Completer<void>();
  var checkpoints = 0;
  try {
    await scenario(
      'overlap',
      (cache, wire, connections) async {
        activeCache = cache;
        original = cache
            .stream(0, payload.length)
            .listen((_) {}, onError: (Object _) {});
        await overlap.future;
        await cancellation;
        heldCheckpoint.complete();
        await replacement.future;
        expect(
          wire.starts.length == 3 && connections.clients == 1,
          'Replacing a reader restarted the shared cache producer',
        );
      },
      checkpoint: () {
        if (++checkpoints == 2) {
          // Replace the reader inside a held body checkpoint. Reader cancel
          // must not pause the shared cache or invalidate its replacement.
          cancellation = original.cancel();
          replacement.complete(sameBytes(activeCache));
          overlap.complete();
          return heldCheckpoint.future;
        }
        return Future<void>.value();
      },
    );
  } finally {
    if (!heldCheckpoint.isCompleted) heldCheckpoint.complete();
  }
}

Future<void> main(List<String> args) async {
  for (var i = 3; i < payload.length; i++) {
    payload[i] = i % 251;
  }
  await overlapCancellation();
  if (args.contains('--overlap-only')) return;
  await scenario('range', (cache, wire, connections) async {
    await sameBytes(cache);
    expect(
      wire.starts.join(',') == '0,1048576,1048576,1048576,2097152',
      'Retry lost blocks or exceeded two retries: ${wire.starts}',
    );
    expect(connections.clients == 3, 'Failed transport client was reused');
    expect(cache.generation == 0, 'Same version changed generation');
  });
  await scenario('sequential', (cache, wire, connections) async {
    await sameBytes(cache);
    expect(wire.starts.length == 2, 'Sequential recovery did not finish');
    expect(
      cache.generation == 0,
      'Sequential retry discarded valid partial data',
    );
  });
  for (final stop in ['pause', 'close']) {
    await scenario('cancel-$stop', (cache, wire, connections) async {
      final subscription = cache
          .stream(0, payload.length)
          .listen((_) {}, onError: (Object _) {});
      await wire.firstCut.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final clock = Stopwatch()..start();
      if (stop == 'close') {
        await cache.close();
      } else {
        await cache.pause();
      }
      expect(clock.elapsedMilliseconds < 750, '$stop waited for retry backoff');
      await subscription.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(wire.starts.length == 1, 'Explicit $stop caused another fetch');
    });
  }
  await scenario('429', (cache, wire, connections) async {
    final error = await failure(() => sameBytes(cache));
    expect(
      error is XmlyException &&
          error.code == 'rate_limited' &&
          error.retryAfter == const Duration(seconds: 17),
      'Retry-After was lost',
    );
    expect(
      wire.starts.length == 1 && connections.clients == 1,
      'Business rate limit was retried',
    );
  });
  await scenario('bad-range', (cache, wire, connections) async {
    final error = await failure(() => sameBytes(cache));
    expect(
      error is XmlyException && error.code == 'cache_range',
      'Invalid Content-Range was not rejected',
    );
    expect(wire.starts.length == 1, 'Protocol error was retried');
  });
  await scenario('exhausted', (cache, wire, connections) async {
    final error = await failure(() => sameBytes(cache));
    expect(
      error is HttpException || error is SocketException,
      'Final error was replaced: $error',
    );
    expect(wire.starts.length == 3, 'Transport retries were not bounded');
  });
  await scenario('changed', (cache, wire, connections) async {
    final error = await failure(() => sameBytes(cache));
    expect(
      error is XmlyException && error.code == 'cache_source_changed',
      'Changed entity was stitched into the existing stream',
    );
    expect(wire.starts.length == 2, 'Changed entity was retried as transport');
  });
  await scenario('checkpoint', (cache, wire, connections) async {
    final error = await failure(() => sameBytes(cache));
    expect(
      error is SocketException && wire.starts.isEmpty,
      'Checkpoint failure was replayed as a byte request',
    );
  }, checkpoint: () async => throw const SocketException('checkpoint failure'));
  var refreshes = 0;
  await scenario(
    '403',
    (cache, wire, connections) async {
      final error = await failure(() => sameBytes(cache));
      expect(
        error is SocketException && refreshes == 1 && wire.starts.length == 1,
        'Authorization refresh failure was retried',
      );
    },
    refresh: (_) async {
      refreshes++;
      throw const SocketException('refresh failure');
    },
  );
}
