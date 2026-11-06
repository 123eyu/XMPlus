import 'package:flutter/material.dart';

import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import 'playback_settings_page.dart';

String playbackTime(double seconds) {
  final total = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final hours = total ~/ 3600;
  final minutes = (total ~/ 60) % 60;
  final rest = (total % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:${minutes.toString().padLeft(2, '0')}:$rest' : '$minutes:$rest';
}

class PlayerPanel extends StatefulWidget {
  const PlayerPanel({required this.runtime, this.expanded = false, super.key});
  final AppRuntime runtime;
  final bool expanded;

  @override
  State<PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends State<PlayerPanel> {
  bool _busy = false;
  double? _dragPosition;
  double? _speedDraft, _volumeDraft;
  String? _error;
  AppRuntime get _runtime => widget.runtime;

  Future<void> _act(Future<void> Function() command) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try { await command(); }
    on XmlyException catch (error) { if (mounted) setState(() => _error = error.message); }
    catch (_) { if (mounted) setState(() => _error = '操作未完成，请重试'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _setting(String key, Object value) => _act(() => persistPlaybackSetting(
    _runtime, key, value, albumId: _runtime.player.current?.albumId.isNotEmpty == true ? _runtime.player.current!.albumId : null));

  void _expand() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Scaffold(
    appBar: AppBar(title: const Text('正在收听')),
    body: PlayerPanel(runtime: _runtime, expanded: true),
  )));

  Future<bool> _confirm(BuildContext context, String title) async => await showDialog<bool>(
    context: context, builder: (context) => AlertDialog(title: Text(title), actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
    ])) == true;

  Future<void> _queue() async {
    await showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true,
      builder: (context) => FractionallySizedBox(heightFactor: 0.8,
        child: ListenableBuilder(listenable: _runtime, builder: (context, _) {
          final player = _runtime.player;
          Future<void> run(Future<void> Function() command) async {
            try { await command(); }
            catch (_) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('队列操作失败'))); }
          }
          return Column(children: [
            ListTile(title: Text('播放队列 · ${player.queue.length} 集'), trailing: TextButton(
              onPressed: player.queue.isEmpty ? null : () async {
                if (await _confirm(context, '清空播放队列？')) await run(player.clearQueue);
              }, child: const Text('清空'))),
            ListTile(dense: true, title: Text(player.queueSourceLabel),
              subtitle: Text(player.queueOrderLabel)),
            if (player.queueSource == 'album' && player.sourceAlbumId.isNotEmpty) ListTile(dense: true, title: const Text('专辑更新'),
              trailing: TextButton(onPressed: () => run(() => player.refreshAlbumTail(player.sourceAlbumId)),
                child: const Text('检查更新'))),
            if (player.queue.isEmpty) const Expanded(child: Center(child: Text('队列为空')))
            else Expanded(child: ReorderableListView.builder(
              itemCount: player.queue.length,
              onReorderItem: (from, to) => run(() => player.moveQueueItem(from, to)),
              itemBuilder: (context, index) {
                final track = player.queue[index];
                return ListTile(key: ValueKey('queue:$index:${track.id}'),
                  leading: Icon(index == player.cursor ? Icons.graphic_eq : Icons.drag_handle),
                  title: Text(track.title.isEmpty ? track.id : track.title),
                  subtitle: Text(track.album),
                  onTap: () => run(() => player.playQueueItem(index)),
                  trailing: IconButton(tooltip: '移出队列', icon: const Icon(Icons.close),
                    onPressed: () => run(() => player.removeQueueItem(index))));
              },
            )),
          ]);
        }),
      ));
  }

  Widget _button(String tooltip, IconData icon, Future<void> Function()? command) => IconButton(
    tooltip: tooltip, onPressed: _busy || command == null ? null : () => _act(command), icon: Icon(icon));

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _runtime, builder: (context, _) {
    final player = _runtime.player;
    final track = player.current;
    final title = track == null ? '尚未选择声音' : track.title.isEmpty ? track.id : track.title;
    final max = player.duration.isFinite && player.duration > 0 ? player.duration : 0.0;
    final position = (_dragPosition ?? player.position).clamp(0.0, max).toDouble();
    final favorites = (((_runtime.storage.state['library'] as Map)[player.libraryIdentity] as Map?)?['favorites'] as Map?) ?? const {};
    final favorite = track != null && favorites.containsKey(track.id);
    final settings = player.effectiveSettings;
    final message = _error ?? player.error ?? player.warning ?? player.status;
    final controls = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _button('上一集', Icons.skip_previous, track == null ? null : player.previous),
      if (widget.expanded) _button('后退 ${settings.seekBackwardSeconds} 秒', Icons.replay, track == null ? null : player.seekBackward),
      _button(player.playing ? '暂停' : '播放', player.playing ? Icons.pause_circle : Icons.play_circle,
        track == null ? null : player.playing ? player.pause : player.resume),
      if (widget.expanded) _button('前进 ${settings.seekForwardSeconds} 秒', Icons.forward_30, track == null ? null : player.seekForward),
      _button('下一集', Icons.skip_next, track == null ? null : player.next),
    ]);
    if (!widget.expanded) return Material(color: Theme.of(context).colorScheme.surfaceContainer, child: Column(
      mainAxisSize: MainAxisSize.min, children: [
        if (_busy || player.buffering) const LinearProgressIndicator(minHeight: 2),
        Row(children: [
          Expanded(child: ListTile(dense: true, title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(message ?? (track?.album ?? '')), onTap: _expand)),
          controls,
          IconButton(tooltip: '播放队列', onPressed: _queue, icon: const Icon(Icons.queue_music)),
          IconButton(tooltip: '展开播放器', onPressed: _expand, icon: const Icon(Icons.expand_less)),
        ]),
      ],
    ));
    return SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(children: [
      if (_busy || player.buffering) const LinearProgressIndicator(),
      if (track?.coverUrl != null) Padding(padding: const EdgeInsets.only(bottom: 16), child: Image.network(
        track!.coverUrl.toString(), width: 200, height: 200, fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const Icon(Icons.album_outlined, size: 120))),
      Text(title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
      if (track != null) Text([track.album, track.artist].where((text) => text.isNotEmpty).join(' · ')),
      Text(switch (player.sourceKind) { 'local' => '本地文件', 'prepaid' => '边听边下', 'online' => '在线播放', _ => '未开始播放' }),
      Text('${player.queueSourceLabel} · ${player.queueOrderLabel}'),
      if (message != null) Padding(padding: const EdgeInsets.all(12), child: Text(message, key: const ValueKey('playerMessage'))),
      Slider(value: position, max: max > 0 ? max : 1, label: playbackTime(position),
        onChanged: track == null || max == 0 || _busy ? null : (value) => setState(() => _dragPosition = value),
        onChangeEnd: track == null || max == 0 || _busy ? null : (value) async {
          await _act(() => player.seek(value));
          if (mounted) setState(() => _dragPosition = null);
        }),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(playbackTime(position)), Text(playbackTime(max))]),
      controls,
      Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
        _button('从头重听', Icons.replay_circle_filled, track == null ? null : player.replay),
        _button(favorite ? '取消收藏' : '收藏', favorite ? Icons.favorite : Icons.favorite_border,
          track == null ? null : () async {
            if (!favorite || await _confirm(context, '取消收藏此声音？')) await player.toggleFavorite();
          }),
        _button('添加书签', Icons.bookmark_add_outlined, track == null ? null : player.bookmark),
        IconButton(tooltip: '播放队列', onPressed: _queue, icon: const Icon(Icons.queue_music)),
        IconButton(tooltip: settings.loopMode == 'single' ? '关闭单集循环' : '单集循环',
          isSelected: settings.loopMode == 'single', icon: const Icon(Icons.repeat_one),
          onPressed: _busy ? null : () => _setting('loopMode', settings.loopMode == 'single' ? 'off' : 'single')),
        IconButton(tooltip: '定时关闭', onPressed: () => showSleepTimerDialog(context, _runtime), icon: const Icon(Icons.timer_outlined)),
      ]),
      if (player.policy.sleepRequest != null) ListTile(
        title: Text(player.policy.sleepWaitingForEnd ? '定时已到，等待本集结束' :
          player.policy.remainingDuration == null ? '本集结束后${player.policy.sleepRequest!.action.name == 'exit' ? '退出' : '暂停'}' :
            '定时剩余 ${playbackTime(player.policy.remainingDuration!.inSeconds.toDouble())}'),
        trailing: TextButton(onPressed: () { player.cancelSleep(); _runtime.changed(); }, child: const Text('取消定时'))),
      ListTile(title: Text('倍速 ${(_speedDraft ?? settings.speed).toStringAsFixed(2)}×'),
        subtitle: Slider(value: _speedDraft ?? settings.speed, min: 0.5, max: 3, divisions: 25,
          label: '${_speedDraft ?? settings.speed}×',
          onChanged: _busy ? null : (value) => setState(() => _speedDraft = value),
          onChangeEnd: _busy ? null : (value) async {
            await _setting('speed', double.parse(value.toStringAsFixed(1)));
            if (mounted) setState(() => _speedDraft = null);
          })),
      ListTile(leading: const Icon(Icons.volume_up), title: Text('音量 ${(_volumeDraft ?? settings.volume).round()}%'),
        subtitle: Slider(value: _volumeDraft ?? settings.volume, max: 100, divisions: 100,
          onChanged: _busy ? null : (value) => setState(() => _volumeDraft = value),
          onChangeEnd: _busy ? null : (value) async {
            await _setting('volume', value);
            if (mounted) setState(() => _volumeDraft = null);
          })),
      SwitchListTile(title: const Text('边听边下'), value: settings.listenAndDownload,
        onChanged: _busy ? null : (value) => _setting('listenAndDownload', value)),
      if (track != null) Wrap(spacing: 8, children: [
        if (player.sourceKind != 'online') TextButton.icon(icon: const Icon(Icons.cloud_outlined), label: const Text('在线播放'),
          onPressed: _busy ? null : () => _act(player.switchToOnline)),
        if (player.sourceKind != 'local' && _runtime.downloads.tasks.any((task) => task.track.id == track.id &&
            task.accountIdentity == player.libraryIdentity && task.state.name == 'completed'))
          TextButton.icon(icon: const Icon(Icons.folder_outlined), label: const Text('切换本地文件'),
            onPressed: _busy ? null : () => _act(player.switchToLocal)),
      ]),
      TextButton.icon(icon: const Icon(Icons.settings_outlined), label: const Text('播放设置'), onPressed: () =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlaybackSettingsPage(runtime: _runtime,
          albumId: track?.albumId.isNotEmpty == true ? track!.albumId : null, albumTitle: track?.album)))),
    ]));
  });
}
