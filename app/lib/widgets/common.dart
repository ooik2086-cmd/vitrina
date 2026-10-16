import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../screens/listing_screen.dart';
import '../screens/login_screen.dart';

void showError(BuildContext context, Object error) {
  final text = error is ApiException ? error.messageKk : 'Байланыс жоқ. Қайта көріңіз.';
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
            child: const Text('Кіру'),
          ),
        ]),
      ),
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
    return InkWell(
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => ListingScreen(listingId: listing.id))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: cover == null
                  ? const Icon(Icons.image_outlined)
                  : Image.network(cover,
                      fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(formatTenge(listing.priceTiyn), style: theme.textTheme.titleMedium),
        Text(listing.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
        Text(label(conditions, listing.condition),
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
      ]),
    );
  }
}

class ListingGrid extends StatelessWidget {
  const ListingGrid({super.key, required this.items});
  final List<Listing> items;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220, mainAxisSpacing: 16, crossAxisSpacing: 12, childAspectRatio: 0.62),
      itemCount: items.length,
      itemBuilder: (_, i) => ListingTile(listing: items[i]),
    );
  }
}
