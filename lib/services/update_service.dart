// Update dialog, startup preference and ABI selection adapted from PiliPlus
// lib/utils/update.dart and lib/pages/main/controller.dart, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:url_launcher/url_launcher.dart';

import '../storage/app_storage.dart';
import 'android_platform.dart';
import 'app_log.dart';
import 'http_log_attempt.dart';

enum UpdateSource { automatic, github, xin }

/// Stable release metadata; download resolution is deferred until user action.
class UpdateRelease {
  UpdateRelease._(
    this.tag,
    this.version,
    this.notes,
    this._assets, {
    this._xinVersionId,
  }) {
    AppLog.instance.trace("lib/services/update_service.dart::UpdateRelease._");
  }

  final String tag;
  final Version version;
  final String notes;
  final List<_UpdateAsset> _assets;
  final int? _xinVersionId;

  static Version parseVersion(String value) {
    AppLog.instance.trace(
      "lib/services/update_service.dart::UpdateRelease.parseVersion",
    );

    final text = value.startsWith('v') ? value.substring(1) : value;
    if (!RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
    ).hasMatch(text)) {
      throw const FormatException('版本号格式无效');
    }
    return Version.parse(text);
  }

  factory UpdateRelease.fromJson(Map<String, dynamic> data) {
    AppLog.instance.trace(
      "lib/services/update_service.dart::UpdateRelease.factory:fromJson",
    );

    final tag = data['tag_name'];
    if (tag is! String ||
        data['draft'] != false ||
        data['prerelease'] != false ||
        data['body'] != null && data['body'] is! String ||
        data['assets'] is! List) {
      throw const FormatException('GitHub 发布数据无效');
    }
    final version = parseVersion(tag);
    if (version.isPreRelease) throw const FormatException('不是稳定版本');
    final assets = <_UpdateAsset>[];
    for (final asset in data['assets'] as List) {
      if (asset is! Map ||
          asset['name'] is! String ||
          asset['browser_download_url'] is! String)
        continue;
      final name = asset['name'] as String;
      final uri = Uri.tryParse(asset['browser_download_url'] as String);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment)
        continue;
      final path = uri.pathSegments;
      if (path.length == 6 &&
          path[0] == 'teikengstudio' &&
          path[1].toLowerCase() == 'xmplus' &&
          path[2] == 'releases' &&
          path[3] == 'download' &&
          path[4] == tag &&
          path[5] == name) {
        assets.add(
          _UpdateAsset(
            name,
            uri,
            sha256: _UpdateAsset.parseDigest(asset['digest']),
            size: asset['size'] is int ? asset['size'] as int : null,
          ),
        );
      }
    }
    return UpdateRelease._(tag, version, data['body'] as String? ?? '', assets);
  }

  Uri get page {
    AppLog.instance.trace(
      "lib/services/update_service.dart::UpdateRelease.page.get",
    );
    return Uri.https('github.com', '/teikengstudio/XMPlus/releases/tag/$tag');
  }

  bool isNewerThan(String currentVersion) {
    AppLog.instance.trace(
      "lib/services/update_service.dart::UpdateRelease.isNewerThan",
    );

    final current = parseVersion(currentVersion);
    // SemVer build metadata is not an upgrade, even though pub_semver orders it.
    Version precedence(Version value) {
      AppLog.instance.trace(
        "lib/services/update_service.dart::UpdateRelease.isNewerThan.precedence",
      );
      return Version(
        value.major,
        value.minor,
        value.patch,
        pre: value.preRelease.isEmpty ? null : value.preRelease.join('.'),
      );
    }

    return precedence(version).compareTo(precedence(current)) > 0;
  }

  /// Exact filenames prevent selecting another architecture or a source archive.
  Uri downloadUri({
    required String platform,
    List<String> androidAbis = const [],
  }) {
    AppLog.instance.trace(
      "lib/services/update_service.dart::UpdateRelease.downloadUri",
    );

    final suffixes = switch (platform) {
      'android' => [
        for (final abi in androidAbis)
          if (const {'arm64-v8a', 'armeabi-v7a', 'x86_64'}.contains(abi))
            'android-$abi.apk',
      ],
      'windows-x64' => ['windows-x64-setup.exe'],
      _ => <String>[],
    };
    for (final suffix in suffixes) {
      final name = 'XMPlus-$version-$suffix';
      for (final asset in _assets) {
        if (asset.name == name) return asset.uri;
      }
    }
    return page;
  }
}

class _UpdateAsset {
  _UpdateAsset(this.name, this.uri, {this.sha256, this.size}) {
    AppLog.instance.trace('lib/services/update_service.dart::_UpdateAsset.new');
  }

  final String name;
  final Uri uri;
  final String? sha256;
  final int? size;

  static String? parseDigest(Object? value) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::_UpdateAsset.parseDigest',
    );
    if (value is! String) return null;
    final text = value.startsWith('sha256:') ? value.substring(7) : value;
    return RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(text)
        ? text.toLowerCase()
        : null;
  }
}

class _UpdateDownload {
  _UpdateDownload(this.file, this.sha256, this.size) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::_UpdateDownload.new',
    );
  }

  final File file;
  final String sha256;
  final int? size;
}

enum _UpdateAction { ignore, download, page }

class UpdateService extends ChangeNotifier {
  UpdateService(this.storage, {HttpClientAdapter? adapter}) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService.new',
    );
    if (adapter != null) _http.httpClientAdapter = adapter;
  }

  final AppStorage storage;
  // No account interceptors, cookies or credentials on artifact requests.
  final Dio _http = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: false,
      headers: const {'Accept': 'application/json', 'User-Agent': 'XMPlus'},
    ),
  );
  final _cancel = CancelToken();
  CancelToken? _downloadCancel;
  PackageInfo? packageInfo;
  bool checking = false;
  String? message;
  String? error;
  bool _disposed = false;

  Map get _preferences {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._preferences.get',
    );
    final value = (storage.state['settings'] as Map)['updates'];
    return value is Map ? value : const {};
  }

  bool get autoCheck {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService.autoCheck.get',
    );
    return _preferences['autoCheck'] != false;
  }

  UpdateSource get source {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService.source.get',
    );
    return switch (_preferences['source']) {
      'github' => UpdateSource.github,
      'xin' => UpdateSource.xin,
      _ => UpdateSource.automatic,
    };
  }

  String? get ignoredVersion {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService.ignoredVersion.get',
    );
    final value = _preferences['ignoredVersion'];
    return value is String ? value : null;
  }

  String get versionLabel {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService.versionLabel.get',
    );
    return packageInfo == null
        ? '正在读取版本…'
        : '${packageInfo!.version}${packageInfo!.buildNumber.isEmpty ? '' : '+${packageInfo!.buildNumber}'}';
  }

  void _changed() {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._changed',
    );
    if (!_disposed) notifyListeners();
  }

  Future<bool> _save(Map<String, dynamic> changes) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._save',
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        'lib/services/update_service.dart::UpdateService._save.closure#1',
      );
      try {
        await storage.transaction((state) {
          AppLog.instance.trace(
            'lib/services/update_service.dart::UpdateService._save.closure#1.closure#1',
          );
          final settings = state['settings'] as Map;
          final previous = settings['updates'];
          settings['updates'] = <String, dynamic>{
            if (previous is Map) ...Map<String, dynamic>.from(previous),
            ...changes,
          };
        });
        error = null;
        _changed();
        return true;
      } catch (failure, stack) {
        _recordFailure('Saving update settings failed', failure, stack);
        error = '更新设置保存失败，原设置已保留';
        _changed();
        return false;
      }
    });
  }

  Future<void> setAutoCheck(bool value) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService.setAutoCheck',
    );
    await _save({'autoCheck': value});
  }

  Future<void> setSource(UpdateSource value) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService.setSource',
    );
    await _save({'source': value.name});
  }

  Future<void> clearIgnoredVersion() async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService.clearIgnoredVersion',
    );
    await _save({'ignoredVersion': null});
  }

  void _localFailure(String operation, Object failure, StackTrace stack) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._localFailure',
    );
    // Never log Dio requestOptions/body or JSON parser source text.
    final safe = failure is DioException
        ? StateError(
            'Update transport ${failure.type.name}; HTTP ${failure.response?.statusCode ?? '-'}',
          )
        : failure is FormatException
        ? FormatException(failure.message)
        : failure;
    AppLog.instance.write(
      AppLogLevel.warning,
      'update',
      operation,
      error: safe,
      stackTrace: stack,
      localOnly: true,
    );
  }

  Future<Map<String, dynamic>?> _githubRelease({
    String? tag,
    CancelToken? token,
  }) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._githubRelease',
    );
    final suffix = tag == null ? 'latest' : 'tags/${Uri.encodeComponent(tag)}';
    try {
      final response = await _http.get<String>(
        'https://api.github.com/repos/teikengstudio/XMPlus/releases/$suffix',
        options: Options(responseType: ResponseType.plain),
        cancelToken: token ?? _cancel,
      );
      AppLog.instance.write(
        AppLogLevel.info,
        'update',
        'GitHub update response: ${response.statusCode}',
        localOnly: true,
      );
      return _jsonObject(response.data);
    } on DioException catch (failure, stack) {
      _localFailure('GitHub update request failed', failure, stack);
      if (failure.response?.statusCode == 404 && tag == null) return null;
      rethrow;
    }
  }

  static Map<String, dynamic> _jsonObject(String? text) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._jsonObject',
    );
    final value = jsonDecode(text ?? '');
    if (value is! Map<String, dynamic>)
      throw const FormatException('更新服务返回的数据无效');
    return value;
  }

  Future<Map<String, dynamic>> _xinRequest(
    String endpoint,
    Map<String, dynamic> body,
    CancelToken token,
  ) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._xinRequest',
    );
    const secret = String.fromEnvironment('XIN_CLIENT_SECRET');
    if (secret.isEmpty)
      throw const FormatException('此构建未配置莘应用更新凭据，请使用 GitHub 更新源');
    try {
      final response = await _http.post<String>(
        'https://xinappstore.qiumingsanyu.top/api/app/update/$endpoint',
        // Use the documented JSON credential form accepted by the deployed API.
        // Neither this body nor credential headers are written to diagnostics.
        data: {
          ...body,
          'client_id': 'xin_e6856fd600973e1af5e7ee6b',
          'client_secret': secret,
        },
        options: Options(responseType: ResponseType.plain),
        cancelToken: token,
      );
      AppLog.instance.write(
        AppLogLevel.info,
        'update',
        'Xin $endpoint response: ${response.statusCode}',
        localOnly: true,
      );
      return _jsonObject(response.data);
    } catch (failure, stack) {
      _localFailure('Xin $endpoint request failed', failure, stack);
      rethrow;
    }
  }

  Future<UpdateRelease?> _xinLatest({CancelToken? token}) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._xinLatest',
    );
    final data = await _xinRequest('check', {
      'identifier': 'teikengstudio.xmplus',
    }, token ?? _cancel);
    if (data['update_available'] == false) return null;
    final latest = data['latest'];
    if (data['update_available'] != true ||
        latest is! Map ||
        latest['version_name'] is! String ||
        latest['version_id'] is! int) {
      throw const FormatException('莘应用返回的版本数据无效');
    }
    final version = UpdateRelease.parseVersion(
      latest['version_name'] as String,
    );
    if (version.isPreRelease) throw const FormatException('莘应用未返回稳定版本');
    return UpdateRelease._(
      'v$version',
      version,
      latest['changelog'] is String ? latest['changelog'] as String : '',
      const [],
      xinVersionId: latest['version_id'] as int,
    );
  }

  Future<UpdateRelease?> _latest() async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._latest',
    );
    final selected = source;
    if (selected == UpdateSource.xin) return _xinLatest();
    try {
      final data = await _githubRelease();
      return data == null ? null : UpdateRelease.fromJson(data);
    } on DioException catch (failure) {
      // Only failure to establish a connection triggers the automatic fallback.
      // HTTP failures, TLS errors and response timeouts stay on the chosen source.
      if (selected != UpdateSource.automatic ||
          failure.type != DioExceptionType.connectionTimeout)
        rethrow;
      return _xinLatest();
    }
  }

  Future<List<String>> _assetNames(UpdateRelease release) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._assetNames',
    );
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      return [
        for (final abi in info.supportedAbis)
          if (const {'arm64-v8a', 'armeabi-v7a', 'x86_64'}.contains(abi))
            'XMPlus-${release.version}-android-$abi.apk',
      ];
    }
    if (Platform.isWindows && Abi.current() == Abi.windowsX64) {
      return ['XMPlus-${release.version}-windows-x64-setup.exe'];
    }
    throw const FormatException('当前平台不支持应用内安装，请查看官方发布页');
  }

  static Uri? _https(Object? value) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._https',
    );
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            !uri.hasFragment
        ? uri
        : null;
  }

  Future<(_UpdateAsset, Uri?)> _resolveAsset(
    UpdateRelease release,
    List<String> names,
    CancelToken token,
  ) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._resolveAsset',
    );
    final assets = <_UpdateAsset>[...release._assets];
    Uri? sums;
    if (release._xinVersionId != null) {
      final response = await _xinRequest('download', {
        'version_id': release._xinVersionId,
        'channel': Platform.isAndroid ? 'default' : 'windows',
      }, token);
      final data = response['data'];
      if (data is! Map || data['identifier'] != 'teikengstudio.xmplus') {
        throw const FormatException('莘应用返回了其他应用或无效的下载信息');
      }
      final version = data['version'];
      if (version is! Map ||
          version['id'] != release._xinVersionId ||
          version['version_name'] is! String ||
          UpdateRelease.parseVersion(version['version_name'] as String) !=
              release.version) {
        throw const FormatException('莘应用下载版本与更新信息不一致');
      }
      final candidates = data['candidates'];
      if (candidates is List) {
        for (final candidate in candidates) {
          if (candidate is! Map ||
              !const {'direct', 'http'}.contains(candidate['type']))
            continue;
          final uri = _https(candidate['resolved']);
          if (uri == null) continue;
          final origin = candidate['uri'] is String
              ? Uri.tryParse(candidate['uri'] as String)
              : null;
          final name = candidate['name'] is String
              ? candidate['name'] as String
              : origin != null && origin.pathSegments.isNotEmpty
              ? origin.pathSegments.last
              : uri.pathSegments.isNotEmpty
              ? uri.pathSegments.last
              : '';
          assets.add(
            _UpdateAsset(
              name,
              uri,
              sha256: _UpdateAsset.parseDigest(
                candidate['sha256'] ?? candidate['digest'],
              ),
              size: candidate['size'] is int ? candidate['size'] as int : null,
            ),
          );
        }
      }
      final main = _https(data['main']);
      if (main != null && main.pathSegments.isNotEmpty) {
        assets.add(
          _UpdateAsset(
            main.pathSegments.last,
            main,
            sha256: _UpdateAsset.parseDigest(data['sha256'] ?? data['digest']),
            size: data['size'] is int ? data['size'] as int : null,
          ),
        );
      }
      if (assets.isEmpty) {
        throw FormatException(
          data['need_parse'] == true
              ? '莘应用下载暂不可用，请切换 GitHub 更新源'
              : '当前设备不支持此渠道',
        );
      }
    }
    for (final asset in assets) {
      if (asset.name == 'SHA256SUMS') sums = asset.uri;
    }
    for (final name in names) {
      for (final asset in assets) {
        if (asset.name == name) return (asset, sums);
      }
    }
    throw FormatException(
      release._xinVersionId != null ? '当前设备不支持此渠道' : '此版本没有适合当前设备的安装包，请查看官方发布页',
    );
  }

  Future<String> _checksum(
    UpdateRelease release,
    _UpdateAsset asset,
    Uri? sums,
    CancelToken token,
  ) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._checksum',
    );
    if (asset.sha256 != null) return asset.sha256!;
    if (sums == null && release._xinVersionId != null) {
      // Mirrored resources can omit hashes; bind them to the original release.
      final data = await _githubRelease(tag: release.tag, token: token);
      final github = UpdateRelease.fromJson(data!);
      for (final original in github._assets) {
        if (original.name == asset.name && original.sha256 != null)
          return original.sha256!;
        if (original.name == 'SHA256SUMS') sums = original.uri;
      }
    }
    if (sums == null) throw const FormatException('此版本缺少安装包校验信息，暂时无法安装');
    try {
      final response = await _http.get<String>(
        sums.toString(),
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          maxRedirects: 5,
          headers: const {'Accept': 'text/plain'},
        ),
        cancelToken: token,
      );
      for (final line in const LineSplitter().convert(response.data ?? '')) {
        final match = RegExp(r'^([a-fA-F0-9]{64})[ \t]+\*?(.+)$')
            .firstMatch(line.trim());
        if (match != null && match[2] == asset.name)
          return match[1]!.toLowerCase();
      }
      throw const FormatException('安装包校验信息不完整，暂时无法安装');
    } catch (failure, stack) {
      _localFailure('Reading update checksum failed', failure, stack);
      rethrow;
    }
  }

  void _checkCancelled(CancelToken token) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._checkCancelled',
    );
    if (token.isCancelled) throw token.cancelError!;
    if (_disposed) throw StateError('Update service disposed');
  }

  Future<void> _deleteFile(File file) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._deleteFile',
    );
    try {
      if (await file.exists()) await file.delete();
    } catch (failure, stack) {
      _localFailure('Cleaning update artifact failed', failure, stack);
    }
  }

  Future<void> _cleanOldArtifacts(Directory directory) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._cleanOldArtifacts',
    );
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File ||
            !RegExp(
              r'^XMPlus-\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?-(?:windows-x64-setup\.exe|android-(?:arm64-v8a|armeabi-v7a|x86_64)\.apk)(?:\.part)?$',
            ).hasMatch(p.basename(entity.path)))
          continue;
        final stat = await entity.stat();
        // Handed-off installers must survive UI/app disposal and OS permission flows.
        if (DateTime.now().difference(stat.modified) > const Duration(days: 7))
          await _deleteFile(entity);
      }
    } catch (failure, stack) {
      _localFailure('Cleaning old updates failed', failure, stack);
    }
  }

  Future<void> _verify(_UpdateDownload download, CancelToken token) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._verify',
    );
    _checkCancelled(token);
    final length = await download.file.length();
    if (length < 4 ||
        download.size != null &&
            download.size! > 0 &&
            length != download.size) {
      throw const FormatException('安装包大小不符，请重新下载');
    }
    final hash = await sha256
        .bind(
          download.file.openRead().map((chunk) {
            AppLog.instance.trace(
              'lib/services/update_service.dart::UpdateService._verify.closure#1',
            );
            _checkCancelled(token);
            return chunk;
          }),
        )
        .first;
    _checkCancelled(token);
    if (hash.toString() != download.sha256)
      throw const FormatException('安装包校验失败，请重新下载');
    final handle = await download.file.open();
    try {
      final header = await handle.read(4);
      final valid = Platform.isAndroid
          ? header[0] == 0x50 &&
                header[1] == 0x4b &&
                header[2] == 3 &&
                header[3] == 4
          : header[0] == 0x4d && header[1] == 0x5a;
      if (!valid) throw const FormatException('下载内容不是有效的安装包');
    } finally {
      await handle.close();
    }
  }

  Future<_UpdateDownload> _download(
    UpdateRelease release,
    CancelToken token,
    void Function(String, double?) progress,
  ) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._download',
    );
    _downloadCancel = token;
    File? partial;
    try {
      final names = await _assetNames(release);
      _checkCancelled(token);
      final (asset, sums) = await _resolveAsset(release, names, token);
      final expected = await _checksum(release, asset, sums, token);
      _checkCancelled(token);
      final root = Platform.isAndroid
          ? await getApplicationSupportDirectory()
          : await getApplicationCacheDirectory();
      final directory = Directory(p.join(root.path, 'updates'));
      await directory.create(recursive: true);
      await _cleanOldArtifacts(directory);
      _checkCancelled(token);
      partial = File(p.join(directory.path, '${asset.name}.part'));
      progress('正在下载更新…', null);
      await _http.download(
        asset.uri.toString(),
        partial.path,
        cancelToken: token,
        deleteOnError: true,
        options: Options(
          followRedirects: true,
          maxRedirects: 5,
          receiveTimeout: const Duration(minutes: 2),
          headers: const {'Accept': 'application/octet-stream'},
        ),
        onReceiveProgress: (received, total) {
          AppLog.instance.trace(
            'lib/services/update_service.dart::UpdateService._download.closure#1',
          );
          progress(
            '正在下载更新…',
            total > 0 ? (received / total).clamp(0.0, 1.0) : null,
          );
        },
      );
      _checkCancelled(token);
      progress('正在校验安装包…', null);
      await _verify(_UpdateDownload(partial, expected, asset.size), token);
      _checkCancelled(token);
      final target = File(p.join(directory.path, asset.name));
      if (await target.exists()) await target.delete();
      final ready = await partial.rename(target.path);
      partial = null;
      return _UpdateDownload(ready, expected, asset.size);
    } catch (failure, stack) {
      if (!token.isCancelled && !_disposed)
        _localFailure('Downloading update failed', failure, stack);
      if (!token.isCancelled &&
          !_disposed &&
          source == UpdateSource.automatic &&
          release._xinVersionId == null &&
          failure is DioException &&
          failure.type == DioExceptionType.connectionTimeout) {
        if (partial != null) {
          await _deleteFile(partial);
          partial = null;
        }
        progress('正在切换更新源…', null);
        final mirror = await _xinLatest(token: token);
        _checkCancelled(token);
        if (mirror == null || mirror.version != release.version) {
          throw const FormatException('莘应用暂未提供此版本，请稍后重试');
        }
        return await _download(mirror, token, progress);
      }
      rethrow;
    } finally {
      if (partial != null) await _deleteFile(partial);
      if (identical(_downloadCancel, token)) _downloadCancel = null;
    }
  }

  Future<void> _install(_UpdateDownload download) async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._install',
    );
    if (Platform.isAndroid) {
      await AndroidPlatform.installUpdate(download.file.path);
    } else if (Platform.isWindows) {
      await const MethodChannel('teikengstudio.xmplus/update')
          .invokeMethod<void>('installUpdate', {'path': download.file.path});
    } else {
      throw const FormatException('当前平台不支持应用内安装');
    }
  }

  Future<void> check(BuildContext context, {bool manual = false}) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService.check',
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        'lib/services/update_service.dart::UpdateService.check.closure#1',
      );
      if (checking || _disposed) return;
      var interactive = manual;
      checking = true;
      message = null;
      error = null;
      _changed();
      try {
        packageInfo ??= await PackageInfo.fromPlatform();
        _changed();
        if (_disposed || !manual && !autoCheck) return;
        final release = await _latest();
        if (release == null || !release.isNewerThan(packageInfo!.version)) {
          message = '已是最新版本或暂无已发布的稳定版本';
          if (manual && context.mounted && !_disposed)
            _toast(context, message!);
          return;
        }
        message = '发现新版本 ${release.tag}';
        if (!context.mounted ||
            _disposed ||
            !manual &&
                (!autoCheck || ignoredVersion == release.version.toString()))
          return;
        final action = await showDialog<_UpdateAction>(
          context: context,
          builder: (dialogContext) {
            AppLog.instance.trace(
              'lib/services/update_service.dart::UpdateService.check.closure#1.closure#1',
            );
            return AlertDialog(
              title: const Text('发现新版本'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        release.tag,
                        style: Theme.of(dialogContext).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text('当前版本：$versionLabel'),
                      const SizedBox(height: 16),
                      SelectableText(
                        release.notes.isEmpty ? '此版本未提供更新说明。' : release.notes,
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () {
                          AppLog.instance.trace(
                            'lib/services/update_service.dart::UpdateService.check.closure#1.closure#1.closure#1',
                          );
                          Navigator.pop(dialogContext, _UpdateAction.page);
                        },
                        child: const Text('查看官方发布页'),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    AppLog.instance.trace(
                      'lib/services/update_service.dart::UpdateService.check.closure#1.closure#1.closure#2',
                    );
                    Navigator.pop(dialogContext, _UpdateAction.ignore);
                  },
                  child: const Text('忽略此版本'),
                ),
                TextButton(
                  onPressed: () {
                    AppLog.instance.trace(
                      'lib/services/update_service.dart::UpdateService.check.closure#1.closure#1.closure#3',
                    );
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('稍后'),
                ),
                FilledButton(
                  onPressed: () {
                    AppLog.instance.trace(
                      'lib/services/update_service.dart::UpdateService.check.closure#1.closure#1.closure#4',
                    );
                    Navigator.pop(dialogContext, _UpdateAction.download);
                  },
                  child: const Text('下载更新'),
                ),
              ],
            );
          },
        );
        if (_disposed) return;
        if (action != null) interactive = true;
        if (action == _UpdateAction.ignore) {
          final saved = await _save({
            'ignoredVersion': release.version.toString(),
          });
          if (!saved && context.mounted && !_disposed) _toast(context, error!);
        } else if (action == _UpdateAction.page) {
          if (!await launchUrl(
            release.page,
            mode: LaunchMode.externalApplication,
          ))
            throw const FormatException('无法打开官方发布页');
        } else if (action == _UpdateAction.download && context.mounted) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) {
              AppLog.instance.trace(
                'lib/services/update_service.dart::UpdateService.check.closure#1.closure#2',
              );
              return _UpdateDownloadDialog(service: this, release: release);
            },
          );
        }
      } catch (failure, stack) {
        if (!_disposed)
          _localFailure('Checking for updates failed', failure, stack);
        error = failure is FormatException
            ? failure.message.toString()
            : '检查更新失败，请检查网络后重试；也可切换更新源或查看官方发布页';
        if (interactive && context.mounted && !_disposed)
          _toast(context, error!);
      } finally {
        checking = false;
        _changed();
      }
    });
  }

  static void _toast(BuildContext context, String text) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._toast',
    );
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _recordFailure(String message, Object failure, StackTrace stack) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService._recordFailure',
    );
    if (!HttpLogOperation.reportFailure(failure, stack) &&
        !AppLog.instance.errorWasRecorded(failure)) {
      AppLog.instance.write(
        AppLogLevel.error,
        'update',
        message,
        error: failure,
        stackTrace: stack,
      );
    }
    AppLog.instance.requestUploadPrompt();
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      'lib/services/update_service.dart::UpdateService.dispose',
    );
    _disposed = true;
    _cancel.cancel('Update service disposed');
    _downloadCancel?.cancel('Update service disposed');
    _http.close(force: true);
    super.dispose();
  }
}

class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({required this.service, required this.release});
  final UpdateService service;
  final UpdateRelease release;

  @override
  State<_UpdateDownloadDialog> createState() {
    AppLog.instance.trace(
      'lib/services/update_service.dart::_UpdateDownloadDialog.createState',
    );
    return _UpdateDownloadDialogState();
  }
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  CancelToken _token = CancelToken();
  _UpdateDownload? _download;
  String _stage = '正在获取下载信息…';
  double? _progress;
  String? _error;
  bool _busy = true;
  bool _installing = false;
  bool _handedOff = false;
  bool _closing = false;
  Future<void>? _pending;

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/services/update_service.dart::_UpdateDownloadDialogState.initState',
    );
    super.initState();
    _retryDownload();
  }

  void _retryDownload() {
    AppLog.instance.trace(
      'lib/services/update_service.dart::_UpdateDownloadDialogState._retryDownload',
    );
    _pending = _startDownload();
    unawaited(_pending!);
  }

  Future<void> _startDownload() async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::_UpdateDownloadDialogState._startDownload',
    );
    _token = CancelToken();
    setState(() {
      AppLog.instance.trace(
        'lib/services/update_service.dart::_UpdateDownloadDialogState._startDownload.closure#1',
      );
      _error = null;
      _busy = true;
      _stage = '正在获取下载信息…';
      _progress = null;
    });
    try {
      final result = await widget.service._download(widget.release, _token, (
        stage,
        progress,
      ) {
        AppLog.instance.trace(
          'lib/services/update_service.dart::_UpdateDownloadDialogState._startDownload.closure#2',
        );
        if (!mounted || _token.isCancelled) return;
        setState(() {
          AppLog.instance.trace(
            'lib/services/update_service.dart::_UpdateDownloadDialogState._startDownload.closure#2.closure#1',
          );
          _stage = stage;
          _progress = progress;
        });
      });
      if (!mounted || _token.isCancelled) {
        await widget.service._deleteFile(result.file);
        return;
      }
      setState(() {
        AppLog.instance.trace(
          'lib/services/update_service.dart::_UpdateDownloadDialogState._startDownload.closure#3',
        );
        _download = result;
        _busy = false;
      });
    } catch (failure) {
      if (!mounted || _token.isCancelled) return;
      setState(() {
        AppLog.instance.trace(
          'lib/services/update_service.dart::_UpdateDownloadDialogState._startDownload.closure#4',
        );
        _busy = false;
        _error = failure is FormatException
            ? failure.message.toString()
            : '下载失败，请检查网络后重试或切换更新源';
      });
    }
  }

  Future<void> _install() async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::_UpdateDownloadDialogState._install',
    );
    setState(() {
      AppLog.instance.trace(
        'lib/services/update_service.dart::_UpdateDownloadDialogState._install.closure#1',
      );
      _installing = true;
      _error = null;
    });
    var verified = false;
    try {
      await widget.service._verify(_download!, _token);
      verified = true;
      // Once passed to the OS, keep the file even if permission/UAC is denied.
      _handedOff = true;
      await widget.service._install(_download!);
      if (!mounted) return;
      setState(() {
        AppLog.instance.trace(
          'lib/services/update_service.dart::_UpdateDownloadDialogState._install.closure#2',
        );
        _installing = false;
        _stage = '已打开系统安装器。如未完成安装，可再次点击安装。';
      });
    } catch (failure, stack) {
      widget.service._localFailure(
        'Starting update installer failed',
        failure,
        stack,
      );
      if (!verified) {
        final invalid = _download;
        _download = null;
        if (!_handedOff && invalid != null)
          await widget.service._deleteFile(invalid.file);
      }
      if (!mounted) return;
      setState(() {
        AppLog.instance.trace(
          'lib/services/update_service.dart::_UpdateDownloadDialogState._install.closure#3',
        );
        _installing = false;
        _error = failure is FormatException
            ? failure.message.toString()
            : '安装未完成，请允许安装后重试';
      });
    }
  }

  Future<void> _close() async {
    AppLog.instance.trace(
      'lib/services/update_service.dart::_UpdateDownloadDialogState._close',
    );
    if (_closing) return;
    _closing = true;
    _token.cancel('User cancelled update');
    // Finish deleting this attempt's partial before another dialog can download.
    await _pending;
    if (_download != null && !_handedOff) {
      await widget.service._deleteFile(_download!.file);
      _download = null;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      'lib/services/update_service.dart::_UpdateDownloadDialogState.dispose',
    );
    _token.cancel('Update dialog disposed');
    if (!_handedOff && _download != null)
      unawaited(widget.service._deleteFile(_download!.file));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/services/update_service.dart::_UpdateDownloadDialogState.build',
    );
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('更新至 ${widget.release.tag}'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _error ??
                    (_installing
                        ? '正在打开系统安装器…'
                        : _download != null
                        ? (_handedOff ? _stage : '下载完成，点击安装')
                        : _stage),
              ),
              if (_busy || _installing) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _installing ? null : _progress),
                if (_progress != null && !_installing) ...[
                  const SizedBox(height: 8),
                  Text('${(_progress! * 100).round()}%'),
                ],
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _installing ? null : _close,
            child: Text(_busy ? '取消下载' : '稍后'),
          ),
          if (_download != null)
            FilledButton(
              onPressed: _installing ? null : _install,
              child: Text(_error == null ? '安装' : '重试安装'),
            )
          else if (_error != null)
            FilledButton(onPressed: _retryDownload, child: const Text('重试下载')),
        ],
      ),
    );
  }
}
