import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

bool retryableStatus(int? status) =>
    status == 408 ||
    status == 425 ||
    status == 429 ||
    status != null &&
        status >= 500 &&
        status <= 599 &&
        status != 501 &&
        status != 505;

bool retryableTransport(Object error) {
  if (error is HandshakeException || error is TlsException) return false;
  if (error is DioException) {
    if (error.error is HandshakeException || error.error is TlsException) {
      return false;
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.badResponse => retryableStatus(
        error.response?.statusCode,
      ),
      DioExceptionType.unknown =>
        error.error != null && retryableTransport(error.error!),
      _ => false,
    };
  }
  return error is SocketException ||
      error is TimeoutException ||
      error is HttpException;
}

Duration retryDelay(int attempt, String? retryAfter) {
  final backoff = Duration(seconds: 1 << attempt);
  final seconds = int.tryParse(retryAfter?.trim() ?? '');
  var server = Duration.zero;
  if (seconds != null && seconds >= 0) {
    server = Duration(seconds: seconds);
  } else if (retryAfter != null) {
    try {
      server = HttpDate.parse(retryAfter).difference(DateTime.now().toUtc());
    } on FormatException {
      // An invalid header cannot shorten the normal cooldown.
    }
  }
  return server > backoff ? server : backoff;
}

/// A close signal interrupts even a long server cooldown and cancels its timer.
Future<void> waitToRetry(
  Duration delay, {
  Future<void>? closed,
  Future<void> Function()? checkpoint,
}) async {
  final deadline = DateTime.now().add(delay);
  final closing = closed?.then<bool>((_) => true);
  while (true) {
    await checkpoint?.call();
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) return;
    final ready = Completer<void>();
    final timer = Timer(
      checkpoint != null && left > const Duration(milliseconds: 100)
          ? const Duration(milliseconds: 100)
          : left,
      ready.complete,
    );
    try {
      final stopped = await Future.any<bool>([
        ready.future.then((_) => false),
        if (closing != null) closing,
      ]);
      if (stopped) throw StateError('HTTP client closed');
    } finally {
      timer.cancel();
    }
  }
}
