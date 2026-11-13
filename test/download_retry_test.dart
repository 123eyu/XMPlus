import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xmly_flutter/api/xmly_client.dart';
import 'package:xmly_flutter/models/xmly_models.dart';
import 'package:xmly_flutter/services/account_service.dart';
import 'package:xmly_flutter/services/app_log.dart';
import 'package:xmly_flutter/services/download_service.dart';
import 'package:xmly_flutter/services/http_log_attempt.dart';
import 'package:xmly_flutter/services/usage_ledger.dart';
import 'package:xmly_flutter/storage/app_storage.dart';
import 'package:xmly_flutter/storage/credential_store.dart';

class _UnusedCredentials implements CredentialStore {
  @override
  Future<String?> read(String key) => throw StateError('No credential access');
  @override
  Future<void> write(String key, String value) =>
      throw StateError('No credential access');
  @override
  Future<void> delete(String key) => throw StateError('No credential access');
}

void main() {
  test('download consumer retries before reporting, but stops for pause and consent', () async {
    final root = await Directory.systemTemp.createTemp(
      'xmplus-download-retry-',
    );
    final storage = await AppStorage.open(p.join(root.path, 'profile'));
    final client = XmlyClient();
    final accounts = AccountService(
      storage: storage,
      secrets: _UnusedCredentials(),
    );
    final ledger = UsageLedger(storage: storage, clientFor: accounts.clientFor);
    final output = await File(p.join(root.path, 'verified.mp3'))
        .writeAsString('audio');
    final attempts = <String, int>{};
    final pausing = Completer<void>();
    final reports = <AppLogRecord>[];
    final log = AppLog.instance;
    final oldSink = log.sink;
    log.sink = (record) {
      if (record.level.index >= AppLogLevel.error.index) reports.add(record);
    };
    final service = DownloadService(
      storage: storage,
      accounts: accounts,
      ledger: ledger,
      anonymous: client,
      transfer: (_, _, _) =>
          throw StateError('A processing retry must not readmit or transfer'),
      processOnly: (task, control) async {
        final count = attempts.update(
          task.id,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        if (task.id == 'recover' && count == 2) return output.path;
        if (task.id == 'consent') {
          throw const XmlyException(
            'confirmation_required',
            'Confirm listening time',
          );
        }
        final error = FileSystemException('Temporary output failure');
        // Real processors and cache producers log before throwing to their consumer.
        log.write(
          AppLogLevel.error,
          'media',
          'Processing attempt failed',
          error: error,
          stackTrace: StackTrace.current,
          promptUser: true,
        );
        if (task.id == 'pause') pausing.complete();
        throw error;
      },
    );
    addTearDown(() async {
      await service.close();
      client.close();
      log.sink = oldSink;
      await storage.close();
      await root.delete(recursive: true);
    });
    const settings = {
      'download': {'retryLimit': 1},
    };
    await storage.transaction((state) {
      state['settings'] = settings;
      state['downloads'] = [
        for (final id in ['recover', 'exhaust', 'pause', 'consent'])
          DownloadTask(
            id: id,
            accountIdentity: 'anonymous',
            track: Track(
              id: '${['recover', 'exhaust', 'pause', 'consent'].indexOf(id) + 1}',
            ),
            rootDirectory: root.path,
            settings: settings,
            createdAt: DateTime.utc(2026),
            state: DownloadState.paused,
            processingFailed: true,
          ).toJson(),
      ];
    });
    await service.load();
    Future<void> reaches(String id, DownloadState state) async {
      if (service.task(id).state == state) return;
      await service.changes.firstWhere((_) => service.task(id).state == state);
    }

    var done = reaches('recover', DownloadState.completed);
    await service.resume('recover');
    await done;
    expect(attempts['recover'], 2);
    expect(service.task('recover').finalPath, output.path);
    expect(
      reports,
      isEmpty,
      reason: 'A recovered processing error must never reach Sentry',
    );

    done = reaches('exhaust', DownloadState.failed);
    await service.resume('exhaust');
    await done;
    expect(
      attempts['exhaust'],
      2,
      reason: 'retryLimit=1 means two attempts, not nested budgets',
    );
    expect(
      reports,
      hasLength(1),
      reason: 'Only the terminal consumer failure is reportable',
    );

    await service.resume('pause');
    await pausing.future;
    await service.pause('pause');
    expect(service.task('pause').state, DownloadState.paused);
    expect(attempts['pause'], 1);
    expect(reports, hasLength(1));

    done = reaches('consent', DownloadState.awaitingDebit);
    await service.resume('consent');
    await done;
    expect(
      attempts['consent'],
      1,
      reason: 'Retries cannot bypass user authorization',
    );
    expect(service.task('consent').needsConfirmation, isTrue);
    expect(reports, hasLength(1));

    // Exercise the public read consumer too: HTTP producers must retain their
    // local failures without reporting before this operation's retry budget ends.
    var reads = 0;
    final value = await DownloadService.readRequests(
      client,
      settings,
      () async {
        if (++reads == 2) return 'resolved';
        final failure = const XmlyException(
          'invalid_media',
          'Incomplete probe',
        );
        final attempt = HttpLogAttempt(
          account: 'anonymous',
          method: 'GET',
          url: 'https://example.com/audio',
        );
        await attempt.fail(failure, StackTrace.current);
        throw failure;
      },
    );
    expect(value, 'resolved');
    expect(reads, 2);
    expect(reports, hasLength(1));

    final stopRead = Completer<void>();
    reads = 0;
    final cancelledRead = DownloadService.readRequests(
      client,
      settings,
      () async {
        reads++;
        final failure = const XmlyException('network', 'Read failed');
        final attempt = HttpLogAttempt(
          account: 'anonymous',
          method: 'GET',
          url: 'https://example.com/audio',
        );
        await attempt.fail(failure, StackTrace.current);
        stopRead.complete();
        throw failure;
      },
      cancelled: stopRead.future,
    );
    await expectLater(
      cancelledRead,
      throwsA(
        isA<XmlyException>().having(
          (error) => error.code,
          'code',
          'request_cancelled',
        ),
      ),
    );
    expect(reads, 1);
    expect(
      reports,
      hasLength(1),
      reason: 'Cancellation after an HTTP failure is not a terminal failure',
    );

    reads = 0;
    final exhaustedRead = DownloadService.readRequests(
      client,
      settings,
      () async {
        reads++;
        final failure = XmlyException(
          'invalid_media',
          'Invalid audio response',
        );
        final attempt = HttpLogAttempt(
          account: 'anonymous',
          method: 'GET',
          url: 'https://example.com/audio',
        );
        await attempt.fail(failure, StackTrace.current);
        throw failure;
      },
    );
    await expectLater(exhaustedRead, throwsA(isA<XmlyException>()));
    expect(reads, 2);
    expect(
      reports,
      hasLength(2),
      reason: 'Exhausted HTTP reads report exactly once',
    );

    log.write(
      AppLogLevel.error,
      'test',
      'Unrelated consumer failure',
      error: StateError('Outside retry scope'),
    );
    expect(
      reports,
      hasLength(3),
      reason: 'Normal consumers keep their reporting behavior',
    );
  });
}
