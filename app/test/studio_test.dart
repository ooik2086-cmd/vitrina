import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/theme.dart';
import 'package:vitrina/widgets/studio.dart';

/// 100 × 50: the left half an opaque shoe, the right half see-through, as a cut-out is.
Future<ui.Image> halfShoe() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 50, 50), Paint()..color = const Color(0xFFE05050));
  return recorder.endRecording().toImage(100, 50);
}

void main() {
  setUp(ContactShadow.clearCache);

  testWidgets('the shadow is the shoe\'s outline in soft black, a few dozen pixels across', (tester) async {
    await tester.runAsync(() async {
      final shadow = await silhouette(await halfShoe());
      expect((shadow.width, shadow.height), (ContactShadow.width, ContactShadow.width ~/ 2));
      final px = (await shadow.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
      int at(int x, int y, int c) => px.getUint8((y * shadow.width + x) * 4 + c);
      expect([at(4, 8, 0), at(4, 8, 1), at(4, 8, 2)], [0, 0, 0]); // black, whatever the shoe's colour
      expect(at(4, 8, 3), closeTo(ContactShadow.opacity * 255, 3));
      expect(at(28, 8, 3), 0); // nothing where the photo is see-through
    });
  });

  Future<MemoryImage> photoOf(WidgetTester tester) async {
    final png =
        await tester.runAsync(() async => (await (await halfShoe()).toByteData(format: ui.ImageByteFormat.png))!);
    return MemoryImage(png!.buffer.asUint8List());
  }

  Widget shadowOf(ImageProvider image, {bool gapless = false, double height = 200}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
              width: 200, height: height, child: ContactShadow(image: image, fit: BoxFit.contain, gapless: gapless))));
  final drawn = find.descendant(of: find.byType(ContactShadow), matching: find.byType(CustomPaint));
  // Decoding and drawing need real time, which widget tests only give inside runAsync, and the photo is handed
  // out on a frame. The app makes the same shadow on its own when a card first shows the photo.
  Future<void> prepare(WidgetTester tester, ImageProvider photo) async {
    ContactShadow.prepare(photo, ImageConfiguration.empty);
    for (var i = 0; i < 200 && !ContactShadow.isMade(photo); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(); // the decoded photo is handed out on a frame
    }
  }

  testWidgets('a card makes its photo\'s shadow itself once the photo is decoded', (tester) async {
    final photo = await photoOf(tester);
    await tester.pumpWidget(shadowOf(photo));
    expect(drawn, findsNothing); // nothing to show until the photo is there
    for (var i = 0; i < 200 && drawn.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(drawn, findsOneWidget);
  });

  testWidgets('a card shows the shadow of a photo already made, from the first frame', (tester) async {
    final photo = await photoOf(tester);
    await prepare(tester, photo);
    await tester.pumpWidget(shadowOf(photo));
    expect(drawn, findsOneWidget);
  });

  testWidgets('the shadow sits just under the photo as drawn, however tall the box', (tester) async {
    final photo = await photoOf(tester);
    await prepare(tester, photo);
    await tester.pumpWidget(shadowOf(photo, height: 600));
    // The 2:1 photo is drawn 200 × 100 in the middle of the 600 high box: rows 250 to 350, and the shadow 3 lower.
    expect(
        tester.renderObject(drawn),
        paints
          ..something((method, args) {
            if (method != #drawImageRect) return false;
            expect(args[2], const Rect.fromLTWH(0, 253, 200, 100));
            return true;
          }));
  });

  testWidgets('a card given another photo drops the old shadow, and has none when the new photo fails', (tester) async {
    final photo = await photoOf(tester);
    await prepare(tester, photo);
    await tester.pumpWidget(shadowOf(photo));
    expect(drawn, findsOneWidget);
    await tester.pumpWidget(shadowOf(const NetworkImage('https://cdn/broken.webp')));
    expect(drawn, findsNothing); // not the previous shoe's outline under a different shoe
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(drawn, findsNothing);
  });

  testWidgets('frames of one turning shoe keep the last shadow until the next is made', (tester) async {
    final photo = await photoOf(tester);
    await prepare(tester, photo);
    await tester.pumpWidget(shadowOf(photo, gapless: true));
    await tester.pumpWidget(shadowOf(MemoryImage(Uint8List.fromList([...photo.bytes, 0])), gapless: true));
    expect(drawn, findsOneWidget);
  });

  testWidgets('an extreme photo gets no shadow rather than a stretched one', (tester) async {
    final strip = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 900, 10), Paint());
      final img = await recorder.endRecording().toImage(900, 10);
      return MemoryImage((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
    await prepare(tester, strip!);
    await tester.pumpWidget(shadowOf(strip));
    expect(drawn, findsNothing);
  });

  for (final (brightness, canvas, icons) in [
    (Brightness.light, Brand.paperCanvas, Brightness.dark),
    (Brightness.dark, Brand.nightCanvas, Brightness.light),
  ]) {
    testWidgets(
        'every page stands on the ${brightness.name} canvas, a page coming in covers the one under it, and the '
        'status bar icons read on it', (tester) async {
      final theme = buildTheme(brightness);
      await tester
          .pumpWidget(MaterialApp(theme: theme, builder: canvasBehind, home: const Scaffold(body: Text('first'))));
      bool isCanvas(Widget w) => w is DecoratedBox && w.decoration == canvas;
      Finder canvasUnder(String text) => find.ancestor(of: find.text(text), matching: find.byWidgetPredicate(isCanvas));
      expect(canvasUnder('first'), findsNWidgets(2)); // its own, and the one behind every page
      tester.state<NavigatorState>(find.byType(Navigator)).push(MaterialPageRoute<void>(
          builder: (_) => Scaffold(appBar: AppBar(title: const Text('t')), body: const Text('second'))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Mid-transition the new page has its own canvas, inside the transition, not shared with the page below,
      expect(canvasUnder('second'), findsNWidgets(2));
      final own = find.ancestor(of: find.text('second'), matching: find.byWidgetPredicate(isCanvas)).first;
      expect(find.descendant(of: own, matching: find.text('first')), findsNothing);
      // and nothing of another colour comes between the pages.
      expect(find.byWidgetPredicate((w) => w is ColoredBox && w.color.a > 0 && w.color != canvas.color), findsNothing);
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<Material>(find.descendant(of: find.byType(AppBar), matching: find.byType(Material)).first)
              .color,
          Colors.transparent);
      final styles = tester
          .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(find.byType(AnnotatedRegion<SystemUiOverlayStyle>))
          .map((r) => r.value.statusBarIconBrightness)
          .toSet();
      expect(styles, {icons});
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('every platform\'s pages get the canvas, with that platform\'s own transition timing', (tester) async {
    final theme = buildTheme(Brightness.light);
    for (final p in TargetPlatform.values) {
      final b = theme.pageTransitionsTheme.builders[p];
      expect(b, isA<OnCanvas>(), reason: '$p');
      final inner = (b! as OnCanvas).inner;
      expect((b.transitionDuration, b.reverseTransitionDuration, b.delegatedTransition == null),
          (inner.transitionDuration, inner.reverseTransitionDuration, inner.delegatedTransition == null));
    }
    for (final p in [TargetPlatform.iOS, TargetPlatform.windows]) {
      debugDefaultTargetPlatformOverride = p;
      await tester.pumpWidget(MaterialApp(
          key: ValueKey(p), theme: theme, builder: canvasBehind, home: const Scaffold(body: Text('first'))));
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('second'))));
      await tester.pumpAndSettle();
      expect(
          find.ancestor(
              of: find.text('second'),
              matching: find.byWidgetPredicate((w) => w is DecoratedBox && w.decoration == Brand.paperCanvas)),
          findsNWidgets(2),
          reason: '$p');
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('switching light and dark blends the canvas instead of jumping', () {
    final light = buildTheme(Brightness.light).extension<AppCanvas>()!;
    final dark = buildTheme(Brightness.dark).extension<AppCanvas>()!;
    final half = light.lerp(dark, 0.5);
    expect(half.decoration, isNot(light.decoration));
    expect(half.decoration, isNot(dark.decoration));
    expect(light.lerp(dark, 1).decoration.gradient, dark.decoration.gradient);
  });
}
