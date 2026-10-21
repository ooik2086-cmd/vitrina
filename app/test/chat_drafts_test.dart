// Leaving a chat, or the phone closing the app, loses nothing written there: the words in the field come back, a
// message that may not have gone comes back with its key (sent again, it arrives once), and so does a pair marked
// sold whose answer was lost.
import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/chat_drafts.dart';
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

Map<String, Object?> _msg(int id, String body, {int sender = 3}) =>
    {'id': id, 'sender_id': sender, 'body': body, 'contact_warning': false, 'created_at': '2026-10-21T10:00:00Z'};

Map<String, Object?> _listing(int left) => {
      'id': 7,
      'status': left > 0 ? 'published' : 'sold',
      'ever_on_sale': true,
      'title': 'Кроссовка',
      'category': 'sneakers',
      'audience': 'unisex',
      'brand': 'Nike',
      'model_name': 'Air',
      'color': 'ақ',
      'price_tiyn': 2490000,
      'delivery_price_tiyn': 150000,
      'condition': 'new_with_box',
      'authenticity': 'unverified',
      'showcase_style': 'clean',
      'sizes': [
        {'id': 2, 'label': '42', 'insole_cm': '27,0', 'available': left > 0, 'quantity': left},
      ],
      'media': [],
      'seller': {'id': 3, 'shop_name': 'Qadam Store', 'city': 'Алматы'},
    };

/// The server's side of one chat: what was posted (and the history before), the keys it has seen, and the sale
/// marks that reached it.
class _Server {
  _Server({List<Map<String, Object?>>? history}) : posted = [...?history];
  final List<Map<String, Object?>> posted;
  final sent = <(String, String?)>[];
  final marks = <String?>[];
  final byKey = <String, Map<String, Object?>>{};
  final seenMarks = <String>{};
  var left = 2;

  /// Whether the next message or mark is posted but its answer lost.
  var lose = false;

  /// When set, a message or mark is posted at once but its answer waits for this.
  Completer<void>? hold;

  /// When set, reading the chat waits for this.
  Completer<void>? readHold;

  late final api = Api(
      base: 'http://x/api/v1',
      client: MockClient((req) async {
        if (req.method == 'GET' && req.url.path.endsWith('/listings/7')) return _json(_listing(left));
        if (req.method == 'GET') {
          await readHold?.future;
          final after = int.tryParse(req.url.queryParameters['after_id'] ?? '') ?? 0;
          return _json({'conversation': _conv, 'items': posted.where((m) => (m['id'] as int) > after).toList()});
        }
        final key = req.headers['Idempotency-Key'];
        if (req.url.path.endsWith('/sold')) {
          marks.add(key);
          if (key != null && seenMarks.add(key)) left--;
          await hold?.future;
          if (lose) throw http.ClientException('answer lost');
          return _json(_listing(left));
        }
        final body = (jsonDecode(req.body) as Map)['body'] as String;
        sent.add((body, key));
        var m = key == null ? null : byKey[key];
        if (m == null) {
          m = _msg(200 + posted.length, body);
          posted.add(m);
          if (key != null) byKey[key] = m;
        }
        await hold?.future;
        if (lose) throw http.ClientException('answer lost');
        return _json(m, 201);
      }));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> leave(WidgetTester tester) async {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Shows a page with a button that opens the chat, signed in as [me] (null: signed in, the profile not loaded
  /// yet, as on a weak connection), as the app does.
  Future<Session> start(WidgetTester tester, _Server server, {int? me = 3, String? draft}) async {
    final session = Session(server.api)
      ..api.token = 't'
      ..me = me == null ? null : Me.fromJson({'id': me, 'phone': '+7701000000$me', 'is_seller': true});
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) =>
                                ChatScreen(conversationId: 9, pollEvery: const Duration(hours: 1), draft: draft))),
                        child: const Text('open')))))));
    await open(tester);
    return session;
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byTooltip('Жіберу'));
    await tester.pumpAndSettle();
  }

  String field(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

  Future<Map<String, dynamic>> kept() async =>
      jsonDecode((await SharedPreferences.getInstance()).getString(ChatDrafts.key) ?? '{}') as Map<String, dynamic>;

  Future<void> seed(Map<String, Map<String, Object?>> entries) async => SharedPreferences.setMockInitialValues({
        ChatDrafts.key: jsonEncode({
          for (final e in entries.entries) e.key: {'kept_at': clock.now().millisecondsSinceEpoch, ...e.value}
        })
      });

  const lineNow = 'Байланыс жоқ. Хабарлама жетпеген болуы мүмкін, мәтіні осы жерде тұр.';
  const lineKept = 'Хабарлама жетпеген болуы мүмкін, мәтіні осы жерде тұр.';

  testWidgets('words in the field come back after leaving the chat, even left at once', (tester) async {
    final server = _Server();
    await start(tester, server);
    await tester.enterText(find.byType(TextField), 'Сәлеметсіз бе, 42 өлшемі');
    await leave(tester); // straight away, before the moment typing is kept after
    await open(tester);
    expect(field(tester), 'Сәлеметсіз бе, 42 өлшемі');
    expect(find.byKey(const Key('chat-not-sent')), findsNothing); // only typed, never sent
  });

  testWidgets('the words are kept the moment the app goes to the background', (tester) async {
    await start(tester, _Server());
    await tester.enterText(find.byType(TextField), 'Ертең жіберемін');
    await tester.pump(); // not yet the moment typing is kept after
    expect(await kept(), isEmpty);
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect((await kept())['3:9']['text'], 'Ертең жіберемін'); // the phone may close the app from here
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
  });

  testWidgets('a message that may not have gone comes back with a calm line and goes once', (tester) async {
    final server = _Server()..lose = true;
    await start(tester, server);
    await send(tester, 'Иә, 42 бар');
    expect(find.text(lineNow), findsOneWidget);
    server.posted.clear(); // it never reached the server after all
    server.byKey.clear();
    server.lose = false;
    await leave(tester);
    await open(tester);
    expect(field(tester), 'Иә, 42 бар');
    expect(find.text(lineKept), findsOneWidget); // the connection is fine now: the line does not say otherwise
    await tester.tap(find.byKey(const Key('chat-resend')));
    await tester.pumpAndSettle();
    expect(server.sent.map((s) => s.$2).toSet(), hasLength(1)); // the same key both times
    expect(server.posted.where((m) => m['body'] == 'Иә, 42 бар'), hasLength(1));
    expect(field(tester), isEmpty);
    await tester.pump(const Duration(seconds: 1)); // the moment typing is kept after
    expect(await kept(), isEmpty); // nothing left to keep
  });

  testWidgets('a message that went after all is not put back, and no line flashes', (tester) async {
    final server = _Server()..lose = true;
    await start(tester, server);
    await send(tester, 'Иә, 42 бар'); // posted; only the answer was lost
    server.lose = false;
    await leave(tester);
    await tester.tap(find.text('open'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byKey(const Key('chat-not-sent')), findsNothing); // never, not even before the chat loads
    }
    await tester.pumpAndSettle();
    expect(find.text('Иә, 42 бар'), findsOneWidget); // in the thread, once
    expect(field(tester), isEmpty);
  });

  testWidgets('left while the message waits for its answer: it is not put back once it went', (tester) async {
    final server = _Server()..hold = Completer<void>();
    await start(tester, server);
    await tester.enterText(find.byType(TextField), 'Ертең жіберемін');
    await tester.pump(const Duration(seconds: 1)); // kept as typed
    await tester.tap(find.byTooltip('Жіберу'));
    await tester.pump();
    expect((await kept())['3:9']['key'], server.sent.single.$2); // kept with its key while it waits
    await leave(tester);
    server.hold!.complete(); // the answer comes after the chat closed
    await tester.pumpAndSettle();
    expect(await kept(), isEmpty);
    await open(tester);
    expect(field(tester), isEmpty);
    expect(find.text('Ертең жіберемін'), findsOneWidget); // once, in the thread
  });

  testWidgets('left while the message waits and its answer never comes: it comes back with its key', (tester) async {
    final server = _Server()
      ..hold = Completer<void>()
      ..lose = true;
    await start(tester, server);
    await send(tester, 'Ертең жіберемін');
    await leave(tester);
    server.hold!.complete();
    await tester.pumpAndSettle();
    server.posted.clear(); // it never reached the server
    server.byKey.clear();
    server.lose = false;
    server.hold = null;
    await open(tester);
    expect(field(tester), 'Ертең жіберемін');
    expect(find.text(lineKept), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-resend')));
    await tester.pumpAndSettle();
    expect(server.sent.map((s) => s.$2).toSet(), hasLength(1));
  });

  testWidgets('the same words sent days before do not count as the kept message having gone', (tester) async {
    await seed({
      '3:9': {'text': 'Рақмет', 'not_sent': true, 'key': 'k-12345678', 'after': 50}
    });
    await start(tester, _Server(history: [_msg(40, 'Рақмет'), _msg(50, 'Сау болыңыз', sender: 2)]));
    expect(field(tester), 'Рақмет');
    expect(find.text(lineKept), findsOneWidget);
  });

  testWidgets('a sent message leaves nothing behind', (tester) async {
    final server = _Server();
    await start(tester, server);
    await tester.enterText(find.byType(TextField), 'Иә, бар');
    await tester.pump(const Duration(seconds: 1));
    expect((await kept())['3:9']['text'], 'Иә, бар'); // kept while typed
    await tester.tap(find.byTooltip('Жіберу'));
    await tester.pumpAndSettle();
    expect(await kept(), isEmpty);
    await leave(tester);
    await open(tester);
    expect(field(tester), isEmpty);
  });

  testWidgets('a pair marked sold whose answer was lost comes back after leaving and is taken once', (tester) async {
    final server = _Server()..lose = true;
    await start(tester, server);
    await tester.tap(find.byKey(const Key('mark-sold')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sold-size-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sold-sure')));
    await tester.pumpAndSettle();
    expect(server.left, 1);
    expect(find.byKey(const Key('sale-not-sent')), findsOneWidget);
    server.lose = false;
    await leave(tester);
    await open(tester);
    expect(find.text('42 өлшемінің белгісі сақталмаған болуы мүмкін.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sale-resend')));
    await tester.pumpAndSettle();
    expect(server.marks, hasLength(2));
    expect(server.marks.toSet(), hasLength(1)); // the same key both times
    expect(server.left, 1); // taken once
    expect(find.byKey(const Key('sale-not-sent')), findsNothing);
    expect(await kept(), isEmpty);
  });

  testWidgets('a pair marked sold while leaving the chat is kept until its answer comes', (tester) async {
    final server = _Server();
    await start(tester, server);
    await tester.tap(find.byKey(const Key('mark-sold')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sold-size-2')));
    await tester.pumpAndSettle();
    server.hold = Completer<void>();
    await tester.tap(find.byKey(const Key('sold-sure')));
    await tester.pump();
    await tester.pump();
    expect((await kept())['3:9']['sale']['key'], server.marks.single); // kept with its key while it waits
    await leave(tester);
    server.hold!.complete();
    await tester.pumpAndSettle();
    expect(await kept(), isEmpty); // answered after the chat closed: nothing to send again
  });

  testWidgets('with the profile not loaded yet, nothing kept is lost; it comes back once it loads', (tester) async {
    await seed({
      '3:9': {
        'text': 'Жетпеген',
        'not_sent': true,
        'key': 'k-12345678',
        'after': 0,
        'sale': {'listing_id': 7, 'size_id': 2, 'label': '42', 'key': 'sale-key-123'},
      }
    });
    final session = await start(tester, _Server(), me: null);
    await tester.enterText(find.byType(TextField), 'Сәлем');
    await tester.pump(const Duration(seconds: 1));
    expect((await kept()).keys, ['3:9']); // nothing kept under no one
    expect((await kept())['3:9']['key'], 'k-12345678'); // not let go, not replaced
    await tester.enterText(find.byType(TextField), '');
    session.update(Me.fromJson({'id': 3, 'phone': '+77010000003', 'is_seller': true}));
    await tester.pumpAndSettle();
    expect(field(tester), 'Жетпеген');
    expect(find.byKey(const Key('chat-not-sent')), findsOneWidget);
    expect(find.byKey(const Key('sale-not-sent')), findsOneWidget);
  });

  testWidgets('another person on the phone neither sees the words nor erases them', (tester) async {
    await seed({
      '3:9': {'text': 'Жеке сөз'}
    });
    await start(tester, _Server(), me: 4);
    expect(field(tester), isEmpty);
    await tester.enterText(find.byType(TextField), 'Менің сөзім');
    await leave(tester);
    final all = await kept();
    expect(all['3:9']['text'], 'Жеке сөз');
    expect(all['4:9']['text'], 'Менің сөзім');
  });

  testWidgets('words kept more than a week ago are let go, in this chat and others', (tester) async {
    final old = clock.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch;
    await seed({
      '3:9': {'text': 'Ескі сөз', 'kept_at': old},
      '3:5': {'text': 'Басқа чаттағы ескі сөз', 'kept_at': old},
      '3:6': {'text': 'Басқа чаттағы жаңа сөз'},
    });
    await start(tester, _Server());
    expect(field(tester), isEmpty);
    await tester.enterText(find.byType(TextField), 'Жаңа');
    await tester.pump(const Duration(seconds: 1));
    expect((await kept()).keys.toSet(), {'3:9', '3:6'});
  });

  testWidgets('the person\'s own words win over the note from the listing', (tester) async {
    await seed({
      '3:9': {'text': 'Өзім жазған сұрақ'}
    });
    await start(tester, _Server(), draft: '43 өлшемі бар ма?');
    expect(field(tester), 'Өзім жазған сұрақ');
    await leave(tester);
    SharedPreferences.setMockInitialValues({});
    await start(tester, _Server(), draft: '43 өлшемі бар ма?');
    expect(field(tester), '43 өлшемі бар ма?'); // nothing kept: the note is there
  });

  test('a deleted account takes its words, its unsaved listing and edits off the phone', () async {
    SharedPreferences.setMockInitialValues({
      ChatDrafts.key: jsonEncode({
        '3:9': {'text': 'Менікі', 'kept_at': clock.now().millisecondsSinceEpoch},
        '4:9': {'text': 'Басқаның', 'kept_at': clock.now().millisecondsSinceEpoch},
      }),
      Session.editorDraftKey: jsonEncode({'owner': 3, 'title': 'Етік'}),
      Session.listingEditsKey: jsonEncode({
        '7': {'owner': 3},
        '8': {'owner': 4},
      }),
    });
    await Session(_Server().api).forgetLocal(3);
    final prefs = await SharedPreferences.getInstance();
    expect((jsonDecode(prefs.getString(ChatDrafts.key)!) as Map).keys, ['4:9']);
    expect(prefs.getString(Session.editorDraftKey), isNull);
    expect((jsonDecode(prefs.getString(Session.listingEditsKey)!) as Map).keys, ['8']);
  });

  test('stale words go at start, even in chats never opened again', () async {
    SharedPreferences.setMockInitialValues({
      ChatDrafts.key: jsonEncode({
        '3:5': {'text': 'Ескі', 'kept_at': clock.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch},
      }),
    });
    await ChatDrafts.sweep();
    expect((await SharedPreferences.getInstance()).getString(ChatDrafts.key), isNull);
  });

  test('the app starting lets stale words go', () async {
    SharedPreferences.setMockInitialValues({
      ChatDrafts.key: jsonEncode({
        '3:5': {'text': 'Ескі', 'kept_at': clock.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch},
      }),
    });
    await Session(_Server().api).restore(); // signed out: nothing else to do
    await Future<void>.delayed(Duration.zero);
    expect((await SharedPreferences.getInstance()).getString(ChatDrafts.key), isNull);
  });

  testWidgets('a kept message waits for the chat to load before saying it may not have gone', (tester) async {
    await seed({
      '3:9': {'text': 'Жетпеген', 'not_sent': true, 'key': 'k-12345678', 'after': 0}
    });
    final server = _Server()..readHold = Completer<void>();
    await start(tester, server);
    expect(field(tester), 'Жетпеген');
    expect(find.byKey(const Key('chat-not-sent')), findsNothing); // not yet known whether it arrived meanwhile
    server.readHold!.complete();
    await tester.pumpAndSettle();
    expect(find.text(lineKept), findsOneWidget);
  });

  testWidgets('a kept message found in the chat already loaded is not put back', (tester) async {
    await seed({
      '3:9': {'text': 'Жетті ме', 'not_sent': true, 'key': 'k-12345678', 'after': 10}
    });
    // The profile comes after the chat has loaded, so what was kept is read last.
    final session = await start(tester, _Server(history: [_msg(5, 'Жетті ме'), _msg(12, 'Жетті ме')]), me: null);
    session.update(Me.fromJson({'id': 3, 'phone': '+77010000003', 'is_seller': true}));
    await tester.pumpAndSettle();
    expect(field(tester), isEmpty);
    expect(find.byKey(const Key('chat-not-sent')), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(await kept(), isEmpty); // it went: nothing comes back next time
  });

  testWidgets('kept words cleared right after they came back are let go', (tester) async {
    await seed({
      '3:9': {'text': 'Керек емес'}
    });
    await start(tester, _Server());
    expect(field(tester), 'Керек емес');
    await tester.enterText(find.byType(TextField), '');
    await leave(tester); // straight away
    await tester.pump(const Duration(seconds: 1));
    expect(await kept(), isEmpty);
  });
}
