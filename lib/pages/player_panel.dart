import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/confirmation_dialog.dart';
import '../common/widgets/local_panel.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart';
import 'manuscript_reader.dart';
import 'playback_settings_page.dart';
import 'playback_speed_control.dart';
import 'player_content_layout.dart';
import 'player_queue_panel.dart';
import 'playback_volume_control.dart';
import 'track_comments_panel.dart';

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
    this.initialQueue = false,
    this.miniWindow = false,
    this.onExpand,
    this.navigatorKey,
    super.key,
  });
  static const routeName = '/player';
  final AppRuntime runtime;
  final bool expanded;
  final bool initialQueue;
  final bool miniWindow;
  final VoidCallback? onExpand;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends State<PlayerPanel> {
  final _keyboardFocus = FocusNode(
    debugLabel: 'Player shortcuts',
    skipTraversal: true,
  );
  bool _busy = false, _cancelling = false;
  double? _dragPosition;
  int? _dragEpoch;
  String? _error;
  XmlyClient? _favoriteClient;
  String? _favoriteKey, _favoriteTrackId, _favoriteError;
  bool? _favorite;
  bool _favoriteBusy = false, _favoriteMutating = false;
  int _favoriteRequest = 0, _libraryRevision = -1;
  XmlyClient? _manuscriptClient;
  String? _manuscriptKey, _manuscriptTrackId, _manuscript, _manuscriptError;
  bool _manuscriptLoading = false;
  bool _showManuscript = false;
  bool _showComments = false;
  bool _showQueue = false;
  bool _manuscriptDisplayChosen = false, _manuscriptLoaded = false;
  int _manuscriptRequest = 0;
  Completer<void>? _manuscriptCancelled;
  AppRuntime get _runtime => widget.runtime;
  NavigatorState get _navigator =>
      widget.navigatorKey?.currentState ?? Navigator.of(context);

  @override
  void initState() {
    super.initState();
    _showQueue = widget.initialQueue;
    _runtime.addListener(_favoriteContextChanged);
    _runtime.addListener(_manuscriptContextChanged);
    if (widget.expanded) unawaited(_refreshFavorite());
  }

  void _useDefaultManuscriptLayout() {
    if (widget.expanded &&
        !_manuscriptDisplayChosen &&
        MediaQuery.sizeOf(context).width >= 920) {
      _showManuscript = true;
      _manuscriptDisplayChosen = true;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasVisible = _showManuscript;
    _useDefaultManuscriptLayout();
    if (!wasVisible && _showManuscript) unawaited(_refreshManuscript());
  }

  @override
  void didUpdateWidget(covariant PlayerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != _runtime) {
      oldWidget.runtime.removeListener(_favoriteContextChanged);
      oldWidget.runtime.removeListener(_manuscriptContextChanged);
      _runtime.addListener(_manuscriptContextChanged);
      _runtime.addListener(_favoriteContextChanged);
      _dragPosition = null;
      _dragEpoch = null;
    }
    if (widget.expanded &&
        (oldWidget.runtime != _runtime || !oldWidget.expanded)) {
      unawaited(_refreshFavorite());
    }
    if (oldWidget.runtime != _runtime ||
        oldWidget.expanded != widget.expanded) {
      _useDefaultManuscriptLayout();
      unawaited(_refreshManuscript());
    }
  }

  @override
  void dispose() {
    _runtime.removeListener(_favoriteContextChanged);
    _runtime.removeListener(_manuscriptContextChanged);
    _manuscriptRequest++;
    _manuscriptCancelled?.complete();
    _manuscriptCancelled = null;
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
      LogicalKeyboardKey.space => _playPause,
      LogicalKeyboardKey.arrowLeft => player.seekBackward,
      LogicalKeyboardKey.arrowRight => player.seekForward,
      _ => null,
    };
    if (command == null) return KeyEventResult.ignored;
    // One command per press; repeats must not toggle or enqueue more seeks.
    if (event is KeyDownEvent) {
      unawaited(
        event.logicalKey == LogicalKeyboardKey.space
            ? _playPause()
            : _act(command),
      );
    }
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

  void _manuscriptContextChanged() {
    if (!mounted || !widget.expanded) return;
    final client = _runtime.client;
    if (!identical(client, _manuscriptClient) ||
        client.cacheIdentity != _manuscriptKey ||
        _runtime.player.current?.id != _manuscriptTrackId) {
      unawaited(_refreshManuscript());
    }
  }

  Future<void> _refreshManuscript({bool force = false}) async {
    final client = _runtime.client, key = _runtime.client.cacheIdentity;
    final trackId = _runtime.player.current?.id;
    if (!force &&
        widget.expanded &&
        _showManuscript &&
        identical(client, _manuscriptClient) &&
        key == _manuscriptKey &&
        trackId == _manuscriptTrackId &&
        (_manuscriptLoaded || _manuscriptLoading)) {
      return;
    }
    final request = ++_manuscriptRequest;
    _manuscriptCancelled?.complete();
    _manuscriptCancelled = null;
    _manuscriptClient = client;
    _manuscriptKey = key;
    _manuscriptTrackId = trackId;
    setState(() {
      _manuscript = null;
      _manuscriptError = null;
      _manuscriptLoaded = false;
      _manuscriptLoading =
          widget.expanded && _showManuscript && trackId != null;
    });
    if (!_manuscriptLoading) return;
    final cancelled = _manuscriptCancelled = Completer<void>();
    bool current() =>
        mounted &&
        widget.expanded &&
        _showManuscript &&
        request == _manuscriptRequest &&
        identical(client, _runtime.client) &&
        key == _runtime.client.cacheIdentity &&
        trackId == _runtime.player.current?.id;
    try {
      final manuscript = await client.withReadPolicy(
        () => client.fetchManuscript(trackId!),
        rateLimitRetries: 0,
        cancelled: cancelled.future,
      );
      if (current()) {
        setState(() {
          _manuscript = manuscript;
          _manuscriptLoaded = true;
        });
      }
    } catch (error) {
      if (current()) {
        setState(
          () => _manuscriptError = error is XmlyException
              ? error.message
              : '文稿读取失败，请重试',
        );
      }
    } finally {
      if (current()) {
        _manuscriptCancelled = null;
        setState(() => _manuscriptLoading = false);
      }
    }
  }

  void _toggleManuscript() {
    _manuscriptDisplayChosen = true;
    setState(() {
      _showManuscript = _showComments || _showQueue || !_showManuscript;
      _showComments = false;
      _showQueue = false;
    });
    if (_showManuscript) {
      unawaited(_refreshManuscript());
    } else {
      _manuscriptRequest++;
      _manuscriptCancelled?.complete();
      _manuscriptCancelled = null;
      _manuscriptLoading = false;
    }
  }

  void _toggleComments() => setState(() {
    _showComments = !_showComments;
    _showQueue = false;
  });

  void _closeSideContent() {
    setState(() {
      _showComments = false;
      _showQueue = false;
      _showManuscript = false;
      _manuscriptDisplayChosen = true;
      _manuscriptLoading = false;
    });
    _manuscriptRequest++;
    _manuscriptCancelled?.complete();
    _manuscriptCancelled = null;
  }

  Widget _manuscriptContent() => ManuscriptReader(
    key: ValueKey((_manuscriptClient, _manuscriptKey, _manuscriptTrackId)),
    manuscript: _manuscript!,
    showTitle: false,
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
      if (favorite &&
          !await showConfirmationDialog(context, const Text('取消收藏此声音？'))) {
        return;
      }
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

  Widget _favoriteControl(Track? track) {
    if (_favoriteError == null) {
      return Tooltip(
        message: _favoriteLabel,
        child: TextButton.icon(
          onPressed: track == null || _favoriteBusy
              ? null
              : () => _favoriteAction(track),
          icon: Icon(
            _favorite == true
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            size: 20,
          ),
          label: Text(_favorite == true ? '已喜欢' : '喜欢'),
        ),
      );
    }
    final colors = Theme.of(context).colorScheme;
    return MenuAnchor(
      consumeOutsideTap: true,
      menuChildren: [
        SizedBox(
          width: math.min(300, MediaQuery.sizeOf(context).width - 32),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('收藏状态暂不可用', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Text(
                  _favoriteError!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        MenuItemButton(
          onPressed: _favoriteBusy ? null : _refreshFavorite,
          leadingIcon: const Icon(Icons.refresh_rounded),
          child: const Text('重试收藏状态'),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: '收藏状态暂不可用，点击查看',
        child: TextButton.icon(
          key: const ValueKey('favoriteStatusUnavailable'),
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
          icon: Badge(
            smallSize: 6,
            backgroundColor: colors.outline,
            child: const Icon(Icons.favorite_border_rounded, size: 20),
          ),
          label: const Text('喜欢'),
        ),
      ),
    );
  }

  Future<void> _act(Future<void> Function() command) async {
    if (_busy || _cancelling) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await command();
    } on XmlyException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playPause() async {
    final player = _runtime.player;
    if (player.current == null || _cancelling) return;
    if (!player.loading && !(_busy && player.playing)) {
      return _act(player.playing ? player.pause : player.resume);
    }
    // Only cancellation may pass a command awaiting catalogue or audio.
    // Keep its busy gate intact until that original command has settled.
    setState(() {
      _cancelling = true;
      _error = null;
    });
    try {
      await player.pause();
    } on XmlyException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请重试');
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  void _expand({bool queue = false}) => _navigator.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: PlayerPanel.routeName),
      builder: (_) =>
          PlayerPanel(runtime: _runtime, expanded: true, initialQueue: queue),
    ),
  );

  void _settings() {
    final track = _runtime.player.current;
    showQuickPlaybackSettings(
      _navigator.context,
      _runtime,
      albumId: track?.albumId.isNotEmpty == true ? track!.albumId : null,
      albumTitle: track?.album,
    );
  }

  void _openAlbum(String albumId) {
    if (albumId.isEmpty) return;
    showLocalPanel<void>(
      context: _navigator.context,
      title: '专辑详情',
      width: 660,
      height: 760,
      showHeader: false,
      builder: (_) =>
          AlbumPageView(runtime: _runtime, albumId: albumId, inPanel: true),
    );
  }

  void _queue() {
    if (!widget.expanded) {
      _expand(queue: true);
      return;
    }
    setState(() {
      _showQueue = !_showQueue;
      _showComments = false;
    });
  }

  Widget _cover(String? url, double size, {bool small = false}) {
    final colors = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          size: size * 0.34,
          color: colors.primary,
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
  }) => IconButton(
    tooltip: tooltip,
    onPressed: _busy || _cancelling || command == null
        ? null
        : () => _act(command),
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
      final epoch = player.playbackEpoch;
      final position =
          ((_dragEpoch == epoch ? _dragPosition : null) ?? player.position)
              .clamp(0.0, max)
              .toDouble();
      final settings = player.effectiveSettings;
      final message = _error ?? player.error ?? player.warning;
      final canPause = player.playing || player.loading;
      final playLabel = player.loading
          ? '取消加载'
          : canPause
          ? '暂停'
          : '播放';
      final VoidCallback? play =
          track == null || _cancelling || (_busy && !canPause)
          ? null
          : () => unawaited(_playPause());
      final coverUrl = track?.coverUrl?.toString();
      final compact = MediaQuery.sizeOf(context).width < 400;
      final queueVisible = _showQueue;
      final commentsVisible = !queueVisible && _showComments && track != null;
      final manuscriptVisible =
          !queueVisible &&
          !commentsVisible &&
          _showManuscript &&
          _manuscript != null;
      final sideContentVisible =
          queueVisible || commentsVisible || manuscriptVisible;
      final widePlayer = MediaQuery.sizeOf(context).width >= 920;
      Widget seekSlider({bool dock = false}) => SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
          inactiveTrackColor: colors.onSurface.withValues(alpha: 0.12),
        ),
        child: KeyedSubtree(
          key: ValueKey((player, epoch, dock)),
          child: Slider(
            key: dock ? const ValueKey('dockSeekSlider') : null,
            padding: EdgeInsets.symmetric(
              vertical: dock ? 12 : 22,
              horizontal: 5,
            ),
            value: position,
            max: max > 0 ? max : 1,
            label: playbackTime(position),
            semanticFormatterCallback: playbackTime,
            onChangeStart: track == null || max == 0 || _busy
                ? null
                : (_) => _dragEpoch = epoch,
            onChanged: track == null || max == 0 || _busy
                ? null
                : (value) {
                    if (_dragEpoch == epoch && player.playbackEpoch == epoch) {
                      setState(() => _dragPosition = value);
                    }
                  },
            onChangeEnd: track == null || max == 0 || _busy
                ? null
                : (value) async {
                    final selectedEpoch = _dragEpoch;
                    setState(() {
                      _dragPosition = null;
                      _dragEpoch = null;
                    });
                    if (selectedEpoch != epoch ||
                        player.playbackEpoch != epoch) {
                      return;
                    }
                    await _act(() => player.seek(value, expectedEpoch: epoch));
                  },
          ),
        ),
      );
      if (!widget.expanded) {
        if (!widget.miniWindow) {
          Widget dockPlay({double size = 52}) => Tooltip(
            message: playLabel,
            child: SizedBox.square(
              dimension: size,
              child: FilledButton(
                key: const ValueKey('dockPlayPause'),
                onPressed: play,
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (player.loading ||
                        player.buffering ||
                        _busy ||
                        _cancelling)
                      SizedBox.square(
                        dimension: size - 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.onPrimary,
                        ),
                      ),
                    Icon(
                      canPause ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 30,
                    ),
                  ],
                ),
              ),
            ),
          );
          final timeStyle = theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          );
          final queueButton = IconButton(
            tooltip: '播放列表',
            onPressed: _queue,
            icon: const Icon(Icons.queue_music_rounded),
          );
          return Material(
            color: colors.surfaceContainerLow,
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 600) {
                  return Padding(
                    key: const ValueKey('playbackDockNarrow'),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            _PlayerExpandTarget(
                              onTap: widget.onExpand ?? _expand,
                              child: _cover(coverUrl, 40, small: true),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _PlayerExpandTarget(
                                onTap: widget.onExpand ?? _expand,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      message ?? track?.artist ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: message == null
                                                ? colors.onSurfaceVariant
                                                : colors.error,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            dockPlay(size: 42),
                            queueButton,
                          ],
                        ),
                        Row(
                          children: [
                            _button(
                              '上一集',
                              Icons.skip_previous_rounded,
                              track == null ? null : player.previous,
                              size: 24,
                            ),
                            Text(playbackTime(position), style: timeStyle),
                            Expanded(child: seekSlider(dock: true)),
                            Text(playbackTime(max), style: timeStyle),
                            _button(
                              '下一集',
                              Icons.skip_next_rounded,
                              track == null ? null : player.next,
                              size: 24,
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }
                return Padding(
                  key: const ValueKey('playbackDockWide'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      _button(
                        '上一集',
                        Icons.skip_previous_rounded,
                        track == null ? null : player.previous,
                        size: 28,
                      ),
                      const SizedBox(width: 4),
                      dockPlay(),
                      const SizedBox(width: 4),
                      _button(
                        '下一集',
                        Icons.skip_next_rounded,
                        track == null ? null : player.next,
                        size: 28,
                      ),
                      const SizedBox(width: 24),
                      _PlayerExpandTarget(
                        onTap: widget.onExpand ?? _expand,
                        child: _cover(coverUrl, 56, small: true),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: _PlayerExpandTarget(
                                    onTap: widget.onExpand ?? _expand,
                                    child: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ),
                                ),
                                if (constraints.maxWidth >= 1180 &&
                                    track?.artist.isNotEmpty == true) ...[
                                  const SizedBox(width: 20),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 130,
                                    ),
                                    child: Text(
                                      track!.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: timeStyle,
                                    ),
                                  ),
                                ],
                                const SizedBox(width: 20),
                                Text(
                                  '${playbackTime(position)} / ${playbackTime(max)}',
                                  key: const ValueKey('dockPlaybackTime'),
                                  style: timeStyle,
                                ),
                              ],
                            ),
                            seekSlider(dock: true),
                            if (message != null)
                              Text(
                                message,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colors.error,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      if (constraints.maxWidth >= 760)
                        PlaybackSpeedControl(
                          runtime: _runtime,
                          albumId: track?.albumId.isNotEmpty == true
                              ? track!.albumId
                              : null,
                        ),
                      if (constraints.maxWidth >= 960)
                        PlaybackVolumeControl(runtime: _runtime),
                      queueButton,
                    ],
                  ),
                );
              },
            ),
          );
        }
        return Material(
          color: colors.surfaceContainer,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _PlayerExpandTarget(
                      onTap: widget.onExpand ?? _expand,
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
                  IconButton(
                    tooltip: playLabel,
                    onPressed: play,
                    icon: Icon(
                      canPause ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 32,
                    ),
                  ),
                  if (widget.miniWindow)
                    _button(
                      '下一集',
                      Icons.skip_next_rounded,
                      track == null ? null : player.next,
                    )
                  else
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
                value:
                    player.loading || player.buffering || _busy || _cancelling
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
        crossAxisAlignment: widePlayer
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Text(
            title,
            textAlign: widePlayer ? TextAlign.center : TextAlign.start,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: compact ? 18 : 24,
              height: 1.45,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (track != null &&
              (track.albumId.isNotEmpty ||
                  track.album.isNotEmpty ||
                  track.artist.isNotEmpty)) ...[
            SizedBox(height: compact ? 4 : 10),
            if (track.albumId.isNotEmpty)
              TextButton(
                key: const ValueKey('playerAlbumLink'),
                onPressed: () => _openAlbum(track.albumId),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  alignment: widePlayer
                      ? Alignment.center
                      : Alignment.centerLeft,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: AdaptiveText(
                        track.album.isEmpty ? '查看专辑' : track.album,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
              )
            else if (track.album.isNotEmpty)
              AdaptiveText(
                track.album,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            if (track.artist.isNotEmpty)
              AdaptiveText(
                track.artist,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
          ],
        ],
      );
      final quickControls = Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PlaybackSpeedControl(
            key: ValueKey((_runtime, track?.id)),
            runtime: _runtime,
            albumId: track?.albumId.isNotEmpty == true ? track!.albumId : null,
          ),
          PlaybackVolumeControl(runtime: _runtime),
          TextButton.icon(
            onPressed: () => showSleepTimerDialog(context, _runtime),
            icon: Icon(
              sleep == null ? Icons.timer_outlined : Icons.timer,
              size: 20,
            ),
            label: Text(
              sleepLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
      final contentActions = Wrap(
        alignment: WrapAlignment.center,
        spacing: 24,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _favoriteControl(track),
          TextButton.icon(
            onPressed: track == null || _busy || _cancelling
                ? null
                : () => _act(() async {
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
                  }),
            icon: const Icon(Icons.bookmark_add_outlined, size: 20),
            label: const Text('书签'),
          ),
        ],
      );
      final progress = Column(
        children: [
          seekSlider(),
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
        padding: EdgeInsets.symmetric(
          vertical: compact
              ? 8
              : widePlayer
              ? 12
              : 20,
        ),
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
              message: _keyHint(playLabel, '空格'),
              child: SizedBox.square(
                dimension: compact
                    ? 64
                    : widePlayer
                    ? 68
                    : 76,
                child: FilledButton(
                  key: const ValueKey('playerPlayPause'),
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: const CircleBorder(),
                  ),
                  onPressed: play,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (_busy ||
                          _cancelling ||
                          player.loading ||
                          player.buffering)
                        SizedBox.square(
                          dimension: compact
                              ? 52
                              : widePlayer
                              ? 56
                              : 62,
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
      Widget sideLinks({bool tabs = false}) {
        Widget link({
          required String key,
          required String label,
          required IconData icon,
          required bool selected,
          required VoidCallback? onPressed,
        }) => Semantics(
          selected: selected,
          child: TextButton.icon(
            key: ValueKey(key),
            onPressed: tabs && selected ? () {} : onPressed,
            style: TextButton.styleFrom(
              foregroundColor: tabs && !selected
                  ? colors.onSurfaceVariant
                  : null,
              backgroundColor: tabs && selected
                  ? colors.surfaceContainerHighest
                  : Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
        );
        return Wrap(
          alignment: WrapAlignment.center,
          spacing: tabs ? 4 : 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            link(
              key: 'toggleComments',
              label: '评论',
              icon: Icons.chat_bubble_outline_rounded,
              selected: commentsVisible,
              onPressed: track == null ? null : _toggleComments,
            ),
            if (track != null && (!_manuscriptLoaded || _manuscript != null))
              Tooltip(
                message: _manuscriptError ?? '查看当前声音的官方文稿',
                child: link(
                  key: 'toggleManuscript',
                  label: _manuscriptLoading
                      ? '读取文稿…'
                      : _manuscriptError != null
                      ? '重试文稿'
                      : '文稿',
                  icon: Icons.article_outlined,
                  selected: manuscriptVisible,
                  onPressed: _manuscriptLoading
                      ? null
                      : _manuscriptError != null
                      ? () => _refreshManuscript(force: true)
                      : _toggleManuscript,
                ),
              ),
            link(
              key: 'toggleQueue',
              label: '播放列表',
              icon: Icons.queue_music_rounded,
              selected: queueVisible,
              onPressed: _queue,
            ),
          ],
        );
      }

      final sideHeader = Row(
        children: [
          const SizedBox(width: 40),
          Expanded(child: sideLinks(tabs: true)),
          IconButton(
            tooltip: queueVisible
                ? '收起播放列表'
                : commentsVisible
                ? '收起评论'
                : '收起文稿',
            onPressed: _closeSideContent,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      );
      final footer = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widePlayer)
            ExcludeFocus(
              excluding: sideContentVisible,
              child: ExcludeSemantics(
                excluding: sideContentVisible,
                child: IgnorePointer(
                  ignoring: sideContentVisible,
                  child: AnimatedOpacity(
                    opacity: sideContentVisible ? 0 : 1,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    child: sideLinks(),
                  ),
                ),
              ),
            )
          else if (!sideContentVisible)
            sideLinks(),
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
        appBar: AppHeader(
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
              offset: const Offset(0, 12),
              icon: const Icon(Icons.more_horiz),
              onSelected: (value) {
                switch (value) {
                  case 'settings':
                    _settings();
                  case 'comments':
                    if (track != null) _toggleComments();
                  case 'album':
                    if (track != null) _openAlbum(track.albumId);
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
                if (track != null)
                  PopupMenuItem(
                    value: 'comments',
                    child: Text(commentsVisible ? '收起评论' : '查看评论'),
                  ),
                if (track?.albumId.isNotEmpty == true)
                  const PopupMenuItem(value: 'album', child: Text('查看专辑')),
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
              // ponytail: reserve the control stack; very short/error states scroll.
              final textHeight = MediaQuery.textScalerOf(context).scale(56);
              final coverHeight =
                  constraints.maxHeight -
                  450 -
                  textHeight -
                  (sleep == null ? 0 : 48);
              final coverSize = math.min(
                280.0,
                math.min(
                  constraints.maxWidth - 64,
                  math.max(120.0, coverHeight),
                ),
              );
              final details = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  controls,
                  progress,
                  contentActions,
                  const SizedBox(height: 4),
                  quickControls,
                  footer,
                ],
              );
              final section = queueVisible
                  ? 'queue'
                  : commentsVisible
                  ? 'comments'
                  : manuscriptVisible
                  ? 'manuscript'
                  : null;
              final Widget? content = queueVisible
                  ? PlayerQueuePanel(
                      key: ValueKey(_runtime.player),
                      runtime: _runtime,
                    )
                  : commentsVisible
                  ? TrackCommentsPanel(runtime: _runtime, track: track)
                  : manuscriptVisible
                  ? _manuscriptContent()
                  : null;

              if (constraints.maxWidth >= 920) {
                final roomy = ((constraints.maxWidth - 1280) / 1080).clamp(
                  0.0,
                  1.0,
                );
                final stageWidth = math.min(1760.0, constraints.maxWidth);
                final playerWidth = 400 + 120 * roomy;
                final sideWidth = 560 + 160 * roomy;
                final extraTextHeight =
                    math.max(
                      0.0,
                      MediaQuery.textScalerOf(context).scale(240) - 240,
                    ) *
                    roomy;
                final sideHeight = math.min(
                  640 + 400 * roomy,
                  math.max(0.0, constraints.maxHeight - 64),
                );
                final availableCoverHeight =
                    constraints.maxHeight -
                    523 -
                    extraTextHeight -
                    (sleep == null ? 0 : 48) -
                    (message == null ? 0 : 56);
                final sideCoverSize = math.min(
                  260 + 100 * roomy,
                  math.min(
                    (stageWidth - 32) * 10 / 21 - 48,
                    math.max(140.0, availableCoverHeight),
                  ),
                );
                return Center(
                  child: SizedBox(
                    width: stageWidth,
                    child: PlayerContentLayout(
                      key: const ValueKey('playerWideLayout'),
                      sideOpen: sideContentVisible,
                      player: SingleChildScrollView(
                        key: const ValueKey('playerControlsScroll'),
                        primary: false,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: playerWidth,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    metadata,
                                    const SizedBox(height: 16),
                                    KeyedSubtree(
                                      key: const ValueKey('playerCover'),
                                      child: _cover(coverUrl, sideCoverSize),
                                    ),
                                    controls,
                                    progress,
                                    const SizedBox(height: 16),
                                    contentActions,
                                    const SizedBox(height: 4),
                                    quickControls,
                                    footer,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      side: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: sideWidth),
                            child: SizedBox(
                              height: sideHeight,
                              child: PlayerSideContent(
                                key: ValueKey(_runtime),
                                section: section,
                                header: sideHeader,
                                content: content,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }

              if (content != null) {
                return Column(
                  key: ValueKey('${section}NarrowLayout'),
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Column(
                          children: [
                            sideHeader,
                            const SizedBox(height: 8),
                            Expanded(child: content),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: math.min(280, constraints.maxHeight * .45),
                      ),
                      child: SingleChildScrollView(
                        primary: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  _cover(coverUrl, 44, small: true),
                                  const SizedBox(width: 12),
                                  Expanded(child: AdaptiveText(title)),
                                  IconButton(
                                    tooltip: playLabel,
                                    onPressed: play,
                                    icon: Icon(
                                      canPause
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      size: 32,
                                    ),
                                  ),
                                  _button(
                                    '下一集',
                                    Icons.skip_next_rounded,
                                    player.next,
                                  ),
                                ],
                              ),
                              progress,
                              contentActions,
                              quickControls,
                              footer,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }
              return SingleChildScrollView(
                key: const ValueKey('playerCenteredLayout'),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 680,
                      minHeight: constraints.maxHeight,
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 8 : 24,
                        compact ? 8 : 20,
                        compact ? 8 : 24,
                        compact ? 8 : 24,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          metadata,
                          SizedBox(height: compact ? 4 : 16),
                          if (!compact) ...[
                            _cover(coverUrl, coverSize),
                            const SizedBox(height: 8),
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

class _PlayerExpandTarget extends StatefulWidget {
  const _PlayerExpandTarget({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_PlayerExpandTarget> createState() => _PlayerExpandTargetState();
}

class _PlayerExpandTargetState extends State<_PlayerExpandTarget> {
  final _states = WidgetStatesController();

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _states,
    builder: (context, _) {
      final radius = BorderRadius.circular(10);
      return InkWell(
        onTap: widget.onTap,
        statesController: _states,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: radius,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              width: 1.5,
              color: _states.value.contains(WidgetState.focused)
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
            ),
          ),
          child: widget.child,
        ),
      );
    },
  );
}
