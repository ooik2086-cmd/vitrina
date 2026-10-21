// A listing whose last pair sold is "Сатылды". Pairs added to it by Save leave it paused, not on sale, which an
// older seller does not expect: the page asks at once whether to put it back on sale.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/demo.dart';
import 'package:vitrina/screens/manage_listing_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';

import 'support/press.dart';
import 'support/screens.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  final demo = (jsonDecode(File('demo/api.json').readAsStringSync()) as Map)['GET /listings/1'] as Map;

  /// The seller's listing 1 in [status] with [count] pairs of every size.
  Map<String, Object?> own(String status, int count) => {
        ...demo.cast<String, Object?>(),
        'status': status,
        'sizes': [
          for (final s in (demo['sizes'] as List).cast<Map<String, Object?>>())
            {...s, 'quantity': count, 'available': count > 0}
        ]
      };

  /// Opens the edit page of a listing the page believes is [shown], while the server has it as [status] (they differ
  /// when it sold out after the page was opened). The server answers as the real one does: Save turns a sold listing
  /// that gets pairs back into a paused one, and only a paused one can be published. [saveFails] answers Save with an
  /// error; [publishLost] publishes but loses the answer; [saveGate] holds Save's answer back.
  Future<List<String>> open(WidgetTester tester,
      {String status = 'sold',
      String? shown,
      int count = 0,
      int? saveFails,
      bool publishLost = false,
      bool saveOffline = false,
      bool saveLostOnce = false,
      Future<void>? saveGate,
      Brightness brightness = Brightness.light}) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadFonts(tester);
    final demoClient = (await tester.runAsync(() => DemoClient.load()))!;
    final asked = <String>[];
    var now = own(status, count);
    final client = MockClient.streaming((req, body) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      asked.add('${req.method} $path');
      http.Response? mine;
      if (req.method == 'PATCH' && path == '/listings/1') {
        if (saveGate != null) await saveGate;
        if (saveOffline) throw http.ClientException('no connection');
        if (saveFails != null) {
          mine = _json({'code': 'unavailable', 'message_kk': 'Сервер қолжетімсіз.'}, saveFails);
        } else {
          final sizes = ((jsonDecode(utf8.decode(await body.toBytes()))['sizes'] as List?) ?? []).cast<Map>();
          final held = ((now['sizes'] as List).first as Map)['quantity'] as int;
          if (sizes.any((s) => s['was'] != null && s['was'] != held && held != s['quantity'])) {
            mine = _json({'code': 'stock_changed', 'message_kk': 'Қалдық өзгерді.'}, 409);
          } else {
            final added = sizes.any((s) => s['quantity'] as int > 0);
            final status = now['status'] == 'sold' && added ? 'paused' : now['status'] as String;
            now = own(status, added ? sizes.first['quantity'] as int : held);
            if (saveLostOnce) {
              saveLostOnce = false;
              throw http.ClientException('answer lost');
            }
            mine = _json(now);
          }
        }
      } else if (req.method == 'POST' && path == '/listings/1/publish') {
        if (now['status'] != 'paused') {
          mine = _json({'code': 'invalid_status', 'message_kk': 'Қазір бұл әрекетті жасау мүмкін емес.'}, 409);
        } else {
          now = {...now, 'status': 'published'};
          if (publishLost) throw http.ClientException('answer lost');
          mine = _json(now);
        }
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
    final page = Listing.fromJson({...now, 'status': shown ?? status});
    await tester.pumpWidget(SessionScope(
        session: session, child: MaterialApp(theme: buildTheme(brightness), home: ManageListingScreen(listing: page))));
    await settle(tester);
    return asked;
  }

  Future<void> toStock(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('Қалдық'), 300,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first);
    await tester.ensureVisible(find.byTooltip('Көбейту').first);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('save')));
    await settle(tester);
  }

  Future<void> addPairAndSave(WidgetTester tester) async {
    await toStock(tester);
    await tester.tap(find.byTooltip('Көбейту').first);
    await tester.pump();
    await save(tester);
  }

  final question = find.text('Қайта сатуға шығару керек пе?');

  testWidgets('pairs added to a sold-out listing: one tap puts it back on sale', (tester) async {
    final asked = await open(tester);
    await addPairAndSave(tester);
    expect(question, findsOneWidget);
    expect(find.textContaining('Жұптар қосылды, бірақ тауар әзірге сатылымда емес.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('restock-publish')));
    await settle(tester);
    expect(asked, contains('POST /listings/1/publish'));
    expect(find.text('Сатылымға шықты'), findsOneWidget);
    expect(find.text('Сақталды'), findsNothing); // the newer word is not kept waiting behind the older
    expect(find.byKey(const Key('publish')), findsNothing); // on sale now, nothing more to press
  });

  testWidgets('saying later leaves it paused, with the button to put it on sale', (tester) async {
    final asked = await open(tester);
    await addPairAndSave(tester);
    await tester.tap(find.text('Кейін'));
    await settle(tester);
    expect(asked, isNot(contains('POST /listings/1/publish')));
    expect(find.byKey(const Key('publish')), findsOneWidget);
  });

  testWidgets('a listing that sold out after the page was opened is asked about too', (tester) async {
    await open(tester, shown: 'published');
    await addPairAndSave(tester);
    expect(question, findsOneWidget);
  });

  testWidgets('a listing already on sale is not asked about', (tester) async {
    final asked = await open(tester, status: 'published', count: 2);
    await addPairAndSave(tester);
    expect(asked, contains('PATCH /listings/1'));
    expect(question, findsNothing);
  });

  testWidgets('a listing the seller paused is not asked about when pairs are added', (tester) async {
    final asked = await open(tester, status: 'paused', count: 1);
    await addPairAndSave(tester);
    expect(asked, contains('PATCH /listings/1'));
    expect(question, findsNothing);
  });

  testWidgets('a Save of a sold-out listing that adds no pairs asks nothing', (tester) async {
    final asked = await open(tester);
    await tester.enterText(find.byKey(const Key('price')), '43000');
    await save(tester);
    expect(asked, contains('PATCH /listings/1'));
    expect(question, findsNothing);
  });

  testWidgets('a Save answered after the seller pressed back does not ask over the leave question', (tester) async {
    final gate = Completer<void>();
    await open(tester, saveGate: gate.future);
    await toStock(tester);
    await tester.tap(find.byTooltip('Көбейту').first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('save')));
    await tester.pump();
    final NavigatorState nav = tester.state(find.byType(Navigator));
    unawaited(nav.maybePop()); // the back button while the answer is on its way
    await settle(tester);
    expect(find.text('Сақтамай шығу керек пе?'), findsOneWidget);
    gate.complete();
    await settle(tester);
    expect(question, findsNothing);
  });

  testWidgets('a publish whose answer was lost is checked, and told as done', (tester) async {
    await open(tester, publishLost: true);
    await addPairAndSave(tester);
    await tester.tap(find.byKey(const Key('restock-publish')));
    await settle(tester);
    expect(find.text('Сатылымға шықты'), findsOneWidget);
    expect(find.byKey(const Key('publish')), findsNothing); // not pressed again into a refusal
  });

  testWidgets('a listing restocked elsewhere is not asked about on a Save that adds no pairs', (tester) async {
    await open(tester, status: 'paused', shown: 'sold', count: 1);
    await tester.enterText(find.byKey(const Key('price')), '43000');
    await save(tester);
    expect(question, findsNothing); // nothing this Save did put it there
  });

  testWidgets('pairs brought back by a Save whose answer was lost are asked about on the next Save', (tester) async {
    await open(tester, saveLostOnce: true);
    await addPairAndSave(tester);
    expect(question, findsNothing);
    await tester.tap(find.byTooltip('Көбейту').first); // the seller adds one more and saves again
    await tester.pump();
    await save(tester);
    expect(question, findsOneWidget); // the listing is paused now: the same question
  });

  testWidgets('putting a paused listing on sale keeps the note about changes not saved', (tester) async {
    await open(tester, status: 'paused', count: 1, saveOffline: true);
    await tester.enterText(find.byKey(const Key('price')), '43000');
    await save(tester);
    await tester.tap(find.byKey(const Key('publish')));
    await settle(tester);
    expect(find.text('Байланыс жоқ. Өзгерістер жоғалған жоқ, осы бетте тұр.'), findsOneWidget);
  });

  testWidgets('a Save that did not go through asks nothing', (tester) async {
    final asked = await open(tester, saveFails: 503);
    await addPairAndSave(tester);
    expect(asked, contains('PATCH /listings/1'));
    expect(question, findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the question fits at 360 wide with large text ($brightness)', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester, brightness: brightness);
      await addPairAndSave(tester);
      expect(question, findsOneWidget);
      expect(tester.takeException(), isNull);
      // Every word of the explanation has its room, none cut off at the bottom.
      final words = tester.renderObject<RenderParagraph>(find.textContaining('Жұптар қосылды'));
      expect(words.size.height, greaterThanOrEqualTo(words.getMinIntrinsicHeight(words.size.width) - 1));
    });
  }
}
