import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../common/widgets/adaptive_text.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import 'playback_settings_page.dart';

String playbackTime(double seconds) {
  final total = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final hours = total ~/ 3600;
  final minutes = (total ~/ 60) % 60;
  final rest = (total % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$rest'
      : '$minutes:$rest';
}

class PlayerPanel extends StatefulWidget {
  const PlayerPanel({
    required this.runtime,
    this.expanded = false,
    this.navigatorKey,
    super.key,
  });
  static const routeName = '/player';
  final AppRuntime runtime;
  final bool expanded;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends State<PlayerPanel> {
  final _keyboardFocus = FocusNode(
    debugLabel: 'Player shortcuts',
    skipTraversal: true,
  );
  bool _busy = false, _interrupting = false;
  int _action = 0;
  double? _dragPosition;
  String? _error;
  XmlyClient? _favoriteClient;
  String? _favoriteKey, _favoriteTrackId, _favoriteError;
  bool? _favorite;
  bool _favoriteBusy = false, _favoriteMutating = false;
  int _favoriteRequest = 0, _libraryRevision = -1;
  AppRuntime get _runtime => widget.runtime;
  NavigatorState get _navigator =>
      widget.navigatorKey?.currentState ?? Navigator.of(context);

  @override
  void initState() {
    super.initState();
    _runtime.addListener(_favoriteContextChanged);
    if (widget.expanded) unawaited(_refreshFavorite());
  }

  @override
  void didUpdateWidget(covariant PlayerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != _runtime) {
      oldWidget.runtime.removeListener(_favoriteContextChanged);
      _runtime.addListener(_favoriteContextChanged);
    }
    if (widget.expanded &&
        (oldWidget.runtime != _runtime || !oldWidget.expanded)) {
      unawaited(_refreshFavorite());
    }
  }

  @override
  void dispose() {
    _runtime.removeListener(_favoriteContextChanged);
    _favoriteRequest++;
    _keyboardFocus.dispose();
    super.dispose();
  }

  bool get _desktopKeyboard => switch (Theme.of(context).platform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };

  String _keyHint(String label, String key) =>
      _desktopKeyboard ? '$label（$key）' : label;

  KeyEventResult _onPlayerKey(FocusNode node, KeyEvent event) {
    // Descendant controls keep their own activation, editing and navigation.
    // Also exclude routes above this player, including non-focusing dialogs.
    if (!node.hasPrimaryFocus || ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final player = _runtime.player;
    if (player.current == null) return KeyEventResult.ignored;
    final command = switch (event.logicalKey) {
      LogicalKeyboardKey.space => player.playing ? player.pause : player.resume,
      LogicalKeyboardKey.arrowLeft => player.seekBackward,
      LogicalKeyboardKey.arrowRight => player.seekForward,
      _ => null,
    };
    if (command == null) return KeyEventResult.ignored;
    // One command per press; repeats must not toggle or enqueue more seeks.
    if (event is KeyDownEvent && !_busy) unawaited(_act(command));
    return KeyEventResult.handled;
  }

  Widget _withKeyboard(Widget child) => !_desktopKeyboard
      ? child
      : Focus(
          focusNode: _keyboardFocus,
          autofocus: true,
          onKeyEvent: _onPlayerKey,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _keyboardFocus.requestFocus,
            child: child,
          ),
        );

  void _favoriteContextChanged() {
    if (!widget.expanded || !mounted) return;
    final client = _runtime.client;
    final changed =
        !identical(client, _favoriteClient) ||
        client.cacheIdentity != _favoriteKey ||
        _runtime.player.current?.id != _favoriteTrackId;
    final revised = _libraryRevision != _runtime.libraryRevision;
    _libraryRevision = _runtime.libraryRevision;
    if (changed || (revised && !_favoriteMutating)) {
      unawaited(_refreshFavorite());
    }
  }

  bool _favoriteCurrent(
    XmlyClient client,
    String key,
    String trackId,
    int request,
  ) =>
      mounted &&
      request == _favoriteRequest &&
      identical(client, _runtime.client) &&
      key == _runtime.client.cacheIdentity &&
      trackId == _runtime.player.current?.id;

  Future<void> _refreshFavorite() async {
    final client = _runtime.client, key = _runtime.client.cacheIdentity;
    final track = _runtime.player.current;
    final request = ++_favoriteRequest;
    _favoriteClient = client;
    _favoriteKey = key;
    _favoriteTrackId = track?.id;
    _libraryRevision = _runtime.libraryRevision;
    setState(() {
      _favorite = null;
      _favoriteError = null;
      _favoriteBusy = track != null && client.accountAvailable;
      _favoriteMutating = false;
    });
    if (track == null || !client.accountAvailable) return;
    try {
      final favorite = await XmlyExperience(client).isFavorite(track.id);
      if (_favoriteCurrent(client, key, track.id, request)) {
        setState(() => _favorite = favorite);
      }
    } catch (error) {
      if (_favoriteCurrent(client, key, track.id, request)) {
        setState(
          () => _favoriteError = error is XmlyException
              ? error.message
              : '收藏状态读取失败，请重试',
        );
      }
    } finally {
      if (_favoriteCurrent(client, key, track.id, request)) {
        setState(() => _favoriteBusy = false);
      }
    }
  }

  Future<void> _favoriteAction(Track track) async {
    if (_favoriteBusy || track.id != _runtime.player.current?.id) return;
    final client = _runtime.client, key = _runtime.client.cacheIdentity;
    if (!client.accountAvailable) {
      setState(() => _favoriteError = '请先登录后收藏声音');
      return;
    }
    final favorite = _favorite;
    if (favorite == null) return _refreshFavorite();
    final request = ++_favoriteRequest, desired = !favorite;
    var attempted = false;
    setState(() {
      _favoriteBusy = true;
      _favoriteMutating = true;
      _favoriteError = null;
    });
    try {
      if (favorite && !await _confirm(context, '取消收藏此声音？')) return;
      if (!_favoriteCurrent(client, key, track.id, request)) return;
      await _runtime.accounts.runWithAccount(client.identity, (admitted) async {
        if (!_favoriteCurrent(client, key, track.id, request) ||
            !identical(admitted, client)) {
          throw const XmlyException('account_changed', '账号已变更，请重试');
        }
        attempted = true;
        await XmlyExperience(client).setFavorite(track, favorite: desired);
      });
      _runtime.libraryChanged();
      if (_favoriteCurrent(client, key, track.id, request)) {
        setState(() => _favorite = desired);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(desired ? '已收藏声音' : '已取消收藏')));
      }
    } catch (error) {
      if (attempted) _runtime.libraryChanged();
      if (!_favoriteCurrent(client, key, track.id, request)) return;
      setState(() {
        _favorite = null;
        _favoriteError = error is XmlyException ? error.message : '收藏操作未完成，请重试';
      });
      if (attempted) {
        try {
          final value = await XmlyExperience(client).isFavorite(track.id);
          if (_favoriteCurrent(client, key, track.id, request)) {
            setState(() => _favorite = value);
          }
        } catch (_) {
          // Do not infer an outcome or replay an uncertain mutation.
        }
      }
    } finally {
      if (_favoriteCurrent(client, key, track.id, request)) {
        setState(() {
          _favoriteBusy = false;
          _favoriteMutating = false;
        });
      }
    }
  }

  String get _favoriteLabel => _favoriteBusy
      ? '正在读取收藏状态'
      : !_runtime.client.accountAvailable
      ? '收藏（需登录）'
      : _favorite == null
      ? '重试收藏状态'
      : _favorite!
      ? '取消收藏'
      : '收藏';

  bool _commandBlocked({bool interrupt = false}) =>
      _busy && (!interrupt || _interrupting);

  Future<void> _act(
    Future<void> Function() command, {
    bool interrupt = false,
  }) async {
    if (_commandBlocked(interrupt: interrupt)) return;
    final action = ++_action;
    setState(() {
      _busy = true;
      _interrupting = interrupt;
      _error = null;
    });
    try {
      await command();
    } on XmlyException catch (error) {
      if (mounted && action == _action) setState(() => _error = error.message);
    } catch (_) {
      if (mounted && action == _action) setState(() => _error = '操作未完成，请重试');
    } finally {
      if (mounted && action == _action) {
        setState(() {
          _busy = false;
          _interrupting = false;
        });
      }
    }
  }

  void _expand() => _navigator.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: PlayerPanel.routeName),
      builder: (_) => PlayerPanel(runtime: _runtime, expanded: true),
    ),
  );

  void _settings() {
    final track = _runtime.player.current;
    _navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => PlaybackSettingsPage(
          runtime: _runtime,
          albumId: track?.albumId.isNotEmpty == true ? track!.albumId : null,
          albumTitle: track?.album,
        ),
      ),
    );
  }

  Future<bool> _confirm(BuildContext context, String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _queue() => _navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('播放列表')),
        body: SafeArea(
          top: false,
          child: ListenableBuilder(
            listenable: _runtime,
            builder: (context, _) {
              final player = _runtime.player;
              Future<void> run(Future<void> Function() command) async {
                try {
                  await command();
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          error is XmlyException ? error.message : '队列操作失败，请重试',
                        ),
                      ),
                    );
                  }
                }
              }

              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Column(
                          children: [
                            ListTile(
                              title: AdaptiveText(
                                '${player.queue.length} 集 · ${player.queueSourceLabel}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              subtitle: AdaptiveText(
                                player.queueOrderLabel,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              trailing: TextButton(
                                onPressed: player.queue.isEmpty
                                    ? null
                                    : () async {
                                        if (await _confirm(
                                          context,
                                          '清空播放队列？',
                                        )) {
                                          await run(player.clearQueue);
                                        }
                                      },
                                child: const Text('清空'),
                              ),
                            ),
                            if (player.queueSource == 'album' &&
                                player.sourceAlbumId.isNotEmpty)
                              ListTile(
                                title: const Text('专辑更新'),
                                trailing: TextButton(
                                  onPressed: () => run(
                                    () => player.refreshAlbumTail(
                                      player.sourceAlbumId,
                                    ),
                                  ),
                                  child: const Text('检查更新'),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (player.queue.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: Text('队列为空')),
                        )
                      else
                        SliverReorderableList(
                          itemCount: player.queue.length,
                          proxyDecorator: (child, index, animation) => Material(
                            elevation: 4,
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainer,
                            child: child,
                          ),
                          onReorderItem: (from, to) =>
                              run(() => player.moveQueueItem(from, to)),
                          itemBuilder: (context, index) {
                            final track = player.queue[index];
                            return ListTile(
                              key: ValueKey('queue:$index:${track.id}'),
                              selected: index == player.cursor,
                              minLeadingWidth: 32,
                              horizontalTitleGap: 12,
                              leading: ReorderableDragStartListener(
                                index: index,
                                child: Tooltip(
                                  message: '拖动调整顺序',
                                  child: SizedBox(
                                    width: 32,
                                    height: 48,
                                    child: Icon(
                                      index == player.cursor
                                          ? Icons.graphic_eq
                                          : Icons.drag_handle,
                                    ),
                                  ),
                                ),
                              ),
                              title: AdaptiveText(
                                track.title.isEmpty ? track.id : track.title,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              subtitle: track.album.isEmpty
                                  ? null
                                  : AdaptiveText(
                                      track.album,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                              onTap: () =>
                                  run(() => player.playQueueItem(index)),
                              trailing: IconButton(
                                tooltip: '移出队列',
                                icon: const Icon(Icons.close),
                                onPressed: () =>
                                    run(() => player.removeQueueItem(index)),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _cover(String? url, double size, {bool small = false}) {
    final colors = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colors.primaryContainer,
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          size: size * 0.34,
          color: colors.onPrimaryContainer,
        ),
      ),
    );
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(small ? 10 : 24),
        child: SizedBox.square(
          dimension: size,
          child: url == null || url.isEmpty
              ? fallback
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }

  Widget _button(
    String tooltip,
    IconData icon,
    Future<void> Function()? command, {
    double size = 28,
    bool interrupt = false,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: _commandBlocked(interrupt: interrupt) || command == null
        ? null
        : () => _act(command, interrupt: interrupt),
    icon: Icon(icon, size: size),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _runtime,
    builder: (context, _) {
      final player = _runtime.player;
      final track = player.current;
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final title = track == null
          ? '尚未选择声音'
          : track.title.isEmpty
          ? track.id
          : track.title;
      final max = player.duration.isFinite && player.duration > 0
          ? player.duration
          : 0.0;
      final position = (_dragPosition ?? player.position)
          .clamp(0.0, max)
          .toDouble();
      final favorite = _favorite == true;
      final settings = player.effectiveSettings;
      final message =
          _error ?? _favoriteError ?? player.error ?? player.warning;
      final canPause = player.playing || player.loading;
      final play = track == null
          ? null
          : canPause
          ? player.pause
          : player.resume;
      final coverUrl = track?.coverUrl?.toString();
      final compact = MediaQuery.sizeOf(context).width < 320;
      if (!widget.expanded) {
        return Material(
          color: colors.surfaceContainer,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _expand,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
                        child: Row(
                          children: [
                            if (!compact) ...[
                              _cover(coverUrl, 44, small: true),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AdaptiveText(
                                    title,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                  AdaptiveText(
                                    message ??
                                        (track?.album.isNotEmpty == true
                                            ? track!.album
                                            : '打开播放器'),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: message == null
                                          ? colors.onSurfaceVariant
                                          : colors.error,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _button(
                    canPause ? '暂停' : '播放',
                    canPause ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    play,
                    size: 32,
                    interrupt: canPause,
                  ),
                  IconButton(
                    tooltip: '播放列表',
                    onPressed: _queue,
                    icon: const Icon(Icons.queue_music_rounded),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
              LinearProgressIndicator(
                minHeight: 2,
                value: player.loading || player.buffering || _busy
                    ? null
                    : max > 0
                    ? position / max
                    : 0,
                backgroundColor: colors.surfaceContainerHighest,
              ),
            ],
          ),
        );
      }

      final sleep = player.policy.sleepRequest;
      final remaining = player.policy.remainingDuration;
      final sleepLabel = sleep == null
          ? '定时关闭'
          : player.policy.sleepWaitingForEnd || remaining == null
          ? '本集结束后${sleep.action.name == 'exit' ? '退出' : '暂停'}'
          : playbackTime(remaining.inSeconds.toDouble());
      final metadata = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdaptiveText(
            title,
            minimumScale: 0.8,
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: compact ? 16 : 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (track != null &&
              (track.album.isNotEmpty || track.artist.isNotEmpty)) ...[
            SizedBox(height: compact ? 4 : 10),
            AdaptiveText(
              [
                track.album,
                track.artist,
              ].where((text) => text.isNotEmpty).join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          SizedBox(height: compact ? 4 : 16),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Tooltip(
                message: '播放倍速与设置',
                child: TextButton(
                  onPressed: _settings,
                  child: Text(
                    '${settings.speed.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}×',
                  ),
                ),
              ),
              _button(
                _favoriteLabel,
                favorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                track == null || _favoriteBusy
                    ? null
                    : () => _favoriteAction(track),
              ),
              _button(
                '添加书签',
                Icons.bookmark_add_outlined,
                track == null
                    ? null
                    : () async {
                        final savedPosition = player.position;
                        await player.bookmark();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '已添加书签 · ${playbackTime(savedPosition)}',
                              ),
                            ),
                          );
                        }
                      },
              ),
            ],
          ),
        ],
      );
      final progress = Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
              inactiveTrackColor: colors.onSurface.withValues(alpha: 0.12),
            ),
            child: Slider(
              padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 5),
              value: position,
              max: max > 0 ? max : 1,
              label: playbackTime(position),
              semanticFormatterCallback: playbackTime,
              onChanged: track == null || max == 0 || _busy
                  ? null
                  : (value) => setState(() => _dragPosition = value),
              onChangeEnd: track == null || max == 0 || _busy
                  ? null
                  : (value) async {
                      await _act(() => player.seek(value));
                      if (mounted) setState(() => _dragPosition = null);
                    },
            ),
          ),
          DefaultTextStyle(
            style: (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
              color: colors.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text(playbackTime(position)), Text(playbackTime(max))],
            ),
          ),
        ],
      );
      final controls = Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 8 : 20),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!compact)
              _button(
                _keyHint('后退 ${settings.seekBackwardSeconds} 秒', '←'),
                Icons.replay_rounded,
                track == null ? null : player.seekBackward,
                size: 24,
              ),
            _button(
              '上一集',
              Icons.skip_previous_rounded,
              track == null ? null : player.previous,
              size: 34,
            ),
            Tooltip(
              message: _keyHint(canPause ? '暂停' : '播放', '空格'),
              child: SizedBox.square(
                dimension: compact ? 64 : 76,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: const CircleBorder(),
                  ),
                  onPressed:
                      _commandBlocked(interrupt: canPause) || play == null
                      ? null
                      : () => _act(play, interrupt: canPause),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (_busy || player.loading || player.buffering)
                        SizedBox.square(
                          dimension: compact ? 52 : 62,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.onPrimary,
                          ),
                        ),
                      Icon(
                        canPause
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 42,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _button(
              '下一集',
              Icons.skip_next_rounded,
              track == null ? null : player.next,
              size: 34,
            ),
            if (!compact)
              _button(
                _keyHint('前进 ${settings.seekForwardSeconds} 秒', '→'),
                Icons.forward_rounded,
                track == null ? null : player.seekForward,
                size: 24,
              ),
          ],
        ),
      );
      final footer = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => showSleepTimerDialog(context, _runtime),
                  icon: Icon(
                    sleep == null ? Icons.timer_outlined : Icons.timer,
                  ),
                  label: Text(
                    sleepLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextButton.icon(
                  onPressed: _queue,
                  icon: const Icon(Icons.queue_music_rounded),
                  label: const Text(
                    '播放列表',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          if (sleep != null)
            TextButton(
              onPressed: () {
                player.cancelSleep();
                _runtime.changed();
              },
              child: const Text('取消定时'),
            ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                message,
                key: const ValueKey('playerMessage'),
                style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      );
      final page = Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '收起播放器',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
          title: const Text('正在收听'),
          centerTitle: true,
          actions: [
            PopupMenuButton<String>(
              tooltip: '更多播放操作',
              icon: const Icon(Icons.more_horiz),
              onSelected: (value) {
                switch (value) {
                  case 'settings':
                    _settings();
                  case 'replay':
                    _act(player.replay);
                  case 'local':
                    _act(player.switchToLocal);
                  case 'backward':
                    _act(player.seekBackward);
                  case 'forward':
                    _act(player.seekForward);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'settings', child: Text('播放设置')),
                PopupMenuItem(
                  value: 'replay',
                  enabled: track != null && !_busy,
                  child: const Text('从头重听'),
                ),
                if (compact) ...[
                  PopupMenuItem(
                    value: 'backward',
                    enabled: track != null && !_busy,
                    child: Text(
                      _keyHint('后退 ${settings.seekBackwardSeconds} 秒', '←'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'forward',
                    enabled: track != null && !_busy,
                    child: Text(
                      _keyHint('前进 ${settings.seekForwardSeconds} 秒', '→'),
                    ),
                  ),
                ],
                if (track != null &&
                    player.sourceKind != 'local' &&
                    _runtime.downloads.tasks.any(
                      (task) =>
                          task.track.id == track.id &&
                          task.state.name == 'completed',
                    ))
                  PopupMenuItem(
                    value: 'local',
                    enabled: !_busy,
                    child: const Text('切换本地文件'),
                  ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final twoColumns =
                  constraints.maxWidth >= 760 && constraints.maxHeight < 700;
              // ponytail: reserve the control stack; very short/error states scroll.
              final textHeight = MediaQuery.textScalerOf(context).scale(56);
              final coverHeight =
                  constraints.maxHeight -
                  380 -
                  textHeight -
                  (sleep == null ? 0 : 48);
              final coverSize = twoColumns
                  ? math.min(360.0, constraints.maxWidth * 0.38)
                  : math.min(
                      360.0,
                      math.min(
                        constraints.maxWidth - 64,
                        math.max(120.0, coverHeight),
                      ),
                    );
              final details = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  metadata,
                  SizedBox(height: compact ? 4 : 20),
                  progress,
                  controls,
                  footer,
                ],
              );
              return SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: twoColumns ? 1040 : 520,
                      minHeight: constraints.maxHeight,
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 8 : 24,
                        compact ? 8 : 20,
                        compact ? 8 : 24,
                        compact ? 8 : 24,
                      ),
                      child: twoColumns
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                _cover(coverUrl, coverSize),
                                const SizedBox(width: 40),
                                Expanded(child: details),
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                if (!compact) ...[
                                  _cover(coverUrl, coverSize),
                                  const SizedBox(height: 28),
                                ],
                                details,
                              ],
                            ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      return _withKeyboard(page);
    },
  );
}
