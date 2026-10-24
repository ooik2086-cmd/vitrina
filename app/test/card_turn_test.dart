// Aza, 2026-10-24 ("кішініде үлкендініде саусақпен бұратындай болу керек"): the shoe on a catalog card turns under a
// sideways finger as on its page, and goes back to its cover when let go; scrolling the catalog still works.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/widgets/card_turn.dart';
import 'package:vitrina/widgets/common.dart';
import 'package:vitrina/widgets/studio.dart';

// A 1×1 see-through PNG, for every picture of the turn.
final _png =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

// The demo's own blue pair, with a turn of [frames] pictures.
Map<String, dynamic> _listing(int frames) {
  final l = (jsonDecode(File('demo/api.json').readAsStringSync()) as Map)['GET /listings/3'] as Map<String, dynamic>;
  return {
    ...l,
    'model': {
      ...l['model'] as Map<String, dynamic>,
      'turn': [for (var i = 0; i < frames; i++) 'https://cdn/t$i.webp'],
    },
  };
}

void main() {
  final made = <ImageProvider, String>{};
  setUp(() {
    made.clear();
    CardTurn.network = (url) {
      final image = MemoryImage(_png, scale: 1 + url.hashCode % 9973 / 1e6); // one provider per picture
      made[image] = url;
      return image;
    };
  });

  Future<void> show(WidgetTester tester, int frames) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListView(children: [
      Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 180, child: ListingTile(listing: Listing.fromJson(_listing(frames))))),
      const SizedBox(height: 1200),
    ]))));
  }

  Future<void> decoded(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  String? shown(WidgetTester tester) {
    final image = tester
        .widget<Image>(find.descendant(of: find.byKey(const Key('card-turn')), matching: find.byType(Image)).last)
        .image;
    return made[(image as ResizeImage).imageProvider];
  }

  testWidgets('a sideways drag turns the card\'s shoe through its turn, and it goes back to the cover', (tester) async {
    await show(tester, 24);
    expect(find.byType(CardTurn), findsOneWidget);
    expect(find.byKey(const Key('card-turn')), findsNothing);
    final g = await tester.startGesture(tester.getCenter(find.byType(CardTurn)));
    await g.moveBy(const Offset(20, 0));
    await decoded(tester); // the pictures come down
    await g.moveBy(const Offset(60, 0)); // a 180 wide card turns once round in 270 px
    await tester.pump();
    expect(find.byKey(const Key('card-turn')), findsOneWidget);
    // About 6 of 24 pictures on: the first move partly goes to telling a drag from a tap.
    expect(shown(tester), isIn(['https://cdn/t5.webp', 'https://cdn/t6.webp']));
    await g.moveBy(const Offset(-80, 0)); // back the same way: the turn follows the finger both ways
    await tester.pump();
    expect(shown(tester), isIn(['https://cdn/t22.webp', 'https://cdn/t23.webp', 'https://cdn/t0.webp']));
    await g.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('card-turn')), findsNothing); // the cover again
    expect(tester.takeException(), isNull);
  });

  testWidgets('an up-and-down drag on the card scrolls the catalog and does not turn the shoe', (tester) async {
    await show(tester, 24);
    final before = tester.getTopLeft(find.byType(CardTurn)).dy;
    final g = await tester.startGesture(tester.getCenter(find.byType(CardTurn)));
    await g.moveBy(const Offset(0, -40));
    await g.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(find.byKey(const Key('card-turn')), findsNothing);
    expect(tester.getTopLeft(find.byType(CardTurn)).dy, lessThan(before - 50));
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a shoe with too few pictures for a turn keeps a still cover', (tester) async {
    await show(tester, CardTurn.minFrames - 1);
    expect(find.byType(CardTurn), findsNothing);
  });

  testWidgets('while its pictures are still coming, the card keeps its cover: the shoe never blinks out',
      (tester) async {
    await show(tester, 24);
    CardTurn.network = (url) => _Never(); // a weak line: nothing has come yet
    final g = await tester.startGesture(tester.getCenter(find.byType(CardTurn)));
    await g.moveBy(const Offset(40, 0));
    await g.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(find.byKey(const Key('card-turn')), findsNothing);
    expect(find.descendant(of: find.byType(CardTurn), matching: find.byType(CoverPhoto)), findsOneWidget);
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('with motion turned down, letting go goes straight back to the cover', (tester) async {
    await show(tester, 24);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final g = await tester.startGesture(tester.getCenter(find.byType(CardTurn)));
    await g.moveBy(const Offset(20, 0));
    await decoded(tester);
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(find.byKey(const Key('card-turn')), findsOneWidget);
    await g.up();
    await tester.pump();
    expect(find.byKey(const Key('card-turn')), findsNothing);
  });
}

/// A picture that never arrives.
class _Never extends ImageProvider<_Never> {
  @override
  Future<_Never> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Never key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}
