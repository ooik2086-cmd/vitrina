// What a finger, a screen reader and weak eyes need from whatever is on screen, for the tests that walk the screens.
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/theme.dart';

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
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    if (!paragraph.hasSize || paragraph.size.isEmpty || _disabled(paragraph)) continue;
    final box =
        MatrixUtils.transformRect(paragraph.getTransformTo(null), Offset.zero & paragraph.size).intersect(screen);
    if (box.width < 4 || box.height < 4 || !_onTop(tester, paragraph, box.center)) continue;
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
    // Pixels by shade, so the paper's fine grain counts as one colour; each shade keeps its pixels' average.
    final counts = <int, List<int>>{}, all = <int, List<int>>{};
    void count(Map<int, List<int>> m, Color c) {
      final r = (c.r * 255).round(), g = (c.g * 255).round(), b = (c.b * 255).round();
      final sums = m.putIfAbsent((r >> 3) << 10 | (g >> 3) << 5 | b >> 3, () => [0, 0, 0, 0]);
      sums[0]++;
      sums[1] += r;
      sums[2] += g;
      sums[3] += b;
    }

    for (var y = box.top.ceil(); y < box.bottom.floor(); y++) {
      for (var x = box.left.ceil(); x < box.right.floor(); x++) {
        final c = at(x, y);
        count(all, c);
        // Not the text itself, nor the soft edge of a letter.
        if (runs.any((r) => _close(Color.alphaBlend(r.$1, c), c) || _close(c, r.$1))) continue;
        count(counts, c);
      }
    }
    List<int> most(Map<int, List<int>> m) => m.values.reduce((a, b) => a[0] >= b[0] ? a : b);
    // What is behind fills much of a text's box. When hardly anything is left once the text's own colour is taken
    // out, the background is about the text's colour, and the text hardly shows.
    final pixels = all.values.fold(0, (n, s) => n + s[0]);
    final shade = counts.isNotEmpty && most(counts)[0] * 10 >= pixels ? most(counts) : most(all);
    final behind = Color.fromARGB(255, shade[1] ~/ shade[0], shade[2] ~/ shade[0], shade[3] ~/ shade[0]);
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

/// Whether [paragraph] is what a person sees at [point], not text under a sheet or a dimmed backdrop. Text a finger
/// passes through (a badge on a photo) counts when the hit lands in the box it is drawn on.
bool _onTop(WidgetTester tester, RenderObject paragraph, Offset point) {
  RenderObject target = paragraph;
  for (RenderObject? o = paragraph; o != null; o = o.parent) {
    if ((o is RenderIgnorePointer && o.ignoring) || (o is RenderAbsorbPointer && o.absorbing)) target = o.parent!;
  }
  final result = HitTestResult();
  tester.binding.hitTestInView(result, point, tester.view.viewId);
  return result.path.any((entry) => entry.target == target);
}

bool _close(Color a, Color b) =>
    (a.r - b.r).abs() * 255 < 6 && (a.g - b.g).abs() * 255 < 6 && (a.b - b.b).abs() * 255 < 6;

String _hex(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}';

final _letter = RegExp(r'[\p{L}\p{N}₸%]', unicode: true); // words, numbers and prices; icons are glyphs of their own

/// Every word in the app's own font, at the weight it asks for: a style that names no family falls back to the
/// phone's, and on the variable font a bare fontWeight is ignored while the inherited 'wght' setting stays.
void oneFont(List<String> errors) {
  void check(String text, TextStyle? style) {
    if (!_letter.hasMatch(text)) return;
    final short = text.length > 30 ? text.substring(0, 30) : text;
    if (style?.fontFamily != appFont) errors.add('font ${style?.fontFamily}: "$short"');
    final wght = style?.fontVariations?.where((v) => v.axis == 'wght').firstOrNull?.value;
    final asked = style?.fontWeight?.value;
    if (wght != null && asked != null && (wght / 100).round() * 100 != asked) {
      errors.add('weight $asked drawn at ${wght.round()}: "$short"');
    }
  }

  void walk(InlineSpan span, TextStyle? inherited) {
    final style = inherited?.merge(span.style) ?? span.style;
    if (span is! TextSpan) return;
    check(span.text ?? '', style);
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  for (final element in find.byType(RichText).evaluate()) {
    walk((element.widget as RichText).text, null);
  }
  // Fields and selectable text draw through EditableText, not RichText.
  for (final element in find.byType(EditableText).evaluate()) {
    final field = element.widget as EditableText;
    check(field.controller.text, field.style);
  }
}

/// What a screen reader and a finger need, wherever the screen is.
Future<void> look(WidgetTester tester, List<String> errors) async {
  final handle = tester.ensureSemantics();
  for (final guideline in [const _TapTargets(), labeledTapTargetGuideline]) {
    final result = await guideline.evaluate(tester);
    if (!result.passed) errors.add(result.reason!);
  }
  await textContrast(tester, errors);
  oneFont(errors);
  handle.dispose();
}
