import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/xmly_client.dart';
import '../api/xmly_catalogue.dart';
import '../api/xmly_rewards.dart';
import '../storage/app_storage.dart';
import '../storage/credential_store.dart';
import 'account_service.dart';
import 'auto_download_service.dart';
import 'usage_ledger.dart';
import '../models/xmly_models.dart';
import 'download_service.dart';
import 'media_pipeline.dart';
import 'player_service.dart';

class AppRuntime extends ChangeNotifier {
  AppRuntime({required this.storage, required this.secrets}) {
    anonymous = XmlyClient(
      urlCacheDirectory: p.join(storage.directory, 'audio-url-cache'),
    );
    accounts = AccountService(
      storage: storage,
      secrets: secrets,
      quiesce: quiesce,
      settle: settle,
      quiesceForRestore: _quiesceForRestore,
    );
    ledger = UsageLedger(storage: storage, clientFor: accounts.clientFor);
    settlementHandlers.add(ledger.stopWatch);
    settlementHandlers.add(ledger.settle);
    pipeline = MediaPipeline(accounts: accounts, anonymous: anonymous);
    downloads = DownloadService(
      storage: storage,
      accounts: accounts,
      ledger: ledger,
      transfer: pipeline.transfer,
      processOnly: pipeline.processOnly,
      discardSource: pipeline.discardSource,
      anonymous: anonymous,
    );
    autoDownloads = AutoDownloadService(
      storage: storage,
      checkAccount: _checkAutomaticAccount,
      loadCatalogue: (identity, albumId) =>
          XmlyCatalogue(accounts.clientFor(identity)).album(albumId),
      hasTask: (identity, trackId) => downloads.tasks.any(
        (task) => task.accountIdentity == identity && task.track.id == trackId,
      ),
      enqueueNew: (identity, track, allowed) async {
        _checkAutomaticAccount(identity);
        final batch = await prepareDownloads(
          [track],
          accountIdentity: identity,
          automatic: true,
        );
        if (!allowed()) return;
        _checkAutomaticAccount(identity);
        await downloads.enqueueAutomatic(
          batch,
          allowed: () {
            if (!allowed()) return false;
            try {
              _checkAutomaticAccount(identity);
              return true;
            } catch (_) {
              return false;
            }
          },
        );
      },
    );
    player = PlayerService(
      storage: storage,
      accounts: accounts,
      ledger: ledger,
      downloads: downloads,
      pipeline: pipeline,
      anonymous: anonymous,
      prepareDownload: (tracks) => prepareDownloads(tracks),
      confirmDownload: (batch) async =>
          await confirmDownload?.call(batch) ?? false,
      exitApplication: () async {
        scheduledExit = true;
        if (requestExit != null) {
          await requestExit!();
        } else {
          scheduledExit = false;
          lifecycleError = '当前窗口不能执行退出';
          notifyListeners();
        }
      },
    );
    pauseHandlers.add(player.quiesce);
    pauseHandlers.add(downloads.pauseAll);
  }

  final AppStorage storage;
  final CredentialStore secrets;
  late final XmlyClient anonymous;
  late final AccountService accounts;
  late final UsageLedger ledger;
  late final MediaPipeline pipeline;
  late final DownloadService downloads;
  late final AutoDownloadService autoDownloads;
  late final PlayerService player;
  Future<bool> Function(DownloadBatch)? confirmDownload;
  Future<void> Function()? requestExit;
  bool scheduledExit = false, _closed = false;
  StreamSubscription<void>? _playerChanges;
  StreamSubscription<void>? _downloadChanges;
  final List<Future<void> Function()> pauseHandlers = [];
  StreamSubscription<void>? _automaticChanges;
  final List<Future<void> Function()> settlementHandlers = [];
  bool closing = false;
  String? lifecycleError;
  Timer? _rewardTimer;
  bool _refreshingRewards = false;

  XmlyClient get client => accounts.activeClient ?? anonymous;
  Future<void> load() async {
    await anonymous.flushUrlCache();
    await accounts.load();
    await ledger.load();
    await downloads.load();
    await player.load();
    _playerChanges = player.changes.listen((_) => notifyListeners());
    _downloadChanges = downloads.changes.listen((_) => notifyListeners());
    _automaticChanges = autoDownloads.changes.listen((_) => notifyListeners());
    unawaited(autoDownloads.scanAll());
    _configureRewards();
  }

  void changed() {
    _configureRewards();
    notifyListeners();
  }

  Future<String> downloadRoot() async {
    final settings = storage.state['settings'] as Map;
    final configured = (settings['download'] as Map?)?['rootDirectory'];
    if (configured is String && configured.isNotEmpty) return configured;
    final parent = Platform.isAndroid
        ? await getExternalStorageDirectory() ??
              await getApplicationSupportDirectory()
        : await getDownloadsDirectory() ??
              await getApplicationDocumentsDirectory();
    final directory = await Directory(p.join(parent.path, 'XMPlus'))
        .create(recursive: true);
    await storage.transaction((state) {
      final settings = state['settings'] as Map;
      final download =
          settings.putIfAbsent('download', () => <String, dynamic>{}) as Map;
      download['rootDirectory'] = directory.path;
    });
    return directory.path;
  }

  Future<DownloadBatch> prepareDownloads(
    List<Track> tracks, {
    String? accountIdentity,
    bool automatic = false,
  }) async {
    final root = await downloadRoot();
    final settings = storage.state['settings'] as Map;
    final identity =
        accountIdentity ?? accounts.primaryAccountId ?? 'anonymous';
    final selected = <Track>[];
    final catalogues = <String, List<Track>>{};
    final pattern =
        (settings['download'] as Map?)?['filenamePattern'] as String? ??
        '{index} - {title} [{trackId}]';
    for (final track in tracks) {
      if (pattern.contains('{index}') &&
          track.orderNo == null &&
          track.officialPosition == null &&
          track.albumId.isNotEmpty) {
        final list = catalogues[track.albumId] ??= await XmlyCatalogue(
          identity == 'anonymous' ? anonymous : accounts.clientFor(identity),
        ).album(track.albumId);
        final matching = list.where((item) => item.id == track.id).toList();
        if (matching.length != 1)
          throw const XmlyException('missing_official_order', '专辑中没有找到此声音');
        selected.add(matching.single);
      } else {
        selected.add(track);
      }
    }
    return downloads.prepare(
      selected,
      accountIdentity: identity,
      rootDirectory: root,
      settings: {
        'download': {
          ...(settings['download'] as Map? ?? const {}),
          if (automatic) 'retryLimit': 0,
        },
        'media': settings['media'] ?? <String, dynamic>{},
        'tags': settings['tags'] ?? <String, dynamic>{},
        'albumTags': settings['albumTags'] ?? <String, dynamic>{},
      },
    );
  }

  void _checkAutomaticAccount(String identity) {
    if (closing ||
        _closed ||
        accounts.admissionPaused ||
        !accounts.accountIds.contains(identity)) {
      throw const XmlyException('missing_account', '请先登录原账号');
    }
    if (ledger.isBlocked(identity))
      throw const XmlyException('usage_uncertain', '请先核对未确认的听时');
  }

  Future<void> pauseDownload(String id) async {
    if (player.currentTaskId == id) await player.pause();
    await downloads.pause(id);
    await pipeline.pauseTask(id);
  }

  Future<void> cancelDownload(String id) async {
    await player.stopTaskReference(id);
    await downloads.cancel(id);
    await pipeline.pauseTask(id);
  }

  Future<void> pauseAllDownloads() async {
    if (player.currentTaskId != null) await player.pause();
    await downloads.pauseAll();
  }

  Future<void> reacquireDownload(String id) async {
    await player.stopTaskReference(id);
    await downloads.pause(id);
    await downloads.retry(id, reacquire: true);
  }

  Future<void> relocateDownload(String id, String directory) async {
    await player.stopTaskReference(id);
    await downloads.pause(id);
    await pipeline.detachTask(id);
    await downloads.relocate(id, directory);
  }

  Future<void> reloadAfterRestore() async {
    try {
      await downloads.reload();
      await ledger.load();
      await player.reload();
      lifecycleError = null;
      changed();
      autoDownloads.resume();
    } catch (_) {
      lifecycleError = '恢复内容已保存，但任务加载未完成；原资料目录已保留';
      notifyListeners();
      rethrow;
    }
  }

  void _configureRewards() {
    final enabled = (storage.state['settings'] as Map)['autoClaim'] == true;
    if (!enabled) {
      _rewardTimer?.cancel();
      _rewardTimer = null;
    } else {
      _rewardTimer ??= Timer.periodic(
        const Duration(minutes: 5),
        (_) => unawaited(_refreshRewards()),
      );
    }
  }

  Future<void> _refreshRewards() async {
    if (_refreshingRewards ||
        closing ||
        (storage.state['settings'] as Map)['autoClaim'] != true)
      return;
    _refreshingRewards = true;
    try {
      for (final identity in accounts.accountIds.toList()) {
        final record = (storage.state['accounts'] as Map)[identity] as Map;
        if (record['rewardPaused'] == true) continue;
        try {
          await accounts.runWithAccount(identity, (client) async {
            final rewards = XmlyRewards(client, automaticEnabled: true);
            await rewards.refresh();
            if (rewards.lastError.isNotEmpty) {
              await storage.transaction((state) {
                ((state['accounts'] as Map)[identity] as Map)['rewardPaused'] =
                    true;
              });
            }
          });
        } catch (_) {
          // A failed account refresh never triggers account rotation or replay.
        }
      }
    } finally {
      _refreshingRewards = false;
    }
  }

  Future<void> _quiesceForRestore() async {
    autoDownloads.suspend();
    try {
      await player.quiesce(preserveUnknown: true);
      await downloads.pauseAll();
      await ledger.captureForRestore();
    } finally {
      // The account mutex still blocks new admissions until restore finishes.
      if (!closing) autoDownloads.resume();
    }
  }

  Future<void> quiesce() async {
    autoDownloads.suspend();
    try {
      for (final pause in List.of(pauseHandlers)) {
        await pause();
      }
    } finally {
      if (!closing) autoDownloads.resume();
    }
  }

  Future<void> settle() async {
    for (final settle in List.of(settlementHandlers)) {
      await settle();
    }
  }

  Future<bool> close() async {
    if (_closed) return true;
    if (closing) return false;
    closing = true;
    autoDownloads.suspend();
    _rewardTimer?.cancel();
    _rewardTimer = null;
    try {
      await quiesce();
      await settle();
      await accounts.close();
      await player.close(quiesced: true);
      await _playerChanges?.cancel();
      await autoDownloads.close();
      await _automaticChanges?.cancel();
      await downloads.close();
      await _downloadChanges?.cancel();
      await pipeline.close();
      anonymous.close();
      await anonymous.flushUrlCache();
      await storage.close();
      _closed = true;
      return true;
    } catch (_) {
      lifecycleError = '保存或结算未完成，请核对后再退出';
      closing = false;
      autoDownloads.resume();
      notifyListeners();
      return false;
    }
  }
}
