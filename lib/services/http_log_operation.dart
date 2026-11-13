import 'dart:async';
import 'dart:collection';

import '../models/xmly_models.dart';
import 'app_log.dart';

/// An awaited operation owns retries and authorization refreshes. Only its
/// terminal failure is reported; attempt bodies remain in the local log.
class HttpLogOperation {
  HttpLogOperation._(this.name) {
    AppLog.instance.trace(
      'lib/services/http_log_operation.dart::HttpLogOperation._',
    );
  }

  static final _key = Object();
  static const _retainedFailures = 8;
  final String name;
  final _failures = ListQueue<Map<String, Object?>>();
  int _attemptCount = 0, _failureCount = 0;
  bool _active = true, _reported = false;
  bool _promptUser = true;

  static HttpLogOperation? get current {
    AppLog.instance.trace(
      'lib/services/http_log_operation.dart::HttpLogOperation.current.get',
    );
    final operation = Zone.current[_key] as HttpLogOperation?;
    return operation?._active == true ? operation : null;
  }

  static Future<T> run<T>(
    String name,
    Future<T> Function() action, {
    bool independent = false,
  }) {
    AppLog.instance.trace(
      'lib/services/http_log_operation.dart::HttpLogOperation.run',
    );
    if (!independent && current != null) {
      return AppLog.instance.runWithErrorScope(action);
    }
    final operation = HttpLogOperation._(name);
    return AppLog.instance.runWithErrorScope(() {
      AppLog.instance.trace(
        'lib/services/http_log_operation.dart::HttpLogOperation.run.closure#1',
      );
      return runZoned(() async {
        AppLog.instance.trace(
          'lib/services/http_log_operation.dart::HttpLogOperation.run.closure#1.closure#1',
        );
        try {
          return await action();
        } catch (error, stack) {
          operation._reportFailure(error, stack);
          rethrow;
        } finally {
          operation._active = false;
          operation._failures.clear();
        }
      }, zoneValues: {_key: operation});
    });
  }

  int startAttempt() {
    AppLog.instance.trace(
      'lib/services/http_log_operation.dart::HttpLogOperation.startAttempt',
    );
    return ++_attemptCount;
  }

  void failedAttempt(
    int attempt,
    Object error, {
    required String kind,
    required bool promptUser,
    int? status,
    int? apiCode,
  }) {
    AppLog.instance.trace(
      'lib/services/http_log_operation.dart::HttpLogOperation.failedAttempt',
    );
    if (!_active) return;
    _failureCount++;
    _promptUser = promptUser;
    if (_failures.length == _retainedFailures) _failures.removeFirst();
    _failures.add(
      Map.unmodifiable({
        'attempt': attempt,
        'kind': kind,
        'exceptionType': '${error.runtimeType}',
        if (status != null) 'httpStatus': status,
        if (apiCode != null) 'apiCode': apiCode,
      }),
    );
  }

  /// For producers which deliver a terminal failure through stored state or a
  /// stream instead of throwing it from the operation's Future.
  static bool reportFailure(
    Object error,
    StackTrace stack, {
    bool promptUser = true,
  }) {
    AppLog.instance.trace(
      'lib/services/http_log_operation.dart::HttpLogOperation.reportFailure',
    );
    return current?._reportFailure(error, stack, promptUser: promptUser) ??
        false;
  }

  bool _reportFailure(
    Object error,
    StackTrace stack, {
    bool promptUser = true,
  }) {
    AppLog.instance.trace(
      'lib/services/http_log_operation.dart::HttpLogOperation._reportFailure',
    );
    if (!_active || _failureCount == 0) return false;
    if (error is XmlyException &&
        const {
          'client_closed',
          'request_cancelled',
          'cache_closed',
          'cache_paused',
          'cache_source_changed',
          'closed',
          'challenge_invalid',
        }.contains(error.code)) {
      return true;
    }
    if (_reported || AppLog.instance.errorWasRecorded(error)) return true;
    _reported = true;
    final kind = _failures.last['kind'];
    final expiredMediaUrl =
        error is XmlyException &&
        error.code == 'media_unauthorized' &&
        _failures.last['httpStatus'] == 403;
    AppLog.instance.write(
      AppLogLevel.error,
      kind == 'api' ? 'api' : 'network',
      'HTTP operation failed',
      data: {
        'httpOperation': {
          'operation': name,
          'outcome': 'failed',
          'attemptCount': _attemptCount,
          'failedAttemptCount': _failureCount,
          'failures': _failures.toList(growable: false),
          if (_failureCount > _failures.length)
            'omittedFailures': _failureCount - _failures.length,
        },
      },
      error: error,
      stackTrace: stack,
      networkError: kind == 'transport' || kind == 'timeout',
      localOnly: expiredMediaUrl,
      promptUser:
          promptUser &&
          _promptUser &&
          !(error is XmlyException &&
              const {
                'login_required',
                'login_expired',
                'permission_denied',
                'rate_limited',
                'media_unauthorized',
              }.contains(error.code)),
    );
    // The local record owns this occurrence so cache/proxy consumers do not
    // report the same expired URL again after authorization recovery is exhausted.
    if (expiredMediaUrl) AppLog.instance.inheritRecordedError(error);
    return true;
  }
}
