// ignore_for_file: avoid_print
import 'dart:async';
// Diagnostic only, on the video probe branch: does each colour's video play on a phone?
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';
import 'package:vitrina/main.dart' as app;
import 'package:vitrina/screens/onboarding_screen.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/widgets/common.dart';

Future<void> wait(WidgetTester t, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

String state(WidgetTester t) {
  final players = find.byType(VideoPlayer, skipOffstage: false).evaluate().toList();
  return [
    for (final e in players)
      () {
        final c = (e.widget as VideoPlayer).controller;
        final v = c.value;
        return '${c.dataSource.split('/').last} init=${v.isInitialized} playing=${v.isPlaying} '
            'pos=${v.position.inMilliseconds} dur=${v.duration.inMilliseconds} size=${v.size} err=${v.errorDescription}';
      }()
  ].join(' | ');
}

Future<void> play(WidgetTester t, String label) async {
  await wait(t, 1500);
  final btn = find.byKey(const Key('video-play'));
  print('PROBE $label play buttons=${btn.evaluate().length}');
  if (btn.evaluate().isEmpty) return;
  await t.tap(btn.first);
  final vs = DateTime.now();
  while (DateTime.now().difference(vs).inSeconds < 30) {
    await wait(t, 200);
    if (find.byKey(const Key('video-time')).evaluate().isNotEmpty ||
        find.byKey(const Key('video-failed')).evaluate().isNotEmpty) break;
  }
  final ms = DateTime.now().difference(vs).inMilliseconds;
  await wait(t, 3000);
  final time = find.byKey(const Key('video-time'));
  print('PROBE $label after ${ms}ms failed=${find.byKey(const Key('video-failed')).evaluate().length} '
      'clock=${time.evaluate().isEmpty ? '-' : t.widget<Text>(time).data} :: ${state(t)}');
  print('PROBE ${DateTime.now().toIso8601String()} MARK $label');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('probe', (t) async {
    await app.main();
    onboarded.value = true;
    appLanguage.value = 'kk';
    await wait(t, 6000);
    await t.tap(find.byType(ListingTile).first);
    await wait(t, 6000);
    await t.tap(find.text('Видео'));
    await play(t, 'first');
    // Every colour, staying on the Видео tab: the swatch brought to the middle of the screen, then the page back to
    // its top so the stage shows.
    final page = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
    for (final id in [1, 2, 4, 6, 7, 8, 9, 10, 11, 12, 13, 3]) {
      final sw = find.byKey(Key('color-$id'));
      if (sw.evaluate().isEmpty) {
        print('PROBE no swatch $id');
        continue;
      }
      unawaited(Scrollable.ensureVisible(sw.evaluate().first, alignment: 0.5));
      await wait(t, 600);
      await t.tap(sw);
      await wait(t, 3000);
      t.state<ScrollableState>(page.first).position.jumpTo(0);
      await wait(t, 800);
      if (find.byKey(const Key('video-play')).evaluate().isEmpty &&
          find.byKey(const Key('video-time')).evaluate().isEmpty) {
        await t.tap(find.text('Видео'));
      }
      await play(t, 'colour$id');
    }
    print('PROBE DONE');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
