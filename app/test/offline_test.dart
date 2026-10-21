// Every main screen and sheet opened with the connection down: it says so and offers to try again, and once the
// connection is back «Try again» brings the screen as it should be. The error states are checked as the screens
// are: for a finger, a screen reader and weak eyes, and on a small phone with large text.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/screens/catalog_screen.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/common.dart';
import 'package:vitrina/widgets/delivery_sheet.dart';
import 'package:vitrina/widgets/todo_card.dart';
import 'package:vitrina/screens/offers_screen.dart';

import 'support/a11y.dart';
import 'support/screens.dart';

final _demo = jsonDecode(File('demo/api.json').readAsStringSync()) as Map<String, dynamic>;

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

/// The app on a made-up server: [answer] gets each request but the account, and throws while the line is [down].
Future<Session> _open(WidgetTester tester, Widget screen, FutureOr<http.Response> Function(http.Request) answer,
    {required bool Function(http.Request request) down}) async {
  SharedPreferences.setMockInitialValues({});
  appLanguage.value = 'kk';
  final api = Api(
      base: 'http://x/api/v1',
      client: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return _json(_demo['GET /me'] as Object);
        if (down(req)) throw http.ClientException('offline', req.url);
        return answer(req);
      }))
    ..token = 'token';
  final session = Session(api);
  session.update((await tester.runAsync(api.me))!);
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(SessionScope(session: session, child: MaterialApp(home: screen)));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  return session;
}

void main() {
  for (final (size, scale) in [(const Size(360, 720), 1.0), (const Size(320, 640), 2.0)]) {
    final setup = '${size.width.round()} wide, text ×$scale';
    for (final e in screens.entries) {
      testWidgets('${e.key} copes with no connection ($setup)', (tester) async {
        expect(
            await visit(tester, 'kk', size, scale, e.value,
                offline: true,
                keepsMissing: e.key == 'home',
                // The listing itself is already on the phone; only the cards at the foot of the page load.
                offlineDepth: e.key == 'manage' ? 15 : 6,
                look: scale == 1 ? look : null),
            isEmpty);
      });
    }
    for (final e in sheets.entries) {
      testWidgets('the ${e.key} sheet copes with no connection ($setup)', (tester) async {
        expect(
            await visit(tester, 'kk', size, scale, () => const SizedBox(),
                sheet: e.value(), offline: true, look: scale == 1 ? look : null),
            isEmpty);
      });
    }
  }

  testWidgets('the catalog stops asking for the next page while the connection is down, and offers to try again',
      (tester) async {
    var down = false, whileDown = 0;
    final one = _demo['GET /listings/1'] as Map<String, dynamic>;
    await _open(tester, const Scaffold(body: CatalogScreen()), (req) {
      if (req.url.path.endsWith('/listings')) {
        final offset = int.parse(req.url.queryParameters['offset'] ?? '0');
        final n = offset == 0 ? 20 : 3;
        return _json({
          'items': [
            for (var i = 0; i < n; i++) {...one, 'id': offset + i + 1, 'title': 'Аяқкиім ${offset + i + 1}'}
          ]
        });
      }
      return _json({'code': 'not_found'}, 404);
    }, down: (_) {
      if (down) whileDown++;
      return down;
    });
    expect(find.text('Аяқкиім 1'), findsOneWidget);
    down = true;
    whileDown = 0;
    final page = find.byType(CustomScrollView);
    for (var i = 0; i < 12 && find.byKey(const Key('more-retry')).evaluate().isEmpty; i++) {
      await tester.drag(page, const Offset(0, -600), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 100));
    }
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16)); // a second of frames with no touch
    }
    expect(whileDown, lessThanOrEqualTo(2), reason: 'one try, not one per frame');
    expect(find.byKey(const Key('more-retry')), findsOneWidget);
    down = false;
    await tester.ensureVisible(find.byKey(const Key('more-retry')));
    await tester
        .tap(find.descendant(of: find.byKey(const Key('more-retry')), matching: find.byKey(const Key('retry'))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byKey(const Key('more-retry')), findsNothing);
    await tester.scrollUntilVisible(find.text('Аяқкиім 23'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Аяқкиім 23'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an agreed price that did not load is said, and buying waits until it is known', (tester) async {
    var down = true;
    final listing = _demo['GET /listings/1'] as Map<String, dynamic>;
    final offer = {
      ...(_demo['GET /offers?role=buyer'] as Map)['items'][0] as Map<String, dynamic>,
      'listing_id': 1,
      'size_id': 4,
      'size_label': '42',
      'status': 'accepted',
      'price_tiyn': (listing['price_tiyn'] as int) - 300000,
    };
    await _open(tester, const ListingScreen(listingId: 1), (req) {
      final path = req.url.path.replaceFirst('/api/v1', '');
      if (path == '/listings/1') return _json(listing);
      if (path == '/offers') {
        return _json({
          'items': [offer]
        });
      }
      return _json({'items': []});
    }, down: (req) => down && req.url.path.endsWith('/offers')); // the page loads, the buyer's offer does not
    final line = find.byKey(const Key('offer-retry'));
    await scrollListingTo(tester, line);
    expect(line, findsOneWidget);
    expect(find.byType(OfferStatusCard), findsNothing);
    // Mid-screen, clear of the buy bar.
    Scrollable.ensureVisible(tester.element(find.text('42').first), alignment: 0.4);
    await tester.pump();
    await tester.tap(find.text('42').first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('buy')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.byType(DeliverySheet), findsNothing, reason: 'not at the full price while the deal is unknown');
    expect(find.byType(SnackBar), findsOneWidget);
    down = false;
    await tester.tap(find.descendant(of: line, matching: find.byKey(const Key('retry'))));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(line, findsNothing);
    expect(find.byType(OfferStatusCard), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('while «Try again» runs, its line stays in place with a spinner', (tester) async {
    var down = true;
    final answer = Completer<http.Response>();
    await _open(tester, const Scaffold(body: TodoCard()), (_) => answer.future, down: (_) => down);
    expect(find.byType(RetryLine), findsOneWidget);
    down = false;
    await tester.tap(find.byKey(const Key('retry')));
    await tester.pump();
    expect(find.byType(RetryLine), findsOneWidget, reason: 'the page does not jump, a screen reader keeps its place');
    expect(tester.widget<TextButton>(find.byKey(const Key('retry'))).onPressed, isNull);
    expect(
        find.descendant(of: find.byType(RetryLine), matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    answer.complete(_json(_demo['GET /me/todo'] as Object));
    await tester.pump();
    await tester.pump();
    expect(find.byType(RetryLine), findsNothing);
    expect(find.byKey(const Key('todo')), findsOneWidget);
  });
}
