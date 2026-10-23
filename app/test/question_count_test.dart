// A seller opens a listing's edit page; buyers' questions waiting there for an answer show on its Q&A row, so the seller
// sees there is something to do without opening it.
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
import 'package:vitrina/widgets/questions.dart';

import 'support/a11y.dart';
import 'support/press.dart';
import 'support/screens.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

/// What the server says about listing 1's questions, as the seller sees them.
class _Questions {
  int waiting = 0;
  bool offline = false;
  int asked = 0; // asks for the number alone
  String status = 'published';
  Completer<void>? hold; // holds the next answer to the number back
}

void main() {
  final demo = (jsonDecode(File('demo/api.json').readAsStringSync()) as Map)['GET /listings/1'] as Map;

  Future<void> open(WidgetTester tester, _Questions q,
      {Size size = const Size(360, 720), double text = 1, Brightness brightness = Brightness.light}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadFonts(tester);
    final demoClient = (await tester.runAsync(() => DemoClient.load()))!;
    // Six sizes, as these cases were written for: the page's rows sit where the scrolling below expects them.
    Map<String, Object?> listing() =>
        {...demo.cast<String, Object?>(), 'sizes': (demo['sizes'] as List).take(6).toList(), 'status': q.status};
    final client = MockClient.streaming((req, body) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      http.Response? mine;
      if (req.method == 'GET' && path == '/listings/1/questions/unanswered') {
        q.asked++;
        final hold = q.hold;
        q.hold = null;
        final now = q.waiting; // what the server has when the ask comes in
        if (hold != null) await hold.future;
        if (q.offline) throw http.ClientException('no connection');
        mine = _json({'unanswered': now});
      } else if (req.method == 'GET' && path == '/listings/1/questions') {
        if (q.offline) throw http.ClientException('no connection');
        mine = _json({'items': [], 'unanswered': q.waiting});
      } else if (req.method == 'POST' && path == '/listings/1/pause') {
        q.status = 'paused';
        mine = _json(listing());
      } else if (req.method == 'POST' && path == '/listings/1/publish') {
        q.status = 'published';
        mine = _json(listing());
      } else if (req.method == 'GET' && path == '/listings/1') {
        mine = _json(listing());
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
        child: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(text)),
          child: MaterialApp(
              theme: buildTheme(brightness),
              home: ManageListingScreen(key: UniqueKey(), listing: Listing.fromJson(listing()))),
        )));
    await settle(tester);
  }

  final row = find.byKey(const Key('listing-questions'));
  final waiting = find.byKey(const Key('questions-waiting'));
  final page = find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical);

  Future<void> toRow(WidgetTester tester, [Finder? what]) async {
    await tester.scrollUntilVisible(what ?? row, 300, scrollable: page.first);
    await tester.pumpAndSettle();
  }

  String? shown(WidgetTester tester) => waiting.evaluate().isEmpty ? null : tester.widget<Text>(waiting).data;

  void away(WidgetTester tester) {
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  void back(WidgetTester tester) {
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  testWidgets('questions waiting for an answer show their number on the Q&A row, in bold', (tester) async {
    final q = _Questions()..waiting = 2;
    await open(tester, q);
    await toRow(tester);
    expect(find.descendant(of: row, matching: find.text('Жауапсыз: 2')), findsOneWidget);
    expect(q.asked, 1);
    // Bold as drawn: the app's font takes its weight from its 'wght' axis.
    final drawn = tester.renderObject<RenderParagraph>(find.descendant(of: waiting, matching: find.byType(RichText)));
    expect(drawn.text.style?.fontVariations, contains(const FontVariation('wght', 700)));
  });

  testWidgets('with none waiting the row reads as before', (tester) async {
    final q = _Questions();
    await open(tester, q);
    await toRow(tester);
    expect(find.descendant(of: row, matching: find.text('Сатып алушылардың сұрақтарына жауап беру')), findsOneWidget);
    expect(waiting, findsNothing);
  });

  testWidgets('with no connection the row says so and asks again on «Try again»', (tester) async {
    final q = _Questions()
      ..waiting = 3
      ..offline = true;
    await open(tester, q);
    final retry = find.byKey(const Key('listing-questions-retry'));
    await toRow(tester, retry);
    // The row still opens the Q&A page, and says why the number is missing.
    expect(find.descendant(of: row, matching: find.byKey(const Key('questions-unknown'))), findsOneWidget);
    q.offline = false;
    await tester.ensureVisible(find.byKey(const Key('retry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('retry')));
    await settle(tester);
    expect(retry, findsNothing);
    if (row.evaluate().isEmpty) await tester.scrollUntilVisible(row, -300, scrollable: page.first);
    expect(find.byKey(const Key('questions-unknown')), findsNothing);
    expect(shown(tester), 'Жауапсыз: 3');
  });

  testWidgets('with no connection the Q&A page still opens from the row', (tester) async {
    final q = _Questions()..offline = true;
    await open(tester, q);
    await toRow(tester, find.byKey(const Key('listing-questions-retry')));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await settle(tester);
    expect(find.byType(QuestionsScreen), findsOneWidget);
  });

  testWidgets('with no connection, large text on a small phone, the row and its button fit', (tester) async {
    final q = _Questions()..offline = true;
    await open(tester, q, size: const Size(320, 640), text: 2);
    await toRow(tester, find.byKey(const Key('listing-questions-retry')));
    expect(tester.takeException(), isNull);
    final button = tester.getRect(find.byKey(const Key('retry')));
    expect(button.right, lessThanOrEqualTo(320));
    for (final p in tester.renderObjectList<RenderParagraph>(
        find.descendant(of: find.byKey(const Key('listing-questions-retry')), matching: find.byType(RichText)))) {
      expect(p.didExceedMaxLines, isFalse);
    }
  });

  testWidgets('a number already shown stays when asking again fails', (tester) async {
    final q = _Questions()..waiting = 3;
    await open(tester, q);
    await toRow(tester);
    q.offline = true;
    away(tester);
    back(tester);
    await settle(tester);
    expect(q.asked, 2);
    expect(shown(tester), 'Жауапсыз: 3');
  });

  testWidgets('answered on the Q&A page, the number is asked again on coming back', (tester) async {
    final q = _Questions()..waiting = 3;
    await open(tester, q);
    await toRow(tester);
    await tester.tap(row);
    await settle(tester);
    expect(q.asked, 1); // the Q&A page has its own list
    q.waiting = 1; // the seller answered two there
    await tester.pageBack();
    await settle(tester);
    expect(q.asked, 2);
    expect(shown(tester), 'Жауапсыз: 1');
  });

  testWidgets('back from the background it asks again: a buyer may have asked meanwhile', (tester) async {
    final q = _Questions();
    await open(tester, q);
    await toRow(tester);
    q.waiting = 1;
    // A dialog or the notification shade over the app is not coming back: nothing is asked.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(q.asked, 1);
    away(tester);
    back(tester);
    await settle(tester);
    expect(q.asked, 2);
    expect(shown(tester), 'Жауапсыз: 1');
  });

  testWidgets('back from the background on the Q&A page, it asks on leaving that page, not before', (tester) async {
    final q = _Questions();
    await open(tester, q);
    await toRow(tester);
    await tester.tap(row);
    await settle(tester);
    away(tester);
    back(tester);
    await settle(tester);
    expect(q.asked, 1);
    await tester.pageBack();
    await settle(tester);
    expect(q.asked, 2);
  });

  testWidgets('an older answer coming in late does not replace a newer one', (tester) async {
    final q = _Questions()..waiting = 5;
    await open(tester, q);
    await toRow(tester);
    final late = Completer<void>();
    q.hold = late; // this ask (5) is held back...
    away(tester);
    back(tester);
    await tester.pump();
    q.waiting = 2;
    await tester.tap(row); // ...while the seller answers three on the Q&A page
    await settle(tester);
    await tester.pageBack();
    await settle(tester);
    expect(shown(tester), 'Жауапсыз: 2');
    late.complete();
    await settle(tester);
    expect(shown(tester), 'Жауапсыз: 2');
    expect(q.asked, 3);
  });

  testWidgets('a paused listing has no Q&A row and asks nothing; put on sale, the row comes with its number',
      (tester) async {
    final q = _Questions()
      ..status = 'paused'
      ..waiting = 4;
    await open(tester, q);
    expect(row, findsNothing);
    expect(q.asked, 0);
    await toRow(tester, find.byKey(const Key('publish')));
    await tester.tap(find.byKey(const Key('publish')));
    await settle(tester);
    await toRow(tester);
    expect(shown(tester), 'Жауапсыз: 4');
    expect(q.asked, 1);
  });

  testWidgets('paused here and put back on sale, the number is asked afresh', (tester) async {
    final q = _Questions()..waiting = 2;
    await open(tester, q);
    expect(q.asked, 1);
    await toRow(tester, find.text('Тоқтату'));
    await tester.tap(find.text('Тоқтату'));
    await settle(tester);
    expect(row, findsNothing);
    away(tester);
    back(tester);
    await settle(tester);
    expect(q.asked, 1); // no row: nothing to ask for
    q.waiting = 0;
    await toRow(tester, find.byKey(const Key('publish')));
    await tester.tap(find.byKey(const Key('publish')));
    await settle(tester);
    await toRow(tester);
    expect(q.asked, 2);
    expect(waiting, findsNothing);
  });

  testWidgets('the number coming in does not rebuild the fields below the row', (tester) async {
    final q = _Questions()..waiting = 1;
    await open(tester, q);
    final field = find.ancestor(of: find.text('Сипаттамасы'), matching: find.byType(TextFormField));
    await toRow(tester, field);
    final before = tester.state(field);
    await tester.scrollUntilVisible(find.text('Қалдық'), -300, scrollable: page.first); // above the row
    await tester.ensureVisible(find.byTooltip('Көбейту').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Көбейту').first);
    await tester.pump();
    await toRow(tester, field);
    expect(identical(tester.state(field), before), isTrue);
  });

  test('the demo answers the number from its recorded questions: those with no answer yet', () async {
    final demo = await DemoClient.load();
    final r = await demo.get(Uri.parse('http://demo/api/v1/listings/1/questions/unanswered'));
    expect(r.statusCode, 200);
    expect(jsonDecode(r.body), {'unanswered': 0});
  });

  for (final brightness in Brightness.values) {
    testWidgets('at 360 wide with text twice as large the row\'s words fit and read (${brightness.name})',
        (tester) async {
      final q = _Questions()..waiting = 120;
      await open(tester, q, text: 2, brightness: brightness);
      await toRow(tester);
      for (final p
          in tester.renderObjectList<RenderParagraph>(find.descendant(of: row, matching: find.byType(RichText)))) {
        expect(p.didExceedMaxLines, isFalse);
        expect(p.size.height, greaterThanOrEqualTo(p.getMaxIntrinsicHeight(p.size.width) - 0.5));
      }
      final errors = <String>[];
      await textContrast(tester, errors);
      expect(errors.where((e) => e.contains('Жауапсыз')), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
