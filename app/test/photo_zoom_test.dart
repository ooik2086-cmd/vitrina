// The Фото tab zooms as the approved demo does (Aza, 2026-10-23: "Суретте зум жоқ"), and a photo or video of any
// shape shows whole on its own colours, never cut at the sides.
import 'dart:ui' show GestureSettings;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/widgets/blur_fill.dart';
import 'package:vitrina/widgets/spin_viewer.dart' show PhotoGallery;
import 'package:vitrina/widgets/video_pane.dart';

void main() {
  Future<void> gallery(WidgetTester tester, {bool cutout = false}) async {
    tester.view.physicalSize = const Size(360, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 360,
                child: PhotoGallery(cutout: cutout, urls: const ['https://cdn/1.webp', 'https://cdn/2.webp'])))));
  }

  double scale(WidgetTester tester) =>
      tester.widget<Transform>(find.byKey(const Key('photo-zoom')).first).transform.getMaxScaleOnAxis();
  int page(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!.page!.round();

  Future<void> doubleTap(WidgetTester tester) async {
    final at = tester.getCenter(find.byType(PageView));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pumpAndSettle();
  }

  testWidgets('a double tap zooms a photo to 2.5× and back; zoomed, a swipe moves it, not the page', (tester) async {
    await gallery(tester);
    expect(scale(tester), 1);
    await doubleTap(tester);
    expect(scale(tester), closeTo(2.5, 0.01));
    await tester.drag(find.byType(PageView), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(page(tester), 0, reason: 'zoomed in, one finger pans the photo');
    await doubleTap(tester);
    expect(scale(tester), closeTo(1, 0.01));
    await tester.drag(find.byType(PageView), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(page(tester), 1, reason: 'at 1× a swipe turns the page');
  });

  testWidgets('two fingers zoom up to 3×, no further', (tester) async {
    await gallery(tester);
    final c = tester.getCenter(find.byType(PageView));
    final a = await tester.startGesture(c - const Offset(20, 0));
    final b = await tester.startGesture(c + const Offset(20, 0));
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(c - Offset(20.0 + i * 15, 0));
      await b.moveTo(c + Offset(20.0 + i * 15, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(scale(tester), closeTo(3, 0.01));
  });

  testWidgets('on the listing page two fingers zoom the photo, not scroll the page, the second landing a moment later',
      (tester) async {
    // Aza, 2026-10-25: "Суретке екі саусақпен жақындатуға болатындай" — on the phone the page's scroll took the fingers.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scroll = ScrollController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListView(controller: scroll, children: [
      const SizedBox(height: 360, child: PhotoGallery(urls: ['https://cdn/1.webp', 'https://cdn/2.webp'])),
      const SizedBox(height: 900),
    ]))));
    final c = tester.getCenter(find.byType(PageView));
    // As a hand does it: the thumb lands and settles a little, the finger lands, and mostly the finger moves.
    final thumb = await tester.startGesture(c - const Offset(30, 30));
    await thumb.moveBy(const Offset(12, 0));
    await tester.pump(const Duration(milliseconds: 60));
    final finger = await tester.startGesture(c + const Offset(30, 30));
    for (var i = 1; i <= 8; i++) {
      await finger.moveBy(const Offset(10, 0));
      await thumb.moveBy(const Offset(-2, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await thumb.up();
    await finger.up();
    await tester.pumpAndSettle();
    expect(scale(tester), greaterThan(1.5));
    expect(scroll.offset, 0);
    expect(page(tester), 0);
  });

  testWidgets('on a phone, where the page takes a finger after 8 dp, two fingers still zoom the photo', (tester) async {
    // The audit: Android hands the page's scroll the thumb after 8 dp, so an unsteady thumb is the page's before the
    // finger lands. The zoom then reads the fingers itself and puts the page back.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.gestureSettings = const GestureSettings(physicalTouchSlop: 8);
    addTearDown(tester.view.reset);
    final scroll = ScrollController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListView(controller: scroll, children: [
      const SizedBox(height: 360, child: PhotoGallery(urls: ['https://cdn/1.webp', 'https://cdn/2.webp'])),
      const SizedBox(height: 900),
    ]))));
    final c = tester.getCenter(find.byType(PageView));
    for (final drift in const [Offset(0, -14), Offset(-14, 0)]) {
      final thumb = await tester.startGesture(c - const Offset(30, 30));
      await thumb.moveBy(drift);
      await tester.pump(const Duration(milliseconds: 60));
      final finger = await tester.startGesture(c + const Offset(30, 30));
      for (var i = 1; i <= 8; i++) {
        await finger.moveBy(const Offset(10, 10));
        await thumb.moveBy(const Offset(-2, -2));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await thumb.up();
      await finger.up();
      await tester.pumpAndSettle();
      expect(scale(tester), greaterThan(1.5), reason: 'drift $drift');
      expect(scroll.offset, 0, reason: 'drift $drift');
      expect(page(tester), 0, reason: 'drift $drift');
      await doubleTap(tester);
      expect(scale(tester), closeTo(1, 0.01));
    }
  });

  testWidgets('two taps too far apart in time, or a tap after a drag, do not zoom', (tester) async {
    await gallery(tester);
    final at = tester.getCenter(find.byType(PageView));
    Future<void> tap(Offset where, int downMs, int upMs) async {
      final g = await tester.createGesture();
      await g.down(where, timeStamp: Duration(milliseconds: downMs));
      await g.up(timeStamp: Duration(milliseconds: upMs));
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Second down 400 ms after the first lift: two taps, not a double tap.
    await tap(at, 1000, 1080);
    await tap(at, 1480, 1560);
    await tester.pumpAndSettle();
    expect(scale(tester), 1);
    // Second down 200 ms after the first lift, a slow hand lifting it 150 ms later: a double tap.
    await tap(at, 3000, 3080);
    await tap(at, 3280, 3430);
    await tester.pumpAndSettle();
    expect(scale(tester), closeTo(2.5, 0.01));
    await tap(at, 5000, 5080);
    await tap(at, 5200, 5280);
    await tester.pumpAndSettle();
    expect(scale(tester), closeTo(1, 0.01));
    // A short drag (under the page's slop) and then a tap: not a double tap.
    final g = await tester.createGesture();
    await g.down(at, timeStamp: const Duration(milliseconds: 7000));
    await g.moveBy(const Offset(0, 30), timeStamp: const Duration(milliseconds: 7040));
    await g.up(timeStamp: const Duration(milliseconds: 7080));
    await tester.pumpAndSettle();
    await tap(at, 7200, 7260);
    await tester.pumpAndSettle();
    expect(scale(tester), 1);
  });

  testWidgets('a double tap zooms in round the spot tapped, not the middle', (tester) async {
    await gallery(tester);
    final topLeft = tester.getTopLeft(find.byType(PageView)) + const Offset(60, 60);
    await tester.tapAt(topLeft);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(topLeft);
    await tester.pumpAndSettle();
    final m = tester.widget<Transform>(find.byKey(const Key('photo-zoom')).first).transform;
    expect(m.getMaxScaleOnAxis(), closeTo(2.5, 0.01));
    // The spot under the finger stays under it: (60, 60) of the photo is still at (60, 60).
    expect(MatrixUtils.transformPoint(m, const Offset(60, 60)), const Offset(60, 60));
  });

  testWidgets('a photo is shown whole: on its own colours when taken, on the scene when cut out', (tester) async {
    await gallery(tester);
    expect(find.byType(BlurFill), findsWidgets);
    for (final image in tester.widgetList<Image>(find.byType(Image))) {
      expect(image.fit, anyOf(BoxFit.contain, BoxFit.cover), reason: 'the blur behind covers; the photo is whole');
    }
    final photos = tester
        .widgetList<Image>(find.byType(Image))
        .where((i) => find.ancestor(of: find.byWidget(i), matching: find.byType(BlurFill)).evaluate().isEmpty);
    expect(photos.map((i) => i.fit).toSet(), {BoxFit.contain});
    await gallery(tester, cutout: true);
    expect(find.byType(BlurFill), findsNothing);
  });

  testWidgets('a video of any shape stands on its own colours, not on bars', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: VideoPane(url: 'https://cdn/v.mp4', posterUrl: 'https://cdn/v.jpg', seconds: 9, active: false)));
    expect(find.byType(BlurFill), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: VideoPane(url: 'https://cdn/v.mp4', seconds: 9, active: false)));
    expect(find.byType(BlurFill), findsNothing);
  });
}
