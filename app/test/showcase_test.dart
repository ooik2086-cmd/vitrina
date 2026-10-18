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

Map<String, dynamic> listing({bool details = true, String? backdrop = 'light', bool cutFrames = true}) => {
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
        if (details) ...[media('top', 'top'), media('sole', 'sole'), media('detail', 'detail')],
        media('label', 'label', cut: false),
        for (var i = 0; i < 24; i++) media('frame', 'f$i', cut: cutFrames || i.isEven),
      ],
      'seller': {'id': 3, 'shop_name': 'Qadam Store', 'city': 'Алматы'},
    };

/// The test binding answers every image request with HTTP 400. A photo that fails after the stage has already moved
/// on to the next frame has nobody left to show its error, so Flutter logs it; that is expected here, not a fault.
void showcaseTest(String description, WidgetTesterCallback body) => testWidgets(description, (tester) async {
      final report = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.exception is! NetworkImageLoadException) report?.call(d);
      };
      try {
        await body(tester);
      } finally {
        FlutterError.onError = report;
      }
    });

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
      expect(plan.steps.last.media.single.angle, 'detail'); // the stitching close-up, not the size label
    });

    test('skips stops the seller did not photograph', () {
      final plan = ShowcasePlan.of(Listing.fromJson(listing(details: false)));
      expect([for (final s in plan.steps) s.kind], ['spin']);
    });

    test('scrolling back walks the same photos in reverse, and forward never goes back', () {
      final plan = ShowcasePlan.of(Listing.fromJson(listing()));
      final down = [for (var i = 0; i <= 1000; i++) plan.at(i / 1000)];
      final up = [for (var i = 1000; i >= 0; i--) plan.at(i / 1000)];
      expect(up.reversed.toList(), down);
      int order(({int step, int frame}) p) => plan.photos.indexOf(p);
      for (var i = 1; i < down.length; i++) {
        expect(order(down[i]), greaterThanOrEqualTo(order(down[i - 1])));
      }
      expect({for (final p in down) p}.length, plan.photos.length); // no photo is skipped
    });

    test('the middle of each photo shows that photo', () {
      final plan = ShowcasePlan.of(Listing.fromJson(listing()));
      for (final p in plan.photos) {
        expect(plan.at(plan.centreOf(p.step, p.frame)), p);
      }
    });

    test('a turn where some frames have no cut-out shows all of them as taken', () {
      final plan = ShowcasePlan.of(Listing.fromJson(listing(cutFrames: false)));
      expect(plan.steps.first.cut, isFalse);
      expect(plan.steps[1].cut, isTrue);
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

  String urlOf(ImageProvider p) => switch (p) {
        NetworkImage(:final url) => url,
        ResizeImage(:final imageProvider) => urlOf(imageProvider),
        _ => '$p',
      };
  // What the stage draws underneath (small copy) and, at rest, on top (full photo).
  String base(WidgetTester tester) => urlOf(tester.widget<Image>(find.byKey(const ValueKey('showcase-base'))).image);
  Iterable<String> full(WidgetTester tester) => tester
      .widgetList<Image>(find.byWidgetPredicate(
          (w) => w is Image && w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('showcase-full-')))
      .map((i) => urlOf(i.image));
  ScrollPosition page(WidgetTester tester) => tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  Matrix4 zoom(WidgetTester tester) => tester.widget<Transform>(find.byKey(const Key('showcase-zoom'))).transform;

  showcaseTest('scrolling turns the shoe while the stage stays in place, and back turns it back', (tester) async {
    await pump(tester, listing());
    expect(page(tester).pixels, 0); // the first-show hint turned it a little and back
    expect(base(tester), 'https://cdn/f0-s.webp');
    final list = find.byType(Scrollable).first;
    await tester.drag(list, const Offset(0, -300));
    await tester.pump();
    // While moving: only the small copy, and the stage still fills the screen from the top.
    expect(base(tester), isNot('https://cdn/f0-s.webp'));
    expect(base(tester), endsWith('-s.webp'));
    expect(full(tester), isEmpty);
    expect(tester.getTopLeft(find.byKey(const Key('showcase'))).dy, 0);
    expect(tester.getSize(find.byKey(const Key('showcase'))).height,
        800 - tester.getSize(find.byKey(const Key('buy'))).height - 24 - 1);
    await tester.pump(const Duration(milliseconds: 200));
    // At rest the full cut-out is laid over the small copy, which stays underneath until it has loaded.
    expect(full(tester).single, base(tester).replaceAll('-s.webp', '.webp'));
    expect(find.byKey(const ValueKey('showcase-base')), findsOneWidget);
    await tester.drag(list, const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 200));
    expect(base(tester), 'https://cdn/f0-s.webp');
  });

  showcaseTest('scrolling within one frame moves the stage without rebuilding it', (tester) async {
    await pump(tester, listing());
    final state = tester.state<ScrollShowcaseState>(find.byType(ScrollShowcase));
    page(tester).jumpTo(200);
    await tester.pumpAndSettle();
    final before = state.builds;
    page(tester).jumpTo(204); // a few pixels: still the same frame
    await tester.pump();
    expect(state.builds, before);
    expect(tester.getTopLeft(find.byKey(const Key('showcase'))).dy, 0); // still pinned
    page(tester).jumpTo(400); // the next frames
    await tester.pump();
    expect(state.builds, greaterThan(before));
  });

  showcaseTest('the catalog photo flies into the turning shoe', (tester) async {
    await pump(tester, listing());
    expect(
        find.descendant(of: find.byType(Hero), matching: find.byKey(const ValueKey('showcase-base'))), findsOneWidget);
    expect(tester.widget<Hero>(find.byType(Hero)).tag, 'listing-7');
  });

  showcaseTest('the stops jump straight to the sole, with one tick when it is reached', (tester) async {
    final ticks = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') ticks.add(call);
      return null;
    });
    await pump(tester, listing());
    await tester.tap(find.byKey(const Key('showcase-step-sole')));
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/sole-s.webp');
    expect(ticks, hasLength(1)); // one tick on arrival, not one for the top passed on the way
    await tester.tap(find.byKey(const Key('showcase-step-close')));
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/detail-s.webp');
  });

  showcaseTest('a pinch started while the page is scrolling zooms, and the page stops there', (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    final a = await tester.startGesture(at, pointer: 1);
    for (var i = 0; i < 5; i++) {
      await a.moveBy(const Offset(0, -20)); // the first finger is scrolling: the shoe is turning
      await tester.pump();
    }
    final scrolled = page(tester).pixels;
    expect(scrolled, greaterThan(0));
    final b = await tester.startGesture(at + const Offset(60, 0), pointer: 2);
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      await a.moveBy(const Offset(-6, -4)); // both drift up too: the page must not follow
      await b.moveBy(const Offset(6, -4));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(page(tester).pixels, scrolled);
    expect(zoom(tester).getMaxScaleOnAxis(), greaterThan(1.5));
    expect(find.byKey(const Key('showcase-reset-zoom')), findsOneWidget);
  });

  showcaseTest('zoomed in, one finger moves the shoe and the page stays; 1x lets the page scroll again',
      (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    final before = zoom(tester).getTranslation();
    await tester.dragFrom(at, const Offset(-40, -200));
    await tester.pumpAndSettle();
    expect(page(tester).pixels, 0);
    expect(zoom(tester).getTranslation(), isNot(before));
    await tester.tap(find.byKey(const Key('showcase-reset-zoom')));
    await tester.pumpAndSettle();
    expect(zoom(tester).getMaxScaleOnAxis(), 1);
    await tester.dragFrom(at, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(page(tester).pixels, greaterThan(0));
  });

  showcaseTest('a pinch never goes past 3x', (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    final a = await tester.startGesture(at - const Offset(10, 0), pointer: 1);
    final b = await tester.startGesture(at + const Offset(10, 0), pointer: 2);
    for (var i = 1; i <= 10; i++) {
      await a.moveBy(const Offset(-15, 0));
      await b.moveBy(const Offset(15, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(zoom(tester).getMaxScaleOnAxis(), 3);
  });

  showcaseTest('a double tap zooms in and a second one zooms out', (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    Future<void> doubleTap() async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
    }

    await doubleTap();
    expect(find.byKey(const Key('showcase-reset-zoom')), findsOneWidget);
    await doubleTap();
    expect(find.byKey(const Key('showcase-reset-zoom')), findsNothing);
    expect(zoom(tester).getMaxScaleOnAxis(), 1);
  });

  showcaseTest('a sideways drag turns the shoe too', (tester) async {
    await pump(tester, listing());
    await tester.drag(find.byKey(const Key('showcase')), const Offset(-200, 0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(base(tester), isNot('https://cdn/f0-s.webp'));
  });

  showcaseTest('the backdrop follows the shoe and can be switched by hand', (tester) async {
    await pump(tester, listing(backdrop: 'dark'));
    BoxDecoration deco() => tester.widget<DecoratedBox>(find.byKey(const Key('showcase'))).decoration as BoxDecoration;
    expect(deco().gradient, isNotNull); // a light shoe on the dark backdrop
    await tester.tap(find.byKey(const Key('showcase-backdrop')));
    await tester.pump();
    expect(deco().gradient, isNull);
  });

  showcaseTest('without a cut-out there is no backdrop switch', (tester) async {
    await pump(tester, listing(backdrop: null));
    expect(find.byKey(const Key('showcase-backdrop')), findsNothing);
  });

  showcaseTest('a turn of photos as taken shows them as taken, with no backdrop switch', (tester) async {
    await pump(tester, listing(cutFrames: false));
    expect(find.byKey(const Key('showcase-backdrop')), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    expect(base(tester), 'https://cdn/f0.jpg'); // not the cut-out's small copy
  });

  showcaseTest('the Photo button shows the photos as taken, and 360° brings the turn back', (tester) async {
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

  showcaseTest('price and the order button stay on screen while the shoe turns', (tester) async {
    await pump(tester, listing());
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('buy')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('total')).hitTestable(), findsOneWidget);
  });

  showcaseTest('without a size picked, the order button takes the buyer to the sizes', (tester) async {
    await pump(tester, listing());
    expect(find.text('Өлшем').hitTestable(), findsNothing);
    await tester.tap(find.byKey(const Key('buy')));
    await tester.pumpAndSettle();
    expect(find.text('Өлшем').hitTestable(), findsOneWidget);
  });

  showcaseTest('the details button skips the rest of the turn', (tester) async {
    await pump(tester, listing());
    expect(find.text('Nike Air Force 1').hitTestable(), findsNothing);
    await tester.tap(find.byKey(const Key('showcase-details')));
    await tester.pumpAndSettle();
    expect(find.text('Nike Air Force 1').hitTestable(), findsOneWidget);
  });

  showcaseTest('the stops are dots with no text beside the shoe, named for screen readers', (tester) async {
    await pump(tester, listing());
    final dots = find.byKey(const Key('showcase-step-sole'));
    expect(find.descendant(of: dots, matching: find.byType(Text)), findsNothing);
    expect(find.text('Табаны'), findsNothing);
    expect(tester.getSemantics(dots), isSemantics(label: 'Табаны', isButton: true, hasTapAction: true));
    expect(tester.getSize(dots), const Size(40, 48));
  });

  showcaseTest('on a narrow phone the stop being shown stays in view and the photos button never scrolls away',
      (tester) async {
    await pump(tester, listing(), size: const Size(320, 700));
    expect(find.byKey(const Key('showcase-photos')).hitTestable(), findsOneWidget);
    final travel = ScrollShowcase.travelFor(tester.getSize(find.byKey(const Key('showcase'))).height, 4);
    page(tester).jumpTo(travel - 1); // the last moment of the turn: the close-up
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('showcase-step-close')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('showcase-photos')).hitTestable(), findsOneWidget);
  });

  showcaseTest('in landscape the stops and buttons stay on screen', (tester) async {
    await pump(tester, listing(), size: const Size(844, 390));
    for (final k in ['showcase-step-spin', 'showcase-photos', 'showcase-details', 'showcase-backdrop']) {
      expect(find.byKey(Key(k)).hitTestable(), findsOneWidget, reason: k);
    }
  });

  showcaseTest('new photos after a reload are shown, not the old ones', (tester) async {
    final scroll = ScrollController();
    var body = listing();
    late StateSetter set;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
      set = setState;
      return ListView(controller: scroll, children: [
        ScrollShowcase(listing: Listing.fromJson(body), scroll: scroll, stageHeight: 600),
      ]);
    }))));
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/f0-s.webp');
    set(() => body = {
          ...listing(details: false),
          'media': [for (var i = 0; i < 8; i++) media('frame', 'n$i')],
        });
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/n0-s.webp');
    expect(find.byKey(const Key('showcase-step-sole')), findsNothing);
  });
}
