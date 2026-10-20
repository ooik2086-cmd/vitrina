// Seller and shop pages on a usual phone, at the usual text size and a size up: no words are cut short with «…»
// where they tell things apart (field labels, the colour at the end of a title, a pair's condition).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/screens.dart';

/// Text cut short on screen, but not a page title (it fades out by design) or a chat's last message (a preview).
List<String> cutShort(WidgetTester tester) => [
      for (final e in find.byType(RichText).evaluate())
        if ((e.renderObject! as RenderParagraph).didExceedMaxLines && e.findAncestorWidgetOfExactType<AppBar>() == null)
          (e.widget as RichText).text.toPlainText(),
    ];

void main() {
  const pages = ['manage', 'my-listings', 'sales', 'orders', 'offers', 'earnings', 'analytics', 'catalog', 'shop1'];
  for (final (lang, scale) in [('kk', 1.0), ('ru', 1.0), ('kk', 1.15), ('kk', 1.3), ('ru', 1.3)]) {
    for (final name in pages) {
      testWidgets('$name keeps its words whole at 360 wide, text ×$scale ($lang)', (tester) async {
        var cut = <String>[];
        final errors = await visit(tester, lang, const Size(360, 2400), scale, screens[name]!,
            check: (tester) async => cut = cutShort(tester));
        expect(errors, isEmpty);
        expect(cut, isEmpty);
      });
    }
  }
}
