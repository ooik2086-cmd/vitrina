// Every main screen and sheet, in the light and the dark theme, against the demo data: each control is big enough
// for a finger and has a name a screen reader can say, and text stands out from what is behind it.
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/screens.dart';

/// Android's 48×48 for anything a finger taps. Text that can only be selected (an address to copy) is not a control,
/// and a control cut by the edge of a list scrolled part way is whole once scrolled.
class _TapTargets extends MinimumTapTargetGuideline {
  const _TapTargets()
      : super(size: const Size(48, 48), link: 'https://support.google.com/accessibility/android/answer/7101858');

  @override
  bool shouldSkipNode(SemanticsNode node) {
    final data = node.getSemanticsData();
    final clip = node.parentPaintClipRect;
    final cut = clip != null &&
        [
          node.rect.top - clip.top,
          clip.bottom - node.rect.bottom,
          node.rect.left - clip.left,
          clip.right - node.rect.right
        ].any((gap) => gap.abs() < 0.5);
    return super.shouldSkipNode(node) ||
        cut ||
        (data.flagsCollection.isTextField && !data.hasAction(ui.SemanticsAction.tap));
  }
}

double _ratio(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (max(x, y) + 0.05) / (min(x, y) + 0.05);
}

/// Whether the text's semantics say it belongs to a switched-off control, which needs no contrast.
bool _disabled(RenderObject object) {
  for (RenderObject? o = object; o != null; o = o.parent) {
    for (SemanticsNode? n = o.debugSemantics; n != null; n = n.parent) {
      if (n.flagsCollection.isEnabled == ui.Tristate.isFalse) return true;
    }
    if (o.debugSemantics != null) return false;
  }
  return false;
}

/// WCAG AA: 4.5:1 for text, 3:1 for large text. A paragraph's colours come from its own styles, which are exact,
/// and what is behind it is the colour most of its box shows on screen, other than its own colours.
Future<void> textContrast(WidgetTester tester, List<String> errors) async {
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final pixels = await tester.runAsync(() async {
    final image = await layer.toImage(view.paintBounds, pixelRatio: 1 / view.flutterView.devicePixelRatio);
    final data = await image.toByteData();
    final size = (image.width, image.height);
    image.dispose();
    return (data!, size);
  });
  final (bytes, (width, height)) = pixels!;
  Color at(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(bytes.getUint8(i + 3), bytes.getUint8(i), bytes.getUint8(i + 1), bytes.getUint8(i + 2));
  }

  final screen = Offset.zero & Size(width.toDouble(), height.toDouble());
  for (final element in find.byType(RichText).hitTestable().evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    if (!paragraph.hasSize || paragraph.size.isEmpty || _disabled(paragraph)) continue;
    final box =
        MatrixUtils.transformRect(paragraph.getTransformTo(null), Offset.zero & paragraph.size).intersect(screen);
    if (box.width < 4 || box.height < 4) continue;
    // Each run of text with its colour and size.
    final runs = <(Color, double, bool, String)>[];
    void walk(InlineSpan span, TextStyle inherited) {
      final style = inherited.merge(span.style);
      if (span is TextSpan) {
        final text = span.text?.trim() ?? '';
        // Icons are drawn as letters of an icon font; they are pictures, not text.
        final icon = style.fontFamily?.contains('Icons') ?? false;
        if (text.isNotEmpty && !icon && style.color != null && style.foreground == null) {
          final size = paragraph.textScaler.scale(style.fontSize ?? 14);
          final bold = (style.fontWeight?.value ?? 400) >= 700;
          runs.add((style.color!, size, size >= 18 || (bold && size >= 14), text));
        }
        span.children?.forEach((c) => walk(c, style));
      }
    }

    walk(paragraph.text, const TextStyle());
    if (runs.isEmpty) continue;
    final counts = <int, int>{};
    for (var y = box.top.ceil(); y < box.bottom.floor(); y++) {
      for (var x = box.left.ceil(); x < box.right.floor(); x++) {
        final c = at(x, y);
        // Not the text itself, nor the soft edge of a letter.
        if (runs.any((r) => _close(Color.alphaBlend(r.$1, c), c) || _close(c, r.$1))) continue;
        counts.update(c.toARGB32(), (n) => n + 1, ifAbsent: () => 1);
      }
    }
    if (counts.isEmpty) continue;
    final behind = Color(counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key);
    for (final (color, size, large, text) in runs) {
      final ratio = _ratio(Color.alphaBlend(color, behind), behind);
      final need = large ? 3.0 : 4.5;
      if (ratio < need - 0.01) {
        errors.add('contrast ${ratio.toStringAsFixed(2)} < $need: "${text.length > 30 ? text.substring(0, 30) : text}" '
            '${_hex(color)} on ${_hex(behind)}, ${size.toStringAsFixed(0)}px');
      }
    }
  }
}

bool _close(Color a, Color b) =>
    (a.r - b.r).abs() * 255 < 6 && (a.g - b.g).abs() * 255 < 6 && (a.b - b.b).abs() * 255 < 6;

String _hex(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}';

/// What a screen reader and a finger need, wherever the screen is.
Future<void> look(WidgetTester tester, List<String> errors) async {
  final handle = tester.ensureSemantics();
  for (final guideline in [const _TapTargets(), labeledTapTargetGuideline]) {
    final result = await guideline.evaluate(tester);
    if (!result.passed) errors.add(result.reason!);
  }
  await textContrast(tester, errors);
  handle.dispose();
}

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
