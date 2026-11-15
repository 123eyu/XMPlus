import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../models/xmly_models.dart';
import '../common/widgets/local_panel.dart';
import '../services/app_log.dart';
import 'manuscript_reader.dart';

/// Compact metadata preview; the reader fetches the dedicated complete detail.
class AlbumIntroduction extends StatelessWidget {
  const AlbumIntroduction({
    required this.text,
    required this.client,
    required this.albumId,
    required this.onOpenAlbum,
    this.subscriptionAction,
    this.album,
    super.key,
  });

  final String text;
  final XmlyClient client;
  final String albumId;
  final ValueChanged<Album> onOpenAlbum;
  final Widget? subscriptionAction;
  final Album? album;

  void _open(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/album_introduction.dart::AlbumIntroduction._open",
    );
    Widget reader(BuildContext context) {
      AppLog.instance.trace(
        "lib/pages/album_introduction.dart::AlbumIntroduction._open.reader",
      );
      return _CompleteIntroduction(
        client: client,
        albumId: albumId,
        album: album,
      );
    }

    if (MediaQuery.sizeOf(context).width >= 700) {
      showLocalPanel<void>(
        context: context,
        title: '专辑详情',
        width: 760,
        height: MediaQuery.sizeOf(context).height * .9,
        showHeader: false,
        builder: reader,
      );
    } else {
      Navigator.of(context).push<void>(MaterialPageRoute(builder: reader));
    }
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/album_introduction.dart::AlbumIntroduction.build",
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (text.trim().isNotEmpty)
          Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () {
                AppLog.instance.trace(
                  "lib/pages/album_introduction.dart::AlbumIntroduction.build.closure#1",
                );
                return _open(context);
              },
              icon: const Icon(Icons.notes_rounded, size: 18),
              label: const Text('查看完整简介'),
            ),
            if (subscriptionAction != null) subscriptionAction!,
          ],
        ),
      ],
    );
  }
}

class _CompleteIntroduction extends StatefulWidget {
  const _CompleteIntroduction({
    required this.client,
    required this.albumId,
    this.album,
  });
  final XmlyClient client;
  final String albumId;
  final Album? album;

  @override
  State<_CompleteIntroduction> createState() {
    AppLog.instance.trace(
      "lib/pages/album_introduction.dart::_CompleteIntroduction.createState",
    );
    return _CompleteIntroductionState();
  }
}

class _CompleteIntroductionState extends State<_CompleteIntroduction> {
  AlbumIntroductionData? _content;
  String? _error;
  bool _busy = true;
  int _request = 0;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/album_introduction.dart::_CompleteIntroductionState.initState",
    );
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _CompleteIntroduction oldWidget) {
    AppLog.instance.trace(
      "lib/pages/album_introduction.dart::_CompleteIntroductionState.didUpdateWidget",
    );
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.albumId != widget.albumId) {
      _load();
    }
  }

  Future<void> _load() async {
    AppLog.instance.trace(
      "lib/pages/album_introduction.dart::_CompleteIntroductionState._load",
    );
    final request = ++_request;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/album_introduction.dart::_CompleteIntroductionState._load.closure#1",
      );
      _busy = true;
      _content = null;
      _error = null;
    });
    try {
      final content = await XmlyExperience(widget.client)
          .albumIntroduction(widget.albumId, includeRecommendations: false);
      if (!mounted || request != _request) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/album_introduction.dart::_CompleteIntroductionState._load.closure#2",
        );
        _content = content;
        _busy = false;
      });
    } catch (error, stack) {
      if (!mounted || request != _request) return;
      final log = AppLog.instance;
      if (!log.errorWasRecorded(error)) {
        log.write(
          AppLogLevel.error,
          'album_introduction',
          'Loading full album introduction failed',
          error: error,
          stackTrace: stack,
          promptUser: true,
        );
      }
      setState(() {
        AppLog.instance.trace(
          "lib/pages/album_introduction.dart::_CompleteIntroductionState._load.closure#3",
        );
        _error = error is XmlyException ? error.message : '完整简介加载失败，请重试';
        _busy = false;
      });
    }
  }

  String _document(AlbumIntroductionData content) {
    AppLog.instance.trace(
      "lib/pages/album_introduction.dart::_CompleteIntroductionState._document",
    );
    const escape = HtmlEscape();
    final album = content.album ?? widget.album;
    final cover = album?.coverUrl?.replace(scheme: 'https');
    // The captured publisher HTML still uses HTTP CDN image URLs. The existing
    // isolated reader allows only HTTPS Ximalaya images and disables scripts.
    final rich = content.richText.replaceAllMapped(
      RegExp(r'''(src\s*=\s*["'])http://''', caseSensitive: false),
      (match) {
        AppLog.instance.trace(
          "lib/pages/album_introduction.dart::_CompleteIntroductionState._document.closure#1",
        );
        return '${match[1]}https://';
      },
    );
    // The reader converts newlines to <br>; keep template formatting out of
    // the HTML while preserving the publisher's own paragraphs and images.
    return '<table width="100%" cellpadding="6"><tr>'
        '${cover == null ? '' : '<td width="56"><img src="${escape.convert(cover.toString())}" width="56" alt="专辑封面"></td>'}'
        '<td><strong>${escape.convert(album?.title ?? '')}</strong></td>'
        '</tr></table><h3>简介</h3>'
        '${rich.trim().isEmpty ? '<p>暂无专辑简介</p>' : rich}';
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/album_introduction.dart::_CompleteIntroductionState.build",
    );
    final content = _content;
    return Scaffold(
      appBar: AppBar(
        title: const Text('专辑详情'),
        centerTitle: true,
        leading: IconButton(
          tooltip: '返回',
          onPressed: () {
            AppLog.instance.trace(
              "lib/pages/album_introduction.dart::_CompleteIntroductionState.build.closure#1",
            );
            Navigator.of(context).maybePop();
          },
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _busy
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        TextButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              : content == null
              ? const SizedBox.shrink()
              : ManuscriptReader(
                  key: ValueKey((widget.client, widget.albumId)),
                  manuscript: _document(content),
                  showTitle: false,
                ),
        ),
      ),
    );
  }
}
