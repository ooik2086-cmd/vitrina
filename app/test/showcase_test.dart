import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/common.dart';
import 'package:vitrina/widgets/scroll_showcase.dart';
import 'package:vitrina/widgets/studio.dart';

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

  showcaseTest('a screen reader\'s focus boxes move with the stage between frames', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, listing());
    Rect onScreen(SemanticsNode node) {
      var rect = node.rect;
      for (SemanticsNode? n = node; n != null; n = n.parent) {
        if (n.transform != null) rect = MatrixUtils.transformRect(n.transform!, rect);
      }
      return rect;
    }

    final dot = find.byKey(const Key('showcase-step-sole'));
    page(tester).jumpTo(200);
    await tester.pumpAndSettle();
    page(tester).jumpTo(204); // same frame: nothing is rebuilt
    await tester.pump();
    expect(onScreen(tester.getSemantics(dot)).top, moreOrLessEquals(tester.getRect(dot).top, epsilon: 0.5));
    semantics.dispose();
  });

  showcaseTest('the catalog card\'s photo flies in while the listing loads', (tester) async {
    final card = Listing.fromJson(listing());
    final loaded = Completer<http.Response>();
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient(
            (req) => req.url.path.endsWith('/similar') ? Future.value(jsonResponse({'items': []})) : loaded.future));
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child:
            MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 180, child: ListingTile(listing: card)))))));
    await tester.tap(find.byType(Hero));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-flight: the cover is drawn in flight, on the way to the waiting listing page.
    expect(find.byWidgetPredicate((w) => w is Image && w.fit == BoxFit.contain), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    loaded.complete(jsonResponse(listing()));
    await tester.pumpAndSettle();
    expect(find.byType(ScrollShowcase), findsOneWidget);
  });

  showcaseTest('a zoomed photo does not fly back into the card', (tester) async {
    await pump(tester, listing());
    bool flies() =>
        tester.widget<HeroMode>(find.ancestor(of: find.byType(Hero), matching: find.byType(HeroMode)).first).enabled;
    expect(flies(), isTrue);
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    expect(flies(), isFalse);
  });

  showcaseTest('one ordinary swipe turns the shoe once round, and a short one moves one stop', (tester) async {
    await pump(tester, listing());
    final stage = tester.getSize(find.byKey(const Key('showcase'))).height;
    final list = find.byType(Scrollable).first;
    await tester.dragFrom(const Offset(200, 600), Offset(0, -stage * 0.6 + 2)); // a drag, no fling
    await tester.pump(const Duration(milliseconds: 200));
    // Nearly the whole turn (the first few pixels of a drag only decide it is a drag), and not past it.
    expect(int.parse(RegExp(r'f(\d+)-s').firstMatch(base(tester))!.group(1)!), greaterThanOrEqualTo(21));
    await tester.drag(list, Offset(0, -stage * 0.3));
    await tester.pump(const Duration(milliseconds: 200));
    expect(base(tester), 'https://cdn/top-s.webp');
  });

  showcaseTest('the full photo waits for the finger to lift, or for a long look', (tester) async {
    await pump(tester, listing());
    final finger = await tester.startGesture(tester.getCenter(find.byKey(const Key('showcase'))));
    await finger.moveBy(const Offset(0, -40));
    await finger.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 300)); // a short pause mid-drag: no decoding
    expect(full(tester), isEmpty);
    await tester.pump(const Duration(milliseconds: 200)); // holding still to look closely
    expect(full(tester), hasLength(1));
    await finger.moveBy(const Offset(0, -60)); // turning on
    await tester.pump();
    expect(full(tester), isEmpty);
    await finger.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(full(tester), hasLength(1));
  });

  showcaseTest('without small copies the photo is drawn once, not twice', (tester) async {
    final body = listing(cutFrames: false);
    for (final m in body['media'] as List) {
      (m as Map)['thumb_url'] = null;
      if (m['angle'] == 'frame') m['processed_url'] = null;
    }
    await pump(tester, body);
    await tester.pump(const Duration(milliseconds: 200));
    // The base is already the photo at screen size; a full layer with the same cache entry would also be dropped
    // from memory with it once the shoe moves on.
    expect(full(tester), isEmpty);
    expect(base(tester), 'https://cdn/f0.jpg');
  });

  showcaseTest('a screen reader\'s focus boxes move with the stage between frames', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, listing());
    Rect onScreen(SemanticsNode node) {
      var rect = node.rect;
      for (SemanticsNode? n = node; n != null; n = n.parent) {
        if (n.transform != null) rect = MatrixUtils.transformRect(n.transform!, rect);
      }
      return rect;
    }

    final dot = find.byKey(const Key('showcase-step-sole'));
    page(tester).jumpTo(200);
    await tester.pumpAndSettle();
    page(tester).jumpTo(204); // same frame: nothing is rebuilt
    await tester.pump();
    expect(onScreen(tester.getSemantics(dot)).top, moreOrLessEquals(tester.getRect(dot).top, epsilon: 0.5));
    semantics.dispose();
  });

  showcaseTest('the catalog card\'s photo flies in while the listing loads', (tester) async {
    final card = Listing.fromJson(listing());
    final loaded = Completer<http.Response>();
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient(
            (req) => req.url.path.endsWith('/similar') ? Future.value(jsonResponse({'items': []})) : loaded.future));
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child:
            MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 180, child: ListingTile(listing: card)))))));
    await tester.tap(find.byType(Hero));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-flight: the cover is drawn in flight, on the way to the waiting listing page.
    expect(find.byWidgetPredicate((w) => w is Image && w.fit == BoxFit.contain), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    loaded.complete(jsonResponse(listing()));
    await tester.pumpAndSettle();
    expect(find.byType(ScrollShowcase), findsOneWidget);
  });

  showcaseTest('a zoomed photo does not fly back into the card', (tester) async {
    await pump(tester, listing());
    bool flies() =>
        tester.widget<HeroMode>(find.ancestor(of: find.byType(Hero), matching: find.byType(HeroMode)).first).enabled;
    expect(flies(), isTrue);
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    expect(flies(), isFalse);
  });

  showcaseTest('one ordinary swipe turns the shoe once round', (tester) async {
    await pump(tester, listing());
    final stage = tester.getSize(find.byKey(const Key('showcase'))).height;
    final plan = ShowcasePlan.of(Listing.fromJson(listing()));
    final turn = plan.startOf(1) * ScrollShowcase.travelFor(stage, plan.steps.length);
    expect(turn, moreOrLessEquals(stage * 0.6, epsilon: 1));
  });

  showcaseTest('the full photo waits until the finger is lifted', (tester) async {
    await pump(tester, listing());
    final finger = await tester.startGesture(tester.getCenter(find.byKey(const Key('showcase'))));
    await finger.moveBy(const Offset(0, -40));
    await finger.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 400)); // the finger rests mid-drag
    expect(full(tester), isEmpty);
    await finger.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(full(tester), hasLength(1));
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
    expect(deco().gradient, isNot(studioGradient));
    await tester.tap(find.byKey(const Key('showcase-backdrop')));
    await tester.pump();
    expect(deco().gradient, studioGradient);
  });

  showcaseTest('a cut-out stands on the studio floor with its shadow; on the dark backdrop there is none',
      (tester) async {
    await pump(tester, listing());
    final shadow = tester.widget<ContactShadow>(find.byType(ContactShadow));
    expect(urlOf(shadow.image), base(tester)); // made from the copy already on screen, not a second download
    expect(shadow.fit, BoxFit.contain);
    await tester.tap(find.byKey(const Key('showcase-backdrop')));
    await tester.pump();
    expect(find.byType(ContactShadow), findsNothing);
  });

  showcaseTest('photos as taken have their own floor and get no shadow', (tester) async {
    await pump(tester, listing(cutFrames: false));
    expect(find.byType(ContactShadow), findsNothing);
  });

  testWidgets('a catalog card shows a cut-out on the studio backdrop with its shadow, a plain photo without',
      (tester) async {
    Future<void> show(Map<String, dynamic> json) => tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 220, height: 400, child: ListingTile(listing: Listing.fromJson(json))))));
    await show(listing());
    final card =
        tester.widget<Container>(find.descendant(of: find.byType(Hero), matching: find.byType(Container)).first);
    expect((card.decoration as BoxDecoration).gradient, studioGradient);
    final shadow = tester.widget<ContactShadow>(find.byType(ContactShadow));
    final photo = tester.widget<Image>(find.descendant(of: find.byType(Hero), matching: find.byType(Image)));
    expect(shadow.image, photo.image); // one decoded copy for both
    await show({
      ...listing(),
      'media': [media('front', 'front', cut: false)]
    });
    expect(find.byType(ContactShadow), findsNothing);
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
