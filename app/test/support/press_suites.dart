// The press suites: every button on every main screen and sheet pressed with the connection down, and pressed twice
// on a slow connection. Shared out over several test files (test/presses_*_test.dart), as each run of presses grows
// the test process's memory; a file's process ends, and gives it back, when its part is done.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'press.dart';
import 'screens.dart';

/// Requests whose failure is rightly quiet: hints a page works without, fetched on the side of what was pressed.
const _hints = [
  '/me/todo', // the count on the profile tab; the profile itself says when it cannot load
  '/delivery-estimate', // the arrival guess under the price; a city the buyer picks is said when it fails
  // Whether online payment is on: unknown counts as on and is asked again, and the server refuses an order itself.
  '/app-config',
  // Signing out: the phone has already signed out; the server ends that sign-in when it is reached, and offline
  // Firebase forgets the phone, so no alert of the account arrives (session.dart signOut).
  '/auth/logout',
];

/// Presses everything with the connection down: whatever it tries to send or fetch is said, and nothing keeps spinning.
Future<List<String>> pressAll(WidgetTester tester, Widget Function() screen, {Widget? sheet}) =>
    forEveryPress(tester, screen, sheet, (label, line, popups, at, errors) async {
      line.down = true;
      final dropped = line.dropped.length;
      await tester.tapAt(at);
      for (var j = 0; j < 10; j++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      final sent = line.dropped.skip(dropped).where((r) => !_hints.any(r.contains)).toSet();
      bool told() =>
          find.textContaining('Байланыс жоқ').evaluate().isNotEmpty ||
          find.byKey(const Key('retry')).evaluate().isNotEmpty;
      // What is said may be further down the page the press opened.
      for (var k = 0; k < 8 && sent.isNotEmpty && !told(); k++) {
        if (!await scrollOn(tester)) break;
      }
      if (sent.isNotEmpty && !told()) {
        errors.add('"$label": nothing says the connection is down (${sent.join(', ')})');
      }
      if (find.byType(CircularProgressIndicator).hitTestable().evaluate().isNotEmpty) {
        errors.add('"$label": still spinning');
      }
    });

Future<List<String>> pressTwice(WidgetTester tester, Widget Function() screen, {Widget? sheet}) =>
    forEveryPress(tester, screen, sheet, (label, line, popups, at, errors) async {
      final slow = Completer<void>();
      line.slow = slow.future;
      final from = line.overlaps.length;
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 150));
      slow.complete();
      line.slow = null;
      await settle(tester);
      // Till everything settles: a change can follow a read the slow line held.
      if (line.overlaps.length > from) {
        errors.add('"$label": sent twice (${line.overlaps.skip(from).toSet().join(', ')})');
      }
      if (popups.opened > 1) errors.add('"$label": opened twice (${popups.opened} dialogs or sheets)');
      if (popups.pages > 1) errors.add('"$label": opened twice (${popups.pages} pages)');
    });

/// Part [part] of [parts] of the screens and sheets, each pressed offline and pressed twice.
void pressSuites(int part, int parts) {
  final all = [
    for (final e in screens.entries) (e.key, e.value, null as Widget Function()?),
    for (final e in sheets.entries) ('the ${e.key} sheet', () => const SizedBox() as Widget, e.value),
  ];
  for (var i = part; i < all.length; i += parts) {
    final (name, screen, sheet) = all[i];
    testWidgets('every button on $name copes with no connection', (tester) async {
      expect(await pressAll(tester, screen, sheet: sheet?.call()), isEmpty);
    });
    testWidgets('every button on $name copes with a double tap', (tester) async {
      expect(await pressTwice(tester, screen, sheet: sheet?.call()), isEmpty);
    });
  }
}
