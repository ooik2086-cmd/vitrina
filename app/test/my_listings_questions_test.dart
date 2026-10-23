// «Менің тауарларым» says which listing has buyers' questions waiting for an answer, so a seller sent there by the
// to-do card's «Жауапсыз сұрақ» line sees where to go instead of opening every listing.
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
import 'package:vitrina/screens/my_listings_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';
import 'package:vitrina/widgets/questions.dart';
import 'package:vitrina/widgets/todo_card.dart';

import 'support/a11y.dart';
import 'support/press.dart';
import 'support/screens.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

/// What the server has: the seller's listings, questions waiting on each, and what the app asked for.
class _Shop {
  var ids = [3, 2, 1];
  final waiting = <int, int>{1: 2, 2: 0, 3: 1, 4: 0, 6: 0, 7: 0};
  final status = <int, String>{
    for (final id in [1, 2, 3, 4, 6, 7]) id: 'published'
  };
  bool sendsCount = true; // false: a server from before the count
  bool offline = false; // the one-listing count fails
  int lists = 0; // asks for the whole list
  final counted = <int>[]; // asks for one listing's number
  final holdCounts = <Completer<void>?>[]; // one per coming one-listing ask, in order: null lets it through
  Completer<void>? holdList; // holds the next whole list back

  /// The server's rule: only a listing on sale or sold has questions waiting (no other one's questions open).
  int waitingOn(int id) => status[id] == 'published' || status[id] == 'sold' ? waiting[id]! : 0;
}

void main() {
  final recorded = jsonDecode(File('demo/api.json').readAsStringSync()) as Map;

  Map<String, Object?> listing(_Shop shop, int id) => {
        ...(recorded['GET /listings/$id'] as Map).cast<String, Object?>(),
        'status': shop.status[id],
        'stats': {
          'views': 3,
          'favorites': 0,
          'chats': 0,
          'orders': 0,
          'sold': 0,
          if (shop.sendsCount) 'unanswered': shop.waitingOn(id),
        },
      };

  /// [shop] null: the plain demo, as the demo APK answers.
  Future<void> open(WidgetTester tester, _Shop? shop,
      {Widget screen = const MyListingsScreen(),
      Size size = const Size(360, 720),
      double text = 1,
      Brightness brightness = Brightness.light}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadFonts(tester);
    final demo = (await tester.runAsync(() => DemoClient.load()))!;
    final client = shop == null
        ? demo
        : MockClient.streaming((req, body) async {
            final path = req.url.path.replaceFirst('/api/v1', '');
            final count = RegExp(r'^/listings/(\d+)/questions/unanswered$').firstMatch(path);
            http.Response? mine;
            if (req.method == 'GET' && path == '/me/listings') {
              shop.lists++;
              final hold = shop.holdList;
              shop.holdList = null;
              if (hold != null) await hold.future;
              mine = _json({
                'items': [for (final id in shop.ids) listing(shop, id)],
                'next_before': null,
              });
            } else if (req.method == 'GET' && count != null) {
              final id = int.parse(count.group(1)!);
              shop.counted.add(id);
              final now = shop.waitingOn(id);
              final hold = shop.holdCounts.isEmpty ? null : shop.holdCounts.removeAt(0);
              if (hold != null) await hold.future;
              if (shop.offline) throw http.ClientException('no connection');
              mine = _json({'unanswered': now});
            } else if (req.method == 'GET' && RegExp(r'^/listings/\d+$').hasMatch(path)) {
              mine = _json(listing(shop, int.parse(path.split('/').last)));
            }
            if (mine != null) {
              return http.StreamedResponse(Stream.value(mine.bodyBytes), mine.statusCode, headers: mine.headers);
            }
            return demo.send(req);
          });
    final session = Session(Api(base: 'http://demo/api/v1', client: client))..api.token = demoToken;
    session.update((await tester.runAsync(() => session.api.me()))!);
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(text)),
          child: MaterialApp(theme: buildTheme(brightness), home: screen),
        )));
    await settle(tester);
  }

  Finder tile(String title) => find.ancestor(of: find.text(title), matching: find.byType(ListTile));
  String title(int id) => namedWithColor(Listing.fromJson((recorded['GET /listings/$id'] as Map).cast()));
  Finder waitingOn(int id, String text) =>
      find.descendant(of: tile(title(id)), matching: find.textContaining(text, findRichText: true));
  final chip = find.byKey(const Key('status-questions'));
  Finder chipSays(String text) => find.descendant(of: chip, matching: find.text(text));

  /// The span as drawn that carries [text].
  TextSpan drawnSpan(WidgetTester tester, int id, String text) {
    final paragraph = tester.renderObject<RenderParagraph>(find.descendant(
        of: tile(title(id)),
        matching: find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains(text))));
    TextSpan? hit;
    paragraph.text.visitChildren((span) {
      if (span is TextSpan && (span.text ?? '').contains(text)) hit = span;
      return hit == null;
    });
    return hit!;
  }

  testWidgets('a listing with questions waiting says how many, in bold; the others stay as they were', (tester) async {
    final shop = _Shop();
    await open(tester, shop);
    expect(waitingOn(1, 'Жауапсыз сұрақ: 2'), findsOneWidget);
    expect(waitingOn(3, 'Жауапсыз сұрақ: 1'), findsOneWidget);
    expect(waitingOn(2, 'Жауапсыз'), findsNothing);
    // Bold as drawn: the app's font takes its weight from its 'wght' axis.
    expect(drawnSpan(tester, 1, 'Жауапсыз').style?.fontVariations, contains(const FontVariation('wght', 700)));
    // Every row keeps its cover in the middle, with the line or without.
    double offCentre(int id) =>
        tester.getCenter(find.descendant(of: tile(title(id)), matching: find.byType(SizedBox)).first).dy -
        tester.getCenter(tile(title(id))).dy;
    expect(offCentre(1), closeTo(0, 1));
    expect(offCentre(2), closeTo(0, 1));
    expect(shop.lists, 1);
    expect(shop.counted, isEmpty, reason: 'the list brings the numbers: no ask per listing');
  });

  testWidgets('«Сұрақ күтеді» keeps only the listings with questions waiting; its number counts questions',
      (tester) async {
    final shop = _Shop();
    await open(tester, shop);
    // 2 + 1 questions, the same number as the to-do line «Жауапсыз сұрақ».
    expect(chipSays('Сұрақ күтеді 3'), findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(tile(title(1)), findsOneWidget);
    expect(tile(title(3)), findsOneWidget);
    expect(tile(title(2)), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await open(tester, _Shop()..waiting.updateAll((_, __) => 0));
    expect(chip, findsNothing, reason: 'none waiting: no chip');
  });

  testWidgets('a listing not on sale has nothing waiting: its questions cannot be opened', (tester) async {
    for (final status in ['paused', 'moderation', 'rejected', 'hidden']) {
      await tester.pumpWidget(const SizedBox());
      await open(tester, _Shop()..status[1] = status);
      expect(waitingOn(1, 'Жауапсыз'), findsNothing, reason: status);
      expect(chipSays('Сұрақ күтеді 1'), findsOneWidget, reason: status);
    }
  });

  testWidgets('the to-do card\'s questions line opens my listings on «Сұрақ күтеді»', (tester) async {
    final line = todoLines.singleWhere((l) => l.key == 'questions');
    final screen = line.open() as MyListingsScreen;
    expect(screen.status, 'questions');
    await open(tester, _Shop(), screen: screen);
    expect(tile(title(2)), findsNothing);
    expect(tile(title(1)), findsOneWidget);
    // Answered meanwhile: it says so instead of an empty page, and its chip stays to go back to all.
    await tester.pumpWidget(const SizedBox());
    await open(tester, _Shop()..waiting.updateAll((_, __) => 0), screen: screen);
    expect(find.text('Жауап күтетін сұрақ жоқ.'), findsOneWidget);
    expect(chip, findsOneWidget);
  });

  testWidgets('a search that hides them does not claim no questions are waiting', (tester) async {
    final shop = _Shop()..ids = [7, 6, 4, 3, 2, 1]; // six listings bring the search box
    await open(tester, shop, screen: const MyListingsScreen(status: 'questions'));
    await tester.enterText(find.byKey(const Key('my-listings-search')), 'zzz');
    await tester.pump();
    expect(find.text('Сай тауар жоқ.'), findsOneWidget);
    expect(find.text('Жауап күтетін сұрақ жоқ.'), findsNothing);
  });

  testWidgets('a server that does not send the number: no line, no chip, and the to-do line opens all', (tester) async {
    await open(tester, _Shop()..sendsCount = false, screen: const MyListingsScreen(status: 'questions'));
    expect(find.textContaining('Жауапсыз', findRichText: true), findsNothing);
    expect(chip, findsNothing);
    expect(find.text('Жауап күтетін сұрақ жоқ.'), findsNothing, reason: 'not known is not none');
    for (final id in [1, 2, 3]) {
      expect(tile(title(id)), findsOneWidget);
    }
  });

  Future<void> visit(WidgetTester tester, _Shop shop, int id, Type page) async {
    await tester.tap(find.text(title(id)));
    await settle(tester);
    expect(find.byType(page), findsOneWidget);
    shop.counted.clear(); // the page opened asks for its number too: only what comes after counts
    await tester.pageBack();
    await settle(tester);
  }

  testWidgets('on «Сұрақ күтеді» a listing opens straight on its questions; back, only its number is asked again',
      (tester) async {
    final shop = _Shop();
    await open(tester, shop, screen: const MyListingsScreen(status: 'questions'));
    shop.waiting[1] = 0; // answered there
    await visit(tester, shop, 1, QuestionsScreen);
    expect(shop.counted, [1]);
    expect(shop.lists, 1, reason: 'not the whole list again');
    expect(tile(title(1)), findsNothing);
    expect(chipSays('Сұрақ күтеді 1'), findsOneWidget);
    // Pulling the list down brings the server's numbers again.
    shop.waiting[1] = 4;
    await tester.fling(find.byType(ListView).last, const Offset(0, 400), 1000);
    await settle(tester);
    expect(shop.lists, 2);
    expect(waitingOn(1, 'Жауапсыз сұрақ: 4'), findsOneWidget);
  });

  testWidgets('from all listings a listing opens its page; back, a sold one is asked again, one with none is not',
      (tester) async {
    final shop = _Shop()..status[1] = 'sold';
    await open(tester, shop);
    await visit(tester, shop, 2, ManageListingScreen);
    expect(shop.counted, isEmpty, reason: 'none waiting');
    shop.waiting[1] = 1;
    await visit(tester, shop, 1, ManageListingScreen);
    expect(shop.counted, [1]);
    expect(waitingOn(1, 'Жауапсыз сұрақ: 1'), findsOneWidget);
  });

  testWidgets('with no connection the number it had stays', (tester) async {
    final shop = _Shop()..offline = true;
    await open(tester, shop);
    shop.waiting[1] = 0;
    await visit(tester, shop, 1, ManageListingScreen);
    expect(shop.counted, [1]);
    expect(waitingOn(1, 'Жауапсыз сұрақ: 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late, older answer does not bring back a number', (tester) async {
    final shop = _Shop();
    // Tall enough that the listing's page shows its questions row, which asks for its number, at once.
    await open(tester, shop, size: const Size(360, 2400));
    // Each visit asks twice: the listing's own page, then the list on coming back. The list's first ask, made
    // while 2 were waiting, is held; the second, after the answer, comes back at once with 0.
    final held = Completer<void>();
    shop.holdCounts.addAll([null, held]);
    await visit(tester, shop, 1, ManageListingScreen);
    shop.waiting[1] = 0;
    await visit(tester, shop, 1, ManageListingScreen);
    expect(waitingOn(1, 'Жауапсыз'), findsNothing);
    held.complete();
    await settle(tester);
    expect(waitingOn(1, 'Жауапсыз'), findsNothing, reason: 'the 2 asked first came last');
  });

  testWidgets('while a slow list loads, a number read since is not replaced by the old one', (tester) async {
    final shop = _Shop();
    await open(tester, shop);
    shop.waiting[1] = 0;
    await visit(tester, shop, 1, ManageListingScreen);
    expect(waitingOn(1, 'Жауапсыз'), findsNothing);
    final held = shop.holdList = Completer<void>();
    await tester.fling(find.byType(ListView).last, const Offset(0, 400), 1000);
    for (var i = 0; i < 30 && shop.lists < 2; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(shop.lists, 2, reason: 'the new list is asked for and held');
    await tester.pump(const Duration(milliseconds: 300));
    expect(tile(title(1)), findsOneWidget, reason: 'the old list stays on screen meanwhile');
    expect(waitingOn(1, 'Жауапсыз сұрақ: 2'), findsNothing, reason: 'and keeps the new 0');
    held.complete();
    await settle(tester);
    expect(shop.lists, 2);
    expect(waitingOn(1, 'Жауапсыз'), findsNothing);
  });

  testWidgets('in the demo, the listing with a question shows it, the same number as the to-do card', (tester) async {
    await open(tester, null, screen: const MyListingsScreen(status: 'questions'));
    final todo = (recorded['GET /me/todo'] as Map)['questions'] as int;
    expect(todo, greaterThan(0));
    expect(chipSays('Сұрақ күтеді $todo'), findsOneWidget);
    expect(waitingOn(2, 'Жауапсыз сұрақ: 1'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('at 360 wide with text ×2 the line fits and reads well, ${brightness.name}', (tester) async {
      await open(tester, _Shop(), text: 2, brightness: brightness);
      expect(tester.takeException(), isNull);
      expect(waitingOn(3, 'Жауапсыз сұрақ: 1'), findsOneWidget);
      final errors = <String>[];
      await look(tester, errors);
      expect(errors, isEmpty);
    });
  }
}
