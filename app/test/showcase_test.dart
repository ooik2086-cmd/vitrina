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
import 'package:vitrina/net_image.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/colors.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';
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

/// A one-pixel picture: the small copies the stage asks for in these tests, each address its own.
final _pixel = [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, //
  137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 144, 239, 63, 254, 31, 0, 4, 187, 2, 117, 232, 219, 201, 232, 0, //
  0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

/// The test binding answers every image request with HTTP 400. A photo that fails after the stage has already moved
/// on to the next frame has nobody left to show its error, so Flutter logs it; that is expected here, not a fault.
/// The small copies come from memory instead and stay on their way (nothing here decodes them), as on a slow
/// connection: a copy that failed is drawn as its own photo, which the tests of failed copies check by themselves.
void showcaseTest(String description, WidgetTesterCallback body) => testWidgets(description, (tester) async {
      final report = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.exception is! NetworkImageLoadException) report?.call(d);
      };
      final bytes = <String, Uint8List>{};
      ScrollShowcaseState.smallSource = (url) => MemoryImage(bytes.putIfAbsent(url, () => Uint8List.fromList(_pixel)));
      try {
        await body(tester);
      } finally {
        FlutterError.onError = report;
        ScrollShowcaseState.smallSource = netImage;
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

    test('the turn\'s end has its own mark on the stop line when frames carry on past it, as on the demo page', () {
      // Frame 8 is frame 0 again, on a line that runs to frame 23 (the close-up).
      expect(ShowcasePlan.of(Listing.fromJson(scan())).turnEnd, closeTo(8 / 23, 1e-9));
      expect(ShowcasePlan.of(Listing.fromJson(listing())).turnEnd, isNull); // the turn is all the first step shows
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
  // What the stage draws underneath (the small copy its painter draws, or the photo itself) and, at rest, on top
  // (full photo).
  String base(WidgetTester tester) {
    final w = tester.widget(find.byKey(const ValueKey('showcase-base')));
    return w is Image ? urlOf(w.image) : tester.state<ScrollShowcaseState>(find.byType(ScrollShowcase)).drawnSmall!;
  }

  Iterable<String> full(WidgetTester tester) => tester
      .widgetList<Image>(find.byWidgetPredicate(
          (w) => w is Image && w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('showcase-full-')))
      .map((i) => urlOf(i.image));

  /// Lets the stage glide after the page and come to rest, frame by frame as a phone draws them.
  Future<void> rest(WidgetTester tester, {int ms = 1200}) async {
    for (var t = 0; t < ms; t += 16) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  ScrollPosition page(WidgetTester tester) => tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  /// A point on the stage off the shoe, beside its buttons, where up and down scrolls the page.
  Offset edge(WidgetTester tester) => Offset(4, tester.getCenter(find.byKey(const Key('showcase-photos'))).dy);
  Matrix4 zoom(WidgetTester tester) => tester.widget<Transform>(find.byKey(const Key('showcase-zoom'))).transform;

  showcaseTest('scrolling turns the shoe while the stage stays in place, and back turns it back', (tester) async {
    await pump(tester, listing());
    expect(page(tester).pixels, 0); // the first-show hint turned it a little and back
    expect(base(tester), 'https://cdn/f0-s.webp');
    await tester.dragFrom(edge(tester), const Offset(0, -300)); // off the shoe: the page itself
    await tester.pump();
    // While moving: only the small copy, and the stage still fills the screen from the top.
    expect(base(tester), isNot('https://cdn/f0-s.webp'));
    expect(base(tester), endsWith('-s.webp'));
    expect(full(tester), isEmpty);
    expect(tester.getTopLeft(find.byKey(const Key('showcase'))).dy, 0);
    expect(tester.getSize(find.byKey(const Key('showcase'))).height,
        800 - tester.getSize(find.byKey(const Key('buy'))).height - 24 - 1);
    await rest(tester);
    // At rest the full cut-out is laid over the small copy, which stays underneath until it has loaded.
    expect(full(tester).single, base(tester).replaceAll('-s.webp', '.webp'));
    expect(find.byKey(const ValueKey('showcase-base')), findsOneWidget);
    await tester.dragFrom(edge(tester), const Offset(0, 300));
    await rest(tester);
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
    addTearDown(() => ScrollShowcaseState.screenSize = netImage);
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
    addTearDown(() => ScrollShowcaseState.screenSize = netImage);
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
    addTearDown(() => ScrollShowcaseState.screenSize = netImage);
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
    await rest(tester);
    // Nearly the whole turn (the first few pixels of a drag only decide it is a drag), and not past it.
    expect(int.parse(RegExp(r'f(\d+)-s').firstMatch(base(tester))!.group(1)!), greaterThanOrEqualTo(21));
    await tester.drag(list, Offset(0, -stage * 0.3));
    await rest(tester);
    expect(base(tester), 'https://cdn/top-s.webp');
  });

  showcaseTest('the full photo comes 160 ms after the shoe stops on a frame, and goes while it moves', (tester) async {
    await pump(tester, listing());
    final finger = await tester.startGesture(tester.getCenter(find.byKey(const Key('showcase'))));
    await finger.moveBy(const Offset(-40, 0));
    await finger.moveBy(const Offset(-60, 0));
    await rest(tester, ms: 600); // the shoe glides after the finger, then holds still under it
    expect(full(tester), hasLength(1));
    await finger.moveBy(const Offset(-60, 0)); // turning on
    await tester.pump(const Duration(milliseconds: 16));
    expect(full(tester), isEmpty); // only the small copies while it moves
    await finger.up();
    // Not before the last frame change is 160 ms old.
    var since = 0;
    for (var i = 0; i < 200 && full(tester).isEmpty; i++) {
      final before = base(tester);
      await tester.pump(const Duration(milliseconds: 16));
      since = base(tester) == before ? since + 16 : 0;
      expect(since, lessThan(160 + 32));
    }
    expect(full(tester), hasLength(1));
    expect(since, greaterThanOrEqualTo(160 - 16));
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

  showcaseTest('a tilted shoe gets its full photo once it holds still, finger down or not', (tester) async {
    await pump(tester, listing());
    final finger = await tester.startGesture(tester.getCenter(find.byKey(const Key('showcase'))));
    await finger.moveBy(const Offset(0, -40));
    await finger.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 100));
    expect(full(tester), isEmpty);
    await tester.pump(const Duration(milliseconds: 100)); // the finger rests: 160 ms after the last change
    expect(full(tester), hasLength(1));
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

  showcaseTest('a pinch started while one finger tilts the shoe zooms, and the page stays put', (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    final a = await tester.startGesture(at, pointer: 1);
    for (var i = 0; i < 5; i++) {
      await a.moveBy(const Offset(0, -20)); // the first finger is tilting the shoe
      await tester.pump();
    }
    final scrolled = page(tester).pixels;
    expect(scrolled, 0);
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
    await tester.dragFrom(edge(tester), const Offset(0, -200));
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

  showcaseTest('a sideways flick keeps the shoe turning and slows it to a stop, within the turn', (tester) async {
    await pump(tester, listing());
    final stage = find.byKey(const Key('showcase'));
    // A fast swipe of a third of the width: dragged alone it moves a few frames; the fling carries it on.
    await tester.fling(stage, const Offset(-120, 0), 2400);
    await tester.pump(const Duration(milliseconds: 100));
    final early = page(tester).pixels;
    expect(early, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(page(tester).pixels, isNot(early)); // still turning after the finger left
    await tester.pumpAndSettle();
    final rest = page(tester).pixels;
    final travel = ScrollShowcase.travelFor(tester.getSize(stage).height, 4);
    expect(rest, lessThan(ShowcasePlan.of(Listing.fromJson(listing())).startOf(1) * travel)); // never up over the shoe
    await tester.pump(const Duration(milliseconds: 200));
    expect(page(tester).pixels, rest); // and it does stop
  });

  showcaseTest('a finger on the shoe stops a flick at once', (tester) async {
    await pump(tester, listing());
    final stage = find.byKey(const Key('showcase'));
    await tester.fling(stage, const Offset(-120, 0), 2400);
    await tester.pump(const Duration(milliseconds: 100));
    final g = await tester.startGesture(tester.getCenter(stage));
    await tester.pump(const Duration(milliseconds: 50));
    final held = page(tester).pixels;
    await tester.pump(const Duration(milliseconds: 300));
    expect(page(tester).pixels, held);
    await g.up();
    await tester.pumpAndSettle();
  });

  showcaseTest('up and down on the shoe tips it to its top and its sole; the page stays', (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    final g = await tester.startGesture(at);
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(0, -20)); // up: the top comes towards the viewer
      await tester.pump();
    }
    expect(base(tester), 'https://cdn/top-s.webp');
    for (var i = 0; i < 40; i++) {
      await g.moveBy(const Offset(0, 20)); // and down past level to the sole
      await tester.pump();
    }
    expect(base(tester), 'https://cdn/sole-s.webp');
    await g.up();
    await tester.pumpAndSettle();
    expect(page(tester).pixels, 0);
    expect(base(tester), 'https://cdn/sole-s.webp'); // a slow lift leaves it tilted
  });

  showcaseTest('on a scan the shoe tips through the frames where the camera rises over it and goes under it',
      (tester) async {
    await pump(tester, scan());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    final g = await tester.startGesture(at);
    final seen = <String>{};
    for (var i = 0; i < 25; i++) {
      await g.moveBy(const Offset(0, -16));
      await tester.pump();
      seen.add(base(tester));
    }
    // The rise after the turn (frames 8 to 11), then the top's own frame: no jump straight to it.
    expect(seen, containsAll(['https://cdn/f9-s.webp', 'https://cdn/f10-s.webp', 'https://cdn/f12-s.webp']));
    seen.clear();
    for (var i = 0; i < 50; i++) {
      await g.moveBy(const Offset(0, 16));
      await tester.pump();
      seen.add(base(tester));
    }
    // Under the sole: from where the camera is level again past the top (frames 15 to 17) to the sole's frame.
    expect(seen, containsAll(['https://cdn/f16-s.webp', 'https://cdn/f18-s.webp']));
    expect(seen, isNot(contains('https://cdn/f20-s.webp'))); // never on to the close-up
    await g.up();
    await tester.pumpAndSettle();
    expect(page(tester).pixels, 0);
  });

  showcaseTest('a quick flick up tips the shoe all the way over, a quick one back levels it', (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    await tester.flingFrom(at, const Offset(0, -60), 1500);
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/top-s.webp');
    await tester.flingFrom(at, const Offset(0, 60), 1500);
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/f0-s.webp');
  });

  showcaseTest('a sideways drag levels a tilted shoe first, then turns it', (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    await tester.dragFrom(at, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/top-s.webp');
    await tester.dragFrom(at, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(base(tester), allOf(startsWith('https://cdn/f'), isNot('https://cdn/f0-s.webp')));
  });

  showcaseTest('off the turn, up and down on the shoe scrolls the page as before', (tester) async {
    await pump(tester, listing());
    await tester.tap(find.byKey(const Key('showcase-step-top')));
    await tester.pumpAndSettle();
    final before = page(tester).pixels;
    await tester.dragFrom(tester.getCenter(find.byKey(const Key('showcase'))), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(page(tester).pixels, greaterThan(before));
  });

  showcaseTest('a tilted shoe comes level when the page moves or the first stop is tapped', (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    await tester.dragFrom(at, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/top-s.webp');
    await tester.tap(find.byKey(const Key('showcase-step-spin')));
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/f0-s.webp');
    await tester.dragFrom(at, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.dragFrom(edge(tester), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(base(tester), startsWith('https://cdn/f')); // the turn the page shows, not the top
  });

  showcaseTest('with no top or sole photo, up and down on the shoe scrolls the page', (tester) async {
    await pump(tester, listing(details: false));
    await tester.dragFrom(tester.getCenter(find.byKey(const Key('showcase'))), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(page(tester).pixels, greaterThan(0));
  });

  showcaseTest('a slow lift leaves the tilt where it is; only a flick carries it on', (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    await tester.timedDragFrom(at, const Offset(0, -40), const Duration(milliseconds: 400)); // 100 dp/s
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/f0-s.webp'); // under a third of the way: still level
  });

  showcaseTest('the page scrolls from the stage beside the buttons', (tester) async {
    await pump(tester, listing());
    await tester.dragFrom(edge(tester), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(page(tester).pixels, greaterThan(0));
  });

  showcaseTest('a touch on the stops row stops a spinning shoe', (tester) async {
    await pump(tester, listing());
    await tester.fling(find.byKey(const Key('showcase')), const Offset(-120, 0), 2400);
    await tester.pump(const Duration(milliseconds: 50));
    final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('showcase-step-top'))));
    await tester.pump(const Duration(milliseconds: 50));
    final held = page(tester).pixels;
    await tester.pump(const Duration(milliseconds: 300));
    expect(page(tester).pixels, held);
    await g.up();
    await tester.pumpAndSettle();
  });

  showcaseTest('a second finger landing mid-drag does not turn the shoe', (tester) async {
    await pump(tester, listing());
    final at = tester.getCenter(find.byKey(const Key('showcase')));
    final a = await tester.startGesture(at);
    await a.moveBy(const Offset(-30, 0));
    await tester.pump(const Duration(milliseconds: 50));
    final turned = page(tester).pixels;
    final b = await tester.startGesture(at + const Offset(150, 0));
    await tester.pump(const Duration(milliseconds: 50));
    // The second finger holds the shoe at the frame it shows: the page waits there for it instead of gliding on.
    final held = (base(tester), page(tester).pixels);
    expect(held.$2, lessThanOrEqualTo(turned));
    await a.moveBy(const Offset(-30, 0)); // the pair's position jumps; the shoe must not
    await tester.pump(const Duration(milliseconds: 50));
    expect((base(tester), page(tester).pixels), held);
    await b.up();
    await a.up();
    await tester.pumpAndSettle();
  });

  showcaseTest('the sharp photo waits until the page stops coasting', (tester) async {
    await pump(tester, listing());
    await tester.flingFrom(edge(tester), const Offset(0, -150), 1500);
    await tester.pump(const Duration(milliseconds: 160)); // past the 140 ms rest, still coasting
    expect(page(tester).isScrollingNotifier.value, isTrue);
    expect(
        find.byWidgetPredicate((w) => w is Image && (w.key?.toString() ?? '').contains('showcase-full')), findsNothing);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byWidgetPredicate((w) => w is Image && (w.key?.toString() ?? '').contains('showcase-full')),
        findsOneWidget);
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

  showcaseTest('the bottom bar takes the scene\'s panel colours under the stage, the page\'s own past it',
      (tester) async {
    await pump(tester, scan());
    final page = Theme.of(tester.element(find.byType(ListingScreen))).colorScheme;
    final total = find.byKey(const Key('total'));
    Color? bar() => tester.widget<Material>(find.ancestor(of: total, matching: find.byType(Material)).first).color;
    Color? label() => tester.widget<Text>(find.text('Жиыны')).style?.color;
    SystemUiOverlayStyle nav() => tester
        .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
            find.ancestor(of: total, matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>)).first)
        .value;
    expect(bar(), ShowcaseScene.dark.panel);
    expect(label(), ShowcaseScene.dark.muted);
    expect(DefaultTextStyle.of(tester.element(total)).style.color, ShowcaseScene.dark.fg);
    expect(nav().systemNavigationBarColor, ShowcaseScene.dark.panel); // Android's own buttons under it too
    expect(nav().systemNavigationBarIconBrightness, Brightness.light);
    await tester.tap(find.byKey(const Key('showcase-backdrop')));
    await tester.pump();
    expect(bar(), ShowcaseScene.light.panel); // at once, as the stage above it
    expect(label(), ShowcaseScene.light.muted);
    expect(nav().systemNavigationBarIconBrightness, Brightness.dark);
    // The buy button keeps the one colour every buy button has.
    expect(tester.widget<FilledButton>(find.byKey(const Key('buy'))).style?.backgroundColor?.resolve({}),
        Brand.accentStrong);
    // It stays on the scene while the stage's foot is on it, to the last pixel of the stage's stretch.
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    final travel = tester.getSize(find.byType(ScrollShowcase)).height - scroll.viewportDimension;
    scroll.jumpTo(travel);
    await tester.pumpAndSettle();
    expect(bar(), ShowcaseScene.light.panel);
    scroll.jumpTo(travel + 2); // the details start to come up under it
    await tester.pump();
    expect(bar(), page.surface); // at once: a fade would pass through grey words on a grey bar
    expect(nav().systemNavigationBarColor, isNot(ShowcaseScene.light.panel));
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(bar(), ShowcaseScene.light.panel); // back under the stage
    await tester.tap(find.byKey(const Key('showcase-photos')));
    await tester.pumpAndSettle();
    expect(bar(), page.surface); // the photos as taken stand on the page
  });

  showcaseTest('a stage that changes height (the phone turned) tells the bar its scene once laid out', (tester) async {
    await pump(tester, scan());
    tester.view.physicalSize = const Size(400, 640);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
        tester
            .widget<Material>(find.ancestor(of: find.byKey(const Key('total')), matching: find.byType(Material)).first)
            .color,
        ShowcaseScene.dark.panel);
  });

  for (final dark in [true, false]) {
    showcaseTest('a buy button that cannot be pressed reads on the ${dark ? 'dark' : 'light'} scene\'s bar',
        (tester) async {
      await pump(tester, {...scan(backdrop: dark ? 'dark' : 'light'), 'status': 'sold'});
      final scene = dark ? ShowcaseScene.dark : ShowcaseScene.light;
      final button = find.descendant(of: find.byKey(const Key('buy')), matching: find.byType(Material));
      expect(tester.widget<FilledButton>(find.byKey(const Key('buy'))).onPressed, isNull);
      expect(tester.widget<Material>(button.first).color, scene.line);
      final words = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.byKey(const Key('buy-text')), matching: find.byType(RichText)));
      expect(words.text.style?.color, scene.muted);
    });
  }

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
      // Under the small copies the stage's painter draws it, made from the copy itself.
      final state = tester.state<ScrollShowcaseState>(find.byType(ScrollShowcase));
      expect(state.castsShadow ? 1 : 0, shadows, reason: '$body');
      expect(find.byType(ContactShadow), findsNothing, reason: '$body');
    }
    await pump(tester, listing());
    await tester.tap(find.byKey(const Key('showcase-step-sole')));
    await tester.pumpAndSettle();
    expect(tester.state<ScrollShowcaseState>(find.byType(ScrollShowcase)).castsShadow,
        isFalse); // the sole stands on nothing
    expect(find.byType(ContactShadow), findsNothing);
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
  String shownOn(WidgetTester tester, int id) => tester
      .state<ScrollShowcaseState>(find.descendant(of: screen(id), matching: find.byType(ScrollShowcase)))
      .drawnSmall!;

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
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20))); // its first frame decodes
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
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20))); // its first frame decodes
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
    await tester.pump(ListingScreen.switchBudget); // the other colour's first frame stops being waited for
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

  showcaseTest('on a scan the turn\'s end mark sits on the line where the turn comes round and lights once passed',
      (tester) async {
    final ticks = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') ticks.add(call);
      return null;
    });
    await pump(tester, scan());
    final plan = ShowcasePlan.of(Listing.fromJson(scan()));
    final mark = find.byKey(const Key('showcase-turn-end'));
    Color? dot() => (tester
            .widget<AnimatedContainer>(find.descendant(of: mark, matching: find.byType(AnimatedContainer)))
            .decoration! as BoxDecoration)
        .color;
    final first = tester.getCenter(find.byKey(const Key('showcase-step-spin'))).dx;
    final last = tester.getCenter(find.byKey(const Key('showcase-step-close'))).dx;
    expect(tester.getCenter(mark).dx, closeTo(first + (last - first) * plan.turnEnd!, 0.5));
    expect(dot(), ShowcaseScene.dark.ink);
    // A button like the stops, with its name for a screen reader.
    expect(tester.getSemantics(mark), isSemantics(label: 'Айналым соңы', isButton: true, hasTapAction: true));
    // Scrolled to frame 7, the turn's last: still out; one frame on (8, frame 0 again), lit, with one tick.
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    final travel = tester.getSize(find.byType(ScrollShowcase)).height - scroll.viewportDimension;
    scroll.jumpTo(plan.centreOf(0, 7) * travel);
    await tester.pumpAndSettle();
    expect(dot(), ShowcaseScene.dark.ink);
    ticks.clear();
    scroll.jumpTo(plan.centreOf(0, 8) * travel);
    await tester.pumpAndSettle();
    expect(dot(), ShowcaseScene.dark.glow);
    expect(ticks, hasLength(1));
    // Back to the first stop from the sole: one tick on arrival, none for the turn's end passed on the way.
    await tester.tap(find.byKey(const Key('showcase-step-sole')));
    await tester.pumpAndSettle();
    expect(dot(), ShowcaseScene.dark.glow);
    ticks.clear();
    await tester.tap(find.byKey(const Key('showcase-step-spin')));
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/f0-s.webp');
    expect(dot(), ShowcaseScene.dark.ink);
    expect(ticks, hasLength(1));
    // A tap on the mark goes to where the turn comes round, with one tick there.
    ticks.clear();
    await tester.tap(mark);
    await tester.pumpAndSettle();
    expect(scroll.pixels, closeTo(plan.centreOf(0, 8) * travel, 1));
    expect(dot(), ShowcaseScene.dark.glow);
    expect(ticks, hasLength(1));
    // And to it from the sole: one tick, on arrival.
    await tester.tap(find.byKey(const Key('showcase-step-sole')));
    await tester.pumpAndSettle();
    ticks.clear();
    await tester.tap(mark);
    await tester.pumpAndSettle();
    expect(scroll.pixels, closeTo(plan.centreOf(0, 8) * travel, 1));
    expect(ticks, hasLength(1));
    // Afterwards a stop passed by scrolling ticks as before.
    ticks.clear();
    scroll.jumpTo(plan.centreOf(1, 0) * travel);
    await tester.pumpAndSettle();
    expect(ticks, hasLength(1));
  });

  showcaseTest('with photo stops there is no turn\'s end mark', (tester) async {
    await pump(tester, listing());
    expect(find.byKey(const Key('showcase-turn-end')), findsNothing);
  });

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

  // The demo page's way of moving (scroll 3D v4): the stage glides after the page through real frames, drawn from
  // small copies decoded once and held outside the image cache.
  int frameOf(String url) => int.parse(RegExp(r'f(\d+)-s').firstMatch(url)!.group(1)!);

  showcaseTest('a long scroll is not shown in one screen refresh: the shoe glides there through the frames between',
      (tester) async {
    await pump(tester, listing(details: false));
    final plan = ShowcasePlan.of(Listing.fromJson(listing(details: false)));
    final travel = ScrollShowcase.travelFor(tester.getSize(find.byKey(const Key('showcase'))).height, 1);
    await tester.dragFrom(const Offset(200, 600), Offset(0, -travel * 0.8));
    final want = plan.at(page(tester).pixels / travel).frame;
    expect(want, greaterThan(12));
    await tester.pump(const Duration(milliseconds: 16));
    final first = frameOf(base(tester));
    expect(first, inExclusiveRange(0, want)); // on its way, not there yet
    var last = first;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final now = frameOf(base(tester));
      expect(now, greaterThanOrEqualTo(last)); // only forward, frame by frame
      last = now;
    }
    expect(last, want); // and it lands exactly where the page is
  });

  showcaseTest('a jump nobody watched lands at once, and so does every move with reduced motion', (tester) async {
    await pump(tester, listing(details: false));
    final plan = ShowcasePlan.of(Listing.fromJson(listing(details: false)));
    final travel = ScrollShowcase.travelFor(tester.getSize(find.byKey(const Key('showcase'))).height, 1);
    page(tester).jumpTo(plan.centreOf(0, 15) * travel); // as when another colour opens at the same view
    await tester.pump();
    expect(base(tester), 'https://cdn/f15-s.webp');

    final scroll = ScrollController();
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(size: Size(400, 800), disableAnimations: true),
            child: Scaffold(
                body: ListView(controller: scroll, children: [
              ScrollShowcase(listing: Listing.fromJson(listing(details: false)), scroll: scroll, stageHeight: 600),
              const SizedBox(height: 2000),
            ])))));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(200, 20), const Offset(0, -300)); // the stage's top strip scrolls the page
    final want = plan.at(scroll.offset / ScrollShowcase.travelFor(600, 1)).frame;
    expect(want, greaterThan(5));
    await tester.pump(const Duration(milliseconds: 16));
    expect(base(tester), 'https://cdn/f$want-s.webp');
  });

  showcaseTest('on a narrow phone a turn still takes 240 px of finger, not less', (tester) async {
    await pump(tester, listing(details: false), size: const Size(300, 700));
    await tester.dragFrom(tester.getCenter(find.byKey(const Key('showcase'))), const Offset(-120, 0));
    await rest(tester);
    expect(frameOf(base(tester)), inInclusiveRange(10, 12)); // half way round, less the touch slop
  });

  showcaseTest('a sideways drag glides frame by frame, but past the turn\'s end it jumps round', (tester) async {
    await pump(tester, listing(details: false));
    // 240 px of finger turn the shoe once round, the demo page's 3 px a frame over its 80 frames.
    await tester.dragFrom(tester.getCenter(find.byKey(const Key('showcase'))), const Offset(-60, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(frameOf(base(tester)), inExclusiveRange(0, 6));
    await rest(tester);
    expect(frameOf(base(tester)), inInclusiveRange(4, 6)); // a quarter of the way round, less the touch slop
    await pump(tester, scan());
    page(tester).jumpTo(0);
    await tester.pumpAndSettle();
    expect(base(tester), 'https://cdn/f0-s.webp');
    await tester.drag(find.byKey(const Key('showcase')), const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(base(tester), 'https://cdn/f7-s.webp'); // at once, not back through the turn
    await rest(tester);
  });

  test('a long scan\'s small copies are decoded narrower, so a colour stays within about 140 MB', () {
    expect(ScrollShowcaseState.smallSide(205), 400);
    expect(ScrollShowcaseState.smallSide(1000), lessThan(400));
    expect(1000 * math.pow(ScrollShowcaseState.smallSide(1000), 2) * 4, lessThanOrEqualTo(140 << 20));
  });

  testWidgets('every small copy is decoded once, held outside the image cache and let go with its photos',
      (tester) async {
    final png = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 48, 48), Paint()..color = const Color(0xFF1F8FC7));
      final image = await recorder.endRecording().toImage(48, 48);
      return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    }))!;
    final asked = <String>[];
    ScrollShowcaseState.smallSource = (url) {
      asked.add(url);
      return MemoryImage(png);
    };
    addTearDown(() => ScrollShowcaseState.smallSource = netImage);
    final cache = PaintingBinding.instance.imageCache..clear();
    Future<void> decode() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    final scroll = ScrollController();
    var body = listing();
    late StateSetter set;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
      set = setState;
      return ListView(controller: scroll, children: [
        ScrollShowcase(listing: Listing.fromJson(body), scroll: scroll, stageHeight: 600),
        const SizedBox(height: 2000),
      ]);
    }))));
    await decode();
    final state = tester.state<ScrollShowcaseState>(find.byType(ScrollShowcase));
    // The 24 frames and the top, sole and close-up photos, each asked for once.
    expect(asked.toSet().length, 27);
    expect(asked.length, 27);
    final held = state.smallImages.values.toList();
    expect(held, hasLength(27));
    expect(held.first.width, 48); // smaller than 400 px: decoded as it is
    expect(cache.currentSize, 0); // not counted twice, and never dropped by the cache mid-turn
    // Turning draws them without asking again.
    scroll.jumpTo(200);
    await tester.pump();
    expect(asked.length, 27);
    // Other photos: the old copies go from memory before the new ones come.
    set(() => body = {
          ...listing(details: false),
          'media': [for (var i = 0; i < 8; i++) media('frame', 'n$i')],
        });
    await tester.pump();
    expect(held.every((i) => i.debugDisposed), isTrue);
    expect(state.smallImages, isEmpty);
    await decode();
    expect(state.smallImages, hasLength(8));
    final now = state.smallImages.values.toList();
    await tester.pumpWidget(const SizedBox());
    expect(now.every((i) => i.debugDisposed), isTrue); // and all go when the page closes
  });

  group('small copies', () {
    late Uint8List png;
    late List<String> asked;
    late ScrollController scroll;
    Future<void> decode(WidgetTester tester, [int rounds = 15]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    Future<ScrollShowcaseState> open(WidgetTester tester,
        {Set<String> broken = const {}, Future<void> Function()? before}) async {
      png = (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 48, 48), Paint()..color = const Color(0xFF1F8FC7));
        final image = await recorder.endRecording().toImage(48, 48);
        return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      }))!;
      asked = [];
      final failOnce = {...broken};
      final bytes = <String, Uint8List>{}; // each address its own picture, as from the server
      ScrollShowcaseState.smallSource = (url) {
        asked.add(url);
        // A broken copy fails the first time only, as on a connection that drops for a moment.
        return MemoryImage(failOnce.remove(url)
            ? Uint8List.fromList([1, 2, 3, 4])
            : bytes.putIfAbsent(url, () => Uint8List.fromList(png)));
      };
      addTearDown(() {
        ScrollShowcaseState.smallSource = netImage;
        ScrollShowcaseState.shortOfMemory = false;
      });
      PaintingBinding.instance.imageCache.clear();
      await before?.call();
      scroll = ScrollController();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ListView(controller: scroll, children: [
        ScrollShowcase(listing: Listing.fromJson(listing()), scroll: scroll, stageHeight: 600),
        const SizedBox(height: 2000),
      ]))));
      return tester.state<ScrollShowcaseState>(find.byType(ScrollShowcase));
    }

    testWidgets('come six at a time, the frames either side of the shoe first', (tester) async {
      await open(tester);
      expect(asked, hasLength(ScrollShowcaseState.decodeAtOnce));
      // Round the turn: frame 23 is next to frame 0.
      expect(asked, containsAll(['https://cdn/f0-s.webp', 'https://cdn/f1-s.webp', 'https://cdn/f23-s.webp']));
      await decode(tester);
      expect(asked, hasLength(27));
    });

    // Without a screen reader (which reads each frame from the built page, so builds it every frame).
    testWidgets('a glide only paints the stage again, frame by frame, without building the page', (tester) async {
      final state = await open(tester);
      await decode(tester);
      expect(state.paintedSmall, 'https://cdn/f0-s.webp');
      final builds = state.builds;
      await tester.dragFrom(const Offset(200, 20), const Offset(0, -300)); // the stage's top strip scrolls the page
      final seen = <String>{};
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        seen.add(state.paintedSmall!);
        expect(state.paintedSmall, state.drawnSmall); // the painter draws the frame the stage is on
      }
      expect(seen.length, greaterThan(5));
      expect(state.builds - builds, lessThanOrEqualTo(2)); // once it comes to rest, for the full photo
    }, semanticsEnabled: false);

    testWidgets('one that did not come is drawn as its own photo, then asked for again', (tester) async {
      final state = await open(tester, broken: {'https://cdn/f0-s.webp'});
      await decode(tester);
      expect(state.smallImages.containsKey('https://cdn/f0-s.webp'), isFalse);
      expect(state.drawnSmall, isNull); // not another frame's copy in its place
      expect(tester.widget(find.byKey(const ValueKey('showcase-base'))), isA<Image>());
      await tester.pump(const Duration(seconds: 2));
      await decode(tester);
      expect(asked.where((u) => u == 'https://cdn/f0-s.webp'), hasLength(2));
      expect(state.smallImages.containsKey('https://cdn/f0-s.webp'), isTrue);
      expect(state.drawnSmall, 'https://cdn/f0-s.webp');
    });

    testWidgets('are let go while another page covers the shoe, and come back with it', (tester) async {
      final state = await open(tester);
      await decode(tester);
      final held = state.smallImages.values.toList();
      expect(held, hasLength(27));
      Navigator.of(tester.element(find.byType(ScrollShowcase)))
          .push(MaterialPageRoute<void>(builder: (_) => const Scaffold()));
      await tester.pumpAndSettle();
      expect(state.smallImages.keys, ['https://cdn/f0-s.webp']); // the shoe on the stage stays
      expect(held.where((i) => i.debugDisposed), hasLength(26));
      Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
      await tester.pumpAndSettle();
      await decode(tester);
      expect(state.smallImages, hasLength(27));
    });

    testWidgets('are made narrower once the phone is short of memory', (tester) async {
      final state = await open(tester);
      await decode(tester);
      expect(ScrollShowcaseState.smallSide(205), 400);
      state.didHaveMemoryPressure();
      expect(ScrollShowcaseState.shortOfMemory, isTrue);
      expect(ScrollShowcaseState.smallSide(205), lessThan(300));
      expect(state.smallImages.length, lessThanOrEqualTo(1));
      await decode(tester);
      expect(state.smallImages, hasLength(27));
    });

    testWidgets('a seller\'s cut-out gets its shadow made from its small copy', (tester) async {
      final state = await open(tester);
      await decode(tester);
      expect(state.castsShadow, isTrue);
      expect(state.smallShadows.containsKey('https://cdn/f0-s.webp'), isTrue);
    });

    testWidgets('a copy already in the image cache for someone else stays there; its own are let go there',
        (tester) async {
      late Object key;
      final state = await open(tester, before: () async {
        // A catalog card holds frame 0 at the size the stage asks for.
        final card = ScrollShowcaseState.smallCopy('https://cdn/f0-s.webp', 400);
        key = (await tester.runAsync(() => card.obtainKey(ImageConfiguration.empty)))!;
        card.resolve(ImageConfiguration.empty).addListener(ImageStreamListener((_, __) {}));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        asked.clear();
      });
      final cache = PaintingBinding.instance.imageCache;
      expect(cache.containsKey(key), isTrue);
      await decode(tester);
      expect(state.smallImages, hasLength(27));
      expect(cache.containsKey(key), isTrue);
      final other = await tester.runAsync(
          () => ScrollShowcaseState.smallCopy('https://cdn/f1-s.webp', 400).obtainKey(ImageConfiguration.empty));
      expect(cache.containsKey(other!), isFalse);
    });
  });
}
