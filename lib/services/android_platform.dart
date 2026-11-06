import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';

/// Android platform operations that cannot use desktop command-line utilities.
class AndroidPlatform {
  static const _channel = MethodChannel('teikengstudio.xmplus/platform');

  static Future<Map<String, String>> mediaToolPaths() async {
    final values = await _channel.invokeMapMethod<String, String>(
      'mediaToolPaths',
    );
    final directory = values?['directory'];
    if (directory == null ||
        !p.isAbsolute(directory) ||
        directory.contains('\u0000') ||
        await Directory(directory).resolveSymbolicLinks() != directory) {
      throw const FormatException('Android 媒体工具安装目录无效');
    }
    final tools = <String, String>{};
    for (final name in ['ffmpeg', 'ffprobe']) {
      final path = values?[name];
      if (path == null ||
          !p.isAbsolute(path) ||
          path != p.join(directory, 'libxmplus_$name.so') ||
          await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          await File(path).resolveSymbolicLinks() != path) {
        throw const FormatException('随附 Android 媒体工具缺失或路径无效');
      }
      tools[name] = path;
    }
    return tools;
  }

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
