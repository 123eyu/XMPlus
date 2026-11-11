// SPDX-License-Identifier: GPL-3.0-only
// Environment/inline bridge structure adapted from PiliPlus
// lib/pages/login/geetest/geetest_webview_dialog.dart, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a. Official GeeTest v4 only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../services/browser_captcha.dart';
import '../services/geetest_document.dart';

/// A new private profile per challenge; never receives application credentials.
class GeetestDialog extends StatefulWidget {
  const GeetestDialog({
    required this.captchaId,
    required this.dataDirectory,
    super.key,
  });

  final String captchaId;
  final String dataDirectory;

  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required String captchaId,
    required String dataDirectory,
  }) => showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        GeetestDialog(captchaId: captchaId, dataDirectory: dataDirectory),
  );

  @override
  State<GeetestDialog> createState() => _GeetestDialogState();
}

class _GeetestDialogState extends State<GeetestDialog> {
  static const _installer =
      'https://developer.microsoft.com/microsoft-edge/webview2/';
  final _nonce = _newNonce();
  late final String _documentUrl = Platform.isAndroid
      ? 'https://appassets.androidplatform.net/xmplus-captcha/$_nonce/index.html'
      : 'about:blank';
  WebViewEnvironment? _environment;
  Directory? _profile;
  Timer? _timeout;
  bool _ready = false, _accepting = false, _finished = false;
  String? _error;
  bool _runtimeMissing = false;
  String _stage = '运行时检测';
  BrowserCaptchaSession? _browser;
  bool _usingBrowser = false, _browserOpening = false;
  String? _browserError;

  static String _newNonce() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
  }

  void _invalidate() {
    _finished = true;
    _accepting = false;
    _timeout?.cancel();
    final browser = _browser;
    _browser = null;
    if (browser != null) unawaited(browser.close());
  }

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      if (!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(widget.captchaId)) {
        throw const FormatException();
      }
      // Plugin debug output can include challenge responses and request URLs.
      PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
      if (Platform.isWindows) {
        final version = await WebViewEnvironment.getAvailableVersion();
        if (!mounted || _usingBrowser || _finished) return;
        if (version == null || version.isEmpty) {
          _runtimeMissing = true;
          _fail('未检测到 WebView2 运行时。可安装微软官方运行时后重试，或返回 Cookie 登录。');
          return;
        }
        _stage = '验证资料目录';
        final base = await Directory(p.join(widget.dataDirectory, 'captcha'))
            .create(recursive: true);
        final profile = await base.createTemp('session-');
        _profile = profile;
        if (!mounted || _usingBrowser || _finished) {
          await _deleteProfile(profile);
          return;
        }
        _stage = 'WebView2 环境创建';
        final environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: profile.path,
            allowSingleSignOnUsingOSPrimaryAccount: false,
            language: 'zh-CN',
          ),
        );
        if (!mounted || _usingBrowser || _finished) {
          await environment.dispose();
          await _deleteProfile(profile);
          return;
        }
        _environment = environment;
      } else if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
        _fail('此平台暂不能显示安全验证，请返回导入登录信息。');
        return;
      }
      if (!mounted || _usingBrowser || _finished) return;
      setState(() => _ready = true);
      _timeout = Timer(
        const Duration(seconds: 45),
        () => _fail('安全验证加载超时，请关闭后重试，或使用登录信息导入。'),
      );
    } catch (error) {
      _failStage(error);
      final profile = _profile;
      if (profile != null && (!mounted || _usingBrowser || _finished)) {
        await _deleteProfile(profile);
      }
    }
  }

  void _fail(String message) {
    if (_usingBrowser) return;
    _accepting = false;
    _timeout?.cancel();
    if (mounted && !_finished) setState(() => _error = message);
  }

  void _failStage(Object error) {
    final code =
        error is PlatformException &&
            RegExp(r'^-?[0-9]{1,12}$').hasMatch(error.code)
        ? '（错误码 ${error.code}）'
        : '';
    _fail('$_stage失败$code。请关闭后重试，或返回 Cookie 登录。');
  }

  static Future<void> _deleteProfile(Directory profile) async {
    // WebView2 may still hold the directory briefly; it contains only this
    // challenge's isolated private profile, never an account credential store.
    try {
      if (await profile.exists()) await profile.delete(recursive: true);
    } on FileSystemException {
      /* The runtime still owns its temporary profile. */
    }
  }

  @override
  void dispose() {
    _invalidate();
    final environment = _environment, profile = _profile;
    unawaited(() async {
      try {
        await environment?.dispose();
      } catch (_) {
        /* Already disposed. */
      }
      if (profile != null) await _deleteProfile(profile);
    }());
    super.dispose();
  }

  bool _allowedResource(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      [
        'geetest.com',
        'geevisit.com',
        'gsensebot.com',
      ].any((host) => uri.host == host || uri.host.endsWith('.$host'));

  String _html() => geetestDocument(widget.captchaId, bridgeNonce: _nonce);

  Future<void> _created(InAppWebViewController controller) async {
    try {
      if (Platform.isWindows) {
        _stage = '下载安全策略初始化';
        final installed = await MethodChannel(
          'com.pichillilorenzo/flutter_inappwebview_${controller.getViewId()}',
        ).invokeMethod<bool>('xmplusDenyDownloads', const <String, dynamic>{});
        if (installed != true)
          throw StateError('Native download guard unavailable');
      }
      if (!mounted || _finished || _usingBrowser || _error != null) return;
      controller.addJavaScriptHandler(
        handlerName: 'xmlyCaptcha',
        callback: (args) async {
          if (!_accepting ||
              !mounted ||
              _finished ||
              args.length != 3 ||
              args[0] != _nonce ||
              (await controller.getUrl())?.toString() != _documentUrl)
            return null;
          if (!mounted || !_accepting || _finished) return null;
          switch (args[1]) {
            case 'ready':
              _timeout?.cancel();
              break;
            case 'success':
              final result = parseGeetestResult(args[2], widget.captchaId);
              if (result == null) {
                _fail('安全验证结果无效，请关闭后重新验证。');
                return null;
              }
              _finished = true;
              _accepting = false;
              Navigator.of(context).pop(result);
              break;
            case 'error':
              _fail('安全验证未完成，请关闭后重试，或使用登录信息导入。');
              break;
            case 'close':
              _finished = true;
              _accepting = false;
              Navigator.of(context).pop();
              break;
          }
          return null;
        },
      );
      _accepting = true;
      _stage = '验证页面加载';
      if (Platform.isAndroid) {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(_documentUrl)),
        );
      } else {
        await controller.loadData(data: _html(), baseUrl: WebUri(_documentUrl));
      }
    } catch (error) {
      _failStage(error);
    }
  }

  Future<void> _openInstaller() async {
    try {
      await InAppBrowser.openWithSystemBrowser(url: WebUri(_installer));
    } catch (_) {
      _fail('无法打开浏览器。请访问 $_installer 安装官方运行时，或返回导入登录信息。');
    }
  }

  Future<void> _openBrowser() async {
    if (_browserOpening || _finished) return;
    _accepting = false;
    _timeout?.cancel();
    setState(() {
      _usingBrowser = true;
      _browserOpening = true;
      _browserError = null;
    });
    BrowserCaptchaSession? session;
    try {
      session = _browser ?? await BrowserCaptchaSession.open(widget.captchaId);
      if (!mounted || _finished) {
        await session.close();
        return;
      }
      if (_browser == null) {
        _browser = session;
        unawaited(_waitForBrowser(session));
      }
      if (!await launchUrl(session.uri, mode: LaunchMode.externalApplication)) {
        throw StateError('Browser unavailable');
      }
    } catch (_) {
      if (identical(_browser, session)) _browser = null;
      await session?.close();
      if (mounted && !_finished) {
        setState(() => _browserError = '无法打开系统浏览器，请重试，或关闭后导入登录信息。');
      }
    } finally {
      if (mounted) setState(() => _browserOpening = false);
    }
  }

  Future<void> _waitForBrowser(BrowserCaptchaSession session) async {
    final result = await session.result;
    if (!mounted || _finished || !identical(_browser, session)) return;
    _browser = null;
    if (result == null) {
      setState(() => _browserError = '浏览器验证已过期，请重新打开浏览器。');
      return;
    }
    // A Windows close/exit prompt can cover this dialog during verification.
    // Do not pop that prompt or continue to SMS consent underneath it.
    if (ModalRoute.of(context)?.isCurrent != true) {
      setState(() => _browserError = '浏览器验证已中断，请重新打开浏览器。');
      return;
    }
    _invalidate();
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _invalidate();
    },
    child: AlertDialog(
      insetPadding: const EdgeInsets.all(12),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      title: const Text('安全验证', maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 440,
        height: min(440.0, MediaQuery.sizeOf(context).height * 0.6),
        child: _usingBrowser
            ? SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.open_in_browser, size: 40),
                    const SizedBox(height: 16),
                    const Text('请在系统浏览器完成安全验证，然后返回 XMPlus 继续。'),
                    const SizedBox(height: 12),
                    const Text('验证成功后仍需由你确认发送短信。'),
                    if (_browserOpening) const LinearProgressIndicator(),
                    if (_browserError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _browserError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              )
            : _error != null
            ? SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_error!),
                    if (Platform.isWindows && _runtimeMissing) ...[
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: _openInstaller,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('微软 WebView2 下载页'),
                      ),
                    ],
                    const SizedBox(height: 16),
                    const Text('关闭此窗口后，仍可选择“导入登录信息”。'),
                  ],
                ),
              )
            : !_ready
            ? const Center(child: CircularProgressIndicator())
            : InAppWebView(
                webViewEnvironment: _environment,
                initialSettings: InAppWebViewSettings(
                  incognito: true,
                  javaScriptEnabled: true,
                  isInspectable: false,
                  disableContextMenu: true,
                  useShouldOverrideUrlLoading: true,
                  useShouldInterceptRequest: true,
                  supportMultipleWindows: false,
                  javaScriptCanOpenWindowsAutomatically: false,
                  allowFileAccess: false,
                  allowContentAccess: false,
                  allowFileAccessFromFileURLs: false,
                  allowUniversalAccessFromFileURLs: false,
                  thirdPartyCookiesEnabled: false,
                  geolocationEnabled: false,
                  saveFormData: false,
                  mediaPlaybackRequiresUserGesture: true,
                  useOnDownloadStart: true,
                ),
                onWebViewCreated: _created,
                shouldOverrideUrlLoading: (_, action) async {
                  if (!action.isForMainFrame) {
                    return NavigationActionPolicy.ALLOW;
                  }
                  final url = action.request.url?.toString();
                  return url == 'about:blank' ||
                          (Platform.isAndroid &&
                              _accepting &&
                              !_finished &&
                              _error == null &&
                              url == _documentUrl)
                      ? NavigationActionPolicy.ALLOW
                      : NavigationActionPolicy.CANCEL;
                },
                shouldInterceptRequest: (_, request) async {
                  // This challenge's main document is local, never fetched remotely.
                  if (Platform.isAndroid &&
                      request.isForMainFrame == true &&
                      mounted &&
                      _accepting &&
                      !_finished &&
                      _error == null &&
                      request.url.toString() == _documentUrl) {
                    return WebResourceResponse(
                      statusCode: 200,
                      reasonPhrase: 'OK',
                      contentType: 'text/html',
                      contentEncoding: 'utf-8',
                      headers: const {'Cache-Control': 'no-store'},
                      data: Uint8List.fromList(utf8.encode(_html())),
                    );
                  }
                  // Windows reports every resource as a main-frame request;
                  // top-level navigation is guarded separately above.
                  if ((Platform.isWindows || request.isForMainFrame != true) &&
                      _allowedResource(request.url.uriValue))
                    return null;
                  return WebResourceResponse(
                    statusCode: 403,
                    reasonPhrase: 'Forbidden',
                    contentType: 'text/plain',
                    headers: const {},
                    data: Uint8List(0),
                  );
                },
                onCreateWindow: (_, __) async => false,
                onPermissionRequest: (_, request) async => PermissionResponse(
                  resources: request.resources,
                  action: PermissionResponseAction.DENY,
                ),
                onDownloadStartRequest: (controller, _) {
                  unawaited(controller.stopLoading());
                  _fail('安全验证不允许下载文件。');
                },
                onReceivedError: (_, request, __) {
                  if (request.isForMainFrame == true) _fail('安全验证加载失败，请关闭后重试。');
                },
                onReceivedHttpError: (controller, request, _) {
                  if (request.isForMainFrame == true) {
                    unawaited(controller.stopLoading());
                    _fail('安全验证页面加载失败，请关闭后重试。');
                  }
                },
              ),
      ),
      actions: [
        if (Platform.isWindows)
          TextButton.icon(
            onPressed: _browserOpening ? null : _openBrowser,
            icon: const Icon(Icons.open_in_browser),
            label: Text(_usingBrowser ? '重新打开浏览器' : '使用系统浏览器验证'),
          ),
        TextButton(
          onPressed: () {
            _invalidate();
            Navigator.of(context).pop();
          },
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
