import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/widgets/common.dart';
import 'package:vitrina/widgets/scroll_showcase.dart';
import 'package:vitrina/widgets/studio.dart';

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
      expect([for (final s in plan.steps) (s.kind, s.media.length)],
          [('spin', 24), ('top', 1), ('sole', 1), ('close', 1)]);
      expect(plan.steps.last.media.single.angle, 'detail'); // the stitching close-up, not the size label
    });

    test('a scan carries on from the turn to each view: every stop starts at its own frame', () {
      final plan = ShowcasePlan.of(Listing.fromJson(scan()));
      expect(plan.scan, isTrue);
      expect([for (final s in plan.steps) (s.kind, s.media.length)],
          [('spin', 12), ('top', 6), ('sole', 5), ('close', 1)]);
      for (final (step, frame) in [(1, 12), (2, 18), (3, 23)]) {
        expect(plan.steps[step].media.first.url, 'https://cdn/f$frame.webp');
      }
      expect(plan.turn, 8); // where the first frame comes round again
    });

    test('two sides settle which way a turn goes; two opposite ones do not', () {
      expect(TurnMap({0: 0, 0.5: 0.5}).sided, isFalse);
      expect(TurnMap({0: 0, 0.25: 0.25}).sided, isTrue);
      final map = TurnMap({0: 0, 0.25: 0.25});
      for (final a in [0.0, 0.1, 0.5, 0.9]) {
        expect(map.angle(map.place(a)), closeTo(a, 1e-9));
      }
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

    test('stop photos that are not frames of the turn stay separate photos', () {
      expect(ShowcasePlan.of(Listing.fromJson(listing())).scan, isFalse);
    });

    test('a turn where some frames have no cut-out shows all of them as taken', () {
      final plan = ShowcasePlan.of(Listing.fromJson(listing(cutFrames: false)));
      expect(plan.steps.first.cut, isFalse);
      expect(plan.steps[1].cut, isTrue);
    });
  });

  test('controls on a ground take whichever ink reads better on it', () {
    expect(darkerScene(const Color(0xFF000000)), isTrue);
    expect(darkerScene(const Color(0xFF3A3A3A)), isTrue);
    expect(darkerScene(const Color(0xFF808080)), isFalse); // mid grey: dark ink reads better than light
    expect(darkerScene(const Color(0xFFFFFFFF)), isFalse);
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
}
