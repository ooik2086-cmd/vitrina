// Every main screen and sheet opened with the connection down: it says so and offers to try again, and once the
// connection is back «Try again» brings the screen as it should be. The error states are checked as the screens
// are: for a finger, a screen reader and weak eyes, and on a small phone with large text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/a11y.dart';
import 'support/screens.dart';

void main() {
  for (final (size, scale) in [(const Size(360, 720), 1.0), (const Size(320, 640), 2.0)]) {
    final setup = '${size.width.round()} wide, text ×$scale';
    for (final e in screens.entries) {
      testWidgets('${e.key} copes with no connection ($setup)', (tester) async {
        expect(await visit(tester, 'kk', size, scale, e.value, offline: true, look: scale == 1 ? look : null), isEmpty);
      });
    }
    for (final e in sheets.entries) {
      testWidgets('the ${e.key} sheet copes with no connection ($setup)', (tester) async {
        expect(
            await visit(tester, 'kk', size, scale, () => const SizedBox(),
                sheet: e.value(), offline: true, look: scale == 1 ? look : null),
            isEmpty);
      });
    }
  }
}
