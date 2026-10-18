import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/scroll_showcase.dart';

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> media(String angle, String name, {bool cut = true}) => {
      'original_url': 'https://cdn/$name.jpg',
      'processed_url': cut ? 'https://cdn/$name.webp' : null,
      'thumb_url': 'https://cdn/$name-s.webp',
      'angle': angle,
    };

Map<String, dynamic> listing({bool details = true, String? backdrop = 'light'}) => {
      'id': 7,
      'status': 'published',
      'title': 'Nike Air Force 1',
      'category': 'sneakers',
      'brand': 'Nike',
      'model_name': 'AF1',
      'color': 'қара',
      'price_tiyn': 4500000,
      'delivery_price_tiyn': 150000,
      'segment': null,
      'condition': 'used_good',
      'authenticity': 'unverified',
      'defects': null,
      'description': null,
      'showcase_style': 'clean',
      'backdrop': backdrop,
      'sizes': [
        {'id': 1, 'label': '42', 'insole_cm': '27,0', 'available': true},
      ],
      'media': [
        media('front', 'front'),
        media('outer', 'outer'),
        media('inner', 'inner'),
        media('back', 'back'),
        if (details) ...[media('top', 'top'), media('sole', 'sole'), media('label', 'label', cut: false)],
        for (var i = 0; i < 24; i++) media('frame', 'f$i'),
      ],
      'seller': {'id': 3, 'shop_name': 'Qadam Store', 'city': 'Алматы'},
    };

void main() {
  group('plan', () {
    test('turns through the frames, then the top, sole and close-up', () {
      final plan = ShowcasePlan.of(Listing.fromJson(listing()));
      expect([for (final s in plan.steps) s.kind], ['spin', 'top', 'sole', 'close']);
      expect(plan.at(0), (step: 0, frame: 0));
      final spinEnd = plan.startOf(1);
      expect(plan.at(spinEnd * 0.5).frame, 12);
      expect(plan.at(spinEnd - 0.0001), (step: 0, frame: 23));
      expect(plan.at(spinEnd + 0.0001).step, 1);
      expect(plan.at(1), (step: 3, frame: 0));
      expect(plan.steps.last.media.single.angle, 'label');
    });

    test('skips stops the seller did not photograph, and a close-up falls back to the front', () {
      final plan = ShowcasePlan.of(Listing.fromJson(listing(details: false)));
      expect([for (final s in plan.steps) s.kind], ['spin', 'close']);
      expect(plan.steps.last.media.single.angle, 'front');
    });

    test('scrolling back gives the same frame as on the way down', () {
      final plan = ShowcasePlan.of(Listing.fromJson(listing()));
      for (var p = 0.0; p <= 1; p += 0.01) {
        expect(plan.at(p), plan.at(p)); // a pure function of the scroll position: no state, no drift
      }
    });
  });

  Future<void> pump(WidgetTester tester, Map<String, dynamic> body, {Size size = const Size(400, 800)}) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
          return jsonResponse(body);
        }));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
  }

  Finder shown(String name) => find.byKey(ValueKey('showcase-https://cdn/$name'));

  testWidgets('scrolling turns the shoe while the viewer stays in place, and back turns it back', (tester) async {
    await pump(tester, listing());
    expect(shown('f0.webp'), findsOneWidget);
    final list = find.byType(Scrollable).first;
    await tester.drag(list, const Offset(0, -300));
    await tester.pump();
    // While moving: a small copy, and the viewer is still at the top of the screen.
    expect(find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.endsWith('-s.webp')),
        findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('showcase'))).dy, 0);
    await tester.pump(const Duration(milliseconds: 200));
    final moved = tester.widgetList<Image>(find.byType(Image)).map((i) => i.key).whereType<ValueKey>().first;
    expect('${moved.value}', isNot(contains('f0.')));
    expect('${moved.value}', endsWith('.webp')); // the full cut-out once it stops
    await tester.drag(list, const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 200));
    expect(shown('f0.webp'), findsOneWidget);
  });

  testWidgets('the stops jump straight to the sole, with a tick each time a stop is reached', (tester) async {
    final ticks = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') ticks.add(call);
      return null;
    });
    await pump(tester, listing());
    await tester.tap(find.byKey(const Key('showcase-step-sole')));
    await tester.pumpAndSettle();
    expect(shown('sole.webp'), findsOneWidget);
    expect(ticks, isNotEmpty);
    await tester.tap(find.byKey(const Key('showcase-step-close')));
    await tester.pumpAndSettle();
    expect(shown('label.jpg'), findsOneWidget); // the close-up is the photo as taken, not a cut-out
  });

  testWidgets('two fingers zoom the shoe and the page stays put; 1x resets', (tester) async {
    await pump(tester, listing());
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    final a = await tester.startGesture(at - const Offset(40, 0), pointer: 1);
    final b = await tester.startGesture(at + const Offset(40, 0), pointer: 2);
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(at - Offset(40.0 + i * 6, -i * 3.0));
      await b.moveTo(at + Offset(40.0 + i * 6, i * 3.0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(scroll.pixels, 0);
    final reset = find.byKey(const Key('showcase-reset-zoom'));
    expect(reset, findsOneWidget);
    await tester.tap(reset);
    await tester.pump();
    expect(reset, findsNothing);
  });

  testWidgets('a double tap zooms in and out', (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('showcase-reset-zoom')), findsOneWidget);
  });

  testWidgets('the backdrop follows the shoe and can be switched by hand', (tester) async {
    await pump(tester, listing(backdrop: 'dark'));
    BoxDecoration deco() => tester.widget<DecoratedBox>(find.byKey(const Key('showcase'))).decoration as BoxDecoration;
    expect(deco().gradient, isNotNull); // a light shoe on the dark backdrop
    await tester.tap(find.byKey(const Key('showcase-backdrop')));
    await tester.pump();
    expect(deco().gradient, isNull);
  });

  testWidgets('without a cut-out there is no backdrop switch', (tester) async {
    await pump(tester, listing(backdrop: null));
    expect(find.byKey(const Key('showcase-backdrop')), findsNothing);
  });

  testWidgets('the Photo tab shows the photos as taken, without the long scroll', (tester) async {
    await pump(tester, listing());
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('showcase-photos')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('showcase')), findsNothing);
    expect(find.byKey(const Key('buy')), findsOneWidget);
    await tester.tap(find.text('360°'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('showcase')), findsOneWidget);
  });

  testWidgets('price and the order button stay on screen while the shoe turns', (tester) async {
    await pump(tester, listing());
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('buy')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('total')).hitTestable(), findsOneWidget);
  });

  testWidgets('on a narrow phone the stop being shown stays in view and the photos button never scrolls away',
      (tester) async {
    await pump(tester, listing(), size: const Size(320, 700));
    expect(find.byKey(const Key('showcase-photos')).hitTestable(), findsOneWidget);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    scroll.jumpTo(ScrollShowcase.travelFor(700, 4) - 1); // the last moment of the turn: the close-up
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('showcase-step-close')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('showcase-photos')).hitTestable(), findsOneWidget);
  });
}
