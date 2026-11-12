import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/app_runtime.dart';
import 'playback_settings_page.dart';

class PlaybackSpeedControl extends StatefulWidget {
  const PlaybackSpeedControl({required this.runtime, this.albumId, super.key});

  final AppRuntime runtime;
  final String? albumId;

  @override
  State<PlaybackSpeedControl> createState() => _PlaybackSpeedControlState();
}

class _PlaybackSpeedControlState extends State<PlaybackSpeedControl> {
  bool _saving = false;
  double? _draft;
  String? _error;

  String _label(double value) =>
      '${value.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}×';

  Future<void> _save(double value) async {
    if (!mounted || _saving) return;
    setState(() {
      _saving = true;
      _draft = value;
      _error = null;
    });
    try {
      await persistPlaybackSetting(
        widget.runtime,
        'speed',
        double.parse(value.toStringAsFixed(2)),
        albumId: widget.albumId,
      );
    } catch (_) {
      if (mounted) setState(() => _error = '倍速保存或应用失败，请重试');
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
  Widget build(BuildContext context) {
    final current = _draft ?? widget.runtime.player.effectiveSettings.speed;
    final theme = Theme.of(context);
    final menuWidth = math.min(340.0, MediaQuery.sizeOf(context).width - 32);
    const speeds = [1.0, 1.25, 1.5, 2.0];
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final columns = ((menuWidth - 24) / (68 * scale + 8)).floor().clamp(
      1,
      speeds.length,
    );
    final presetWidth = (menuWidth - 32 - (columns - 1) * 8) / columns;
    return MenuAnchor(
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(theme.colorScheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        elevation: const WidgetStatePropertyAll(6),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      onClose: () {
        if (mounted && !_saving && _draft != null) {
          setState(() => _draft = null);
        }
      },
      menuChildren: [
        SizedBox(
          width: menuWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.albumId == null ? '全局倍速' : '专辑倍速',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: _saving
                          ? const CircularProgressIndicator(
                              strokeWidth: 2,
                              semanticsLabel: '正在保存倍速',
                            )
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _label(current),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final speed in speeds)
                      SizedBox(
                        width: presetWidth,
                        child: ChoiceChip(
                          key: ValueKey('quickSpeed:$speed'),
                          showCheckmark: false,
                          labelPadding: EdgeInsets.zero,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          label: Center(child: Text(_label(speed))),
                          selected: current == speed,
                          onSelected: _saving ? null : (_) => _save(speed),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                  ],
                ),
                Slider(
                  key: const ValueKey('playbackSpeedSlider'),
                  autofocus: true,
                  value: current,
                  min: 0.5,
                  max: 3,
                  divisions: 50,
                  label: _label(current),
                  semanticFormatterCallback: _label,
                  // Keep keyboard focus while saving without admitting a
                  // second edit until the current value has been applied.
                  onChanged: (value) {
                    if (!_saving) setState(() => _draft = value);
                  },
                  onChangeEnd: _save,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '0.5×',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '3.0×',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
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
        message: '调整播放倍速',
        child: TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: SizedBox(
            width: MediaQuery.textScalerOf(context).scale(44),
            child: Text(_label(current), textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
