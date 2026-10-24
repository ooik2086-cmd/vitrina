// Aza, 2026-10-24: on a phone whose own buttons draw over the app, a sheet's last button sat under them and could not
// be pressed. Every sheet keeps its content above them.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/widgets/common.dart';
import 'package:vitrina/widgets/listing_lines.dart';

void main() {
  const bar = 48.0; // the phone's own buttons at the bottom of the screen

  Future<void> open(WidgetTester tester, void Function(BuildContext) show) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: bar);
    tester.view.viewPadding = const FakeViewPadding(bottom: bar);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) =>
                Scaffold(body: Center(child: TextButton(onPressed: () => show(context), child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  var presses = 0;
  Widget last() => FilledButton(key: const Key('last'), onPressed: () => presses++, child: const Text('Сұрақ қою'));

  Future<void> pressLast(WidgetTester tester) async {
    presses = 0;
    expect(tester.getRect(find.byKey(const Key('last'))).bottom, lessThanOrEqualTo(640 - bar));
    await tester.tap(find.byKey(const Key('last')), warnIfMissed: false);
    expect(presses, 1);
  }

  testWidgets('a short sheet ends above the phone\'s buttons', (tester) async {
    await open(tester, (context) => showSheet<void>(context: context, builder: (_) => last()));
    await pressLast(tester);
  });

  testWidgets('a long page sheet scrolls its last button above the phone\'s buttons', (tester) async {
    await open(
        tester,
        (context) => showPageSheet<void>(context,
            title: 'Сұрақтар',
            builder: (_) => Column(children: [for (var i = 0; i < 40; i++) Text('Сұрақ $i'), last()])));
    await tester.drag(find.text('Сұрақ 3'), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(find.byType(Scrollable).last).position.pixels, greaterThan(0));
    await pressLast(tester);
  });

  test('every sheet in the app opens through showSheet, so none can sit under the phone\'s buttons again', () {
    final raw = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') &&
            !f.path.endsWith('common.dart') &&
            f.readAsStringSync().contains('showModalBottomSheet'))
          f.path
    ];
    expect(raw, isEmpty);
  });
}
