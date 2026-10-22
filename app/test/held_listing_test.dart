// A listing held because its words hold a contact: the card names it, one tap takes it out of the fields, and Save
// ends the check at once when nothing else holds the listing (the server's release_if_fixed).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/demo.dart';
import 'package:vitrina/quick_replies.dart';
import 'package:vitrina/screens/manage_listing_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';

import 'support/press.dart';
import 'support/screens.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  final demo = (jsonDecode(File('demo/api.json').readAsStringSync()) as Map)['GET /listings/1'] as Map;

  Map<String, Object?> held(String title, String description, String found) => {
        ...demo.cast<String, Object?>(),
        'title': title,
        'description': description,
        'status': 'moderation',
        'moderation': {
          'flags': ['contacts'],
          'reasons': ['Байланыс тек VITRINA чатында.'],
          'note': null,
          'found': found,
        },
      };

  /// Opens the edit page of a held listing. The server answers Save as the real one does for a listing held for
  /// contacts alone: on sale once the words hold none, else still held. Returns the bodies Save sent.
  Future<List<Map>> open(WidgetTester tester, Map<String, Object?> listing,
      {double text = 1, Brightness brightness = Brightness.light, String releaseTo = 'published'}) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadFonts(tester);
    final demoClient = (await tester.runAsync(() => DemoClient.load()))!;
    final sent = <Map>[];
    var now = listing;
    final client = MockClient.streaming((req, body) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      http.Response? mine;
      if (req.method == 'PATCH' && path == '/listings/1') {
        final patch = jsonDecode(utf8.decode(await body.toBytes())) as Map;
        sent.add(patch);
        now = {
          ...now,
          for (final k in ['title', 'description'])
            if (patch[k] != null) k: patch[k]
        };
        final words = '${now['title']}\n${now['description']}';
        if (!looksLikeContact(words)) {
          now = {
            ...now,
            if (now['status'] == 'moderation') 'status': releaseTo, // a rejected one waits to be sent again
            'moderation': {'flags': [], 'reasons': [], 'note': null, 'found': null}
          };
        }
        mine = _json(now);
      } else if (req.method == 'POST' && path == '/listings/1/publish') {
        sent.add({'publish': true});
        final words = '${now['title']}\n${now['description']}';
        now = {...now, 'status': looksLikeContact(words) ? 'moderation' : 'published'};
        mine = _json(now);
      } else if (req.method == 'GET' && path == '/listings/1') {
        mine = _json(now);
      }
      if (mine != null) {
        return http.StreamedResponse(Stream.value(mine.bodyBytes), mine.statusCode, headers: mine.headers);
      }
      return demoClient.send(req);
    });
    final session = Session(Api(base: 'http://demo/api/v1', client: client))..api.token = demoToken;
    session.update((await tester.runAsync(() => session.api.me()))!);
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            theme: buildTheme(brightness),
            builder: (context, child) =>
                MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text)), child: child!),
            home: ManageListingScreen(listing: Listing.fromJson(listing)))));
    await settle(tester);
    return sent;
  }

  final remove = find.byKey(const Key('moderation-remove-contacts'));
  Finder fieldWith(String text) => find.byWidgetPredicate((w) => w is TextField && w.controller?.text == text);

  Future<void> scrollTo(WidgetTester tester, Finder finder) => tester.scrollUntilVisible(finder, 200,
      scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first);

  Future<void> tapRemove(WidgetTester tester) async {
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pump();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('save')));
    await settle(tester);
  }

  testWidgets('one tap takes the contacts out of the name and the description; Save ends the check', (tester) async {
    final sent = await open(
        tester, held('Жеңіл кроссовка WhatsApp', 'Жазыңыз: qadam@mail.ru. Қорабы бар.', 'WhatsApp», «qadam@mail.ru'));
    expect(find.text('Мынаны алып тастаңыз: «WhatsApp», «qadam@mail.ru»'), findsOneWidget);
    expect(find.textContaining('Сонда тексеру бірден аяқталады.'), findsOneWidget);
    expect(tester.getSize(remove).height, greaterThanOrEqualTo(48));
    await tapRemove(tester);
    await scrollTo(tester, fieldWith('Жазыңыз. Қорабы бар.'));
    expect(fieldWith('Жазыңыз. Қорабы бар.'), findsOneWidget);
    expect(sent, isEmpty, reason: 'the tap saves nothing');
    await tester.scrollUntilVisible(find.byKey(const Key('moderation-next')), -200,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first);
    expect(find.text('Байланыс алынды. Енді «Сақтау» басыңыз.'), findsOneWidget);
    expect(find.byKey(const Key('moderation-found')), findsNothing, reason: 'nothing asked for that is gone');
    expect(remove, findsNothing, reason: 'nothing left to take out');
    await save(tester);
    expect(sent.single['title'], 'Жеңіл кроссовка');
    expect(sent.single['description'], 'Жазыңыз. Қорабы бар.');
    expect(find.text('Сақталды. Тексеру аяқталды, тауар сатылымда.'), findsOneWidget);
    expect(find.byKey(const Key('moderation-card')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a contact the check did not name is told after the tap, and the listing stays held', (tester) async {
    final sent = await open(
        tester,
        held(demo['title'] as String, 'WhatsApp, Instagram, qadam@mail.ru, @qadam_kz',
            'WhatsApp», «Instagram», «qadam@mail.ru'));
    await tapRemove(tester);
    expect(find.text('Мәтінде тағы байланыс бар. Оны да алып тастаңыз.'), findsOneWidget);
    await save(tester);
    expect(sent.single['description'], '@qadam_kz');
    expect(find.text('Тауар тексерілуде'), findsOneWidget);
    expect(find.text('Сақталды. Тексеру аяқталды, тауар сатылымда.'), findsNothing);
  });

  testWidgets('no button once the seller has changed what was found by hand', (tester) async {
    await open(tester, held(demo['title'] as String, 'Telegram: qadam, қорабы бар.', 'Telegram: qadam'));
    expect(remove, findsOneWidget);
    final description = fieldWith('Telegram: qadam, қорабы бар.');
    await scrollTo(tester, description);
    await tester.enterText(description, 'Telegram: qadamm, қорабы бар.');
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(const Key('moderation-found')), -200,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first);
    expect(find.text('Мынаны алып тастаңыз: «Telegram: qadam»'), findsOneWidget, reason: 'the name stays till Save');
    expect(remove, findsNothing);
  });

  testWidgets('no button while one of the named contacts is not in the fields as written', (tester) async {
    await open(tester, held('Жеңіл кроссовка WhatsApp', 'Қорабы бар.', 'WhatsApp», «Instagram'));
    expect(find.byKey(const Key('moderation-found')), findsOneWidget);
    expect(remove, findsNothing, reason: 'one tap would leave «Instagram» named and not taken out');
  });

  testWidgets('no button and the old words for a listing held for something else', (tester) async {
    await open(tester, {
      ...held(demo['title'] as String, demo['description'] as String, ''),
      'moderation': {
        'flags': ['low_price'],
        'reasons': ['Баға тым төмен.'],
        'note': null,
        'found': null
      },
    });
    expect(remove, findsNothing);
    expect(
        find.text('Қызметкер қарап шыққанша сатып алушылар көрмейді. Нәтижесі хабарландыруда келеді.'), findsOneWidget);
  });

  testWidgets('a sent-back listing: one tap, then «Қайта жіберу» saves what is on the page and sends it',
      (tester) async {
    final sent = await open(tester, {
      ...held('Жеңіл кроссовка WhatsApp', 'Қорабы бар.', 'WhatsApp'),
      'status': 'rejected',
    });
    await tapRemove(tester);
    expect(find.text('Байланыс алынды. Енді «Қайта жіберу» басыңыз.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('publish')));
    await settle(tester);
    expect(sent.first['title'], 'Жеңіл кроссовка', reason: 'saved first');
    expect(sent.last, {'publish': true});
    expect(find.text('Сатылымға шықты'), findsOneWidget);
  });

  testWidgets('a listing that cannot go on sale yet is told how to sell it after Save', (tester) async {
    await open(tester, held('Жеңіл кроссовка WhatsApp', 'Қорабы бар.', 'WhatsApp'), releaseTo: 'paused');
    await tapRemove(tester);
    await save(tester);
    expect(find.text('Сақталды. Тексеру аяқталды. Сатуға «Сатылымға шығару» басыңыз.'), findsOneWidget);
  });

  testWidgets('held for contacts and something else: no promise that Save ends the check', (tester) async {
    await open(tester, {
      ...held('Жеңіл кроссовка WhatsApp', 'Қорабы бар.', 'WhatsApp'),
      'moderation': {
        'flags': ['contacts', 'low_price'],
        'reasons': ['Байланыс тек VITRINA чатында.', 'Баға тым төмен.'],
        'note': null,
        'found': 'WhatsApp'
      },
    });
    expect(remove, findsOneWidget);
    expect(find.textContaining('Сонда тексеру бірден аяқталады.'), findsNothing);
    expect(
        find.text('Қызметкер қарап шыққанша сатып алушылар көрмейді. Нәтижесі хабарландыруда келеді.'), findsOneWidget);
  });

  for (final (name, b, t) in [
    ('light', Brightness.light, 1.0),
    ('dark', Brightness.dark, 1.0),
    ('2x', Brightness.light, 2.0)
  ]) {
    testWidgets('the card and its button fit at 360 wide ($name)', (tester) async {
      await open(tester, held('Жеңіл кроссовка WhatsApp', 'Қорабы бар.', 'WhatsApp'), text: t, brightness: b);
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(remove).right, lessThanOrEqualTo(360));
    });
  }
}
