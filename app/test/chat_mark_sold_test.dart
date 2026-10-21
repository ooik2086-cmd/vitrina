// With online payment off, a pair is sold in the chat and paid in hand. The seller marks it sold right there, so the
// page does not keep offering it: one pair of the chosen size, once, even when the answer is lost on weak data.
import 'dart:async';
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

Map<String, Object?> _conv(String role) => {
      'id': 9,
      'listing_id': 7,
      'listing_title': 'Nike Air Force 1',
      'listing_cover': null,
      'price_tiyn': 4500000,
      'role': role,
      'other_name': 'Айгүл',
      'last_message': null,
      'unread': 0,
    };

Map<String, Object?> _listing(Map<int, int> stock, [String status = 'published']) => {
      'id': 7,
      'status': status == 'published' && !stock.values.any((q) => q > 0) ? 'sold' : status,
      'ever_on_sale': status != 'draft',
      'title': 'Nike Air Force 1',
      'category': 'sneakers',
      'audience': 'unisex',
      'brand': 'Nike',
      'model_name': 'Air Force 1',
      'color': 'ақ',
      'price_tiyn': 4500000,
      'delivery_price_tiyn': 150000,
      'condition': 'new_with_box',
      'authenticity': 'unverified',
      'showcase_style': 'clean',
      'sizes': [
        for (final e in stock.entries)
          {'id': e.key, 'label': '${41 + e.key}', 'insole_cm': '27,0', 'available': e.value > 0, 'quantity': e.value},
      ],
      'media': [],
      'seller': {'id': 3, 'shop_name': 'Qadam Store', 'city': 'Алматы'},
    };

const _tooLate = 'Белгіні қайтару уақыты өтті (10 минут). Жұп санын тауарды өңдеу бетінде түзетіп, '
    'қайта сатылымға қойыңыз.';

void main() {
  /// Opens the chat as [role]. The server keeps [stock] by size id and takes a pair as the real one does, once per
  /// key; [lost] says, by mark, that it was taken but its answer never came back. Marks sent go into the list.
  Future<List<(int, String?)>> open(WidgetTester tester,
      {required Map<int, int> stock,
      String role = 'seller',
      String status = 'published',
      bool Function(int mark)? lost,
      bool Function(int mark)? broken,
      List<(int, String?)>? undos,
      bool Function(int undo)? undoLost,
      bool tooLate = false,
      Future<void>? undoGate}) async {
    final sent = <(int, String?)>[];
    final taken = <String, int>{}, putBack = <String>{};
    var marks = 0, unmarks = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          final path = req.url.path;
          if (req.method == 'GET' && path.endsWith('/messages')) {
            return _json({'conversation': _conv(role), 'items': []});
          }
          if (req.method == 'GET' && path.endsWith('/listings/7')) return _json(_listing(stock, status));
          final undo = RegExp(r'/listings/7/sizes/(\d+)/sold/undo$').firstMatch(path);
          if (req.method == 'POST' && undo != null) {
            // As the server: only a mark made on this size, once, and only soon after.
            final n = ++unmarks;
            final id = int.parse(undo.group(1)!), key = req.headers['Idempotency-Key'];
            undos?.add((id, key));
            if (key == null || taken[key] != id) return _json({'code': 'not_found', 'message_kk': 'Табылмады.'}, 404);
            if (tooLate && !putBack.contains(key)) {
              return _json({'code': 'too_late_to_undo', 'message_kk': _tooLate}, 409);
            }
            if (undoGate != null) await undoGate;
            if (putBack.add(key)) stock[id] = stock[id]! + 1;
            if (undoLost?.call(n) ?? false) throw http.ClientException('answer lost');
            return _json(_listing(stock, status));
          }
          final sold = RegExp(r'/listings/7/sizes/(\d+)/sold$').firstMatch(path);
          if (req.method == 'POST' && sold != null) {
            final n = ++marks;
            final id = int.parse(sold.group(1)!), key = req.headers['Idempotency-Key'];
            sent.add((id, key));
            if (key != null && !taken.containsKey(key)) {
              if (stock[id]! <= 0) return _json({'code': 'out_of_stock', 'message_kk': 'Бұл өлшем қалмады.'}, 409);
              taken[key] = id;
              stock[id] = stock[id]! - 1;
            }
            if (lost?.call(n) ?? false) throw http.ClientException('answer lost');
            if (broken?.call(n) ?? false) return http.Response('<html>Bad Gateway</html>', 502);
            return _json(_listing(stock, status));
          }
          return _json({}, 404);
        }));
    final session = Session(api)..me = Me.fromJson({'id': 3, 'phone': '+77010000003', 'is_seller': true});
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const ChatScreen(conversationId: 9, pollEvery: Duration(hours: 1)))),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return sent;
  }

  final markSold = find.byKey(const Key('mark-sold'));

  Future<void> sell(WidgetTester tester, {int? size}) async {
    await tester.tap(markSold);
    await tester.pumpAndSettle();
    if (size != null) {
      await tester.tap(find.byKey(Key('sold-size-$size')));
      await tester.pumpAndSettle();
    }
  }

  Future<void> sure(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('sold-sure')));
    await tester.pumpAndSettle();
  }

  testWidgets('one pair of the chosen size leaves the stock, after the seller says yes', (tester) async {
    final stock = {1: 2, 2: 0, 3: 1};
    final sent = await open(tester, stock: stock);
    await sell(tester);
    expect(find.byKey(const Key('sold-size-2')), findsNothing); // nothing left of it to sell
    expect(find.text('Қалды: 2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sold-size-1')));
    await tester.pumpAndSettle();
    expect(find.text('42 өлшемі: 2 жұп еді, 1 жұп қалады.'), findsOneWidget);
    await sure(tester);
    expect(sent.single.$1, 1);
    expect(sent.single.$2, isNotNull);
    expect(stock, {1: 1, 2: 0, 3: 1});
    expect(find.text('Белгіленді: 42 өлшемінен 1 жұп қалды.'), findsOneWidget);
  });

  testWidgets('saying no changes nothing', (tester) async {
    final sent = await open(tester, stock: {1: 2});
    await sell(tester, size: 1);
    await tester.tap(find.text('Болдырмау'));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
  });

  testWidgets('the last pair says the item will show as sold', (tester) async {
    final stock = {1: 1, 2: 0};
    await open(tester, stock: stock);
    await sell(tester, size: 1);
    expect(find.textContaining('Бұл соңғы жұп.'), findsOneWidget);
    await sure(tester);
    expect(stock, {1: 0, 2: 0});
    expect(find.text('Белгіленді: тауар түгел сатылды.'), findsOneWidget);
  });

  testWidgets('a pair that is not the last one says nothing about the item being sold', (tester) async {
    await open(tester, stock: {1: 1, 2: 1});
    await sell(tester, size: 1);
    expect(find.textContaining('Бұл соңғы жұп.'), findsNothing);
  });

  testWidgets('one size with more pairs left says nothing about the item being sold', (tester) async {
    await open(tester, stock: {1: 2});
    await sell(tester, size: 1);
    expect(find.textContaining('Бұл соңғы жұп.'), findsNothing);
  });

  testWidgets('a size sold out while others are left is not told as the whole item sold', (tester) async {
    await open(tester, stock: {1: 1, 2: 2});
    await sell(tester, size: 1);
    await sure(tester);
    expect(find.text('Белгіленді: 42 өлшемінен 0 жұп қалды.'), findsOneWidget);
    expect(find.text('Белгіленді: тауар түгел сатылды.'), findsNothing);
  });

  testWidgets('the last pair of a paused item does not promise it will show as sold', (tester) async {
    await open(tester, stock: {1: 1}, status: 'paused');
    await sell(tester, size: 1);
    expect(find.textContaining('Бұл соңғы жұп.'), findsNothing);
  });

  testWidgets('an item that cannot change its stock now says so before asking anything', (tester) async {
    await open(tester, stock: {1: 1}, status: 'hidden');
    await sell(tester);
    expect(find.text('Бұл тауардың қалдығын қазір өзгерту мүмкін емес.'), findsOneWidget);
    expect(find.byKey(const Key('sold-size-1')), findsNothing);
  });

  final pendingLine = find.byKey(const Key('sale-not-sent'));
  bool canMark(WidgetTester tester) => tester.widget<ActionChip>(markSold).onPressed != null;

  testWidgets('a mark whose answer was lost stays in a line, and sent again takes one pair only', (tester) async {
    final stock = {1: 2};
    final sent = await open(tester, stock: stock, lost: (n) => n == 1);
    await sell(tester, size: 1);
    await sure(tester);
    expect(find.text('Байланыс жоқ. 42 өлшемінің белгісі сақталмаған болуы мүмкін.'), findsOneWidget);
    expect(canMark(tester), isFalse); // the open mark is finished first, so no pair is marked twice
    await tester.tap(find.byKey(const Key('sale-resend')));
    await tester.pumpAndSettle();
    expect(sent, hasLength(2));
    expect(sent[1], sent[0]); // the same mark with its key, so the pair is taken once
    expect(stock, {1: 1});
    expect(pendingLine, findsNothing);
    expect(find.text('Белгіленді: 42 өлшемінен 1 жұп қалды.'), findsOneWidget);
    expect(canMark(tester), isTrue);
    await sell(tester, size: 1); // and then a real second pair, with its own key
    await sure(tester);
    expect(stock, {1: 0});
    expect(sent[2].$2, isNot(sent[0].$2));
  });

  testWidgets('a failing server after the pair was taken keeps the mark to send again, not a new one', (tester) async {
    final stock = {1: 2};
    final sent = await open(tester, stock: stock, broken: (n) => n == 1);
    await sell(tester, size: 1);
    await sure(tester);
    expect(pendingLine, findsOneWidget);
    await tester.tap(find.byKey(const Key('sale-resend')));
    await tester.pumpAndSettle();
    expect(sent[1], sent[0]);
    expect(stock, {1: 1});
  });

  testWidgets('a refused mark is not kept: the next tap asks again', (tester) async {
    final stock = {1: 1};
    final sent = await open(tester, stock: stock);
    await sell(tester, size: 1);
    stock[1] = 0;
    await sure(tester);
    expect(find.text('Бұл өлшем қалмады.'), findsOneWidget);
    expect(pendingLine, findsNothing);
    await sell(tester);
    expect(find.text('Бұл тауардың қалдығы жоқ.'), findsOneWidget);
    expect(sent, hasLength(1));
  });

  testWidgets('a pair gone meanwhile some other way is not put back', (tester) async {
    final stock = {1: 2};
    await open(tester, stock: stock);
    await sell(tester, size: 1);
    stock[1] = 1; // ordered by a buyer while the question was open
    await sure(tester);
    expect(stock, {1: 0}); // both pairs are gone, not one
    expect(find.text('Белгіленді: тауар түгел сатылды.'), findsOneWidget);
  });

  testWidgets('with nothing left it says so', (tester) async {
    await open(tester, stock: {1: 0});
    await sell(tester);
    expect(find.text('Бұл тауардың қалдығы жоқ.'), findsOneWidget);
    expect(find.byKey(const Key('sold-size-1')), findsNothing);
  });

  testWidgets('only the seller can mark a pair sold', (tester) async {
    await open(tester, stock: {1: 2}, role: 'buyer');
    expect(markSold, findsNothing);
  });

  final undoMark = find.byKey(const Key('sale-undo'));
  final undoLine = find.byKey(const Key('sale-undo-line'));

  testWidgets('a mark tapped by mistake is taken back with its own key, once', (tester) async {
    final stock = {1: 1, 2: 0}, undos = <(int, String?)>[];
    final sent = await open(tester, stock: stock, undos: undos);
    await sell(tester, size: 1);
    await sure(tester);
    expect(find.descendant(of: undoLine, matching: find.text('Белгіленді: тауар түгел сатылды.')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing); // said once, in the line, with nothing over the field
    await tester.tap(undoMark);
    await tester.pumpAndSettle();
    expect(undos.single, sent.single); // the mark's size and key: no other mark can be undone by it
    expect(stock, {1: 1, 2: 0});
    expect(find.text('Белгі алынды: 42 өлшемінен 1 жұп бар.'), findsOneWidget);
    expect(undoLine, findsNothing); // nothing left to take back: a second undo cannot be sent from here
    expect(canMark(tester), isTrue);
  });

  testWidgets('the way back stays while the server still allows it, then goes', (tester) async {
    await open(tester, stock: {1: 2});
    await sell(tester, size: 1);
    await sure(tester);
    await tester.pump(const Duration(minutes: 8));
    expect(undoMark, findsOneWidget); // long after the message, for a seller who notices late
    await tester.pump(const Duration(minutes: 2));
    expect(undoLine, findsNothing); // before the server's ten minutes, so a tap never meets a refusal
  });

  testWidgets('a newer mark is the one the line takes back', (tester) async {
    final stock = {1: 3}, undos = <(int, String?)>[];
    final sent = await open(tester, stock: stock, undos: undos);
    await sell(tester, size: 1);
    await sure(tester);
    await sell(tester, size: 1);
    await sure(tester);
    await tester.tap(undoMark);
    await tester.pumpAndSettle();
    expect(undos.single, sent[1]);
    expect(stock, {1: 2});
  });

  testWidgets('an undo whose answer was lost stays in the line and goes again with the same key', (tester) async {
    final stock = {1: 2}, undos = <(int, String?)>[];
    await open(tester, stock: stock, undos: undos, undoLost: (n) => n == 1);
    await sell(tester, size: 1);
    await sure(tester);
    await tester.tap(undoMark);
    await tester.pumpAndSettle();
    expect(find.text('Байланыс жоқ. 42 өлшемінің белгісі алынбаған болуы мүмкін.'), findsOneWidget);
    expect(canMark(tester), isFalse); // the open undo is finished first
    await tester.pump(const Duration(minutes: 20));
    expect(undoLine, findsOneWidget); // still the way to know: the server answers a repeat at any time
    await tester.tap(find.byKey(const Key('sale-undo-again')));
    await tester.pumpAndSettle();
    expect(undos, hasLength(2));
    expect(undos[1], undos[0]);
    expect(stock, {1: 2}); // back once, not twice
    expect(find.text('Белгі алынды: 42 өлшемінен 2 жұп бар.'), findsOneWidget);
    expect(undoLine, findsNothing);
  });

  testWidgets('too late to take back says what to do instead, long enough to read', (tester) async {
    final stock = {1: 2};
    await open(tester, stock: stock, tooLate: true);
    await sell(tester, size: 1);
    await sure(tester);
    await tester.tap(undoMark);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1)); // a bar timed out by now would be gone
    expect(find.text(_tooLate), findsOneWidget);
    expect(undoLine, findsNothing);
    expect(stock, {1: 1});
  });

  testWidgets('an undo answered after the chat was left is still told', (tester) async {
    final stock = {1: 2}, gate = Completer<void>();
    await open(tester, stock: stock, undoGate: gate.future);
    await sell(tester, size: 1);
    await sure(tester);
    await tester.tap(undoMark);
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    gate.complete();
    await tester.pumpAndSettle();
    expect(stock, {1: 2});
    expect(find.text('Белгі алынды: 42 өлшемінен 2 жұп бар.'), findsOneWidget);
  });

  testWidgets('the way back fits at 360 wide with large text', (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, stock: {1: 2});
    await sell(tester, size: 1);
    await sure(tester);
    expect(undoMark, findsOneWidget);
    expect(tester.getSize(undoMark).height, greaterThanOrEqualTo(48));
    final row = tester.getRect(find.byKey(const Key('quick-replies')));
    final words = tester.getRect(find.descendant(of: markSold, matching: find.text('Сатылды')));
    expect(row.top, lessThanOrEqualTo(words.top)); // the button that starts it is not cut
    expect(row.bottom, greaterThanOrEqualTo(words.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the size list and the question fit at 360 wide with large text', (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, stock: {1: 1, 2: 3, 3: 2, 4: 5});
    await sell(tester, size: 4);
    expect(find.byKey(const Key('sold-sure')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
