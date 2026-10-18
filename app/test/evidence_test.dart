import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/order_screen.dart';
import 'package:vitrina/session.dart';

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

class _FakePicker extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource(
          {required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async =>
      XFile.fromData(utf8.encode('jpeg bytes'), name: 'p.jpg', path: '/picked/p.jpg');
}

Map<String, dynamic> evidence(int id, String from, {String kind = 'photo', String? note}) => {
      'id': id,
      'from': from,
      'url': 'https://cdn/e$id.${kind == 'video' ? 'mp4' : 'jpg'}',
      'kind': kind,
      'note': note,
      'at': '2026-10-18T08:00:00+00:00'
    };

Map<String, dynamic> order(String status, List<Map<String, dynamic>> items) => {
      'id': 5,
      'status': status,
      'listing_id': 7,
      'buyer_id': 2,
      'seller_id': 1,
      'total_tiyn': 4650000,
      'history': [],
      'listing_details': {
        'brand': 'Nike',
        'model_name': 'Air Max 90',
        'color': 'Ақ',
        'condition': 'used_good',
        'defects': 'Өкшесі сәл тозған',
        'description': null,
      },
      'evidence': items,
    };

void main() {
  Future<void> pump(WidgetTester tester, http.Client client, {int meId = 2}) async {
    final api = Api(base: 'http://x/api/v1', client: client)..token = 't';
    final session = Session(api)
      ..update(Me.fromJson({'id': meId, 'phone': '+7701000000$meId', 'is_seller': meId == 1}));
    tester.view.physicalSize = const Size(500, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrderScreen(orderId: 5))));
    await tester.pumpAndSettle();
  }

  testWidgets('a dispute shows what the listing said and both sides\' evidence', (tester) async {
    await pump(
        tester,
        MockClient((req) async => jsonResponse(order('DISPUTED', [
              evidence(1, 'buyer', note: 'Табаны жарылған'),
              evidence(2, 'seller', kind: 'video'),
            ]))));
    expect(find.text('Тапсырыс берген кездегі сипаттама'), findsOneWidget);
    expect(find.text('Nike · Air Max 90 · Ақ'), findsOneWidget);
    expect(find.text('Күйі: Киілген, жақсы'), findsOneWidget);
    expect(find.text('Ақаулар: Өкшесі сәл тозған'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('add-evidence')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Сіз · 18.10'), findsOneWidget);
    expect(find.text('Сатушы · 18.10'), findsOneWidget);
    expect(find.text('Табаны жарылған'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.text('Дәлел қосу (9 қалды)'), findsOneWidget);
  });

  testWidgets('evidence can be read after a decision but no longer added', (tester) async {
    await pump(tester, MockClient((req) async => jsonResponse(order('REFUND_PENDING', [evidence(1, 'buyer')]))));
    await tester.scrollUntilVisible(find.byKey(const Key('evidence')), 200, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('evidence-1')), findsOneWidget);
    expect(find.byKey(const Key('add-evidence')), findsNothing);
  });

  testWidgets('a buyer adds a photo with a note and sees it in the list', (tester) async {
    ImagePickerPlatform.instance = _FakePicker();
    final items = <Map<String, dynamic>>[];
    final sent = <http.Request>[];
    await pump(tester, MockClient((req) async {
      if (req.method == 'POST' && req.url.path.endsWith('/orders/5/evidence')) {
        sent.add(req);
        final item = evidence(items.length + 1, 'buyer', note: 'Табаны');
        items.add(item);
        return jsonResponse(item, 201);
      }
      return jsonResponse(order('RETURN_REQUESTED', items));
    }));
    expect(find.text('Әзірге дәлел жоқ.'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('add-evidence')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('add-evidence')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('evidence-gallery')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('evidence-note')), 'Табаны');
    await tester.tap(find.byKey(const Key('evidence-send')));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    final body = utf8.decode(sent.single.bodyBytes, allowMalformed: true);
    expect(body, contains('name="note"'));
    expect(body, contains('Табаны'));
    expect(body, contains('filename="p.jpg"'));
    expect(find.text('Дәлел қосылды'), findsOneWidget);
    expect(find.byKey(const Key('evidence-1')), findsOneWidget);
    expect(find.text('Дәлел қосу (9 қалды)'), findsOneWidget);
  });

  testWidgets('a cancelled note sends nothing', (tester) async {
    ImagePickerPlatform.instance = _FakePicker();
    var posts = 0;
    await pump(tester, MockClient((req) async {
      if (req.method == 'POST') posts++;
      return jsonResponse(order('DISPUTED', []));
    }), meId: 1);
    await tester.scrollUntilVisible(find.byKey(const Key('add-evidence')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('add-evidence')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('evidence-gallery')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Бас тарту'));
    await tester.pumpAndSettle();
    expect(posts, 0);
  });
}
