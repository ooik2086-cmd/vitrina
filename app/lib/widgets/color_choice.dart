import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../screens/listing_screen.dart';
import '../theme.dart';
import 'studio.dart';

/// The same model's colours in this shop as small round photos, this one ringed. Tapping another opens that
/// colour's listing in place of this one, so back still leads where the buyer came from.
class ColorSwatches extends StatelessWidget {
  const ColorSwatches({super.key, required this.listing, this.onDark = false});
  final Listing listing;

  /// Drawn on a dark stage: the ring is white.
  final bool onDark;

  static const size = 44.0;

  static void open(BuildContext context, Colorway c) {
    final thumb = c.thumbUrl;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ListingScreen(listingId: c.id, cover: thumb, coverIsCutout: c.cutout && thumb != null)));
  }

  @override
  Widget build(BuildContext context) {
    final ring = onDark ? Colors.white : Theme.of(context).colorScheme.primary;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final c in listing.colors)
          Semantics(
            button: !c.current,
            selected: c.current,
            label: c.inStock ? c.color : trf('{0}, өлшемдері таусылған', [c.color]),
            excludeSemantics: true,
            child: Tooltip(
              message: c.color,
              excludeFromSemantics: true,
              child: InkWell(
                key: Key('color-${c.id}'),
                customBorder: const CircleBorder(),
                onTap: c.current ? null : () => open(context, c),
                // 48 dp to touch, the photo inside a ring when it is this one.
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: Center(
                    child: Container(
                      width: size,
                      height: size,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: c.current ? ring : Colors.transparent, width: 2),
                      ),
                      child: Opacity(
                        opacity: c.inStock ? 1 : 0.45, // still there to look at, but nothing to order
                        child: ClipOval(
                          child: DecoratedBox(
                            decoration: const BoxDecoration(gradient: studioGradient),
                            child: c.thumbUrl == null
                                ? const SizedBox.expand()
                                : Image(
                                    image: ResizeImage.resizeIfNeeded(
                                        (size * MediaQuery.devicePixelRatioOf(context)).round(),
                                        null,
                                        NetworkImage(c.thumbUrl!)),
                                    fit: c.cutout ? BoxFit.contain : BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const SizedBox.expand(),
                                  ),
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
  }
}

/// Under the title: the shoe's colour in words, and the other colours to switch to when the shop has them.
class ColorChoice extends StatelessWidget {
  const ColorChoice({super.key, required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text.rich(
        key: const Key('color-name'),
        TextSpan(children: [
          TextSpan(text: '${tr('Түсі')}: ', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          TextSpan(text: listing.color, style: weight(theme.textTheme.bodyLarge!, 650)),
        ]),
        style: theme.textTheme.bodyLarge,
      ),
      if (listing.colors.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Transform.translate(
            offset: const Offset(-4, 0), // the first ring lines up with the text, not its touch margin
            child: ColorSwatches(listing: listing),
          ),
        ),
    ]);
  }
}
