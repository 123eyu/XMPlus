import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xmly_flutter/api/xmly_client.dart';
import 'package:xmly_flutter/models/xmly_models.dart';
import 'package:xmly_flutter/pages/track_comments_panel.dart';
import 'package:xmly_flutter/services/account_service.dart';
import 'package:xmly_flutter/services/app_runtime.dart';

class _CommentsClient extends XmlyClient {
  _CommentsClient({String uid = '1', int count = 60})
    : rows = List.generate(
        count,
        (index) => {
          'id': '${index + 1}',
          'uid': '99',
          'nickname': 'Listener ${index + 1}',
          'content': 'Comment ${index + 1}',
          'likes': 0,
          'liked': false,
          'replyCount': index == 0 ? 2 : 0,
        },
      ),
      super(
        credentials: Credentials(token: '$uid&fixture', deviceId: 'fixture'),
      );

  final List<Map<String, dynamic>> rows;
  final pages = <int>[];
  final creates = <Completer<Map<String, dynamic>>>[];
  final replies = [
    {
      'id': '101',
      'uid': '99',
      'nickname': 'Reply author',
      'content': 'First reply',
      'likes': 0,
      'liked': false,
    },
    {
      'id': '102',
      'uid': '99',
      'nickname': 'Reply author',
      'content': 'Second reply',
      'likes': 0,
      'liked': false,
    },
  ];
  int replyReads = 0;
  Completer<void>? likeGate;

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String origin,
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? data,
    bool account = true,
    bool signed = false,
    bool form = false,
  }) async {
    if (path == '/comment-mobile/v1/create') {
      final pending = Completer<Map<String, dynamic>>();
      creates.add(pending);
      return pending.future;
    }
    if (path == '/comment-mobile/like') {
      await likeGate?.future;
      final row = [
        ...rows,
        ...replies,
      ].singleWhere((row) => row['id'] == data!['commentId']);
      final liked = data!['islike'] == 'true';
      if (row['liked'] != liked)
        row['likes'] = (row['likes'] as int) + (liked ? 1 : -1);
      row['liked'] = liked;
      return {'ret': 0};
    }
    if (path == '/revision/comment/queryReplies') {
      replyReads++;
      return {
        'data': {
          'currentPage': 1,
          'totalComment': 2,
          'totalPage': 1,
          'replies': replies,
        },
      };
    }
    if (path.startsWith('/comment-mobile/v1/track/comment/')) {
      final page = query!['pageId'] as int;
      pages.add(page);
      return {
        'comment': {
          'pageId': page,
          'totalCount': rows.length,
          'maxPageId': (rows.length / 20).ceil(),
          'list': rows.skip((page - 1) * 20).take(20).toList(),
        },
      };
    }
    throw StateError('Unexpected request: $method $path');
  }
}

class _OpenAccounts implements AccountService {
  @override
  bool get admissionPaused => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CommentsRuntime extends ChangeNotifier implements AppRuntime {
  _CommentsRuntime(this.client);
  @override
  _CommentsClient client;
  @override
  final AccountService accounts = _OpenAccounts();

  void useClient(_CommentsClient next) {
    client = next;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Finder _row(String id) => find.byKey(ValueKey(('xmly:100', id)));
Finder _like(Finder row) => find.descendant(
  of: row,
  matching: find.widgetWithIcon(TextButton, Icons.thumb_up_outlined),
);

Widget _app(_CommentsRuntime runtime, {String trackId = '100'}) => MaterialApp(
  theme: ThemeData(splashFactory: InkRipple.splashFactory),
  home: Scaffold(
    body: TrackCommentsPanel(
      runtime: runtime,
      track: Track(id: trackId, albumId: '200'),
    ),
  ),
);

Future<_CommentsRuntime> _mount(
  WidgetTester tester,
  List<_CommentsClient> clients,
) async {
  final runtime = _CommentsRuntime(clients.first);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final client in clients) {
      for (final create in client.creates) {
        if (!create.isCompleted) create.complete({'ret': 0});
      }
      final gate = client.likeGate;
      if (gate != null && !gate.isCompleted) gate.complete();
      client.close();
    }
    await tester.pump();
    runtime.dispose();
  });
  await tester.pumpWidget(_app(runtime));
  await tester.pumpAndSettle();
  return runtime;
}

void main() {
  testWidgets(
    'liking a later page keeps the page, position and recycled row state',
    (tester) async {
      final client = _CommentsClient();
      await _mount(tester, [client]);
      final list = find.byKey(const ValueKey('trackCommentsScroll'));
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(
        _like(_row('25')),
        500,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      final controller = tester.widget<ListView>(list).controller!;
      final offset = controller.offset;
      final pages = List.of(client.pages);
      expect(pages, contains(2));

      await tester.tap(_like(_row('25')));
      await tester.pumpAndSettle();
      expect(
        client.pages,
        pages,
        reason: 'Liking must not reload the first page',
      );
      expect(controller.offset, closeTo(offset, 1));
      expect(
        find.descendant(of: _row('25'), matching: find.byIcon(Icons.thumb_up)),
        findsOneWidget,
      );

      controller.jumpTo(0);
      await tester.pumpAndSettle();
      expect(_row('25'), findsNothing);
      controller.jumpTo(offset);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _row('25'), matching: find.byIcon(Icons.thumb_up)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _row('25'), matching: find.text('1')),
        findsOneWidget,
      );
    },
  );

  testWidgets('a like survives its row being recycled before completion', (
    tester,
  ) async {
    final client = _CommentsClient()..likeGate = Completer<void>();
    await _mount(tester, [client]);
    await tester.tap(_like(_row('1')));
    await tester.pump();
    final list = find.byKey(const ValueKey('trackCommentsScroll'));
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(
      find.text('Comment 15'),
      500,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(_row('1'), findsNothing);
    final pages = List.of(client.pages);
    client.likeGate!.complete();
    await tester.pumpAndSettle();
    tester.widget<ListView>(list).controller!.jumpTo(0);
    await tester.pumpAndSettle();
    expect(client.pages, pages);
    expect(
      find.descendant(of: _row('1'), matching: find.byIcon(Icons.thumb_up)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row('1'), matching: find.text('1')),
      findsOneWidget,
    );
  });

  testWidgets('liking an inline reply does not reload its list', (
    tester,
  ) async {
    final client = _CommentsClient(count: 1);
    await _mount(tester, [client]);
    await tester.tap(find.byKey(const ValueKey('commentReplies:1')));
    await tester.pumpAndSettle();
    expect(client.replyReads, 1);
    final reply = find.byKey(const ValueKey('101'));
    await tester.tap(_like(reply));
    await tester.pumpAndSettle();
    expect(client.replyReads, 1);
    expect(
      find.descendant(of: reply, matching: find.byIcon(Icons.thumb_up)),
      findsOneWidget,
    );
  });

  testWidgets(
    'a like completing after a refresh preserves the newer row data',
    (tester) async {
      final client = _CommentsClient(count: 1)..likeGate = Completer<void>();
      await _mount(tester, [client]);
      await tester.tap(_like(_row('1')));
      await tester.pump();
      client.rows.first['likes'] = 10;
      client.rows.first['content'] = 'Refreshed comment';
      await tester.tap(find.byTooltip('刷新评论'));
      await tester.pump();
      await tester.pump();
      client.likeGate!.complete();
      await tester.pumpAndSettle();
      expect(client.pages, [1, 1]);
      expect(find.text('Refreshed comment'), findsOneWidget);
      expect(
        find.descendant(of: _row('1'), matching: find.text('11')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'an old account send cannot lock or finish a newer account send',
    (tester) async {
      final first = _CommentsClient(count: 1);
      final second = _CommentsClient(uid: '2', count: 1);
      final runtime = await _mount(tester, [first, second]);
      await tester.enterText(find.byType(TextField), 'First account comment');
      await tester.tap(find.byTooltip('发送评论'));
      await tester.pump();
      expect(first.creates, hasLength(1));
      runtime.useClient(second);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);

      await tester.enterText(find.byType(TextField), 'Second account comment');
      await tester.tap(find.byTooltip('发送评论'));
      await tester.pump();
      expect(second.creates, hasLength(1));
      first.creates.single.complete({'ret': 0});
      await tester.pump();
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enabled, isFalse);
      expect(field.controller!.text, 'Second account comment');
      second.creates.single.complete({'ret': 0});
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    },
  );

  for (final fails in [false, true]) {
    testWidgets(
      'returning to a cached account keeps a draft after an old send ${fails ? 'fails' : 'succeeds'}',
      (tester) async {
        final first = _CommentsClient(count: 1);
        final second = _CommentsClient(uid: '2', count: 1);
        final runtime = await _mount(tester, [first, second]);
        await tester.enterText(find.byType(TextField), 'Earlier comment');
        await tester.tap(find.byTooltip('发送评论'));
        await tester.pump();
        runtime.useClient(second);
        await tester.pump();
        runtime.useClient(first);
        await tester.pump();
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isTrue,
        );
        await tester.enterText(find.byType(TextField), 'Keep this new draft');
        if (fails) {
          first.creates.single.completeError(
            const XmlyException('rate_limited', 'Earlier send failed'),
          );
        } else {
          first.creates.single.complete({'ret': 0});
        }
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Keep this new draft',
        );
        expect(find.text('Earlier send failed'), findsNothing);
      },
    );
  }

  testWidgets('changing tracks unlocks the composer and ignores an old send', (
    tester,
  ) async {
    final client = _CommentsClient(count: 1);
    final runtime = await _mount(tester, [client]);
    await tester.enterText(find.byType(TextField), 'Earlier track comment');
    await tester.tap(find.byTooltip('发送评论'));
    await tester.pump();
    expect(client.creates, hasLength(1));
    await tester.pumpWidget(_app(runtime, trackId: '101'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, isEmpty);
    await tester.enterText(find.byType(TextField), 'New track draft');
    client.creates.single.complete({'ret': 0});
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'New track draft',
    );
  });
}
