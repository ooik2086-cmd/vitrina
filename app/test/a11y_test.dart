// Every main screen and sheet, in the light and the dark theme, against the demo data: each control is big enough
// for a finger and has a name a screen reader can say, and text stands out from what is behind it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/a11y.dart';
import 'support/screens.dart';

void main() {
  const size = Size(360, 720);
  for (final brightness in Brightness.values) {
    for (final e in screens.entries) {
      testWidgets('${e.key} can be used by touch and by ear (${brightness.name})', (tester) async {
        expect(await visit(tester, 'kk', size, 1, e.value, brightness: brightness, look: look), isEmpty);
      });
    }
    for (final e in sheets.entries) {
      testWidgets('the ${e.key} sheet can be used by touch and by ear (${brightness.name})', (tester) async {
        expect(
            await visit(tester, 'kk', size, 1, () => const SizedBox(),
                sheet: e.value(), brightness: brightness, look: look),
            isEmpty);
      });
    }
  }
}
