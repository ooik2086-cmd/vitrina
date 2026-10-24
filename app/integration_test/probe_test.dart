// ignore_for_file: avoid_print
// Diagnostic only, on the emulator probe branch: how long the 3D takes, whether two fingers zoom it, whether the
// video plays.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vitrina/main.dart' as app;
import 'package:vitrina/screens/onboarding_screen.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/widgets/common.dart';
import 'package:vitrina/widgets/model_stage.dart';

Future<void> wait(WidgetTester t, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('probe', (t) async {
    await app.main();
    onboarded.value = true;
    appLanguage.value = 'kk';
    await wait(t, 6000);
    for (var round = 0; round < 2; round++) {
      print('PROBE open listing round $round');
      await t.tap(round == 0 ? find.byType(ListingTile).first : find.text('21 100 ₸').first);
      final start = DateTime.now();
      var shown = false;
      var firstSeen = -1, loadingSeen = false;
      while (DateTime.now().difference(start).inSeconds < 60) {
        await wait(t, 100);
        if (firstSeen < 0 && find.byKey(const Key('model-first')).evaluate().isNotEmpty &&
            find.byKey(const Key('model-loading')).evaluate().isEmpty) {
          firstSeen = DateTime.now().difference(start).inMilliseconds;
        }
        if (find.byKey(const Key('model-loading')).evaluate().isNotEmpty) loadingSeen = true;
        if (find.byType(ModelStage).evaluate().isNotEmpty && find.byKey(const Key('model-loading')).evaluate().isEmpty) {
          shown = true;
          break;
        }
      }
      print('PROBE first picture shown after $firstSeen ms; loading line seen: $loadingSeen');
      print('PROBE 3D ready=$shown after ${DateTime.now().difference(start).inMilliseconds} ms');
      print('PROBE ${DateTime.now().toIso8601String()} MARK ready$round');
      await wait(t, 2500);
      final state = t.state<ModelStageState>(find.byType(ModelStage));
      print('PROBE view before: ${await state.view()}');
      final c = t.getCenter(find.byType(ModelStage));
      // one finger: turn
      final g = await t.startGesture(c);
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(8, 0));
        await wait(t, 16);
      }
      await g.up();
      await wait(t, 1500);
      print('PROBE view after drag: ${await state.view()}');
      // two fingers: pinch out
      final a = await t.startGesture(c - const Offset(40, 0), pointer: 7);
      await wait(t, 30);
      final b = await t.startGesture(c + const Offset(40, 0), pointer: 8);
      for (var i = 0; i < 15; i++) {
        await a.moveBy(const Offset(-6, 0));
        await b.moveBy(const Offset(6, 0));
        await wait(t, 16);
      }
      await a.up();
      await b.up();
      await wait(t, 1500);
      print('PROBE view after pinch: ${await state.view()}');
      print('PROBE ${DateTime.now().toIso8601String()} MARK pinch$round');
      // double tap
      final g2 = await t.startGesture(c, pointer: 9);
      await g2.up();
      await wait(t, 120);
      final g3 = await t.startGesture(c, pointer: 10);
      await g3.up();
      await wait(t, 1500);
      print('PROBE view after double tap: ${await state.view()}');
      if (round == 0) {
        await t.tap(find.text('Видео'));
        await wait(t, 1500);
        print('PROBE play button: ${find.byKey(const Key('video-play')).evaluate().length}');
        print('PROBE ${DateTime.now().toIso8601String()} MARK videotab');
        await t.tap(find.byKey(const Key('video-play')));
        final vs = DateTime.now();
        while (DateTime.now().difference(vs).inSeconds < 30) {
          await wait(t, 200);
          if (find.byKey(const Key('video-time')).evaluate().isNotEmpty ||
              find.byKey(const Key('video-failed')).evaluate().isNotEmpty) break;
        }
        print('PROBE video time=${find.byKey(const Key('video-time')).evaluate().length} failed=${find.byKey(const Key('video-failed')).evaluate().length} after ${DateTime.now().difference(vs).inMilliseconds} ms');
        await wait(t, 3000);
        final time = find.byKey(const Key('video-time'));
        if (time.evaluate().isNotEmpty) print('PROBE video clock: ${(t.widget<Text>(time)).data}');
        print('PROBE ${DateTime.now().toIso8601String()} MARK videoplay');
        await wait(t, 2000);
      }
      await t.binding.handlePopRoute();
      await wait(t, 2000);
    }
  });
}
