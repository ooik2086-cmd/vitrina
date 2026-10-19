import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../labels.dart';
import '../screens/listing_screen.dart';
import '../screens/login_screen.dart';
import '../theme.dart';
import '../i18n.dart';
import 'card_turn.dart';
import 'studio.dart';

void showError(BuildContext context, Object error) {
  final text = error is ApiException ? error.message : tr('Байланыс жоқ. Қайта көріңіз.');
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// A failed load in people's words: the server's own message when it sent one, never a raw exception.
String errorText(Object? error) => error is ApiException ? error.message : tr('Серверге қосылу мүмкін болмады.');

/// Widest a screen's text column grows on a tablet or the web; phones are narrower than this anyway.
const maxContentWidth = 640.0;

/// [base] padding widened at the sides so the column, padding included, stays [maxContentWidth] wide and centred,
/// the same box [ContentWidth] draws, so capped lists, rows and chip strips line up on a wide screen.
/// For lists, so the whole screen still scrolls and only the column narrows.
EdgeInsets contentPadding(BuildContext context, EdgeInsets base) {
  final extra = (MediaQuery.sizeOf(context).width - maxContentWidth) / 2;
  return extra <= 0 ? base : base.copyWith(left: base.left + extra, right: base.right + extra);
}

/// Keeps a screen body no wider than [maxContentWidth], centred, on wide screens.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: maxContentWidth), child: child),
      );
}

/// An icon, one friendly line and an optional action: for empty lists and failed loads.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(text, style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
          if (action != null) action!,
        ]),
      ),
    );
  }
}

/// A load that failed, with a retry. Used wherever a screen has nothing to show but the error.
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.error, required this.onRetry});
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final e = error;
    return EmptyState(
      icon: e is ApiException && !e.offline ? Icons.error_outline_rounded : Icons.wifi_off_rounded,
      text: errorText(e),
      action: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextButton(key: const Key('retry'), onPressed: onRetry, child: Text(tr('Қайта көру'))),
      ),
    );
  }
}

/// Shown on tabs that need an account.
class SignInPrompt extends StatelessWidget {
  const SignInPrompt({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(text, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
            child: Text(tr('Кіру')),
          ),
        ]),
      ),
    );
  }
}

/// Camera or gallery, asked in a bottom sheet. Null when the person cancels.
Future<XFile?> pickPhoto(BuildContext context, {String? title, String? subtitle}) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (title != null) ListTile(title: Text(title), subtitle: subtitle == null ? null : Text(subtitle)),
        ListTile(
          leading: const Icon(Icons.photo_camera_outlined),
          title: Text(tr('Камера')),
          onTap: () => Navigator.pop(context, ImageSource.camera),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library_outlined),
          title: Text(tr('Галерея')),
          onTap: () => Navigator.pop(context, ImageSource.gallery),
        ),
      ])),
    ),
  );
  if (source == null) return null;
  return ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 90);
}

/// ҚАЗ / РУС / ENG, with the full name as a tooltip. Every screen is rebuilt in the chosen language.
class LanguageSwitch extends StatelessWidget {
  const LanguageSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      key: const Key('language'),
      showSelectedIcon: false,
      // Narrow, as the short names need, but a finger's 48 tall.
      style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(56, 48))),
      segments: [
        for (final e in languages.entries)
          ButtonSegment(value: e.key, label: Text(languageShort[e.key]!), tooltip: e.value),
      ],
      selected: {appLanguage.value},
      onSelectionChanged: (s) => setLanguage(s.first),
    );
  }
}

/// A listing's cover as tiles and the page opening from them draw it, so both share one decoded copy.
/// A tile is at most 240 wide; three times that covers dense screens.
ImageProvider coverImage(String url) => ResizeImage.resizeIfNeeded(720, null, NetworkImage(url));

class ListingTile extends StatelessWidget {
  const ListingTile({super.key, required this.listing, this.turns = true});
  final Listing listing;

  /// A sideways drag turns the shoe; off in a sideways list, where that drag scrolls the list.
  final bool turns;

  Widget _cover(String url) => CoverPhoto(
      image: coverImage(url),
      cutout: listing.coverIsCutout,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Colors.black26));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = listing.coverUrl;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ListingScreen(listingId: listing.id, cover: cover, coverIsCutout: listing.coverIsCutout))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 1,
          // The card stays put; only the shoe flies into the listing page and back.
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: studioBackdrop(radius: BorderRadius.circular(Brand.radius)),
            child: Stack(fit: StackFit.expand, children: [
              Hero(
                tag: 'listing-${listing.id}',
                child: switch (cover) {
                  null => const Icon(Icons.image_outlined, color: Colors.black26),
                  final cover when !turns => _cover(cover),
                  final cover => CardTurn(listing: listing, cover: _cover(cover)),
                },
              ),
              // The badges let a drag that starts on them turn the shoe underneath.
              if (listing.frames.isNotEmpty)
                const Positioned(left: 10, top: 10, child: IgnorePointer(child: Badge360())),
              if (listing.wasPriceTiyn != null)
                Positioned(right: 10, top: 10, child: IgnorePointer(child: SaleBadge(listing: listing))),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        PriceLine(listing: listing, style: weight(theme.textTheme.titleMedium!, 750)),
        const SizedBox(height: 2),
        Text(listing.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 2),
        Text(label(conditions, listing.condition),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

int salePercent(Listing l) => ((1 - l.priceTiyn / l.wasPriceTiyn!) * 100).round();

/// "−20%" on an accent pill, for listings whose price was really cut.
class SaleBadge extends StatelessWidget {
  const SaleBadge({super.key, required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: Brand.accentStrong, borderRadius: BorderRadius.circular(99)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          child: Text('−${salePercent(listing)}%',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
        ),
      );
}

/// The price, and during a sale the old one crossed out beside it.
class PriceLine extends StatelessWidget {
  const PriceLine({super.key, required this.listing, required this.style});
  final Listing listing;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final was = listing.wasPriceTiyn;
    // A price is never broken over lines: with large text in a narrow tile it shrinks to fit instead.
    return Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 8, children: [
      FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(formatTenge(listing.priceTiyn),
              style: was == null ? style : style.copyWith(color: accentText(context)))),
      if (was != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(formatTenge(was),
              key: const Key('was-price'),
              style: TextStyle(
                  fontSize: (style.fontSize ?? 16) * 0.7,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  decoration: TextDecoration.lineThrough)),
        ),
    ]);
  }
}

class Badge360 extends StatelessWidget {
  const Badge360({super.key, this.dark = false});
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.white : Brand.ink;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? Colors.black.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.threesixty, size: 14, color: fg),
          const SizedBox(width: 4),
          Text('360°', style: weight(Theme.of(context).textTheme.labelSmall!, 700).copyWith(color: fg)),
        ]),
      ),
    );
  }
}

/// Height of the lines under a [ListingTile]'s photo at the current text size: price, two title lines, condition.
double listingTileTextExtent(BuildContext context) {
  final t = Theme.of(context).textTheme;
  final scaler = MediaQuery.textScalerOf(context);
  double line(TextStyle? s, double size, double height) => scaler.scale(s?.fontSize ?? size) * (s?.height ?? height);
  final price = line(t.titleMedium, 16, 1.5);
  // With large text a sale price and the crossed-out one no longer fit side by side.
  final priceLines = scaler.scale(16) > 20 ? 2 : 1;
  return 10 + price * priceLines + 2 + 2 * line(t.bodyMedium, 14, 1.43) + 2 + line(t.labelMedium, 12, 1.33) + 4;
}

/// Listing tiles up to 240 wide, each row as tall as a square photo plus the lines under it at the current text
/// size, so large text never makes one tile run into the next (a fixed aspect ratio did).
class ListingGridDelegate extends SliverGridDelegate {
  const ListingGridDelegate({required this.textExtent, this.mainAxisSpacing = 22, this.crossAxisSpacing = 14});
  ListingGridDelegate.of(BuildContext context, {double mainAxisSpacing = 22})
      : this(textExtent: listingTileTextExtent(context), mainAxisSpacing: mainAxisSpacing);

  static const maxCrossAxisExtent = 240.0;
  final double textExtent;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final across = constraints.crossAxisExtent;
    final count = max(1, ((across + crossAxisSpacing) / (maxCrossAxisExtent + crossAxisSpacing)).ceil());
    final width = max(0.0, (across - crossAxisSpacing * (count - 1)) / count);
    return SliverGridRegularTileLayout(
      crossAxisCount: count,
      mainAxisStride: width + textExtent + mainAxisSpacing,
      crossAxisStride: width + crossAxisSpacing,
      childMainAxisExtent: width + textExtent,
      childCrossAxisExtent: width,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(ListingGridDelegate oldDelegate) =>
      oldDelegate.textExtent != textExtent ||
      oldDelegate.mainAxisSpacing != mainAxisSpacing ||
      oldDelegate.crossAxisSpacing != crossAxisSpacing;
}

class ListingGrid extends StatelessWidget {
  const ListingGrid({super.key, required this.items, this.padding = const EdgeInsets.all(16)});
  final List<Listing> items;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      gridDelegate: ListingGridDelegate.of(context, mainAxisSpacing: 20),
      itemCount: items.length,
      itemBuilder: (_, i) => ListingTile(listing: items[i]),
    );
  }
}

/// Asks before an action that cannot be taken back; true only when the person pressed [action].
Future<bool> confirmAction(BuildContext context,
    {required String title, required String action, bool destructive = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Болдырмау'))),
        FilledButton(
          key: const Key('confirm-action'),
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}
