import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/spin_capture_screen.dart';
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

  test('a large photo gets longer to travel on weak mobile data than a small one, never under a minute', () {
    expect(Api.uploadLimit(200 * 1000), const Duration(seconds: 60));
    expect(Api.uploadLimit(3 * 1000 * 1000), const Duration(seconds: 180)); // a 3 MB close-up at about 20 KB/s
  });

  testWidgets('a 360° set added later keeps the frames that went and sends only the rest again', (tester) async {
    ImagePickerPlatform.instance = _FakePicker();
    var uploads = 0;
    final media = <int>[];
    List<dynamic>? added;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/media')) {
            final n = ++uploads;
            if (n >= 3 && n <= 5) return jsonResponse({}, 500); // weak mobile data drops three frames
            media.add(n);
            return jsonResponse({'url': 'https://cdn/u$n.jpg'}, 201);
          }
          if (req.method == 'PATCH') added = (jsonDecode(req.body) as Map)['add_photos'] as List;
          return jsonResponse({...listing(), 'media': (listing()['media'] as List).take(4).toList()});
        }))
      ..uploadWaits = const [];
    final noSpin = Listing.fromJson({...listing(), 'media': (listing()['media'] as List).take(4).toList()});
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(child: ListingContentsCard(listing: noSpin, onChanged: (_) {}))))));
    await tester.tap(find.byKey(const Key('add-spin')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // the camera screen is up; its camera never opens here
    Navigator.of(tester.element(find.byType(SpinCaptureScreen))).pop([
      for (var i = 0; i < 8; i++) XFile.fromData(utf8.encode('frame $i'), name: 'f$i.jpg', path: '/f$i.jpg'),
    ]);
    await tester.pumpAndSettle();
    expect(added, isNull); // not all frames went: nothing is added yet
    expect(find.byKey(const Key('resend-spin')), findsOneWidget);
    await tester.tap(find.byKey(const Key('resend-spin')));
    await tester.pumpAndSettle();
    expect(uploads, 11); // the three that failed went again, the five that went were kept
    expect([
      for (final p in added!) p['url']
    ], [
      for (final n in [1, 2, 9, 10, 11, 6, 7, 8]) 'https://cdn/u$n.jpg'
    ]);
    expect(find.byKey(const Key('resend-spin')), findsNothing);
  });
}
