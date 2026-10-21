// On weak mobile data a message can reach the other side while its answer is lost. Sent again, it must arrive once,
// and a message that did not go keeps its text and says so.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/chat_screen.dart';
import 'package:vitrina/session.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

const _conv = {
  'id': 9,
  'listing_id': 7,
  'listing_title': 'Кроссовка',
  'listing_cover': null,
  'price_tiyn': 2490000,
  'role': 'seller',
  'other_name': 'Сатып алушы',
  'last_message': null,
  'unread': 0,
};

void main() {
  /// Opens the chat over another page. Sends go into [sent] with their keys; [lost] says, by send, that the message
  /// was posted but its answer never came back; [down] that it never left the phone. The thread shows what was posted.
  Future<List<(String, String?)>> open(WidgetTester tester,
      {bool Function(int send)? lost,
      bool Function(int send)? down,
      int? status,
      Duration pollEvery = const Duration(hours: 1)}) async {
    final sent = <(String, String?)>[];
    final posted = <Map<String, Object?>>[];
    final byKey = <String, Map<String, Object?>>{}; // as the server keeps them
    var sends = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.method == 'GET') {
            final after = int.tryParse(req.url.queryParameters['after_id'] ?? '') ?? 0;
            return _json({'conversation': _conv, 'items': posted.where((m) => (m['id'] as int) > after).toList()});
          }
          final n = ++sends;
          if (down?.call(n) ?? false) throw http.ClientException('no connection');
          if (status != null) return _json({'code': 'rate_limited', 'message_kk': 'Тым жиі жазып жатырсыз.'}, status);
          final body = (jsonDecode(req.body) as Map)['body'] as String;
          final key = req.headers['Idempotency-Key'];
          sent.add((body, key));
          var m = key == null ? null : byKey[key];
          if (m == null) {
            m = {
              'id': 100 + n,
              'sender_id': 3,
              'body': body,
              'contact_warning': false,
              'created_at': '2026-10-21T10:00:00Z',
            };
            posted.add(m);
            if (key != null) byKey[key] = m;
          }
          if (lost?.call(n) ?? false) throw http.ClientException('answer lost');
          return _json(m, 201);
        }));
    final session = Session(api)..me = Me.fromJson({'id': 3, 'phone': '+77010000003', 'is_seller': true});
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => ChatScreen(conversationId: 9, pollEvery: pollEvery))),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return sent;
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byTooltip('Жіберу'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder field(String text) => find.widgetWithText(TextField, text);
  const notSent = 'Байланыс жоқ. Хабарлама жетпеген болуы мүмкін, мәтіні осы жерде тұр.';

  testWidgets('a message whose answer was lost, sent again, goes with the same key and shows once', (tester) async {
    final sent = await open(tester, lost: (n) => n == 1);
    await send(tester, 'Иә, 42 бар');
    expect(find.text(notSent), findsOneWidget);
    expect(field('Иә, 42 бар'), findsOneWidget); // the text is still there
    final line = tester.getRect(find.byKey(const Key('chat-not-sent')));
    expect(line.bottom, lessThanOrEqualTo(tester.getRect(find.byType(TextField)).top)); // above the field, not over it
    await tester.tap(find.byKey(const Key('chat-resend')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(sent, hasLength(2));
    expect(sent[1].$2, sent[0].$2); // the same message, so the server posts it once
    expect(sent[0].$2, isNotNull);
    expect(find.text('Иә, 42 бар'), findsOneWidget); // shown once, the field empty
    expect(field('Иә, 42 бар'), findsNothing);
    expect(find.text(notSent), findsNothing); // it went: the line is gone
  });

  testWidgets('a text changed after it may not have gone is a new message with its own key', (tester) async {
    final sent = await open(tester, lost: (n) => n == 1);
    await send(tester, 'Иә, бар');
    await tester.enterText(find.byType(TextField), 'Иә, 42 бар');
    await tester.pump();
    expect(find.text(notSent), findsNothing); // the line was about the old text
    await tester.tap(find.byTooltip('Жіберу'));
    await tester.pump();
    expect(sent.map((s) => s.$1), ['Иә, бар', 'Иә, 42 бар']);
    expect(sent[1].$2, isNot(sent[0].$2));
  });

  testWidgets('the same words written again after a cleared field are posted again', (tester) async {
    final sent = await open(tester, lost: (n) => n == 1);
    await send(tester, 'Иә');
    await tester.enterText(find.byType(TextField), ''); // the seller gave up on it
    await tester.pump();
    expect(find.text(notSent), findsNothing);
    await send(tester, 'Иә'); // and later says it again
    expect(sent, hasLength(2));
    expect(sent[1].$2, isNot(sent[0].$2)); // not taken as the old one sent again
    expect(field('Иә'), findsNothing); // it went
  });

  testWidgets('the same words sent twice in a row both go', (tester) async {
    final sent = await open(tester);
    await send(tester, 'Рақмет');
    await send(tester, 'Рақмет');
    expect(sent, hasLength(2));
    expect(sent[1].$2, isNot(sent[0].$2));
    expect(find.text('Рақмет'), findsNWidgets(2));
  });

  testWidgets('a message that went after all, shown by the thread, leaves the field and the line', (tester) async {
    await open(tester, lost: (n) => n == 1, pollEvery: const Duration(seconds: 5));
    await send(tester, 'Ертең жіберемін');
    expect(find.text(notSent), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // the thread is read again
    await tester.pump();
    expect(find.text('Ертең жіберемін'), findsOneWidget); // in the thread, once
    expect(field('Ертең жіберемін'), findsNothing);
    expect(find.text(notSent), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
  });

  testWidgets('a refusal from the server is told in its own words, not as a lost connection', (tester) async {
    await open(tester, status: 429);
    await send(tester, 'Сәлем');
    expect(find.text('Тым жиі жазып жатырсыз.'), findsOneWidget);
    expect(find.text(notSent), findsNothing);
    expect(field('Сәлем'), findsOneWidget);
  });

  testWidgets('a message that never left the phone says so, and a screen reader hears it', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, down: (n) => n == 1);
    await send(tester, 'Иә, бар');
    expect(find.text(notSent), findsOneWidget);
    expect(tester.getSemantics(find.text(notSent)), isSemantics(isLiveRegion: true));
    expect(tester.getSize(find.byKey(const Key('chat-resend'))).height, greaterThanOrEqualTo(48));
    handle.dispose();
  });
}
