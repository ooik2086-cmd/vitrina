import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/colors.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/color_choice.dart';
import 'package:vitrina/widgets/common.dart';
import 'package:vitrina/widgets/scroll_showcase.dart';
import 'package:vitrina/widgets/spin_viewer.dart';
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

/// One continuous scan, as on the approved demo page: the turn is frames 0-7 (frame 8 is frame 0 again), then the
/// camera rises to the top (frame 12), goes under the sole (18) and in close (23). The stop photos are those frames.
Map<String, dynamic> scan({String? backdrop = 'dark'}) => {
      ...listing(backdrop: backdrop),
      'media': [
        for (final (angle, i) in [('outer', 0), ('top', 12), ('sole', 18), ('detail', 23)]) media(angle, 'f$i'),
        for (var i = 0; i < 24; i++) media('frame', i == 8 ? 'f0' : 'f$i'),
      ],
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
  // The server keeps or drops a turn's cut-outs per part (serializers.showcase_parts), so it must split the frames
  // as this page shows them. Both sides' tests read the same cases from contracts/.
  group('splits the frames as the server does', () {
    String name(MediaItem m) => m.originalUrl.split('/').last.replaceAll('.jpg', '');
    List<List<MediaItem>> parts(ShowcasePlan plan) => plan.scan
        ? [for (final s in plan.steps) s.media]
        : [if (plan.steps.first.media.isNotEmpty) plan.steps.first.media];

    test('in the shared cases', () {
      final cases = (jsonDecode(File('../contracts/showcase_parts.json').readAsStringSync()) as Map)['cases'] as List;
      expect(cases.length, greaterThan(5));
      for (final c in cases.cast<Map<String, dynamic>>()) {
        final plan = ShowcasePlan.of(Listing.fromJson({
          ...listing(),
          'media': [for (final m in (c['media'] as List).cast<List>()) media(m[0] as String, m[1] as String)],
          'cover_frame': c['cover_frame'] == null ? null : 'https://cdn/${c['cover_frame']}.jpg',
        }));
        final want = [for (final p in (c['parts'] as List).cast<List>()) p.cast<String>()];
        // A plain turn starts here at the cover's frame, within the turn; the server keeps the order taken.
        if (!plan.scan && want.isNotEmpty) {
          final (w, k) = (want.first, c['turn'] as int);
          final s = math.max(0, w.take(k).toList().indexOf((c['cover_frame'] as String?) ?? ''));
          want.first = [...w.sublist(s, k), ...w.take(s), ...w.skip(k)];
        }
        expect([for (final p in parts(plan)) p.map(name).toList()], want, reason: c['name'] as String);
        expect(plan.turn, c['turn'], reason: c['name'] as String);
      }
    });

    test('in the demo listings', () {
      final demo = jsonDecode(File('demo/api.json').readAsStringSync()) as Map<String, dynamic>;
      final want =
          (jsonDecode(File('../contracts/showcase_parts_demo.json').readAsStringSync()) as Map)['listings'] as Map;
      final keys = demo.keys.where((k) => RegExp(r'^GET /listings/\d+$').hasMatch(k)).toList();
      expect(keys..sort(), want.keys.toList()..sort());
      for (final k in keys) {
        final plan = ShowcasePlan.of(Listing.fromJson(demo[k] as Map<String, dynamic>));
        final p = parts(plan);
        final w = want[k] as Map;
        expect([for (final x in p) x.length], w['sizes'], reason: k);
        expect(plan.turn, w['turn'], reason: k);
        if (plan.scan) expect([for (final x in p) x.first.originalUrl], w['starts'], reason: k);
      }
    });
  });

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

    test('a turn carries to the same side only when both turns\' ways are known', () {
      Listing sided(Map<String, String> sides, {String? cover = 'https://cdn/f0.jpg'}) =>
          Listing.fromJson({...listing(), 'cover_frame': cover, 'angle_frames': sides});
      final here = sided({'front': 'https://cdn/f0.jpg', 'outer': 'https://cdn/f6.jpg'});
      // Two opposite sides fit either way round: the way is a guess, not known.
      expect(TurnMap({0: 0, 0.5: 0.5}).sided, isFalse);
      expect(TurnMap({0: 0, 0.25: 0.25}).sided, isTrue);
      const mid = (kind: 'spin', at: 9 / 24);
      // The other colour's way unknown: as before, the same frame when both start at the same side, else nothing.
      final opposite = sided({'front': 'https://cdn/f0.jpg', 'back': 'https://cdn/f12.jpg'});
      expect(ScrollShowcase.carry(mid, here, opposite), mid);
      expect(ScrollShowcase.carry(mid, here, sided(const {}, cover: null)), isNull);
      // A side matched a frame before the other turn's first stays at the start, not at the far end of the turn.
      final early = sided({'front': 'https://cdn/f23.jpg', 'outer': 'https://cdn/f5.jpg'});
      expect(ScrollShowcase.carry((kind: 'spin', at: 0.0), here, early), (kind: 'spin', at: 0.0));
      expect(ScrollShowcase.carry(mid, here, early), mid); // a frame apart all round: the same place
      // The same stop needs no turn at all.
      expect(ScrollShowcase.carry((kind: 'sole', at: 0.0), here, opposite), (kind: 'sole', at: 0.0));
    });

    test('the same view on another colour: the frame nearest the angle, or the same stop', () {
      final plan = ShowcasePlan.of(Listing.fromJson(listing()));
      final fewer = ShowcasePlan.of(Listing.fromJson({
        ...listing(details: false),
        'media': [media('outer', 'outer'), for (var i = 0; i < 12; i++) media('frame', 'f$i')],
      }));
      for (final (frame, other) in [(0, 0), (6, 3), (12, 6), (22, 11)]) {
        final view = plan.viewAt(plan.centreOf(0, frame))!;
        expect(view, (kind: 'spin', at: frame / 24));
        expect(plan.at(plan.progressFor(view)!), (step: 0, frame: frame)); // back again on the same turn
        expect(fewer.at(fewer.progressFor(view)!), (step: 0, frame: other));
      }
      // Twelve frames to twenty-four: each photo to the one taken at exactly its angle.
      for (final k in [0, 3, 11]) {
        expect(plan.at(plan.progressFor(fewer.viewAt(fewer.centreOf(0, k))!)!), (step: 0, frame: 2 * k));
      }
      final sole = plan.viewAt(plan.centreOf(2, 0))!;
      expect(sole, (kind: 'sole', at: 0.0));
      expect(plan.at(plan.progressFor(sole)!), (step: 2, frame: 0));
      expect(fewer.progressFor(sole), isNull); // no sole photo: the page opens at its cover
      final scanned = ShowcasePlan.of(Listing.fromJson(scan()));
      // A scan tells where it is too: on a stop, how far into its move to the next, which another scan shows the
      // same and a single photo as itself.
      expect(scanned.viewAt(scanned.centreOf(0, 3))!.kind, 'spin');
      final top = scanned.steps.indexWhere((s) => s.kind != 'spin');
      final stop = scanned.viewAt(scanned.centreOf(top, 2))!;
      expect(scanned.at(scanned.progressFor(stop)!), (step: top, frame: 2));
      expect(plan.at(plan.progressFor(stop)!), (step: plan.steps.indexWhere((s) => s.kind == 'top'), frame: 0));
      // Its turn starts wherever the camera did: without known sides it carries nowhere, even to itself.
      final scanListing = Listing.fromJson(scan());
      expect(ScrollShowcase.carry((kind: 'spin', at: 0.25), scanListing, scanListing), isNull);
      // With its sides known, a scan carries the side: here frame 3 of its turn (of 8, the move goes on to 12) is
      // a frame past the toe, which on the other scan is frame 7.
      Listing sidedScan(int outer, int front) => Listing.fromJson({
            ...scan(),
            'angle_frames': {'outer': 'https://cdn/f$outer.jpg', 'front': 'https://cdn/f$front.jpg'},
          });
      expect(ScrollShowcase.carry((kind: 'spin', at: 3 / 12), sidedScan(0, 2), sidedScan(4, 6)),
          (kind: 'spin', at: 7 / 12));
      // A photo turn near its end carried to a scan stays in the scan's turn, never on its rise over the top.
      final photos = Listing.fromJson({
        ...listing(),
        'cover_frame': 'https://cdn/f0.jpg',
        'angle_frames': {'outer': 'https://cdn/f22.jpg', 'front': 'https://cdn/f4.jpg'},
      });
      final toScan = ScrollShowcase.carry((kind: 'spin', at: 22 / 24), photos, sidedScan(0, 2))!;
      expect(scanned.at(scanned.progressFor(toScan)!), (step: 0, frame: 7)); // a frame from the outer side, f0
      // On the rise past its turn a scan is heading for the top: another scan opens at the same place on its rise,
      // photos at the side early on and at the top once well up. The frame where the turn comes round again is its
      // start.
      expect(ScrollShowcase.carry((kind: 'spin', at: 10 / 12), sidedScan(0, 2), sidedScan(4, 6)),
          (kind: 'spin', at: 10 / 12));
      expect(ScrollShowcase.carry((kind: 'spin', at: 11 / 12), sidedScan(0, 2), photos), (kind: 'top', at: 0.0));
      expect(ScrollShowcase.carry((kind: 'spin', at: 9 / 12), sidedScan(0, 2), photos)!.kind, 'spin');
      expect(
          ScrollShowcase.carry((kind: 'spin', at: 8 / 12), sidedScan(0, 2), sidedScan(0, 2)), (kind: 'spin', at: 0.0));
      // A scan without known sides does not even wait for the other colour.
      expect(ScrollShowcase.mayCarry((kind: 'spin', at: 0.25), scanListing), isFalse);
      expect(ScrollShowcase.mayCarry((kind: 'spin', at: 0.25), sidedScan(0, 2)), isTrue);
      expect(ScrollShowcase.mayCarry((kind: 'top', at: 0.0), scanListing), isTrue);
      // Turns compare only when both start at the frame matched to a cover of the same side.
      final a = Listing.fromJson({...listing(), 'cover_frame': 'https://cdn/f0.jpg'});
      expect(ScrollShowcase.turnsAlike(a, a), isTrue);
      expect(ScrollShowcase.turnsAlike(a, Listing.fromJson(listing())), isFalse); // not matched yet
      expect(ScrollShowcase.turnsAlike(a, Listing.fromJson({...listing(), 'cover_frame': 'https://cdn/gone.jpg'})),
          isFalse);
      final photosOnly = ShowcasePlan.of(Listing.fromJson({
        ...listing(details: false),
        'media': [media('outer', 'o')]
      }));
      expect(photosOnly.progressFor((kind: 'spin', at: 0.5)), isNull);
    });

    test('a scan stays a scan once its stop photos and frames are cut out apart', () {
      // The server cuts out the stop row and its frame row separately, under different keys.
      final cut = {
        ...scan(),
        'media': [
          for (final m in (scan()['media'] as List).cast<Map<String, dynamic>>())
            m['angle'] == 'frame' ? m : <String, dynamic>{...m, 'processed_url': '${m['processed_url']}?stop'},
        ],
      };
      final plan = ShowcasePlan.of(Listing.fromJson(cut));
      expect((plan.scan, plan.turn), (true, 8));
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

    test('a scan carries on from the turn to each view: every stop starts at its own frame, evenly paced', () {
      final plan = ShowcasePlan.of(Listing.fromJson(scan()));
      expect(plan.scan, isTrue);
      expect([for (final s in plan.steps) (s.kind, s.media.length)],
          [('spin', 12), ('top', 6), ('sole', 5), ('close', 1)]);
      for (final (step, frame) in [(1, 12), (2, 18), (3, 23)]) {
        expect(plan.steps[step].media.first.url, 'https://cdn/f$frame.webp');
      }
      // Each frame takes the same share of the scroll, and the whole is as long as a turn with three photo stops.
      expect(plan.total, closeTo(5, 1e-9));
      for (final s in plan.steps) {
        expect(s.weight / s.media.length, closeTo(5 / 24, 1e-9));
      }
      expect({for (var i = 0; i <= 1000; i++) plan.at(i / 1000)}.length, 24); // every frame shows, in order
      expect(plan.turn, 8); // where the first frame comes round again
    });

    test('stop photos that are not frames of the turn stay separate photos', () {
      expect(ShowcasePlan.of(Listing.fromJson(listing())).scan, isFalse);
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

  showcaseTest('photos without small copies are fetched only near the shoe, not all on arrival', (tester) async {
    final asked = <String>{};
    ScrollShowcaseState.screenSize = (url) {
      asked.add(url);
      return NetworkImage(url);
    };
    addTearDown(() => ScrollShowcaseState.screenSize = NetworkImage.new);
    final body = listing(cutFrames: false);
    for (final m in body['media'] as List) {
      (m as Map)['thumb_url'] = null;
      if (m['angle'] == 'frame') m['processed_url'] = null;
    }
    await pump(tester, body);
    Set<int> frames() => {
          for (final u in asked)
            if (RegExp(r'/f(\d+)\.jpg$').firstMatch(u) case final m?) int.parse(m.group(1)!)
        };
    // Of the 24 frames, those within three of the shoe as the first-show hint turns it a little and back, and
    // round the turn the last three, where a sideways drag goes from the first.
    expect(frames(), containsAll([0, 1, 2, 3, 21, 22, 23]));
    expect(frames().where((i) => i > 6 && i < 21), isEmpty);
    // Each stop's photo, where scrolling on or a stop button lands.
    for (final stop in ['top', 'sole', 'detail']) {
      expect(asked, contains('https://cdn/$stop.webp'));
    }
    // Turned on to about the middle, the frames around it come; still not the far ones.
    page(tester).jumpTo(page(tester).maxScrollExtent * 0.1);
    await tester.pump();
    final at = int.parse(RegExp(r'/f(\d+)\.jpg$').firstMatch(base(tester))!.group(1)!);
    expect(at, inInclusiveRange(7, 17));
    expect(frames(), containsAll([for (var i = at - 3; i <= at + 3; i++) i]));
    expect(frames().where((i) => i > at + 3 && i < 21), isEmpty);
  });

  showcaseTest('a stop button fetches where it lands, not every frame it passes', (tester) async {
    final asked = <String>{};
    ScrollShowcaseState.screenSize = (url) {
      asked.add(url);
      return NetworkImage(url);
    };
    addTearDown(() => ScrollShowcaseState.screenSize = NetworkImage.new);
    final body = listing(cutFrames: false);
    for (final m in body['media'] as List) {
      (m as Map)['thumb_url'] = null;
      if (m['angle'] == 'frame') m['processed_url'] = null;
    }
    await pump(tester, body);
    asked.clear();
    await tester.tap(find.byKey(const Key('showcase-step-close')));
    await tester.pumpAndSettle();
    final frames = {
      for (final u in asked)
        if (RegExp(r'/f(\d+)\.jpg$').firstMatch(u) case final m?) int.parse(m.group(1)!)
    };
    // The last frames, next to the stops in showing order, and the few the stage drew on the way; not the whole
    // turn the jump passed.
    expect(frames.where((i) => i < 21).length, lessThanOrEqualTo(3), reason: '$frames');
    expect(asked, contains('https://cdn/detail.webp'));
  });

  showcaseTest('cut-out small copies are not used for a turn shown as taken, and only near frames come',
      (tester) async {
    final asked = <String>{};
    ScrollShowcaseState.screenSize = (url) {
      asked.add(url);
      return NetworkImage(url);
    };
    addTearDown(() => ScrollShowcaseState.screenSize = NetworkImage.new);
    // Every other frame could not be cut out: the turn shows the photos as taken. The odd frames' small copies are
    // of those photos and fit; the even frames' are of their cut-outs and do not.
    await pump(tester, listing(cutFrames: false));
    final frames = {
      for (final u in asked)
        if (RegExp(r'/f(\d+)\.jpg$').firstMatch(u) case final m?) int.parse(m.group(1)!)
    };
    expect(frames, isNotEmpty);
    expect(frames.every((i) => i.isEven), isTrue, reason: '$frames');
    expect(frames.where((i) => i > 6 && i < 21), isEmpty);
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
    // Mid-flight: the cover is drawn in flight, on the way to the waiting listing page, with its shadow and no
    // backdrop of its own, so nothing flashes if the page opens on a dark stage.
    expect(find.byWidgetPredicate((w) => w is Image && w.fit == BoxFit.contain), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is ContactShadow && w.fit == BoxFit.contain), findsOneWidget);
    expect(
        find.byWidgetPredicate((w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient == studioGradient),
        findsOneWidget); // only the card left behind
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
    // Mid-flight: the cover is drawn in flight, on the way to the waiting listing page, with its shadow and no
    // backdrop of its own, so nothing flashes if the page opens on a dark stage.
    expect(find.byWidgetPredicate((w) => w is Image && w.fit == BoxFit.contain), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is ContactShadow && w.fit == BoxFit.contain), findsOneWidget);
    expect(
        find.byWidgetPredicate((w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient == studioGradient),
        findsOneWidget); // only the card left behind
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
    // The demo page's colours: a light shoe on its dark scene, in a soft light that does not zoom with the shoe.
    expect(deco().color, ShowcaseScene.dark.ink);
    final halo = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_Halo');
    expect(halo, findsOneWidget);
    expect(find.ancestor(of: halo, matching: find.byKey(const Key('showcase-zoom'))), findsNothing);
    await tester.tap(find.byKey(const Key('showcase-backdrop')));
    await tester.pump();
    expect(deco().color, ShowcaseScene.light.ink);
    expect(halo, findsOneWidget);
  });

  showcaseTest('the status bar icons read on the stage under them, until the page scrolls past it', (tester) async {
    await pump(tester, listing(backdrop: 'dark'));
    await tester.pump();
    SystemUiOverlayStyle? style() => tester.widget<AppBar>(find.byType(AppBar)).systemOverlayStyle;
    expect(style(), SystemUiOverlayStyle.light);
    await tester.tap(find.byKey(const Key('showcase-backdrop')));
    await tester.pump();
    expect(style(), SystemUiOverlayStyle.dark); // dark icons on the light scene, even in the app's dark theme
    await tester.tap(find.byKey(const Key('showcase-backdrop')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('showcase-details')));
    await tester.pumpAndSettle();
    // The details come up under the app bar, which still stands on the stage's last stretch: so do the icons.
    expect(style(), SystemUiOverlayStyle.light);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(style(), isNull); // the page's own canvas: the theme decides
  });

  showcaseTest('a stage step that changes between light and dark updates the status bar at once', (tester) async {
    // The turn's photos as taken stand on the light studio; the cut-out top on the listing's dark scene.
    await pump(tester, listing(backdrop: 'dark', cutFrames: false));
    await tester.pump();
    SystemUiOverlayStyle? style() => tester.widget<AppBar>(find.byType(AppBar)).systemOverlayStyle;
    expect(style(), SystemUiOverlayStyle.dark);
    await tester.tap(find.byKey(const Key('showcase-step-top')));
    await tester.pumpAndSettle();
    expect(style(), SystemUiOverlayStyle.light);
  });

  test('controls on a ground take whichever ink reads better on it', () {
    expect(darkerScene(const Color(0xFF000000)), isTrue);
    expect(darkerScene(const Color(0xFF3A3A3A)), isTrue);
    expect(darkerScene(const Color(0xFF808080)), isFalse); // mid grey: dark ink reads better than light
    expect(darkerScene(const Color(0xFFFFFFFF)), isFalse);
  });

  showcaseTest('a dark scan\'s Photo tab keeps light status bar icons and page dots over its photos', (tester) async {
    // As the demo's scan: each photo is itself cut out, so the one file is both original and cut-out.
    final body = scan();
    for (final m in body['media'] as List) {
      m['processed_url'] = m['original_url'];
    }
    await pump(tester, body);
    await tester.tap(find.byKey(const Key('showcase-photos')));
    await tester.pumpAndSettle();
    SystemUiOverlayStyle? style() => tester.widget<AppBar>(find.byType(AppBar)).systemOverlayStyle;
    expect(style(), SystemUiOverlayStyle.light);
    expect(tester.widget<PhotoGallery>(find.byType(PhotoGallery)).dark, isTrue);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(style(), isNull); // past the photos: the page's own canvas
  });

  test('the stage behind photos as taken is the colour around their edge', () {
    // 10 × 10, a light grey frame two pixels wide around a black middle.
    final px = ByteData(10 * 10 * 4);
    for (var y = 0; y < 10; y++) {
      for (var x = 0; x < 10; x++) {
        final edge = x < 2 || y < 2 || x > 7 || y > 7;
        for (var c = 0; c < 3; c++) {
          px.setUint8((y * 10 + x) * 4 + c, edge ? 0xE6 : 0);
        }
        px.setUint8((y * 10 + x) * 4 + 3, 255);
      }
    }
    expect(edgeColour(px, 10, 10), const Color(0xFFE6E6E6));
  });

  showcaseTest('a scan is drawn edge to edge, its frames having their own margin', (tester) async {
    await pump(tester, scan());
    expect(
        find
            .ancestor(of: find.byKey(const ValueKey('showcase-base')), matching: find.byType(Padding))
            .evaluate()
            .where((e) => (e.widget as Padding).padding == const EdgeInsets.all(20)),
        isEmpty);
    await pump(tester, listing());
    expect(
        find
            .ancestor(of: find.byKey(const ValueKey('showcase-base')), matching: find.byType(Padding))
            .evaluate()
            .where((e) => (e.widget as Padding).padding == const EdgeInsets.all(20)),
        isNotEmpty);
  });

  showcaseTest('a seller\'s cut-out turns on its own shadow on a light stage; a scan brings its own', (tester) async {
    for (final (body, shadows) in [
      (listing(), 1),
      (listing(backdrop: 'dark'), 0), // a shadow would not show
      ({...listing(backdrop: null), 'showcase_style': 'premium'}, 0),
      ({...listing(backdrop: null), 'showcase_style': 'dynamic'}, 1),
      (scan(backdrop: 'light'), 0), // the scan's frames have their floor shadow in them
    ]) {
      await pump(tester, body);
      expect(find.byType(ContactShadow), findsNWidgets(shadows), reason: '$body');
    }
    await pump(tester, listing());
    await tester.tap(find.byKey(const Key('showcase-step-sole')));
    await tester.pumpAndSettle();
    expect(find.byType(ContactShadow), findsNothing); // the sole stands on nothing
    expect(showcaseBackground('clean').gradient, studioGradient);
  });

  Map<String, dynamic> colorway(int id, String color, {bool current = false, bool inStock = true}) => {
        'id': id,
        'color': color,
        'price_tiyn': 4500000,
        'current': current,
        'in_stock': inStock,
        'thumb_url': 'https://cdn/c$id-s.webp',
        'cutout': true,
      };

  final colours = [colorway(9, 'ақ', inStock: false), colorway(8, 'көк'), colorway(7, 'қара', current: true)];

  /// The listing opened from another page, so leaving it shows where the buyer came from.
  /// Returns the paths asked for; the other colours (8 and 9) answer after [otherColour], with [other] if given.
  Future<List<String>> pumpOpened(WidgetTester tester, Map<String, dynamic> body,
      {Duration otherColour = Duration.zero, Map<String, dynamic>? other}) async {
    final asked = <String>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          asked.add(req.url.path);
          final otherOne = RegExp(r'/listings/[89]$').hasMatch(req.url.path);
          if (otherOne) await Future<void>.delayed(otherColour);
          return jsonResponse(req.url.path.endsWith('/similar') ? {'items': []} : (otherOne ? other ?? body : body));
        }));
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: MaterialApp(
            home: Builder(
                builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const ListingScreen(listingId: 7))),
                    child: const Text('catalog'))))));
    await tester.tap(find.text('catalog'));
    await tester.pumpAndSettle();
    return asked;
  }

  showcaseTest('the other colours sit beside the turning shoe, and one tap opens that colour in place', (tester) async {
    await pumpOpened(tester, {...listing(), 'colors': colours});
    final stage = find.byKey(const Key('showcase'));
    expect(find.descendant(of: stage, matching: find.byType(ColorSwatches)), findsOneWidget);
    expect(find.descendant(of: stage, matching: find.text('қара')), findsNothing); // no words beside the shoe
    final soldOut = tester.getSemantics(find.byKey(const Key('color-9')));
    expect(soldOut.label, allOf(startsWith('ақ, '), contains('45'), endsWith('өлшемдері таусылған')));
    expect(find.byKey(const Key('color-sold-out-9')), findsOneWidget); // struck through, not only faded
    expect(find.byKey(const Key('color-sold-out-8')), findsNothing);
    final current = tester.getSemantics(find.byKey(const Key('color-7')));
    expect(current.flagsCollection.isSelected, ui.Tristate.isTrue);
    // A screen reader can open a colour too, not only a finger.
    expect(tester.getSemantics(find.byKey(const Key('color-8'))).getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue);
    // The ring is the stage's ink, whatever the phone's theme.
    BoxDecoration ring(int id) =>
        tester.widget<Container>(find.byKey(Key('color-ring-$id'))).decoration as BoxDecoration;
    expect((ring(7).border as Border).top.color, ShowcaseScene.light.fg);
    expect((ring(8).border as Border).top.color, ShowcaseScene.light.line);
    await tester.tap(find.descendant(of: stage, matching: find.byKey(const Key('color-8'))));
    await tester.pumpAndSettle();
    final opened = tester.widget<ListingScreen>(find.byType(ListingScreen));
    expect((opened.listingId, opened.atDetails), (8, false));
    // In place of the black one: back leads to where the buyer came from.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(ListingScreen), findsNothing);
    expect(find.text('catalog'), findsOneWidget);
  });

  // Both colours' turns start at the frame matched to their front cover.
  final anchored = {...listing(), 'cover_frame': 'https://cdn/f0.jpg', 'colors': colours};
  final plan = ShowcasePlan.of(Listing.fromJson(anchored));
  Future<void> turnTo(WidgetTester tester, int step, int frame) async {
    final stage = tester.getSize(find.byType(Scrollable).first).height;
    page(tester).jumpTo(plan.centreOf(step, frame) * ScrollShowcase.travelFor(stage, plan.steps.length));
    await tester.pumpAndSettle();
  }

  Finder swatch(int id) =>
      find.descendant(of: find.byKey(const Key('showcase')), matching: find.byKey(Key('color-$id')));
  Finder screen(int id) => find.byWidgetPredicate((w) => w is ListingScreen && w.listingId == id);
  String shownOn(WidgetTester tester, int id) => urlOf(tester
      .widget<Image>(find.descendant(of: screen(id), matching: find.byKey(const ValueKey('showcase-base'))))
      .image);

  showcaseTest('a colour picked mid-turn fades in at the same angle, already loaded', (tester) async {
    final asked = await pumpOpened(tester, anchored, other: {...anchored, 'id': 8});
    await turnTo(tester, 0, 9);
    expect(base(tester), 'https://cdn/f9-s.webp');
    SemanticsNode heard() => tester.getSemantics(find.ancestor(of: swatch(8), matching: find.byType(Semantics)).first);
    final before = heard();
    expect((before.label, before.flagsCollection.isLiveRegion),
        (ColorSwatches.describe(Colorway.fromJson(colours[1])), false));
    await tester.tap(swatch(8));
    await tester.pump();
    expect(find.byKey(const Key('color-coming-8')), findsOneWidget); // the tap shows at once
    // and is heard at once, on the same node the reader is on: the wait is not silent to a screen reader.
    final coming = heard();
    expect((coming.id, coming.label, coming.flagsCollection.isLiveRegion),
        (before.id, '${colorName(Colorway.fromJson(colours[1]).color)}: ашылуда', true));
    expect((tester.widget<Container>(find.byKey(const Key('color-ring-8'))).decoration as BoxDecoration).border,
        Border.all(color: ShowcaseScene.light.fg, width: 2));
    for (var i = 0; i < 5 && screen(8).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    // Its very first frame: the same frame of the other turn, with no cover or spinner first.
    expect(shownOn(tester, 8), 'https://cdn/f9-s.webp');
    expect(find.descendant(of: screen(8), matching: find.byType(CircularProgressIndicator)), findsNothing);
    final opened = tester.widget<ListingScreen>(screen(8));
    expect((opened.view, opened.listing?.id, opened.pending), ((kind: 'spin', at: 9 / 24), 8, null));
    await tester.pumpAndSettle();
    expect(shownOn(tester, 8), 'https://cdn/f9-s.webp');
    expect(asked.where((p) => p.endsWith('/listings/8')).length, 1);
  });

  showcaseTest('on the sole the other colour opens on its sole', (tester) async {
    await pumpOpened(tester, anchored, other: {...anchored, 'id': 8});
    await turnTo(tester, 2, 0);
    await tester.tap(swatch(8));
    await tester.pumpAndSettle();
    expect(tester.widget<ListingScreen>(screen(8)).view, (kind: 'sole', at: 0.0));
    expect(base(tester), 'https://cdn/sole-s.webp');
  });

  showcaseTest('a turn that may start at another angle opens at its cover', (tester) async {
    // The other colour's cover is its back: the same place in its turn is the other side of the shoe.
    final other = {
      ...anchored,
      'id': 8,
      'media': [
        media('back', 'back'),
        for (final m in anchored['media'] as List)
          if (m['angle'] != 'back') m
      ],
    };
    await pumpOpened(tester, anchored, other: other);
    await turnTo(tester, 0, 9);
    await tester.tap(swatch(8));
    await tester.pumpAndSettle();
    final opened = tester.widget<ListingScreen>(screen(8));
    expect((opened.view, opened.listing != null), (null, true));
    expect(page(tester).pixels, 0);
  });

  showcaseTest('with its sides matched, a turn started from another side opens at the same side, already loaded',
      (tester) async {
    // This colour turns from its toe towards its outer side; the other starts at its heel and turns the same way
    // round the shoe, so the angle shown here (between heel and outer side) is near the end of its turn.
    final here = {
      ...anchored,
      'angle_frames': {'front': 'https://cdn/f0.jpg', 'outer': 'https://cdn/f6.jpg'},
    };
    final other = {
      ...here,
      'id': 8,
      'media': [
        media('back', 'back'),
        for (final m in anchored['media'] as List)
          if (m['angle'] != 'back') m
      ],
      'angle_frames': {'front': 'https://cdn/f12.jpg', 'outer': 'https://cdn/f18.jpg'},
    };
    await pumpOpened(tester, here, other: other);
    await turnTo(tester, 0, 9);
    await tester.tap(swatch(8));
    for (var i = 0; i < 5 && screen(8).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(shownOn(tester, 8), 'https://cdn/f21-s.webp'); // its very first frame, fetched ahead
    await tester.pumpAndSettle();
    expect(tester.widget<ListingScreen>(screen(8)).view, (kind: 'spin', at: 21 / 24));
    expect(shownOn(tester, 8), 'https://cdn/f21-s.webp');
  });

  showcaseTest('a colour picked before turning opens at its cover, as before', (tester) async {
    await pumpOpened(tester, anchored);
    await tester.tap(swatch(8));
    await tester.pumpAndSettle();
    final opened = tester.widget<ListingScreen>(screen(8));
    expect((opened.view, opened.listing, opened.pending), (null, null, null));
    expect(page(tester).pixels, 0);
  });

  showcaseTest('on a slow network the colour opens at its cover soon, with the one request', (tester) async {
    final asked = await pumpOpened(tester, anchored, otherColour: const Duration(seconds: 3));
    await turnTo(tester, 0, 15);
    await tester.tap(swatch(8));
    await tester.pump(ListingScreen.switchBudget);
    await tester.pump(const Duration(milliseconds: 300));
    final opened = tester.widget<ListingScreen>(screen(8));
    expect((opened.view, opened.listing, opened.pending != null), (null, null, true));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(page(tester).pixels, 0); // no jump once it arrives
    expect(asked.where((p) => p.endsWith('/listings/8')).length, 1);
  });

  showcaseTest('the latest colour picked opens; back while waiting cancels the switch', (tester) async {
    await pumpOpened(tester, anchored, otherColour: const Duration(milliseconds: 400));
    await turnTo(tester, 0, 9);
    await tester.tap(swatch(8));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(swatch(9));
    await tester.pump();
    // Only the colour now on its way is heard as opening.
    bool live(int id) => tester
        .getSemantics(find.ancestor(of: swatch(id), matching: find.byType(Semantics)).first)
        .flagsCollection
        .isLiveRegion;
    expect((live(8), live(9)), (false, true));
    await tester.pumpAndSettle();
    expect(screen(8), findsNothing);
    expect(screen(9), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('catalog'), findsOneWidget); // in place of the first colour: back leads where it came from

    await tester.tap(find.text('catalog'));
    await tester.pumpAndSettle();
    await turnTo(tester, 0, 9);
    await tester.tap(swatch(8));
    await tester.pump(const Duration(milliseconds: 100));
    tester.state<NavigatorState>(find.byType(Navigator)).pop(); // back, while the other colour is on its way
    await tester.pumpAndSettle();
    expect(find.byType(ListingScreen), findsNothing);
    expect(find.text('catalog'), findsOneWidget);
  });

  showcaseTest('a colour picked under the title opens at the title, with the size the buyer picked', (tester) async {
    await pumpOpened(tester, {...listing(), 'colors': colours});
    await tester.tap(find.byKey(const Key('showcase-details')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('42').first);
    await tester.pump();
    final under = find.byType(ColorChoice);
    expect(find.descendant(of: under, matching: find.byType(ColorSwatches)), findsOneWidget);
    await tester.tap(find.descendant(of: under, matching: find.byKey(const Key('color-8'))));
    await tester.pumpAndSettle();
    final opened = tester.widget<ListingScreen>(find.byType(ListingScreen));
    expect((opened.listingId, opened.sizeLabel, opened.atDetails), (8, '42', true));
    expect(page(tester).pixels, greaterThan(800)); // past the showcase, not back at its first frame
    expect(find.byKey(const Key('color-name')).hitTestable(), findsOneWidget);
  });

  showcaseTest('the colour is named under the title, with no swatches when there is only one', (tester) async {
    await pump(tester, listing());
    expect(find.byType(ColorSwatches), findsNothing);
    await tester.tap(find.byKey(const Key('showcase-details')));
    await tester.pumpAndSettle();
    expect(find.byType(ColorSwatches), findsNothing);
    final name = tester.widget<Text>(find.byKey(const Key('color-name')));
    expect(name.textSpan!.toPlainText(), 'Түсі: қара');
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
    final card = tester.widget<Container>(find.ancestor(of: find.byType(Hero), matching: find.byType(Container)).first);
    expect((card.decoration as BoxDecoration).gradient, studioGradient); // the card stays; only the shoe flies
    final shadow = tester.widget<ContactShadow>(find.byType(ContactShadow));
    final photo = tester.widget<Image>(find.descendant(of: find.byType(Hero), matching: find.byType(Image)));
    expect(shadow.image, photo.image); // one decoded copy for both
    final layers = tester.widget<Stack>(find.descendant(of: find.byType(CoverPhoto), matching: find.byType(Stack)));
    expect([for (final w in layers.children) w.runtimeType], [ContactShadow, Image]); // under the photo
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

  showcaseTest('the stops sit on a line with no text beside the shoe, named for screen readers', (tester) async {
    await pump(tester, listing());
    final dots = find.byKey(const Key('showcase-step-sole'));
    expect(find.descendant(of: dots, matching: find.byType(Text)), findsNothing);
    expect(find.text('Табаны'), findsNothing);
    expect(tester.getSemantics(dots), isSemantics(label: 'Табаны', isButton: true, hasTapAction: true));
    expect(tester.getSize(dots), const Size(48, 48));
    // Reached stops light up as the line fills.
    BoxDecoration tick(String kind) => tester
        .widget<AnimatedContainer>(
            find.descendant(of: find.byKey(Key('showcase-step-$kind')), matching: find.byType(AnimatedContainer)))
        .decoration! as BoxDecoration;
    expect(tick('spin').color, ShowcaseScene.light.glow);
    expect(tick('sole').color, ShowcaseScene.light.ink);
    await tester.tap(dots);
    await tester.pumpAndSettle();
    expect(tick('sole').color, ShowcaseScene.light.glow);
    expect(tick('close').color, ShowcaseScene.light.ink);
  });

  for (final (name, body) in [('photos', listing()), ('a scan', scan())]) {
    showcaseTest('with $name the line reaches each stop just as its view comes up', (tester) async {
      await pump(tester, body);
      final line = find.byKey(const Key('showcase-line-fill'));
      for (final kind in ['top', 'sole', 'close']) {
        await tester.tap(find.byKey(Key('showcase-step-$kind')));
        await tester.pumpAndSettle();
        final stop = tester.getCenter(find.byKey(Key('showcase-step-$kind')));
        final end = tester.getTopRight(line).dx;
        expect(end, closeTo(stop.dx, 1), reason: kind);
      }
    });
  }

  showcaseTest('on a scan a sideways drag goes round within the turn, never up over the shoe', (tester) async {
    await pump(tester, scan());
    // Frame 0 dragged back goes round to the last frame of the turn, not on to the top view.
    await tester.drag(find.byKey(const Key('showcase')), const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(base(tester), 'https://cdn/f7-s.webp');
    expect(ShowcasePlan.of(Listing.fromJson(listing())).turn, 24); // photos: the whole turn
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
