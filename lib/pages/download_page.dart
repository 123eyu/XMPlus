import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';

import '../services/download_service.dart';
import '../models/xmly_models.dart' show XmlyException;
import '../services/auto_download_service.dart';
import '../services/android_platform.dart';

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
      title: const Text('自动下载新声音'),
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
  if (batch.items.isEmpty) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('所选声音已在下载列表中')));
    return false;
  }
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('下载 ${batch.items.length} 集'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  batch.totalSeconds == 0
                      ? '本批无需扣除奖励听时'
                      : '本批扣除 ${batch.totalSeconds} 秒\n当前余额 ${batch.balance ?? "未知"} 秒',
                ),
                if (batch.totalSeconds > 0) ...[
                  const SizedBox(height: 8),
                  const Text('逐集扣除整首时长，下载失败或取消不自动退回。原任务重试不会重复扣时。'),
                ],
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: Scrollbar(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: batch.items.length,
                      itemBuilder: (_, index) {
                        final item = batch.items[index];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(item.track.title),
                          trailing: Text('${item.seconds} 秒'),
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
  const DownloadPage({
    required this.service,
    this.autoDownloads,
    this.onPause,
    this.onCancel,
    this.onStop,
    this.onPauseAll,
    this.onReacquire,
    this.onRelocate,
    super.key,
  });
  final DownloadService service;
  final AutoDownloadService? autoDownloads;
  final Future<void> Function(String)? onPause, onCancel, onStop, onReacquire;
  final Future<void> Function()? onPauseAll;
  final Future<void> Function(String, String)? onRelocate;
  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  String? _error;
  Future<void> _run(Future<void> Function() operation) async {
    try {
      await operation();
      if (mounted)
        setState(() {
          _error = null;
        });
    } on XmlyException catch (error) {
      if (mounted)
        setState(() {
          _error = error.message;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _error = '操作未完成，任务和文件已保留';
        });
    }
  }

  Future<void> _retry(DownloadTask task) async {
    if (task.state == DownloadState.completed) {
      try {
        await widget.service.retry(task.id);
        return;
      } on XmlyException catch (error) {
        if (error.code != 'confirmation_required') rethrow;
        task = widget.service.task(task.id);
      }
    }
    if (task.processingFailed) {
      await widget.service.retry(task.id);
      return;
    }
    if (task.needsConfirmation) {
      final batch = await widget.service.prepareRetry(task.id);
      if (!mounted) return;
      if (await confirmDownloadBatch(context, batch))
        await widget.service.enqueue(batch, confirmed: true);
    } else {
      await widget.service.retry(task.id);
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
          title: const Text('调整处理'),
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
                      DropdownMenuItem(value: 'skip', child: Text('同名：校验后跳过')),
                      DropdownMenuItem(
                        value: 'overwrite',
                        child: Text('同名：新文件完成后替换'),
                      ),
                      DropdownMenuItem(
                        value: 'number',
                        child: Text('同名：自动加编号'),
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
      await widget.service.reprocess(
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
        title: const Text('重新获取音频？'),
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
    if (widget.onReacquire == null)
      throw const XmlyException('integration_required', '当前界面不能重新获取源文件');
    await widget.onReacquire!(task.id);
  }

  Future<void> _relocate(DownloadTask task) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('更换目录'),
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
    if (widget.onRelocate == null)
      throw const XmlyException('integration_required', '当前界面不能更换任务目录');
    await widget.onRelocate!(task.id, directory);
  }

  Future<void> _cancel(DownloadTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消此任务？'),
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
    if (confirmed == true)
      await (widget.onCancel?.call(task.id) ?? widget.service.cancel(task.id));
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
            title: const Text('下载目录'),
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
    final path = task.finalPath;
    if (path == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除音频文件？'),
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
    if (confirmed == true) {
      await widget.onStop?.call(task.id);
      final file = File(path);
      if (await file.exists()) await file.delete();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: widget.autoDownloads?.changes,
    builder: (context, _) => StreamBuilder<void>(
      stream: widget.service.changes,
      builder: (context, _) {
        final tasks = widget.service.tasks;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: () =>
                        _run(widget.onPauseAll ?? widget.service.pauseAll),
                    icon: const Icon(Icons.pause),
                    label: const Text('全部暂停'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _run(widget.service.resumeAll),
                    icon: const Icon(Icons.download),
                    label: const Text('全部继续'),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            for (final error
                in widget.autoDownloads?.errors ?? const <String>[])
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: tasks.isEmpty
                  ? const Center(child: Text('暂无下载'))
                  : Scrollbar(
                      child: ListView.builder(
                        itemCount: tasks.length,
                        itemBuilder: (context, index) {
                          final task = tasks[index];
                          final total = task.totalBytes;
                          final progress = total == null || total <= 0
                              ? null
                              : (task.receivedBytes / total).clamp(0.0, 1.0);
                          final remaining =
                              total == null || task.bytesPerSecond <= 0
                              ? null
                              : ((total - task.receivedBytes).clamp(0, total) /
                                        task.bytesPerSecond)
                                    .ceil();
                          return Card(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 6,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    task.track.title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  Text(
                                    '${task.track.album} · ${_state(task.state)}',
                                  ),
                                  if (task.error != null)
                                    Text(
                                      task.error!,
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                      ),
                                    ),
                                  if (task.state == DownloadState.downloading ||
                                      task.state ==
                                          DownloadState.processing) ...[
                                    const SizedBox(height: 12),
                                    LinearProgressIndicator(
                                      value:
                                          task.state == DownloadState.processing
                                          ? null
                                          : progress,
                                    ),
                                  ],
                                  const SizedBox(height: 8),
                                  Text(
                                    '${_bytes(task.receivedBytes)} / ${total == null ? "未知" : _bytes(total)} · ${_bytes(task.bytesPerSecond.round())}/s${remaining == null ? "" : " · 剩余 ${remaining}s"}',
                                  ),
                                  if (task.retryAt != null)
                                    Text(
                                      '下次重试 ${task.retryAt!.toLocal().toString().split(".").first}',
                                    ),
                                  if (task.actualQuality != null)
                                    Text('实际音质：${task.actualQuality}'),
                                  if (task.warning != null)
                                    Text(
                                      task.warning!,
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .tertiary,
                                      ),
                                    ),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      if (task.active)
                                        TextButton(
                                          onPressed: () => _run(
                                            () =>
                                                widget.onPause?.call(task.id) ??
                                                widget.service.pause(task.id),
                                          ),
                                          child: const Text('暂停'),
                                        ),
                                      if (task.state == DownloadState.paused)
                                        TextButton(
                                          onPressed: () =>
                                              _run(() => _retry(task)),
                                          child: Text(
                                            task.needsConfirmation &&
                                                    !task.processingFailed
                                                ? '重新确认'
                                                : '继续',
                                          ),
                                        ),
                                      if (task.state == DownloadState.failed ||
                                          task.state ==
                                              DownloadState.awaitingDebit ||
                                          task.state ==
                                              DownloadState.completed ||
                                          task.state == DownloadState.cancelled)
                                        TextButton(
                                          onPressed: () =>
                                              _run(() => _retry(task)),
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
                                              task.state ==
                                                  DownloadState.paused ||
                                              task.state ==
                                                  DownloadState.cancelled))
                                        TextButton(
                                          onPressed: () =>
                                              _run(() => _reacquire(task)),
                                          child: const Text('重新获取音频'),
                                        ),
                                      if (task.processingFailed &&
                                          (task.state == DownloadState.failed ||
                                              task.state ==
                                                  DownloadState.paused ||
                                              task.state ==
                                                  DownloadState.cancelled))
                                        TextButton(
                                          onPressed: () => _run(
                                            () => _adjustProcessing(task),
                                          ),
                                          child: const Text('调整处理'),
                                        ),
                                      if (task.state !=
                                              DownloadState.completed &&
                                          task.state != DownloadState.cancelled)
                                        TextButton(
                                          onPressed: () =>
                                              _run(() => _cancel(task)),
                                          child: const Text('取消'),
                                        ),
                                      if (!task.active &&
                                          task.state != DownloadState.completed)
                                        TextButton(
                                          onPressed: () =>
                                              _run(() => _relocate(task)),
                                          child: const Text('更换目录'),
                                        ),
                                      TextButton(
                                        onPressed: () =>
                                            _run(() => _open(task)),
                                        child: const Text('打开目录'),
                                      ),
                                      if (widget.autoDownloads != null &&
                                          task.accountIdentity != 'anonymous' &&
                                          task.track.albumId.isNotEmpty)
                                        TextButton(
                                          onPressed: () => _run(
                                            () => setAlbumAutoDownload(
                                              context,
                                              widget.autoDownloads!,
                                              task.accountIdentity,
                                              task.track.albumId,
                                              task.track.album,
                                            ),
                                          ),
                                          child: Text(
                                            widget.autoDownloads!.enabled(
                                                  task.accountIdentity,
                                                  task.track.albumId,
                                                )
                                                ? '关闭自动下载新声音'
                                                : '自动下载新声音',
                                          ),
                                        ),
                                      if (task.finalPath != null)
                                        TextButton(
                                          onPressed: () =>
                                              _run(() => _delete(task)),
                                          child: const Text('删除音频'),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    ),
  );
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
