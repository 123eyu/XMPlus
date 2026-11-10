import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';

import '../common/widgets/adaptive_text.dart';
import '../services/app_runtime.dart';
import '../services/download_service.dart';
import '../models/xmly_models.dart';
import '../services/auto_download_service.dart';
import '../services/android_platform.dart';
import 'catalogue_page.dart';

Future<({String identity, bool polling})?> _chooseDownloadAccount(
  BuildContext context,
  AppRuntime runtime,
) async {
  final primary = runtime.accounts.primaryAccountId ?? 'anonymous';
  final accountIds = runtime.accounts.accountIds;
  var polling =
      ((runtime.storage.state['settings'] as Map)['download']
          as Map?)?['polling'] !=
      false;
  if (accountIds.isEmpty) return (identity: 'anonymous', polling: false);
  final selected = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => SimpleDialog(
        title: const Text('下载账号'),
        children: [
          SwitchListTile(
            title: const Text('轮询'),
            subtitle: const Text('请求失败时尝试下一个账号；扣时结果不明时停止'),
            value: polling,
            onChanged: (value) => setState(() => polling = value),
          ),
          for (final id in accountIds)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, id),
              child: Text(
                '账号 ${(runtime.storage.state['accounts'] as Map)[id]['uid']}'
                '${id == primary ? ' · 主账号' : ''}',
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'anonymous'),
            child: const Text('不登录（免费内容）'),
          ),
        ],
      ),
    ),
  );
  if (selected == null) return null;
  await runtime.storage.transaction((state) {
    final settings = state['settings'] as Map;
    final download =
        settings.putIfAbsent('download', () => <String, dynamic>{}) as Map;
    download['polling'] = polling;
  });
  return (identity: selected, polling: selected != 'anonymous' && polling);
}

Future<void> requestDownloads(
  BuildContext context,
  AppRuntime runtime,
  List<Track> tracks,
) async {
  final account = await _chooseDownloadAccount(context, runtime);
  if (account == null || !context.mounted) return;
  final batch = await runtime.prepareDownloads(
    tracks,
    accountIdentity: account.identity,
    polling: account.polling,
    previewBilling: false,
  );
  if (!context.mounted) return;
  if (batch.items.isEmpty) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('所选声音已在下载列表中')));
    return;
  }
  await runtime.downloads.enqueue(batch, confirmed: true);
}

Future<void> requestAlbumDownloads(
  BuildContext context,
  AppRuntime runtime,
  String albumId,
) async {
  final account = await _chooseDownloadAccount(context, runtime);
  if (account == null || !context.mounted) return;
  final batch = await runtime.prepareAlbumDownloads(
    albumId,
    accountIdentity: account.identity,
    polling: account.polling,
  );
  if (!context.mounted) return;
  await runtime.downloads.enqueue(batch, confirmed: true);
}

Future<bool> deleteDownloadedAudio(
  BuildContext context,
  AppRuntime runtime,
  DownloadTask task,
) async {
  final path = task.finalPath;
  if (path == null) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: const Text(
        '删除音频文件？',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SelectableText(path),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除文件'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  await runtime.player.stopTaskReference(task.id);
  final file = File(path);
  if (await file.exists()) await file.delete();
  await runtime.downloads.markAudioDeleted(task.id);
  return true;
}

Future<void> setAlbumAutoDownload(
  BuildContext context,
  AutoDownloadService service,
  String identity,
  String albumId,
  String title,
) async {
  if (service.enabled(identity, albumId)) {
    await service.setEnabled(identity, albumId, confirmed: false);
    return;
  }
  final account = (service.storage.state['accounts'] as Map)[identity];
  final label = account is Map && account['uid'] is String
      ? account['uid'] as String
      : identity;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: const Text(
        '自动下载新声音',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SingleChildScrollView(
        child: Text(
          '${title.isEmpty ? "此专辑" : title}\n账号 $label\n\n'
          '开启后，启动应用或打开专辑时检查更新，只下载开启后新增的声音，不补下已有集数。\n\n'
          '始终使用此账号及正常下载规则。奖励内容会逐集预扣整首听时，未来新增声音不再逐次询问；'
          '失败或取消不自动退回。余额不足、登录失效或扣时结果未知时停止，不切换账号或重试扣时。\n\n'
          '可随时关闭；已加入的任务和扣时记录保留。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('同意并开启'),
        ),
      ],
    ),
  );
  if (accepted == true && context.mounted)
    await service.setEnabled(identity, albumId, confirmed: true);
}

Future<bool> confirmDownloadBatch(
  BuildContext context,
  DownloadBatch batch,
) async {
  if (batch.items.isEmpty && batch.albumId == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('所选声音已在下载列表中')));
    return false;
  }
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(
            batch.albumId == null ? '下载 ${batch.items.length} 集' : '下载整个专辑',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (batch.albumId != null) ...[
                  Text(
                    '共 ${batch.albumTotalCount ?? "未知"} 集，首批 ${batch.items.length} 集。'
                    '当前页处理结束后再请求下一页，单集失败不影响其余声音。',
                  ),
                  const SizedBox(height: 8),
                  const Text('后续每页继续按正常规则逐集扣时；已下载声音自动跳过，可随时暂停。'),
                  const SizedBox(height: 8),
                ],
                Text(
                  batch.totalSeconds == 0
                      ? '本批预览无需扣除奖励听时'
                      : '本批预计扣除 ${batch.totalSeconds} 秒（按实际使用的账号逐集扣除）',
                ),
                if (batch.totalSeconds > 0) ...[
                  const SizedBox(height: 8),
                  const Text('逐集扣除整首时长，下载失败或取消不自动退回。原任务重试不会重复扣时。'),
                ],
                if (batch.items.isNotEmpty) const SizedBox(height: 12),
                if (batch.items.isNotEmpty)
                  SizedBox(
                    height: (batch.items.length * 72.0).clamp(72.0, 260.0),
                    child: Scrollbar(
                      child: ListView.builder(
                        itemCount: batch.items.length,
                        itemBuilder: (_, index) {
                          final item = batch.items[index];
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              item.track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              item.error ??
                                  '${item.accountIdentity != batch.accountIdentity ? "已切换账号 · " : ""}${item.seconds} 秒',
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(batch.totalSeconds > 0 ? '确认扣时并下载' : '下载'),
            ),
          ],
        ),
      ) ==
      true;
}

class DownloadPage extends StatefulWidget {
  const DownloadPage({required this.runtime, super.key});
  final AppRuntime runtime;
  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  final _refreshingAlbums = <String>{};
  DownloadService get _service => widget.runtime.downloads;
  AutoDownloadService get _autoDownloads => widget.runtime.autoDownloads;
  String? _error;
  String? _availabilityKey;
  int _availabilityEpoch = 0;
  Map<String, bool> _available = const {};
  final _expandedAlbums = <String>{};
  StreamSubscription<void>? _taskChanges;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _taskChanges = _service.changes.listen((_) => _tasksChanged());
    widget.runtime.albumCache.addListener(_cacheChanged);
    unawaited(_refreshAvailability(_service.tasks));
  }

  void _tasksChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_refreshAvailability(_service.tasks));
  }

  void _cacheChanged() {
    _availabilityKey = null;
    _tasksChanged();
  }

  @override
  void didUpdateWidget(covariant DownloadPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime) return;
    unawaited(_taskChanges?.cancel());
    oldWidget.runtime.albumCache.removeListener(_cacheChanged);
    _availabilityKey = null;
    _available = const {};
    _listen();
  }

  @override
  void dispose() {
    unawaited(_taskChanges?.cancel());
    widget.runtime.albumCache.removeListener(_cacheChanged);
    super.dispose();
  }

  Future<void> _refreshAvailability(List<DownloadTask> tasks) async {
    final key = tasks
        .map((task) => '${task.id}:${task.finalPath}:${task.state.name}')
        .join('|');
    if (key == _availabilityKey) return;
    _availabilityKey = key;
    final epoch = ++_availabilityEpoch;
    final paths = {
      for (final task in tasks)
        if (task.finalPath != null) task.id: task.finalPath!,
    };
    final result = <String, bool>{};
    for (final entry in paths.entries) {
      try {
        result[entry.key] = await File(entry.value).exists();
      } on FileSystemException {
        result[entry.key] = false;
      }
    }
    if (mounted && epoch == _availabilityEpoch && key == _availabilityKey) {
      setState(() => _available = result);
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    try {
      await operation();
      if (mounted) setState(() => _error = null);
    } on XmlyException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，任务和文件已保留');
    }
  }

  Future<void> _retry(DownloadTask task) async {
    task = _service.task(task.id);
    if (task.state != DownloadState.failed &&
        task.state != DownloadState.paused)
      return;
    if (task.processingFailed) {
      await _service.retry(task.id);
      return;
    }
    if (task.needsConfirmation) {
      final batch = await _service.prepareRetry(task.id);
      if (!mounted) return;
      if (await confirmDownloadBatch(context, batch))
        await _service.enqueue(batch, confirmed: true);
    } else {
      await _service.retry(task.id);
    }
  }

  Future<void> _adjustProcessing(DownloadTask task) async {
    var format =
        (task.settings['media'] as Map?)?['format'] as String? ?? 'original';
    var bitrate =
        (task.settings['media'] as Map?)?['bitrateKbps'] as int? ?? 64;
    var conflict =
        (task.settings['download'] as Map?)?['conflict'] as String? ?? 'skip';
    var currentTools = true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text(
            '调整处理',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('仅重跑处理，不重新取流或扣时。'),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: format,
                    items: const [
                      DropdownMenuItem(value: 'original', child: Text('原格式')),
                      DropdownMenuItem(value: 'mp3', child: Text('MP3')),
                      DropdownMenuItem(value: 'm4a', child: Text('M4A')),
                      DropdownMenuItem(value: 'm4b', child: Text('M4B')),
                      DropdownMenuItem(value: 'flac', child: Text('FLAC')),
                    ],
                    onChanged: (value) => update(() {
                      format = value!;
                    }),
                  ),
                  if (format != 'original' && format != 'flac')
                    DropdownButton<int>(
                      isExpanded: true,
                      value: bitrate,
                      items: [
                        for (final value in [32, 64, 96, 128, 192])
                          DropdownMenuItem(
                            value: value,
                            child: Text('$value kbps'),
                          ),
                      ],
                      onChanged: (value) => update(() {
                        bitrate = value!;
                      }),
                    ),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: conflict,
                    items: const [
                      DropdownMenuItem(
                        value: 'skip',
                        child: Text(
                          '同名：校验后跳过',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'overwrite',
                        child: Text(
                          '同名：新文件完成后替换',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'number',
                        child: Text(
                          '同名：自动加编号',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    onChanged: (value) => update(() {
                      conflict = value!;
                    }),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: currentTools,
                    title: const Text('使用当前工具路径'),
                    onChanged: (value) => update(() {
                      currentTools = value!;
                    }),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存并重试'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true)
      await _service.reprocess(
        task.id,
        format: format,
        bitrateKbps: bitrate,
        conflict: conflict,
        useCurrentTools: currentTools,
      );
  }

  Future<void> _reacquire(DownloadTask task) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text(
          '重新获取音频？',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text('${task.track.title}\n清除本任务缓存并重新核验权限，成品和扣时记录会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新获取'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await widget.runtime.reacquireDownload(task.id);
  }

  Future<void> _relocate(DownloadTask task) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('更换目录', maxLines: 1, overflow: TextOverflow.ellipsis),
        content: SelectableText(
          '${task.track.title}\n${task.rootDirectory}\n旧缓存不自动移动，原扣时记录保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('选择目录'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择本任务的下载目录',
    );
    if (directory == null) return;
    await widget.runtime.relocateDownload(task.id, directory);
  }

  Future<void> _cancel(DownloadTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text(
          '取消此任务？',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: const Text('缓存和已扣听时记录会保留，不自动退款。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消任务'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.runtime.cancelDownload(task.id);
  }

  Future<void> _open(DownloadTask task) async {
    final path = task.finalPath == null
        ? task.rootDirectory
        : p.dirname(task.finalPath!);
    if (!await Directory(path).exists())
      throw const FileSystemException('Directory missing');
    if (Platform.isAndroid) {
      if (task.finalPath case final file?) {
        await AndroidPlatform.openAudioFile(file);
      } else if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: const Text(
              '下载目录',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            content: SelectableText(path),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
      return;
    }
    final executable = Platform.isWindows
        ? 'explorer.exe'
        : Platform.isMacOS
        ? 'open'
        : 'xdg-open';
    await Process.start(executable, [path], runInShell: false);
  }

  Future<void> _delete(DownloadTask task) async {
    if (await deleteDownloadedAudio(context, widget.runtime, task)) {
      _availabilityKey = null;
      await _refreshAvailability(_service.tasks);
    }
  }

  Future<void> _openAlbum(String albumId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AlbumPageView(
          runtime: widget.runtime,
          albumId: albumId,
          onDownload: (tracks) =>
              requestDownloads(context, widget.runtime, tracks),
          onPlayAlbum: widget.runtime.player.playAlbum,
        ),
      ),
    );
    if (!mounted) return;
    _availabilityKey = null;
    await _refreshAvailability(_service.tasks);
  }

  Widget _albumCard(
    String albumId,
    List<DownloadTask> tasks,
    bool compact, {
    required bool downloaded,
  }) {
    final cached = albumId.isEmpty ? null : widget.runtime.albumCache[albumId];
    final album = cached?.album;
    final total = album?.total ?? 0;
    final completed = {
      for (final task in tasks)
        if (task.state == DownloadState.completed &&
            _available[task.id] == true)
          task.track.id,
    }.length;
    final missing = tasks
        .where(
          (task) =>
              task.state == DownloadState.completed &&
              (task.finalPath == null || _available[task.id] == false),
        )
        .length;
    final states = <DownloadState, int>{};
    for (final task in tasks) {
      states.update(task.state, (count) => count + 1, ifAbsent: () => 1);
    }
    final summary = [
      for (final entry in states.entries) '${_state(entry.key)} ${entry.value}',
      if (missing > 0) '文件缺失 $missing',
    ].join(' · ');
    final title = albumId.isEmpty
        ? '未归属专辑的声音'
        : album != null && album.title.isNotEmpty
        ? album.title
        : tasks.first.track.album.isNotEmpty
        ? tasks.first.track.album
        : '专辑 $albumId';
    final expansionKey = '${downloaded ? 'downloaded' : 'tasks'}:$albumId';
    final expanded = _expandedAlbums.contains(expansionKey);
    void toggle() => setState(() {
      if (expanded) {
        _expandedAlbums.remove(expansionKey);
      } else {
        _expandedAlbums.add(expansionKey);
      }
    });
    return Card(
      margin: EdgeInsets.symmetric(horizontal: compact ? 8 : 16, vertical: 6),
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 16,
              vertical: 6,
            ),
            leading: compact
                ? null
                : CoverImage(
                    uri: album?.coverUrl ?? tasks.first.track.coverUrl,
                    localPath: cached?.coverPath,
                    size: 52,
                    downloaded: downloaded && completed > 0,
                  ),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (downloaded)
                  Text(
                    '$completed / ${total > 0 ? total : "总集数未知"} 集已下载',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                if (downloaded && total > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: LinearProgressIndicator(
                      value: (completed / total).clamp(0.0, 1.0),
                    ),
                  ),
                Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
            onTap: albumId.isEmpty
                ? toggle
                : () => _run(() => _openAlbum(albumId)),
            trailing: IconButton(
              tooltip: expanded ? '收起声音与操作' : '展开声音与操作',
              icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
              onPressed: toggle,
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            SizedBox(
              height: (tasks.length * (downloaded ? 80.0 : 260.0))
                  .clamp(80.0, 400.0)
                  .toDouble(),
              child: ListView.builder(
                primary: false,
                itemCount: tasks.length,
                itemBuilder: (_, index) => downloaded
                    ? _downloadedTrack(tasks[index], compact)
                    : _taskCard(tasks[index], compact),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _downloadedTrack(DownloadTask task, bool compact) {
    final available = _available[task.id] == true;
    return ListTile(
      leading: compact
          ? null
          : CoverImage(
              uri: task.track.coverUrl,
              localPath:
                  widget.runtime.albumCache[task.track.albumId]?.coverPath,
              downloaded: available,
              size: 44,
            ),
      title: AdaptiveText(task.track.title),
      subtitle: Text(
        _available.containsKey(task.id)
            ? (available ? '已下载' : '音频文件已不存在')
            : '正在检查本地文件',
      ),
      onTap: available
          ? () => _run(() => widget.runtime.player.playLocal(task.id))
          : null,
      trailing: PopupMenuButton<String>(
        tooltip: '已下载声音操作',
        onSelected: (action) => _run(() async {
          switch (action) {
            case 'play':
              await widget.runtime.player.playLocal(task.id);
            case 'open':
              await _open(task);
            case 'delete':
              await _delete(task);
          }
        }),
        itemBuilder: (_) => [
          if (available) const PopupMenuItem(value: 'play', child: Text('播放')),
          const PopupMenuItem(value: 'open', child: Text('打开目录')),
          if (available)
            const PopupMenuItem(value: 'delete', child: Text('删除音频')),
        ],
      ),
    );
  }

  Future<void> _refreshAlbum(String id) async {
    if (!_refreshingAlbums.add(id)) return;
    setState(() {});
    try {
      final batch = await _service.prepareAlbumRefresh(id);
      if (!mounted || !await confirmDownloadBatch(context, batch) || !mounted) {
        return;
      }
      await _service.enqueue(batch, confirmed: true);
    } finally {
      _refreshingAlbums.remove(id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _cancelAlbum(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消整专辑下载？'),
        content: const Text('停止后续分页；已创建的任务、缓存和扣时记录保留，不自动退款。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消专辑任务'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _service.cancelAlbum(id);
  }

  Widget _albumList({required bool downloaded}) {
    final compact = MediaQuery.sizeOf(context).width < 320;
    final groups = <String, List<DownloadTask>>{};
    for (final task in _service.tasks) {
      if ((task.state == DownloadState.completed) != downloaded ||
          task.state == DownloadState.cancelled)
        continue;
      groups.putIfAbsent(task.track.albumId, () => []).add(task);
    }
    final albums = groups.entries.toList();
    final jobs = _service.albumJobs
        .where((job) => job.state != 'completed' && job.state != 'cancelled')
        .toList();
    return Scrollbar(
      child: ListView.builder(
        key: PageStorageKey(
          downloaded ? 'downloaded-albums' : 'download-tasks',
        ),
        itemCount: albums.length + 1,
        itemBuilder: (context, index) {
          if (index > 0) {
            final group = albums[index - 1];
            return _albumCard(
              group.key,
              group.value,
              compact,
              downloaded: downloaded,
            );
          }
          return Padding(
            padding: EdgeInsets.all(compact ? 8 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!downloaded) ...[
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _run(widget.runtime.pauseAllDownloads),
                        icon: const Icon(Icons.pause),
                        label: const Text('全部暂停'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _run(_service.resumeAll),
                        icon: const Icon(Icons.download),
                        label: const Text('全部继续'),
                      ),
                    ],
                  ),
                  for (final job in jobs)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AdaptiveText('${job.title} · 整专辑下载'),
                            Text('第 ${job.page} 页 · ${job.total} 集'),
                            if (job.error != null) Text(job.error!),
                            Wrap(
                              spacing: 8,
                              children: [
                                if (job.state == 'queued' ||
                                    job.state == 'running')
                                  TextButton(
                                    onPressed: () =>
                                        _run(() => _service.pauseAlbum(job.id)),
                                    child: const Text('暂停专辑'),
                                  )
                                else
                                  TextButton(
                                    onPressed: () => _run(
                                      () => _service.resumeAlbum(job.id),
                                    ),
                                    child: Text(
                                      job.state == 'failed' ? '重试专辑' : '继续专辑',
                                    ),
                                  ),
                                if (job.state == 'failed' ||
                                    job.state == 'paused')
                                  TextButton(
                                    onPressed:
                                        _refreshingAlbums.contains(job.id)
                                        ? null
                                        : () =>
                                              _run(() => _refreshAlbum(job.id)),
                                    child: Text(
                                      _refreshingAlbums.contains(job.id)
                                          ? '正在刷新…'
                                          : '刷新并重新确认',
                                    ),
                                  ),
                                TextButton(
                                  onPressed: () =>
                                      _run(() => _cancelAlbum(job.id)),
                                  child: const Text('取消专辑任务'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
                for (final error in [
                  if (_error != null) _error!,
                  if (!downloaded) ..._autoDownloads.errors,
                ])
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (albums.isEmpty && (downloaded || jobs.isEmpty))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(downloaded ? '暂无已下载内容' : '暂无下载任务'),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: _autoDownloads.changes,
    builder: (context, _) => DefaultTabController(
      length: 2,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: '下载任务'),
                  Tab(text: '已下载'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _albumList(downloaded: false),
                    _albumList(downloaded: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _taskCard(DownloadTask task, bool compact) {
    final total = task.totalBytes;
    final progress = total == null || total <= 0
        ? null
        : (task.receivedBytes / total).clamp(0.0, 1.0);
    final remaining = total == null || task.bytesPerSecond <= 0
        ? null
        : ((total - task.receivedBytes).clamp(0, total) / task.bytesPerSecond)
              .ceil();
    return Card(
      margin: EdgeInsets.symmetric(horizontal: compact ? 8 : 16, vertical: 6),
      child: Padding(
        padding: EdgeInsets.all(compact ? 8 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              task.track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${task.track.album} · ${_state(task.state)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            if (task.error != null)
              Text(
                task.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (task.state == DownloadState.downloading ||
                task.state == DownloadState.processing) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: task.state == DownloadState.processing ? null : progress,
              ),
            ],
            const SizedBox(height: 8),
            AdaptiveText(
              '${_bytes(task.receivedBytes)} / ${total == null ? "未知" : _bytes(total)} · ${_bytes(task.bytesPerSecond.round())}/s${remaining == null ? "" : " · 剩余 ${remaining}s"}',
            ),
            if (task.retryAt != null)
              AdaptiveText(
                '下次重试 ${task.retryAt!.toLocal().toString().split(".").first}',
              ),
            if (task.actualQuality != null)
              AdaptiveText('实际音质：${task.actualQuality}'),
            if (task.warning != null)
              Text(
                task.warning!,
                style: TextStyle(color: Theme.of(context).colorScheme.tertiary),
              ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (task.active)
                  TextButton(
                    onPressed: () =>
                        _run(() => widget.runtime.pauseDownload(task.id)),
                    child: const Text('暂停'),
                  ),
                if (task.state == DownloadState.paused)
                  TextButton(
                    onPressed: () => _run(() => _retry(task)),
                    child: Text(
                      task.needsConfirmation && !task.processingFailed
                          ? '重新确认'
                          : '继续',
                    ),
                  ),
                if (task.state == DownloadState.failed)
                  TextButton(
                    onPressed: () => _run(() => _retry(task)),
                    child: Text(
                      task.needsConfirmation
                          ? '重新确认'
                          : task.processingFailed
                          ? '重试处理'
                          : '重试',
                    ),
                  ),
                if (task.processingFailed &&
                    (task.state == DownloadState.failed ||
                        task.state == DownloadState.paused ||
                        task.state == DownloadState.cancelled))
                  TextButton(
                    onPressed: () => _run(() => _reacquire(task)),
                    child: const Text('重新获取音频'),
                  ),
                if (task.processingFailed &&
                    (task.state == DownloadState.failed ||
                        task.state == DownloadState.paused ||
                        task.state == DownloadState.cancelled))
                  TextButton(
                    onPressed: () => _run(() => _adjustProcessing(task)),
                    child: const Text('调整处理'),
                  ),
                if (task.state != DownloadState.completed &&
                    task.state != DownloadState.cancelled)
                  TextButton(
                    onPressed: () => _run(() => _cancel(task)),
                    child: const Text('取消'),
                  ),
                if (!task.active && task.state != DownloadState.completed)
                  TextButton(
                    onPressed: () => _run(() => _relocate(task)),
                    child: const Text('更换目录'),
                  ),
                TextButton(
                  onPressed: () => _run(() => _open(task)),
                  child: const Text('打开目录'),
                ),
                if (task.finalPath != null)
                  TextButton(
                    onPressed: () => _run(() => _delete(task)),
                    child: const Text('删除音频'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _bytes(int value) => value < 1024
    ? '${value}B'
    : value < 1024 * 1024
    ? '${(value / 1024).toStringAsFixed(1)}KiB'
    : '${(value / (1024 * 1024)).toStringAsFixed(1)}MiB';
String _state(DownloadState state) => switch (state) {
  DownloadState.queued => '等待中',
  DownloadState.awaitingDebit => '等待扣时确认',
  DownloadState.downloading => '下载中',
  DownloadState.paused => '已暂停',
  DownloadState.processing => '处理中',
  DownloadState.completed => '已完成',
  DownloadState.failed => '失败',
  DownloadState.cancelled => '已取消',
};
