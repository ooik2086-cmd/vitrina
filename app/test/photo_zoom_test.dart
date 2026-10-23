// The Фото tab zooms as the approved demo does (Aza, 2026-10-23: "Суретте зум жоқ"), and a photo or video of any
// shape shows whole on its own colours, never cut at the sides.
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

  double scale(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer).first)
      .transformationController!
      .value
      .getMaxScaleOnAxis();
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
