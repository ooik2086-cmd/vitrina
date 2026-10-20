import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
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
  _FakePicker([this.size = 10]);
  final int size;

  @override
  Future<XFile?> getVideo(
          {ImageSource source = ImageSource.gallery,
          CameraDevice preferredCameraDevice = CameraDevice.rear,
          Duration? maxDuration}) async =>
      XFile.fromData(Uint8List(size), name: 'v.mp4', path: '/picked/v.mp4', mimeType: 'video/mp4');

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
        'backfilled': false,
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
    expect(find.text('Жағдайы: Киілген, жақсы'), findsOneWidget);
    expect(find.text('Ақаулар: Өкшесі сәл тозған'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('add-evidence')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Сіз · 18.10 '), findsOneWidget);
    expect(find.textContaining('Сатушы · 18.10 '), findsOneWidget);
    expect(find.text('Табаны жарылған'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.text('Дәлел қосу (9 қалды)'), findsOneWidget);
  });

  testWidgets('a photo opened an hour later gets a fresh link first', (tester) async {
    var loads = 0;
    final start = DateTime(2026, 10, 18, 12);
    await withClock(Clock.fixed(start), () async {
      await pump(tester, MockClient((req) async {
        loads++;
        final item = evidence(1, 'buyer');
        item['url'] = 'https://cdn/e1.jpg?sig=$loads'; // every load signs the link anew
        return jsonResponse(order('DISPUTED', [item]));
      }));
    });
    await tester.scrollUntilVisible(find.byKey(const Key('evidence-1')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(loads, 1);
    await withClock(Clock.fixed(start.add(const Duration(minutes: 55))), () async {
      await tester.tap(find.byKey(const Key('evidence-1')));
      await tester.pumpAndSettle();
    });
    expect(loads, 2);
    final shown = tester.widgetList<Image>(find.descendant(of: find.byType(Dialog), matching: find.byType(Image)));
    expect(shown.map((i) => (i.image as NetworkImage).url), contains('https://cdn/e1.jpg?sig=2'));
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
    expect(body, contains('name="key"'));
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
    await tester.tap(find.text('Болдырмау'));
    await tester.pumpAndSettle();
    expect(posts, 0);
  });

  testWidgets('a long gallery video is refused before it is read', (tester) async {
    ImagePickerPlatform.instance = _FakePicker(12 * 1024 * 1024 + 1);
    var posts = 0;
    await pump(tester, MockClient((req) async {
      if (req.method == 'POST') posts++;
      return jsonResponse(order('DISPUTED', []));
    }));
    await tester.scrollUntilVisible(find.byKey(const Key('add-evidence')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('add-evidence')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('evidence-video')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Файл тым үлкен'), findsOneWidget);
    expect(find.byKey(const Key('evidence-send')), findsNothing);
    expect(posts, 0);
  });

  testWidgets('after a dropped connection the retry sends the same key', (tester) async {
    ImagePickerPlatform.instance = _FakePicker();
    final keys = <String>[];
    final items = <Map<String, dynamic>>[];
    await pump(tester, MockClient((req) async {
      if (req.method == 'POST') {
        final body = utf8.decode(req.bodyBytes, allowMalformed: true);
        keys.add(RegExp(r'name="key"\r\n\r\n([0-9a-f]+)').firstMatch(body)!.group(1)!);
        if (keys.length == 1) throw http.ClientException('connection reset');
        final item = evidence(1, 'buyer');
        items.add(item);
        return jsonResponse(item, 201);
      }
      return jsonResponse(order('DISPUTED', items));
    }));
    await tester.scrollUntilVisible(find.byKey(const Key('add-evidence')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('add-evidence')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('evidence-gallery')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('evidence-preview')), findsOneWidget);
    expect(find.text('Жіберген соң өзгертуге не өшіруге болмайды. Екі тарап та, қолдау қызметі де көреді.'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('evidence-send')));
    await tester.pumpAndSettle();
    expect(find.text('Дәлел жіберілмеді: байланыс үзілді.'), findsOneWidget);
    await tester.tap(find.text('Қайталау'));
    await tester.pumpAndSettle();
    expect(keys, hasLength(2));
    expect(keys[1], keys[0]);
    expect(find.byKey(const Key('evidence-1')), findsOneWidget);
  });

  testWidgets('a case closed meanwhile reloads the order and hides the button', (tester) async {
    ImagePickerPlatform.instance = _FakePicker();
    var status = 'DISPUTED';
    await pump(tester, MockClient((req) async {
      if (req.method == 'POST') {
        status = 'COMPLETED';
        return jsonResponse({'code': 'invalid_status', 'message_kk': 'Қазір бұл әрекетті жасау мүмкін емес.'}, 409);
      }
      return jsonResponse(order(status, [evidence(1, 'seller')]));
    }));
    await tester.scrollUntilVisible(find.byKey(const Key('add-evidence')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('add-evidence')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('evidence-gallery')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('evidence-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add-evidence')), findsNothing);
    expect(find.byKey(const Key('evidence-1')), findsOneWidget);
  });

  testWidgets('the evidence sheet fits a small phone with large text', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final api = Api(base: 'http://x/api/v1', client: MockClient((req) async => jsonResponse(order('DISPUTED', []))))
      ..token = 't';
    final session = Session(api)..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrderScreen(orderId: 5))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('add-evidence')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.byKey(const Key('add-evidence')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-evidence')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('evidence-camera')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('evidence-video')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('evidence-video')).hitTestable(), findsOneWidget);
  });

  testWidgets('a dispute says until when evidence can be added', (tester) async {
    await pump(
        tester,
        MockClient(
            (req) async => jsonResponse({...order('DISPUTED', []), 'evidence_until': '2026-10-20T08:00:00+00:00'})));
    await tester.scrollUntilVisible(find.byKey(const Key('evidence-until')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Дәлел қосу мерзімі: 20.10'), findsOneWidget);
  });

  testWidgets('during the inspection days only the buyer can add photos', (tester) async {
    await pump(tester, MockClient((req) async => jsonResponse(order('DELIVERED_PENDING_CONFIRMATION', []))));
    await tester.scrollUntilVisible(find.byKey(const Key('add-evidence')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Ақау байқасаңыз'), findsOneWidget);
  });

  testWidgets('the seller has nothing to add during the inspection days', (tester) async {
    await pump(tester, MockClient((req) async => jsonResponse(order('DELIVERED_PENDING_CONFIRMATION', []))), meId: 1);
    expect(find.byKey(const Key('evidence')), findsNothing);
  });
}
