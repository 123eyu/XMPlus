import 'package:flutter/services.dart';

/// Android platform operations that cannot use desktop command-line utilities.
class AndroidPlatform {
  static const _channel = MethodChannel('teikengstudio.xmplus/platform');

  static Future<int> availableBytes(String path) async {
    final bytes = await _channel.invokeMethod<int>('availableBytes', {
      'path': path,
    });
    if (bytes == null || bytes < 0) throw const FormatException('无法查询可用空间');
    return bytes;
  }

  static Future<void> openAudioFile(String path) =>
      _channel.invokeMethod<void>('openAudioFile', {'path': path});
}
