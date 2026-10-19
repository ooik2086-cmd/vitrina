// What a second tap on a slow connection must not do, where the press suites (test/presses_*_test.dart) cannot see it:
// notification switches saved in order, and the once() guard itself.
import 'dart:async';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/demo.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/screens/login_screen.dart';
import 'package:vitrina/screens/notification_settings_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/common.dart';
import 'package:vitrina/widgets/delivery_sheet.dart';

import 'support/press.dart';
import 'support/screens.dart';

/// Notification settings whose saves wait for [answers], one per save, and fail when one completes with false.
Future<List<bool>> _settings(WidgetTester tester, List<Completer<bool>> answers) async {
  final on = {'price_drop': true, 'saved_search': true};
  final saved = <bool>[];
  var asked = 0;
  http.Response items() => http.Response(
      jsonEncode({
        'items': [
          for (final e in on.entries) {'kind': e.key, 'on': e.value}
        ]
      }),
      200,
      headers: {'content-type': 'application/json'});
  final api = Api(
      base: 'http://x/api/v1',
      client: MockClient((req) async {
        if (req.method == 'GET') return items();
        final change = (jsonDecode(req.body) as Map).entries.single;
        final (kind, wish) = (change.key as String, change.value as bool);
        final answer = answers[asked++];
        // Done as it arrives; the answer, made then, may come back late.
        final before = on[kind]!;
        on[kind] = wish;
        final reply = items();
        if (!await answer.future) {
          on[kind] = before;
          throw http.ClientException('down');
        }
        saved.add(wish);
        return reply;
      }));
  await tester
      .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: NotificationSettingsScreen())));
  await tester.pumpAndSettle();
  return saved;
}

bool _switch(WidgetTester tester, [String kind = 'price_drop']) =>
    tester.widget<SwitchListTile>(find.byKey(Key('alert-$kind'))).value;

/// Listing 1 on the demo data; its offers fail while [offersDown] is left set on the returned switch.
Future<(Line, Popups, _Switch)> _listing(WidgetTester tester, {required bool signedIn, bool offersDown = false}) async {
  tester.view.physicalSize = const Size(360, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await loadFonts(tester);
  final demo = (await tester.runAsync(() => DemoClient.load()))!;
  final offers = _Switch(offersDown);
  final line = Line(MockClient.streaming((req, body) async {
    if (offers.down && req.url.path.endsWith('/offers')) throw http.ClientException('down');
    return demo.send(req);
  }));
  final session = Session(Api(base: 'http://demo/api/v1', client: line));
  if (signedIn) {
    session.api.token = demoToken;
    session.update((await tester.runAsync(() => session.api.me()))!);
  }
  final popups = Popups();
  await tester.pumpWidget(SessionScope(
      session: session, child: MaterialApp(navigatorObservers: [popups], home: const ListingScreen(listingId: 1))));
  await settle(tester);
  await tester.scrollUntilVisible(find.text('42'), 300,
      scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first);
  await tester.pump();
  popups
    ..opened = 0
    ..pages = 0;
  return (line, popups, offers);
}

class _Switch {
  _Switch(this.down);
  bool down;
}

/// Picks size 42, then presses Buy and Buy again (or [then]) 150 ms apart while [line] (when given) holds its answers.
Future<void> _pressBuyTwice(WidgetTester tester, Line? line, {Finder? then}) async {
  // Mid-screen, clear of the buy bar.
  Scrollable.ensureVisible(tester.element(find.text('42').first), alignment: 0.4);
  await tester.pump();
  await tester.tap(find.text('42').first);
  await tester.pump();
  final slow = Completer<void>();
  line?.slow = slow.future;
  await tester.tap(find.byKey(const Key('buy')));
  await tester.pump(const Duration(milliseconds: 150));
  await tester.tap(then ?? find.byKey(const Key('buy')), warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 150));
  slow.complete();
  line?.slow = null;
  await settle(tester);
}

void main() {
  testWidgets('a switch flipped twice on a slow connection is saved in order and ends as last flipped', (tester) async {
    final answers = [Completer<bool>(), Completer<bool>()];
    final saved = await _settings(tester, answers);
    await tester.tap(find.byKey(const Key('alert-price_drop')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('alert-price_drop')));
    await tester.pump();
    expect(_switch(tester), isTrue, reason: 'it moves at once each time');
    answers[0].complete(true);
    await tester.pump();
    expect(_switch(tester), isTrue, reason: 'the first answer does not undo the later flip');
    answers[1].complete(true);
    await tester.pumpAndSettle();
    expect(saved, [false, true], reason: 'one save at a time, the last wish last');
    expect(_switch(tester), isTrue);
  });

  testWidgets('when that save fails, the switch shows what the server last kept', (tester) async {
    final answers = [Completer<bool>(), Completer<bool>()];
    final saved = await _settings(tester, answers);
    await tester.tap(find.byKey(const Key('alert-price_drop')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('alert-price_drop')));
    await tester.pump();
    answers[0].complete(true); // off is saved
    await tester.pump();
    answers[1].complete(false); // on again is not
    await tester.pumpAndSettle();
    expect(saved, [false]);
    expect(_switch(tester), isFalse);
    expect(find.textContaining('Байланыс жоқ'), findsOneWidget);
  });

  testWidgets('a switch answered while another still saves leaves the other as flipped', (tester) async {
    final answers = [Completer<bool>(), Completer<bool>()];
    await _settings(tester, answers);
    await tester.tap(find.byKey(const Key('alert-price_drop')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('alert-saved_search')));
    await tester.pump();
    answers[0].complete(true);
    await tester.pump();
    expect(_switch(tester, 'saved_search'), isFalse, reason: 'its save is still on the way');
    answers[1].complete(true);
    await tester.pumpAndSettle();
    expect(_switch(tester), isFalse);
    expect(_switch(tester, 'saved_search'), isFalse);
  });

  testWidgets('an older answer arriving late does not undo a switch already saved', (tester) async {
    final answers = [Completer<bool>(), Completer<bool>()];
    await _settings(tester, answers);
    await tester.tap(find.byKey(const Key('alert-price_drop'))); // done first: its answer still has the other on
    await tester.pump();
    await tester.tap(find.byKey(const Key('alert-saved_search')));
    await tester.pump();
    answers[1].complete(true);
    await tester.pump();
    answers[0].complete(true);
    await tester.pumpAndSettle();
    expect(_switch(tester, 'saved_search'), isFalse);
    expect(_switch(tester), isFalse);
  });

  test('the line tells a change asked again while it is on its way, unless under the same key', () async {
    final hold = Completer<void>();
    final line = Line(MockClient((_) async => http.Response('{}', 200)))..slow = hold.future;
    Future<void> send(String path, [String? key]) => line.send(http.Request('POST', Uri.parse('http://x/api/v1$path'))
      ..headers.addAll({if (key != null) 'Idempotency-Key': key}));
    final sent = [
      send('/orders', 'k1'),
      send('/orders', 'k1'), // the server answers it once
      send('/favorites/1'),
      send('/favorites/1'),
      send('/offers/1/accept', 'a'),
      send('/offers/1/accept', 'b'),
    ];
    hold.complete();
    await Future.wait(sent);
    expect(line.overlaps, ['POST /favorites/1', 'POST /offers/1/accept']);
    await send('/favorites/1');
    expect(line.overlaps, hasLength(2), reason: 'asked again after its answer: the next wish');
  });

  testWidgets('Buy pressed twice while signed out opens one sign-in page', (tester) async {
    final (_, popups, _) = await _listing(tester, signedIn: false);
    await _pressBuyTwice(tester, null);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(popups.pages, 1);
  });

  testWidgets('Buy, then the heart, pressed while signed out open one sign-in page', (tester) async {
    final (_, popups, _) = await _listing(tester, signedIn: false);
    await _pressBuyTwice(tester, null, then: find.byTooltip('Таңдаулыға'));
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(popups.pages, 1);
  });

  testWidgets('Buy pressed twice while a missed agreed price is fetched again opens one order sheet', (tester) async {
    final (line, popups, offers) = await _listing(tester, signedIn: true, offersDown: true);
    expect(find.byKey(const Key('offer-retry')), findsOneWidget, reason: 'the agreed price did not load');
    offers.down = false;
    await _pressBuyTwice(tester, line);
    expect(find.byType(DeliverySheet), findsOneWidget);
    expect(popups.opened, 1);
  });

  testWidgets('once lets a second run go while the first still runs, and runs again after', (tester) async {
    final gate = Completer<void>();
    var runs = 0;
    final first = once('k', () async {
      runs++;
      await gate.future;
    });
    await once('k', () async => runs++);
    expect(runs, 1);
    gate.complete();
    await first;
    await once('k', () async => runs++);
    expect(runs, 2);
    await expectLater(once('k', () async => throw StateError('x')), throwsStateError);
    await once('k', () async => runs++);
    expect(runs, 3, reason: 'a failed run lets the next one go');
  });
}
