// Aza, 2026-10-24 ("бірінің үстіне бірі қабаттасып тұр ашқан кезде"): a page opening showed through to the one under
// it. A page now slides in whole: wherever it has reached, it alone shows, never blended with the page below.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/theme.dart';

void main() {
  testWidgets('mid-way an opening page covers the page under it, nothing blended', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final nav = GlobalKey<NavigatorState>();
    const under = Color(0xFFFF0000), over = Color(0xFF0000FF);
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('screen'),
      child: MaterialApp(
          navigatorKey: nav,
          theme: buildTheme(Brightness.light),
          builder: canvasBehind,
          home: const ColoredBox(color: under, child: SizedBox.expand())),
    ));
    nav.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => const ColoredBox(color: over, child: SizedBox.expand())));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final pixels = (await tester.runAsync(() async {
      final box = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('screen')));
      final image = await box.toImage();
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    }))!;
    Color at(int x, int y) {
      final i = (y * 360 + x) * 4;
      return Color.fromARGB(pixels.getUint8(i + 3), pixels.getUint8(i), pixels.getUint8(i + 1), pixels.getUint8(i + 2));
    }

    // Some of the way in: the right edge is the new page, unblended, while the old one still shows at the left.
    expect(at(355, 320), over);
    expect(at(2, 320).r, greaterThan(0.9));
    int byte(double v) => (v * 255).round();
    final row = [for (var x = 0; x < 360; x += 2) at(x, 320)];
    // Only the sliding page's own edge, part-way across a pixel, may mix the two.
    expect(row.where((c) => byte(c.r) > 40 && byte(c.b) > 40).length, lessThanOrEqualTo(1),
        reason: 'no pixel mixes the two pages');
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a drag from the left edge of a page turns what is there, it does not close the page', (tester) async {
    var turned = 0.0;
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: nav, theme: buildTheme(Brightness.light), builder: canvasBehind, home: const Text('first')));
    nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => GestureDetector(
            onHorizontalDragUpdate: (d) => turned += d.delta.dx,
            child: const ColoredBox(color: Color(0xFF0000FF), child: SizedBox.expand()))));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(8, 300), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(turned, greaterThan(100));
    expect(find.text('first'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
