import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/listing_contents.dart';

/// Records the size the screen asked the picker for.
class _FakePicker extends ImagePickerPlatform {
  final sides = <double?>[];

  @override
  Future<XFile?> getImageFromSource(
      {required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async {
    sides.add(options.maxWidth);
    return XFile.fromData(utf8.encode('jpeg bytes'), name: 'p.jpg', path: '/picked/p.jpg');
  }
}

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> listing() => {
      'id': 7,
      'status': 'published',
      'title': 'Nike Air Force 1',
      'category': 'sneakers',
      'brand': 'Nike',
      'model_name': 'AF1',
      'color': 'қара',
      'price_tiyn': 4500000,
      'delivery_price_tiyn': 150000,
      'condition': 'used_good',
      'authenticity': 'unverified',
      'showcase_style': 'clean',
      'sizes': [
        {'id': 1, 'label': '42', 'insole_cm': '27,0', 'available': true},
      ],
      'media': [
        for (final a in ['front', 'outer', 'inner', 'back'])
          {'original_url': 'https://cdn/$a.jpg', 'processed_url': null, 'angle': a},
        for (var i = 0; i < 8; i++) {'original_url': 'https://cdn/f$i.jpg', 'processed_url': null, 'angle': 'frame'},
      ],
      'seller': {'id': 3, 'shop_name': 'Qadam Store', 'city': 'Алматы'},
    };

void main() {
  Future<List<Uri>> pump(WidgetTester tester, _FakePicker picker) async {
    ImagePickerPlatform.instance = picker;
    final uploads = <Uri>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/media')) {
            uploads.add(req.url);
            return jsonResponse({'url': 'https://cdn/new.jpg'}, 201);
          }
          return jsonResponse(listing());
        }));
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: ListingContentsCard(listing: Listing.fromJson(listing()), onChanged: (_) {}))))));
    return uploads;
  }

  Future<void> addFrom(WidgetTester tester, Key button) async {
    await tester.tap(find.byKey(button));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('source-camera')));
    await tester.pumpAndSettle();
  }

  testWidgets('a close-up asked for by the showcase hint is taken and kept at 3000 px', (tester) async {
    final picker = _FakePicker();
    final uploads = await pump(tester, picker);
    await addFrom(tester, const Key('stop-detail'));
    expect(picker.sides, [3000]);
    expect(uploads.single.queryParameters['detail'], 'true');
  });

  testWidgets('a side photo stays at the usual 2000 px', (tester) async {
    final picker = _FakePicker();
    final uploads = await pump(tester, picker);
    await tester.tap(find.byKey(const Key('add-photo')));
    await tester.pumpAndSettle();
    await addFrom(tester, const Key('angle-outer'));
    expect(picker.sides, [2000]);
    expect(uploads.single.queryParameters.containsKey('detail'), isFalse);
  });
}
