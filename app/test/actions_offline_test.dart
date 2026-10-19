// Presses with the connection down that need more than one press to reach: a purchase and a delivery city. Every
// button on every screen is pressed offline by the press suites (test/presses_*_test.dart).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/order_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/delivery_eta.dart';

import 'support/press.dart';
import 'support/screens.dart';

void main() {
  testWidgets('a city picked for the arrival guess says when it cannot be asked', (tester) async {
    pickedDeliveryCity.value = null;
    addTearDown(() => pickedDeliveryCity.value = null);
    var down = false;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (down) throw http.ClientException('down');
          return http.Response(
              jsonEncode({
                'estimate': null,
                'cities': ['Алматы', 'Астана']
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    await tester.pumpWidget(
        SessionScope(session: Session(api), child: const MaterialApp(home: Scaffold(body: DeliveryEta(listingId: 5)))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delivery-eta')));
    await tester.pumpAndSettle();
    down = true;
    await tester.tap(find.byKey(const Key('eta-city-Астана')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Байланыс жоқ'), findsOneWidget);
    expect(pickedDeliveryCity.value, isNull, reason: 'the next listing would quietly ask for a city not shown here');
  });
  testWidgets('an order placed with the connection down is said, and nothing opens as if it went through',
      (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (line, _) = await openFresh(tester, screens['listing1']!, null);
    await tester.scrollUntilVisible(find.text('42'), 300,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first);
    // Mid-screen, clear of the buy bar.
    Scrollable.ensureVisible(tester.element(find.text('42').first), alignment: 0.4);
    await tester.pump();
    await tester.tap(find.text('42').first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('buy')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('delivery-name')), 'Аза Сапар');
    await tester.enterText(find.byKey(const Key('delivery-phone')), '+7 701 000 00 00');
    await tester.enterText(find.byKey(const Key('delivery-city')), 'Алматы');
    await tester.enterText(find.byKey(const Key('delivery-address')), 'Абай даңғылы 10');
    await tester.ensureVisible(find.byKey(const Key('delivery-continue')));
    await tester.pump();
    line.down = true;
    final before = line.dropped.length;
    await tester.tap(find.byKey(const Key('delivery-continue')));
    await settle(tester);
    expect(line.dropped.skip(before), contains('POST /orders'));
    expect(find.textContaining('Байланыс жоқ'), findsOneWidget);
    expect(find.byType(OrderScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
