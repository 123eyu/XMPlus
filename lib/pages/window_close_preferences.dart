import 'package:flutter/material.dart';

import '../services/app_runtime.dart';

enum WindowCloseAction {
  ask('每次询问'),
  mini('收起到小窗'),
  tray('收起到托盘'),
  exit('彻底退出');

  const WindowCloseAction(this.label);
  final String label;

  static WindowCloseAction read(AppRuntime runtime) {
    final value =
        (runtime.storage.state['settings'] as Map)['windowCloseAction'];
    return values.firstWhere(
      (action) => action.name == value,
      orElse: () => ask,
    );
  }

  Future<void> save(AppRuntime runtime) async {
    await runtime.storage.transaction((state) {
      (state['settings'] as Map)['windowCloseAction'] = name;
    });
    runtime.changed();
  }
}

class WindowCloseChoiceDialog extends StatefulWidget {
  const WindowCloseChoiceDialog({super.key});

  @override
  State<WindowCloseChoiceDialog> createState() =>
      _WindowCloseChoiceDialogState();
}

class _WindowCloseChoiceDialogState extends State<WindowCloseChoiceDialog> {
  bool _remember = false;

  void _choose(WindowCloseAction action) =>
      Navigator.pop(context, (action, _remember));

  Widget _option({
    required WindowCloseAction action,
    required IconData icon,
    required String description,
    bool recommended = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return TextButton(
      key: ValueKey('windowCloseAction:${action.name}'),
      onPressed: () => _choose(action),
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft,
        minimumSize: const Size(0, 76),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        foregroundColor: colors.onSurface,
        backgroundColor: recommended
            ? colors.primaryContainer.withValues(alpha: .5)
            : colors.surfaceContainerLow,
        side: BorderSide(
          color: recommended
              ? colors.primary.withValues(alpha: .24)
              : colors.outlineVariant.withValues(alpha: .55),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: recommended
                  ? colors.primary.withValues(alpha: .1)
                  : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              size: 22,
              color: recommended ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      action.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (recommended)
                      Text(
                        '推荐',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.primary,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('windowCloseChoiceDialog'),
    constraints: const BoxConstraints(maxWidth: 520),
    insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    scrollable: true,
    titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
    contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
    actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    title: const Text('关闭主窗口'),
    content: SizedBox(
      width: 472,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _option(
            action: WindowCloseAction.tray,
            icon: Icons.minimize_rounded,
            description: '播放不中断，点击右下角托盘图标恢复',
            recommended: true,
          ),
          const SizedBox(height: 10),
          _option(
            action: WindowCloseAction.mini,
            icon: Icons.picture_in_picture_alt_rounded,
            description: '保留封面和播放控制，方便随时操作',
          ),
          const SizedBox(height: 10),
          _option(
            action: WindowCloseAction.exit,
            icon: Icons.power_settings_new_rounded,
            description: '停止播放并退出 XMPlus',
          ),
          const SizedBox(height: 16),
          CheckboxListTile(
            key: const ValueKey('rememberWindowCloseChoice'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('记住我的选择'),
            subtitle: const Text('下次直接使用所选方式，可在设置中更改'),
            value: _remember,
            onChanged: (value) => setState(() => _remember = value == true),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}

class WindowClosePreference extends StatefulWidget {
  const WindowClosePreference({required this.runtime, super.key});
  final AppRuntime runtime;

  @override
  State<WindowClosePreference> createState() => _WindowClosePreferenceState();
}

class _WindowClosePreferenceState extends State<WindowClosePreference> {
  bool _saving = false;
  String? _error;

  Future<void> _save(WindowCloseAction? action) async {
    if (action == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action.save(widget.runtime);
    } catch (_) {
      if (mounted) setState(() => _error = '设置保存失败，原设置已保留');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.runtime,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('关闭主窗口时'),
        DropdownButton<WindowCloseAction>(
          isExpanded: true,
          value: WindowCloseAction.read(widget.runtime),
          items: WindowCloseAction.values
              .map(
                (action) =>
                    DropdownMenuItem(value: action, child: Text(action.label)),
              )
              .toList(),
          onChanged: _saving ? null : _save,
        ),
        const Text('关闭小窗会收起到右下角托盘，继续播放；点击托盘图标恢复。'),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}
