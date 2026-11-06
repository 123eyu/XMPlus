import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import '../services/media_processor.dart';

class MediaSettingsPage extends StatefulWidget {
  const MediaSettingsPage({required this.runtime, super.key});
  final AppRuntime runtime;

  @override
  State<MediaSettingsPage> createState() => _MediaSettingsPageState();
}

class _MediaSettingsPageState extends State<MediaSettingsPage> {
  static const _formats = {
    'original': '原格式',
    'mp3': 'MP3',
    'm4a': 'M4A',
    'm4b': 'M4B',
    'flac': 'FLAC',
  };
  static const _bitrates = [32, 64, 96, 128, 192];
  final _form = GlobalKey<FormState>();
  final _ffmpeg = TextEditingController();
  final _ffprobe = TextEditingController();
  String _format = 'original';
  int _bitrate = 64;
  bool _tags = true, _cover = false, _busy = false;
  String? _error, _status;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final settings = widget.runtime.storage.state['settings'] as Map;
    final media = settings['media'] is Map
        ? settings['media'] as Map
        : const {};
    final tags = settings['tags'] is Map ? settings['tags'] as Map : const {};
    _format = _formats.containsKey(media['format'])
        ? media['format'] as String
        : 'original';
    _bitrate = _bitrates.contains(media['bitrateKbps'])
        ? media['bitrateKbps'] as int
        : 64;
    _tags = tags['enabled'] is bool ? tags['enabled'] as bool : true;
    _cover = tags['cover'] is bool ? tags['cover'] as bool : false;
    _ffmpeg.text = !Platform.isAndroid && media['ffmpegPath'] is String
        ? media['ffmpegPath'] as String
        : '';
    _ffprobe.text = !Platform.isAndroid && media['ffprobePath'] is String
        ? media['ffprobePath'] as String
        : '';
  }

  @override
  void dispose() {
    _ffmpeg.dispose();
    _ffprobe.dispose();
    super.dispose();
  }

  String? _pathError(String? text) {
    final value = (text ?? '').trim();
    if (value.isEmpty) return null;
    if (!p.isAbsolute(value) || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      return '请输入本地可执行文件的绝对路径';
    }
    return null;
  }

  Future<void> _validateFiles() async {
    if (Platform.isAndroid) return;
    for (final entry in {
      'FFmpeg': _ffmpeg.text.trim(),
      'FFprobe': _ffprobe.text.trim(),
    }.entries) {
      final error = _pathError(entry.value);
      if (error != null) throw FormatException(error);
      if (entry.value.isNotEmpty && !await File(entry.value).exists()) {
        throw FormatException('${entry.key} 文件不存在');
      }
    }
  }

  Future<void> _pick(TextEditingController controller, String name) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final file = await FilePicker.pickFile(dialogTitle: '选择 $name');
      if (!mounted || file == null) return;
      if (file.path == null) throw const FormatException('请选择本地文件');
      controller.text = file.path!;
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法选择文件，请手动填写路径');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkTools() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      await _validateFiles();
      await MediaProcessor(
        ffmpegPath: _ffmpeg.text.trim().isEmpty ? null : _ffmpeg.text.trim(),
        ffprobePath: _ffprobe.text.trim().isEmpty ? null : _ffprobe.text.trim(),
      ).checkTools();
      if (mounted) setState(() => _status = '工具版本检查通过');
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on XmlyException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '工具检查失败，请检查路径和执行权限');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    var writing = false;
    try {
      if (!_formats.containsKey(_format) || !_bitrates.contains(_bitrate)) {
        throw const FormatException('格式或码率无效');
      }
      await _validateFiles();
      writing = true;
      await widget.runtime.storage.transaction((state) {
        final settings = state['settings'] as Map;
        final media =
            settings.putIfAbsent('media', () => <String, dynamic>{}) as Map;
        media['format'] = _format;
        media['bitrateKbps'] = _bitrate;
        for (final entry in {
          'ffmpegPath': _ffmpeg.text.trim(),
          'ffprobePath': _ffprobe.text.trim(),
        }.entries) {
          if (Platform.isAndroid || entry.value.isEmpty) {
            media.remove(entry.key);
          } else {
            media[entry.key] = entry.value;
          }
        }
        final tags =
            settings.putIfAbsent('tags', () => <String, dynamic>{}) as Map;
        tags['enabled'] = _tags;
        tags['cover'] = _cover;
      });
      widget.runtime.changed();
      if (mounted) setState(() => _status = '已保存');
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted)
        setState(() {
          if (writing) _reload();
          _error = '设置保存失败，原值已保留';
        });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _toolField(String name, TextEditingController controller) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            key: ValueKey('${name.toLowerCase()}Path'),
            controller: controller,
            enabled: !_busy,
            validator: _pathError,
            decoration: InputDecoration(
              labelText: '$name 路径',
              hintText: '留空使用随附工具',
            ),
            onChanged: (_) => setState(() {
              _error = null;
              _status = null;
            }),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: '选择 $name',
          onPressed: _busy ? null : () => _pick(controller, name),
          icon: const Icon(Icons.folder_open),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('媒体处理', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            key: const ValueKey('mediaError'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_status != null) Text(_status!, key: const ValueKey('mediaStatus')),
        DropdownButtonFormField<String>(
          key: ValueKey('format:$_format'),
          initialValue: _format,
          decoration: const InputDecoration(labelText: '输出格式'),
          items: _formats.entries
              .map(
                (entry) => DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value),
                ),
              )
              .toList(),
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null)
                    setState(() {
                      _format = value;
                      _status = null;
                    });
                },
        ),
        if (const {'mp3', 'm4a', 'm4b'}.contains(_format)) ...[
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            key: ValueKey('bitrate:$_bitrate'),
            initialValue: _bitrate,
            decoration: const InputDecoration(labelText: '码率'),
            items: _bitrates
                .map(
                  (value) => DropdownMenuItem(
                    value: value,
                    child: Text('$value kbps'),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null)
                      setState(() {
                        _bitrate = value;
                        _status = null;
                      });
                  },
          ),
        ],
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('写入标签'),
          value: _tags,
          onChanged: _busy
              ? null
              : (value) => setState(() {
                  _tags = value;
                  _status = null;
                }),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('嵌入封面'),
          value: _cover,
          onChanged: _busy
              ? null
              : (value) => setState(() {
                  _cover = value;
                  _status = null;
                }),
        ),
        if (Platform.isAndroid)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('Android 使用安装包随附的 FFmpeg / FFprobe，无需设置桌面工具路径。'),
          )
        else ...[
          _toolField('FFmpeg', _ffmpeg),
          _toolField('FFprobe', _ffprobe),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: const ValueKey('checkMediaTools'),
            onPressed: _busy ? null : _checkTools,
            child: const Text('检查工具版本'),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              key: const ValueKey('saveMedia'),
              onPressed: _busy ? null : _save,
              child: const Text('保存'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _form.currentState!.reset();
                      _reload();
                      _error = null;
                      _status = null;
                    }),
              child: const Text('取消'),
            ),
          ],
        ),
      ],
    ),
  );
}

class AlbumTagsPage extends StatefulWidget {
  const AlbumTagsPage({
    required this.runtime,
    required this.albumId,
    required this.albumTitle,
    super.key,
  });
  final AppRuntime runtime;
  final String albumId, albumTitle;

  @override
  State<AlbumTagsPage> createState() => _AlbumTagsPageState();
}

class _AlbumTagsPageState extends State<AlbumTagsPage> {
  static const _fields = {
    'titlePrefix': '标题前缀',
    'album': '专辑名',
    'artist': '主播',
    'genre': '类型',
    'description': '简介',
  };
  final _form = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _overridden = <String>{};
  final _changed = <String>{};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings = widget.runtime.storage.state['settings'] as Map;
    final albums = settings['albumTags'];
    final saved = albums is Map && albums[widget.albumId] is Map
        ? albums[widget.albumId] as Map
        : const {};
    for (final key in _fields.keys) {
      final value = saved[key];
      _controllers[key] = TextEditingController(
        text: value is String ? value : '',
      );
      if (value is String) _overridden.add(key);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _reset(String key) {
    _controllers[key]!.clear();
    _overridden.remove(key);
    _changed.add(key);
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    if (widget.albumId.trim().isEmpty) {
      setState(() => _error = '专辑标识无效');
      return;
    }
    if (_changed.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.runtime.storage.transaction((state) {
        final settings = state['settings'] as Map;
        final albums =
            settings.putIfAbsent('albumTags', () => <String, dynamic>{}) as Map;
        final values = albums.putIfAbsent(
          widget.albumId,
          () => <String, dynamic>{},
        ) as Map;
        for (final key in _changed) {
          if (_overridden.contains(key)) {
            values[key] = _controllers[key]!.text;
          } else {
            values.remove(key);
          }
        }
        if (values.isEmpty) albums.remove(widget.albumId);
      });
      widget.runtime.changed();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = '标签保存失败，原值已保留');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      appBar: AppBar(title: Text(widget.albumTitle)),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_saving) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            for (final entry in _fields.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: TextFormField(
                  key: ValueKey('albumTag:${entry.key}'),
                  controller: _controllers[entry.key],
                  enabled: !_saving,
                  minLines: 1,
                  maxLines: entry.key == 'description' ? 5 : 1,
                  decoration: InputDecoration(
                    labelText: entry.value,
                    helperText: _overridden.contains(entry.key)
                        ? '已覆盖'
                        : '使用原标签',
                    suffixIcon: IconButton(
                      tooltip: '重置${entry.value}',
                      onPressed: _saving
                          ? null
                          : () => setState(() => _reset(entry.key)),
                      icon: const Icon(Icons.restart_alt),
                    ),
                  ),
                  validator: (value) =>
                      (value ?? '').contains('\u0000') ? '不能包含空字符' : null,
                  onChanged: (_) => setState(() {
                    _overridden.add(entry.key);
                    _changed.add(entry.key);
                  }),
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  key: const ValueKey('saveAlbumTags'),
                  onPressed: _saving ? null : _save,
                  child: const Text('保存'),
                ),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          for (final key in _fields.keys) {
                            _reset(key);
                          }
                        }),
                  child: const Text('全部重置'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
