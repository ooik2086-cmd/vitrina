import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/widgets/spin_viewer.dart';

/// The app's own scroll behaviour on a computer (main.dart _MouseDrags): the mouse drags as a finger.
class _M extends MaterialScrollBehavior {
  const _M();
  @override
  Set<PointerDeviceKind> get dragDevices => {...super.dragDevices, PointerDeviceKind.mouse};
}

void main() {
  // The demo on a laptop: the photos turn page by page under the mouse (Aza, 2026-11-04).
  testWidgets('a mouse drag turns the photo page, not the zoom', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        scrollBehavior: _M(),
        home: Scaffold(
            body: SizedBox(height: 400, child: PhotoGallery(urls: ['https://x/a.webp', 'https://x/b.webp'])))));
    final g = await tester.startGesture(const Offset(600, 200), kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 15; i++) {
      await g.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 1.0);
    final zoom = tester.widget<Transform>(find.byKey(const Key('photo-zoom')).first);
    expect(zoom.transform.getMaxScaleOnAxis(), 1.0, reason: 'still a whole photo');
  });
}
