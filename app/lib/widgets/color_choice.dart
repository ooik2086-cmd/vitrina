import 'package:flutter/material.dart';

import '../api.dart';
import '../colors.dart';
import '../i18n.dart';
import '../labels.dart';
import '../theme.dart';
import 'studio.dart';

/// The same model's colours in this shop as small round photos, this one ringed, always in the same order whichever
/// colour is open. A sold-out colour is struck through, and still opens: the buyer can look and ask to be told.
class ColorSwatches extends StatelessWidget {
  const ColorSwatches({super.key, required this.colors, required this.ring, required this.edge, required this.onPick});
  final List<Colorway> colors;

  /// The ring around the colour shown, and the thin edge of the others: from the stage or the page they sit on.
  final Color ring;
  final Color edge;
  final ValueChanged<Colorway> onPick;

  static const size = 44.0;

  /// What a swatch says when touched and long-pressed: the colour, its price, and that it is sold out.
  static String describe(Colorway c) {
    final named = '${colorName(c.color)}, ${formatTenge(c.priceTiyn)}';
    return c.inStock ? named : trf('{0}, өлшемдері таусылған', [named]);
  }

  @override
  Widget build(BuildContext context) {
    final side = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: tr('Басқа түстер'),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final c in colors)
            Semantics(
              button: !c.current,
              selected: c.current,
              label: describe(c),
              onTap: c.current ? null : () => onPick(c),
              excludeSemantics: true,
              child: Tooltip(
                message: describe(c),
                excludeFromSemantics: true,
                child: InkWell(
                  key: Key('color-${c.id}'),
                  customBorder: const CircleBorder(),
                  onTap: c.current ? null : () => onPick(c),
                  // 48 dp to touch, as the round buttons beside them; the photo inside a ring when it is this one.
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Container(
                        key: Key('color-ring-${c.id}'),
                        width: size,
                        height: size,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: c.current ? ring : edge, width: c.current ? 2 : 1),
                        ),
                        child: ClipOval(
                          child: Stack(fit: StackFit.expand, children: [
                            DecoratedBox(
                              decoration: const BoxDecoration(gradient: studioGradient),
                              child: c.thumbUrl == null
                                  ? null
                                  : Opacity(
                                      opacity: c.inStock ? 1 : 0.5,
                                      child: Image(
                                        image: ResizeImage(NetworkImage(c.thumbUrl!),
                                            width: side, height: side, policy: ResizeImagePolicy.fit),
                                        fit: c.cutout ? BoxFit.contain : BoxFit.cover,
                                        errorBuilder: (_, __, ___) => const SizedBox.expand(),
                                      ),
                                    ),
                            ),
                            if (!c.inStock) CustomPaint(key: Key('color-sold-out-${c.id}'), painter: _Strike(ring)),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// One line across a sold-out colour, as a crossed-out item on a shop shelf label.
class _Strike extends CustomPainter {
  const _Strike(this.colour);
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
        Offset(size.width * 0.15, size.height * 0.85),
        Offset(size.width * 0.85, size.height * 0.15),
        Paint()
          ..color = colour
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_Strike old) => old.colour != colour;
}

/// Under the title: the shoe's colour in words, and the other colours to switch to when the shop has them.
class ColorChoice extends StatelessWidget {
  const ColorChoice({super.key, required this.listing, required this.onPick});
  final Listing listing;
  final ValueChanged<Colorway> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text.rich(
        key: const Key('color-name'),
        TextSpan(children: [
          TextSpan(text: '${tr('Түсі')}: ', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          TextSpan(text: colorName(listing.color), style: weight(theme.textTheme.bodyLarge!, 650)),
        ]),
        style: theme.textTheme.bodyLarge,
      ),
      if (listing.colors.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Transform.translate(
            offset: const Offset(-2, 0), // the first ring lines up with the text, not its touch margin
            child: ColorSwatches(
              colors: listing.colors,
              ring: theme.colorScheme.primary,
              edge: theme.colorScheme.outlineVariant,
              onPick: onPick,
            ),
          ),
        ),
    ]);
  }
}
