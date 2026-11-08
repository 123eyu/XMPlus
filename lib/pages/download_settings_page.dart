import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../common/widgets/adaptive_text.dart';
import '../services/app_runtime.dart';

class DownloadSettingsPage extends StatefulWidget {
  const DownloadSettingsPage({required this.runtime, super.key});
  final AppRuntime runtime;
  @override
  State<DownloadSettingsPage> createState() => _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends State<DownloadSettingsPage> {
  String? _error;
  bool _saving = false;
  Map get _settings =>
      (widget.runtime.storage.state['settings'] as Map)['download'] as Map? ??
      const {};

  Future<void> _set(String key, Object value) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.runtime.storage.transaction((state) {
        final settings = state['settings'] as Map;
        final download =
            settings.putIfAbsent('download', () => <String, dynamic>{}) as Map;
        download[key] = value;
      });
      widget.runtime.changed();
    } catch (_) {
      if (mounted)
        setState(() {
          _error = '设置保存失败，原值已保留';
        });
    } finally {
      if (mounted)
        setState(() {
          _saving = false;
        });
    }
  }

  Future<void> _directory() async {
    final directory = await FilePicker.getDirectoryPath(dialogTitle: '选择下载目录');
    if (directory != null) await _set('rootDirectory', directory);
  }

  Widget _number(
    String key,
    String title,
    int fallback,
    int minimum,
    int maximum,
  ) => TextFormField(
    key: ValueKey('$key:${_settings[key] ?? fallback}'),
    initialValue: '${_settings[key] ?? fallback}',
    enabled: !_saving,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(
      labelText: title,
      helperText: '$minimum–$maximum',
      errorMaxLines: 3,
    ),
    autovalidateMode: AutovalidateMode.onUserInteraction,
    validator: (text) {
      final value = int.tryParse(text ?? '');
      return value == null || value < minimum || value > maximum
          ? '请输入 $minimum–$maximum 的整数'
          : null;
    },
    onFieldSubmitted: (text) {
      final value = int.tryParse(text);
      if (value != null && value >= minimum && value <= maximum)
        _set(key, value);
    },
  );

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
        ),
        children: [
          AdaptiveText('下载', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          if (_saving) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const Text('下载目录'),
          const SizedBox(height: 8),
          SelectableText(
            _settings['rootDirectory'] as String? ?? '首次下载时使用系统下载目录',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _saving ? null : _directory,
              icon: const Icon(Icons.folder_open),
              label: const Text('选择目录'),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('按专辑建立文件夹'),
            value: _settings['albumFolders'] as bool? ?? true,
            onChanged: _saving ? null : (value) => _set('albumFolders', value),
          ),
          _number('parallelism', '同时下载数量', 3, 1, 6),
          const SizedBox(height: 16),
          _number('retryLimit', '限流重试上限', 3, 0, 1000),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('限流后至少等待 5 分钟；0 表示不自动重试。'),
          ),
          _number('minimumFreeMiB', '最低剩余空间（MiB）', 512, 512, 1048576),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _settings['quality'] as String? ?? 'auto',
            isExpanded: true,
            decoration: const InputDecoration(labelText: '音质'),
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('自动')),
              DropdownMenuItem(value: 'mp3_64', child: Text('MP3 64 kbps')),
              DropdownMenuItem(value: 'mp3_32', child: Text('MP3 32 kbps')),
              DropdownMenuItem(value: 'm4a_64', child: Text('M4A 64 kbps')),
              DropdownMenuItem(value: 'm4a_24', child: Text('M4A 24 kbps')),
            ],
            onChanged: _saving
                ? null
                : (value) {
                    if (value != null) _set('quality', value);
                  },
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: ValueKey(_settings['filenamePattern']),
            initialValue:
                _settings['filenamePattern'] as String? ??
                '{index} - {title} [{trackId}]',
            enabled: !_saving,
            decoration: const InputDecoration(
              labelText: '文件名格式',
              helperText: '{index} {title} {trackId} {album} {albumId}',
              helperMaxLines: 2,
            ),
            onFieldSubmitted: (value) {
              final tokens = RegExp(r'\{([^{}]+)\}')
                  .allMatches(value)
                  .map((match) => match[1]!);
              if (value.trim().isEmpty ||
                  tokens.any(
                    (token) => !const {
                      'index',
                      'title',
                      'trackId',
                      'album',
                      'albumId',
                    }.contains(token),
                  ) ||
                  value
                      .replaceAll(RegExp(r'\{[^{}]+\}'), '')
                      .contains(RegExp(r'[{}]'))) {
                setState(() {
                  _error = '文件名格式包含无效变量';
                });
              } else {
                _set('filenamePattern', value);
              }
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _settings['conflict'] as String? ?? 'skip',
            isExpanded: true,
            decoration: const InputDecoration(labelText: '同名文件'),
            items: const [
              DropdownMenuItem(value: 'skip', child: Text('校验后跳过')),
              DropdownMenuItem(value: 'overwrite', child: Text('新文件完成后替换')),
              DropdownMenuItem(value: 'number', child: Text('自动加编号')),
            ],
            onChanged: _saving
                ? null
                : (value) {
                    if (value != null) _set('conflict', value);
                  },
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('暂停播放时同步暂停下载'),
            value: _settings['pauseDownloadWithPlayback'] as bool? ?? false,
            onChanged: _saving
                ? null
                : (value) => _set('pauseDownloadWithPlayback', value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('定时结束后继续下载'),
            value: _settings['continueDownloadAfterSleep'] as bool? ?? false,
            onChanged: _saving
                ? null
                : (value) => _set('continueDownloadAfterSleep', value),
          ),
        ],
      ),
    ),
  );
}
