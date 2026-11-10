import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/app_runtime.dart';

class PlaybackVolumeControl extends StatefulWidget {
  const PlaybackVolumeControl({required this.runtime, super.key});

  final AppRuntime runtime;

  @override
  State<PlaybackVolumeControl> createState() => _PlaybackVolumeControlState();
}

class _PlaybackVolumeControlState extends State<PlaybackVolumeControl> {
  bool _saving = false;
  double? _draft;
  String? _error;

  String _label(double value) => '${value.round()}%';

  Future<void> _save(double value) async {
    if (!mounted || _saving) return;
    setState(() {
      _saving = true;
      _draft = value;
      _error = null;
    });
    try {
      await widget.runtime.player.setMasterVolume(value);
      widget.runtime.changed();
    } catch (_) {
      if (mounted) setState(() => _error = '主音量保存或应用失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _draft = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.runtime,
    builder: (context, _) {
      final current =
          _draft ?? widget.runtime.player.effectiveSettings.masterVolume;
      final theme = Theme.of(context);
      return MenuAnchor(
        consumeOutsideTap: true,
        onClose: () {
          if (mounted && !_saving && _draft != null) {
            setState(() => _draft = null);
          }
        },
        menuChildren: [
          SizedBox(
            width: math.min(340, MediaQuery.sizeOf(context).width - 32),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 12,
                    children: [
                      Text('主音量 · 所有专辑', style: theme.textTheme.labelLarge),
                      Text(_label(current), style: theme.textTheme.labelLarge),
                    ],
                  ),
                  Slider(
                    key: const ValueKey('playbackVolumeSlider'),
                    autofocus: true,
                    value: current,
                    min: 0,
                    max: 100,
                    divisions: 100,
                    label: _label(current),
                    semanticFormatterCallback: (value) =>
                        '主音量 ${_label(value)}',
                    // Disabling a focused slider drops keyboard focus. Keep
                    // it enabled, but ignore edits while this save is pending.
                    onChanged: (value) {
                      if (!_saving) setState(() => _draft = value);
                    },
                    onChangeEnd: _save,
                  ),
                  const Text('切换专辑后保持；各专辑的音量设置仍单独生效。'),
                  if (_saving) const Text('正在保存…'),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        builder: (context, controller, _) => Tooltip(
          message: '调整主音量（所有专辑）',
          child: TextButton.icon(
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: Icon(
              current == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              size: 20,
            ),
            label: Text(_label(current)),
          ),
        ),
      );
    },
  );
}
