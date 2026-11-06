import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// Device observations, not requested commands. Epoch rejects old-source events.
class AudioSnapshot {
  const AudioSnapshot({required this.epoch, this.playing = false,
    this.buffering = false, this.completed = false, this.position = 0,
    this.duration = 0, this.error});
  final int epoch;
  final bool playing, buffering, completed;
  final double position, duration;
  final String? error;
}

/// The only sound-device boundary. Tests implement this with recorded commands.
abstract class AudioDriver {
  Stream<AudioSnapshot> get snapshots;
  Future<void> open(Uri localUri, {required int epoch});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(double seconds);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> close();
}

void requireLocalAudio(Uri uri) {
  if (uri.scheme == 'file' && uri.host.isEmpty && uri.path.isNotEmpty &&
      !uri.hasQuery && !uri.hasFragment) return;
  if (uri.scheme == 'http' && uri.host == '127.0.0.1' && uri.hasPort &&
      uri.userInfo.isEmpty && !uri.hasQuery && !uri.hasFragment) return;
  throw ArgumentError('播放器仅接受本机缓存或已下载文件');
}

/// Constructing this adapter never initializes media_kit or a sound device.
class MediaKitAudioDriver implements AudioDriver {
  Player? _player;
  final _events = StreamController<AudioSnapshot>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int _epoch = 0;
  bool _opening = false;
  bool _closed = false;
  @override
  Stream<AudioSnapshot> get snapshots => _events.stream;

  void _emit({String? error}) {
    final player = _player;
    if (player == null || _opening || _closed) return;
    final state = player.state;
    _events.add(AudioSnapshot(epoch: _epoch, playing: state.playing,
      buffering: state.buffering, completed: state.completed,
      position: state.position.inMicroseconds / 1000000,
      duration: state.duration.inMicroseconds / 1000000, error: error));
  }

  Player _create() {
    if (_closed) throw StateError('播放器已关闭');
    MediaKit.ensureInitialized();
    // Independent pitch remains 1.0 while scaletempo changes playback rate.
    final player = Player(configuration: const PlayerConfiguration(
      pitch: true, title: 'XMPlus'));
    _player = player;
    _subscriptions.addAll([
      player.stream.playing.listen((_) => _emit()),
      player.stream.buffering.listen((_) => _emit()),
      player.stream.position.listen((_) => _emit()),
      player.stream.duration.listen((_) => _emit()),
      player.stream.completed.listen((_) => _emit()),
      player.stream.error.listen((_) => _emit(error: '音频播放失败，请重试')),
    ]);
    return player;
  }

  @override
  Future<void> open(Uri localUri, {required int epoch}) async {
    requireLocalAudio(localUri);
    _opening = true;
    try {
      final player = _player ?? _create();
      await player.stop();
      _epoch = epoch;
      await player.open(Media(localUri.toString()), play: false);
      await player.setPitch(1.0);
    } finally { _opening = false; }
    _emit();
  }
  @override
  Future<void> play() async { await _player?.play(); }
  @override
  Future<void> pause() async { await _player?.pause(); }
  @override
  Future<void> stop() async { await _player?.stop(); }
  @override
  Future<void> seek(double seconds) async {
    await _player?.seek(Duration(microseconds: (seconds * 1000000).round()));
  }
  @override
  Future<void> setRate(double rate) async { await _player?.setRate(rate); }
  @override
  Future<void> setVolume(double volume) async { await _player?.setVolume(volume); }
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions) { await subscription.cancel(); }
    await _player?.dispose();
    _player = null;
    await _events.close();
  }
}
