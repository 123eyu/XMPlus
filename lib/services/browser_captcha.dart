import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'geetest_document.dart';

/// A memory-only, single-use return channel for human browser verification.
/// It handles no credentials and has no capability to send an SMS.
class BrowserCaptchaSession {
  BrowserCaptchaSession._(this._server, this._captchaId, Duration lifetime) {
    final random = Random.secure();
    final nonce = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    uri = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: _server.port,
      path: '/$nonce/index.html',
    );
    _server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object _) => unawaited(close()),
      onDone: () => unawaited(close()),
    );
    _expiry = Timer(lifetime, () => unawaited(close()));
  }

  static Future<BrowserCaptchaSession> open(
    String captchaId, {
    Duration lifetime = const Duration(minutes: 5),
  }) async {
    if (!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(captchaId) ||
        lifetime <= Duration.zero) {
      throw const FormatException('安全验证配置无效');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      return BrowserCaptchaSession._(server, captchaId, lifetime);
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }
  }

  final HttpServer _server;
  final String _captchaId;
  final _result = Completer<Map<String, dynamic>?>();
  late final Uri uri;
  late final Timer _expiry;
  bool _closed = false, _consumed = false;
  Future<void>? _closing;

  Future<Map<String, dynamic>?> get result => _result.future;

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _expiry.cancel();
    if (!_result.isCompleted) _result.complete(null);
    return _closing = _server.close(force: true).then((_) {});
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.persistentConnection = false;
    response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Content-Security-Policy', "frame-ancestors 'none'");
    Future<void> reject(int status) async {
      response.statusCode = status;
      await response.close();
    }

    try {
      if (_closed || _consumed) return await reject(HttpStatus.gone);
      if (request.headers.value(HttpHeaders.hostHeader) != uri.authority ||
          request.uri.hasQuery) {
        return await reject(HttpStatus.forbidden);
      }
      if (request.uri.path == uri.path && request.method == 'GET') {
        response.headers.contentType = ContentType.html;
        response.write(geetestDocument(_captchaId));
        await response.close();
        return;
      }
      if (request.uri.path != uri.resolve('result').path) {
        return await reject(HttpStatus.notFound);
      }
      if (request.method != 'POST') {
        return await reject(HttpStatus.methodNotAllowed);
      }
      if (request.headers.value('Origin') != uri.origin) {
        return await reject(HttpStatus.forbidden);
      }
      if (request.headers.contentType?.mimeType != 'application/json') {
        return await reject(HttpStatus.unsupportedMediaType);
      }
      const maxBytes = 48 * 1024;
      if (request.contentLength > maxBytes) {
        return await reject(HttpStatus.requestEntityTooLarge);
      }
      final bytes = await request
          .fold<List<int>>(<int>[], (buffer, chunk) {
            if (buffer.length + chunk.length > maxBytes) {
              throw const _BodyTooLarge();
            }
            return buffer..addAll(chunk);
          })
          .timeout(const Duration(seconds: 10));
      final proof = parseGeetestResult(
        jsonDecode(utf8.decode(bytes)),
        _captchaId,
      );
      if (proof == null) return await reject(HttpStatus.badRequest);
      if (_closed || _consumed) return await reject(HttpStatus.gone);
      _consumed = true;
      try {
        response.headers.contentType = ContentType.json;
        response.write('{"ok":true}');
        await response.close();
      } finally {
        if (!_closed && !_result.isCompleted) _result.complete(proof);
        await close();
      }
    } catch (error) {
      try {
        await reject(
          error is _BodyTooLarge
              ? HttpStatus.requestEntityTooLarge
              : error is TimeoutException
              ? HttpStatus.requestTimeout
              : HttpStatus.badRequest,
        );
      } catch (_) {
        // Closing/cancelling a challenge may already have closed this socket.
      }
    }
  }
}

class _BodyTooLarge implements Exception {
  const _BodyTooLarge();
}
