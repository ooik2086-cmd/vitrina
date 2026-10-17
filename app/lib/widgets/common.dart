import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../labels.dart';
import '../screens/listing_screen.dart';
import '../screens/login_screen.dart';
import '../theme.dart';
import '../i18n.dart';

void showError(BuildContext context, Object error) {
  final text = error is ApiException ? error.message : tr('Байланыс жоқ. Қайта көріңіз.');
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
    builder: (context) => SafeArea(
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
      ]),
    ),
  );
  if (source == null) return null;
  return ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 90);
}

/// Қазақша / Русский. Every screen is rebuilt in the chosen language.
class LanguageSwitch extends StatelessWidget {
  const LanguageSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      key: const Key('language'),
      showSelectedIcon: false,
      segments: [for (final e in languages.entries) ButtonSegment(value: e.key, label: Text(e.value))],
      selected: {appLanguage.value},
      onSelectionChanged: (s) => setLanguage(s.first),
    );
  }
}

class ListingTile extends StatelessWidget {
  const ListingTile({super.key, required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = listing.coverUrl;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListingScreen(listingId: listing.id))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 1,
          child: Hero(
            tag: 'listing-${listing.id}',
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: Brand.studio, borderRadius: BorderRadius.circular(Brand.radius)),
              child: Stack(fit: StackFit.expand, children: [
                if (cover == null)
                  const Icon(Icons.image_outlined, color: Colors.black26)
                else
                  Image.network(cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Colors.black26)),
                if (listing.frames.isNotEmpty) const Positioned(left: 10, top: 10, child: Badge360()),
                if (listing.wasPriceTiyn != null)
                  Positioned(right: 10, top: 10, child: SaleBadge(listing: listing)),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 10),
        PriceLine(listing: listing, style: weight(theme.textTheme.titleMedium!, 750)),
        const SizedBox(height: 2),
        Text(listing.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 2),
        Text(label(conditions, listing.condition),
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
        decoration: BoxDecoration(color: Brand.accent, borderRadius: BorderRadius.circular(99)),
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
    return Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 8, children: [
      Text(formatTenge(listing.priceTiyn), style: was == null ? style : style.copyWith(color: Brand.accent)),
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

class ListingGrid extends StatelessWidget {
  const ListingGrid({super.key, required this.items, this.padding = const EdgeInsets.all(16)});
  final List<Listing> items;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 240, mainAxisSpacing: 20, crossAxisSpacing: 14, childAspectRatio: 0.64),
      itemCount: items.length,
      itemBuilder: (_, i) => ListingTile(listing: items[i]),
    );
  }
}
