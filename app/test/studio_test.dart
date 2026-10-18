import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('a shadow is drawn once its photo is decoded, and the next card with that photo has it at once',
      (tester) async {
    final png =
        await tester.runAsync(() async => (await (await halfShoe()).toByteData(format: ui.ImageByteFormat.png))!);
    final photo = MemoryImage(png!.buffer.asUint8List());
    Widget shadowOf(ImageProvider image) => Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 200, height: 200, child: ContactShadow(image: image, fit: BoxFit.contain)));
    await tester.pumpWidget(shadowOf(photo));
    expect(find.byType(RawImage), findsNothing); // nothing to show until the photo is there
    for (var i = 0; i < 10 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, ContactShadow.width);
    await tester.pumpWidget(const SizedBox.shrink()); // the first card is gone
    await tester.pumpWidget(shadowOf(photo));
    expect(find.byType(RawImage), findsOneWidget); // from the cache, on the first frame
  });
}
