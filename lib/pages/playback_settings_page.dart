import 'package:flutter/material.dart';

import '../services/app_runtime.dart';
import '../services/playback_policy.dart';

/// Commit first: a failed disk write must not change the live playback policy.
Future<void> persistPlaybackSetting(AppRuntime runtime, String key, Object? value,
    {String? albumId}) async {
  await runtime.storage.transaction((state) {
    final settings = state['settings'] as Map;
    final global = settings.putIfAbsent('playback', () => <String, dynamic>{}) as Map;
    Map target = global;
    if (albumId != null) {
      final overrides = settings.putIfAbsent('albumOverrides', () => <String, dynamic>{}) as Map;
      target = overrides.putIfAbsent(albumId, () => <String, dynamic>{}) as Map;
    }
    if (value == null) { target.remove(key); } else { target[key] = value; }
    PlaybackSettings.resolve(global, albumId == null ? const {} : target);
    if (key == 'syncHistory' && value is! bool) throw const FormatException('同步设置无效');
  });
  await runtime.player.applySettings();
  runtime.changed();
}

class PlaybackSettingsPage extends StatefulWidget {
  const PlaybackSettingsPage({required this.runtime, this.albumId, this.albumTitle, this.embedded = false, super.key});
  final AppRuntime runtime;
  final String? albumId, albumTitle;
  final bool embedded;

  @override
  State<PlaybackSettingsPage> createState() => _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  bool _busy = false;
  String? _error;

  Map get _settings => widget.runtime.storage.state['settings'] as Map;
  Map get _global => _settings['playback'] as Map? ?? const {};
  Map get _album => (_settings['albumOverrides'] as Map?)?[widget.albumId] as Map? ?? const {};
  String _source(String key) => widget.albumId == null ? '全局设置' : _album.containsKey(key) ? '专辑设置' : '继承全局';

  Future<void> _save(String key, Object? value) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await persistPlaybackSetting(widget.runtime, key, value, albumId: widget.albumId);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '设置保存或应用失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _inherit(String key) => widget.albumId != null && _album.containsKey(key)
      ? TextButton(key: ValueKey('inherit:$key'), onPressed: _busy ? null : () => _save(key, null),
          child: const Text('恢复继承全局')) : const SizedBox.shrink();

  Widget _number(String key, String title, num value, num min, num max, {bool decimal = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(title: Text(title), subtitle: Text('${_source(key)} · $min–$max'),
        trailing: SizedBox(width: 140, child: TextFormField(
          key: ValueKey('$key:$value:$_busy'), initialValue: '$value', enabled: !_busy,
          keyboardType: TextInputType.numberWithOptions(decimal: decimal),
          decoration: InputDecoration(suffixText: key == 'speed' ? '倍' : key == 'volume' ? '%' : '秒'),
          onFieldSubmitted: (text) {
            final parsed = decimal ? double.tryParse(text) : int.tryParse(text);
            if (parsed == null || !parsed.isFinite || parsed < min || parsed > max) {
              setState(() => _error = '$title请输入 $min–$max');
              return;
            }
            _save(key, parsed);
          },
        )),
      ),
      Padding(padding: const EdgeInsets.only(left: 16), child: _inherit(key)),
    ],
  );

  Widget _toggle(String key, String title, bool value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile(key: ValueKey(key), title: Text(title), subtitle: Text(_source(key)),
        value: value, onChanged: _busy ? null : (value) => _save(key, value)),
      Padding(padding: const EdgeInsets.only(left: 16), child: _inherit(key)),
    ],
  );

  Future<void> _sync(bool value) async {
    if (value) {
      final allowed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('同步收听历史？'),
        content: const Text('开启后会读取并写入当前账号的喜马拉雅收听历史。本地文件播放也会同步实际进度。'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('开启同步'))],
      ));
      if (allowed != true || !mounted) return;
    }
    await _save('syncHistory', value);
  }

  Future<void> _downloadOption(String key, bool value) async {
    setState(() { _busy = true; _error = null; });
    try {
      await widget.runtime.storage.transaction((state) {
        final download = (state['settings'] as Map).putIfAbsent('download', () => <String, dynamic>{}) as Map;
        download[key] = value;
      });
      widget.runtime.changed();
    } catch (_) {
      if (mounted) setState(() => _error = '设置保存失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = ListenableBuilder(listenable: widget.runtime, builder: (context, _) {
      PlaybackSettings resolved;
      try { resolved = PlaybackSettings.resolve(_global, widget.albumId == null ? const {} : _album); }
      on FormatException catch (error) { return Center(child: Text('播放设置无效：${error.message}')); }
      final download = _settings['download'] as Map? ?? const {};
      final body = ListView(padding: const EdgeInsets.all(16), children: [
        Text(widget.albumTitle ?? (widget.albumId == null ? '播放' : '专辑播放设置'),
          style: Theme.of(context).textTheme.titleLarge),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!, key: const ValueKey('playbackError'),
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const Padding(padding: EdgeInsets.all(16), child: Text('数值修改后按回车保存')),
        _number('speed', '播放倍速', resolved.speed, 0.5, 3.0, decimal: true),
        _number('volume', '音量', resolved.volume, 0, 100, decimal: true),
        _number('skipIntroSeconds', '跳过片头', resolved.skipIntroSeconds, 0, 3600),
        _number('skipOutroSeconds', '跳过片尾', resolved.skipOutroSeconds, 0, 3600),
        _number('seekBackwardSeconds', '后退间隔', resolved.seekBackwardSeconds, 1, 300),
        _number('seekForwardSeconds', '前进间隔', resolved.seekForwardSeconds, 1, 300),
        _toggle('autoNext', '自动播放下一集', resolved.autoNext),
        _toggle('listenAndDownload', '默认边听边下', resolved.listenAndDownload),
        ListTile(title: const Text('循环方式'), subtitle: Text(_source('loopMode')),
          trailing: DropdownButton<String>(key: const ValueKey('loopMode'), value: resolved.loopMode,
            items: const [DropdownMenuItem(value: 'off', child: Text('顺序播放')),
              DropdownMenuItem(value: 'single', child: Text('单集循环'))],
            onChanged: _busy ? null : (value) { if (value != null) _save('loopMode', value); })),
        _inherit('loopMode'),
        if (widget.albumId == null) ...[
          const Divider(),
          SwitchListTile(key: const ValueKey('syncHistory'), title: const Text('同步云端收听历史'),
            value: _global['syncHistory'] == true, onChanged: _busy ? null : _sync),
          ListTile(title: const Text('重试历史同步'), trailing: const Icon(Icons.sync),
            onTap: _busy ? null : () async {
              try { await widget.runtime.player.retryHistory(); }
              catch (_) { if (mounted) setState(() => _error = '历史同步失败，进度已保留'); }
            }),
          SwitchListTile(title: const Text('暂停播放时也暂停当前下载'),
            value: download['pauseDownloadWithPlayback'] == true,
            onChanged: _busy ? null : (value) => _downloadOption('pauseDownloadWithPlayback', value)),
          SwitchListTile(title: const Text('定时结束后继续下载'),
            value: download['continueDownloadAfterSleep'] == true,
            onChanged: _busy ? null : (value) => _downloadOption('continueDownloadAfterSleep', value)),
          ListTile(title: const Text('定时关闭偏好'), trailing: const Icon(Icons.timer_outlined),
            onTap: _busy ? null : () => showSleepTimerDialog(context, widget.runtime, startTimer: false)),
        ],
      ]);
      return body;
    });
    return widget.embedded ? content : Scaffold(appBar: AppBar(title: const Text('播放设置')), body: content);
  }
}

Future<void> showSleepTimerDialog(BuildContext context, AppRuntime runtime, {bool startTimer = true}) =>
    showDialog<void>(context: context, builder: (_) => _SleepTimerDialog(runtime: runtime, startTimer: startTimer));

class _SleepTimerDialog extends StatefulWidget {
  const _SleepTimerDialog({required this.runtime, required this.startTimer});
  final AppRuntime runtime;
  final bool startTimer;
  @override
  State<_SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<_SleepTimerDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _minutes;
  late SleepMode _mode;
  late SleepAction _action;
  late bool _wait;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final stored = (widget.runtime.storage.state['settings'] as Map)['sleep'];
    SleepRequest request;
    try { request = SleepRequest.fromJson(stored is Map ? stored : const {}); }
    on FormatException { request = SleepRequest(); }
    _minutes = TextEditingController(text: '${request.minutes}');
    _mode = request.mode; _action = request.action; _wait = request.waitForEnd;
  }

  @override
  void dispose() { _minutes.dispose(); super.dispose(); }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      final request = SleepRequest(mode: _mode, action: _action,
        minutes: int.parse(_minutes.text), waitForEnd: _wait);
      await widget.runtime.storage.transaction((state) => (state['settings'] as Map)['sleep'] = request.toJson());
      if (widget.startTimer) widget.runtime.player.setSleep(request);
      widget.runtime.changed();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() { _saving = false; _error = '定时设置保存失败'; });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.startTimer ? '定时关闭' : '定时关闭偏好'),
    content: SizedBox(width: 380, child: Form(key: _form, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, children: [
        if (_error != null) Text(_error!),
        DropdownButtonFormField<SleepMode>(initialValue: _mode, decoration: const InputDecoration(labelText: '结束时间'),
          items: const [DropdownMenuItem(value: SleepMode.afterDuration, child: Text('倒计时')),
            DropdownMenuItem(value: SleepMode.endOfTrack, child: Text('本集结束'))],
          onChanged: _saving ? null : (value) { if (value != null) setState(() => _mode = value); }),
        if (_mode == SleepMode.afterDuration) ...[
          Wrap(spacing: 6, children: [for (final minutes in [15, 30, 45, 60])
            ActionChip(label: Text('$minutes 分钟'), onPressed: _saving ? null : () => setState(() => _minutes.text = '$minutes'))]),
          TextFormField(key: const ValueKey('sleepMinutes'), controller: _minutes, enabled: !_saving,
            decoration: const InputDecoration(labelText: '自定义分钟（1–1440）'), keyboardType: TextInputType.number,
            validator: (text) { final n = int.tryParse(text ?? ''); return n == null || n < 1 || n > 1440 ? '请输入 1–1440 分钟' : null; }),
          CheckboxListTile(contentPadding: EdgeInsets.zero, title: const Text('到时等待本集结束'), value: _wait,
            onChanged: _saving ? null : (value) => setState(() => _wait = value == true)),
        ],
        DropdownButtonFormField<SleepAction>(initialValue: _action, decoration: const InputDecoration(labelText: '结束动作'),
          items: const [DropdownMenuItem(value: SleepAction.pause, child: Text('暂停')),
            DropdownMenuItem(value: SleepAction.exit, child: Text('保存并退出应用'))],
          onChanged: _saving ? null : (value) { if (value != null) setState(() => _action = value); }),
      ],
    )))),
    actions: [TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(key: const ValueKey('saveSleep'), onPressed: _saving ? null : _save,
        child: Text(widget.startTimer ? '开始' : '保存'))],
  );
}
