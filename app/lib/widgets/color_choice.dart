import 'package:flutter/material.dart';

import '../net_image.dart';
import '../api.dart';
import '../colors.dart';
import '../i18n.dart';
import '../labels.dart';
import '../theme.dart';
import 'studio.dart';

/// The same model's colours in this shop as small round photos in one calm row, this one ringed, always in the same
/// order whichever colour is open; room for ten and more: the row scrolls sideways and fades out at its right edge to
/// show there are more. A sold-out colour is struck through, and still opens: the buyer can look and ask to be told.
class ColorSwatches extends StatelessWidget {
  const ColorSwatches(
      {super.key,
      required this.colors,
      required this.ring,
      required this.edge,
      required this.onPick,
      this.gap,
      this.pending});
  final List<Colorway> colors;

  /// A colour picked and still on its way: the ring moves to it at once, with a small turning arc.
  final int? pending;

  /// The ring around the colour shown, and the thin edge of the others: from the page they sit on.
  final Color ring;
  final Color edge;

  /// The page's colour, between the shown colour's photo and its ring.
  final Color? gap;
  final ValueChanged<Colorway> onPick;

  /// The photo's size, and the round place around it a finger taps (as Aza set them, 2026-10-22).
  static const size = 34.0;
  static const target = 44.0;

  /// How wide the row's right edge fades out.
  static const fade = 40.0;

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
      child: LayoutBuilder(builder: (context, box) {
        final row = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // The last colour can come out of the fade.
          padding: const EdgeInsets.only(right: fade - 16),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final (i, c) in colors.indexed)
              if ((pending == null ? c.current : c.id == pending, c.id == pending) case (final ringed, final coming))
                Padding(
                  padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
                  child: Semantics(
                    button: !c.current,
                    selected: c.current,
                    // While it comes, a screen reader says so at once rather than leaving the wait silent; short, as
                    // the page is replaced within a second and would cut a longer one off.
                    liveRegion: coming,
                    label: coming ? trf('{0}: ашылуда', [colorName(c.color)]) : describe(c),
                    onTap: c.current ? null : () => onPick(c),
                    excludeSemantics: true,
                    child: Tooltip(
                      message: describe(c),
                      excludeFromSemantics: true,
                      child: InkWell(
                        key: Key('color-${c.id}'),
                        customBorder: const CircleBorder(),
                        onTap: c.current ? null : () => onPick(c),
                        child: SizedBox(
                          width: target,
                          height: target,
                          child: Center(
                            child: Container(
                              key: Key('color-ring-${c.id}'),
                              width: size + 7,
                              height: size + 7,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                // The shown colour: the page's colour, then a dark ring, as on the approved demo.
                                border: ringed ? Border.all(color: ring, width: 1.5) : null,
                              ),
                              padding: EdgeInsets.all(ringed ? 2 : 3.5),
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: gap,
                                  border: ringed ? null : Border.all(color: edge),
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
                                                image: ResizeImage(netImage(c.thumbUrl!),
                                                    width: side, height: side, policy: ResizeImagePolicy.fit),
                                                fit: c.cutout ? BoxFit.contain : BoxFit.cover,
                                                errorBuilder: (_, __, ___) => const SizedBox.expand(),
                                              ),
                                            ),
                                    ),
                                    if (!c.inStock)
                                      CustomPaint(key: Key('color-sold-out-${c.id}'), painter: _Strike(ring)),
                                    if (coming)
                                      CircularProgressIndicator(
                                          key: Key('color-coming-${c.id}'), strokeWidth: 2, color: ring),
                                  ]),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
          ]),
        );
        // Faded only where the row runs past the page's edge.
        final wide = colors.length * (target + 4) > box.maxWidth;
        if (!wide || !box.maxWidth.isFinite) return row;
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            colors: const [Colors.black, Colors.black, Colors.transparent],
            stops: [0, (rect.width - fade) / rect.width, 1],
          ).createShader(rect),
          child: row,
        );
      }),
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
  const ColorChoice({super.key, required this.listing, required this.onPick, this.pending});
  final Listing listing;
  final ValueChanged<Colorway> onPick;

  /// A colour picked and on its way (see [ColorSwatches.pending]).
  final int? pending;

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
            offset: const Offset(-5, 0), // the first picture lines up with the text, not its touch margin
            child: ColorSwatches(
              colors: listing.colors,
              ring: theme.colorScheme.onSurface,
              edge: theme.colorScheme.outlineVariant,
              gap: theme.scaffoldBackgroundColor,
              pending: pending,
              onPick: onPick,
            ),
          ),
        ),
    ]);
  }
}
