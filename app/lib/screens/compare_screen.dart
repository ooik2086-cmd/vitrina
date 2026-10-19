import 'package:flutter/material.dart';

import '../api.dart';
import '../colors.dart';
import '../i18n.dart';
import '../labels.dart';
import '../my_size.dart';
import '../theme.dart';
import '../widgets/card_turn.dart';
import '../widgets/common.dart';
import '../widgets/studio.dart';
import 'listing_screen.dart';

/// Up to this many listings side by side; a fourth column no longer fits a phone.
const maxCompared = 3;

/// What the buyer actually pays for each listing: the price plus its delivery.
int totalTiyn(Listing l) => l.priceTiyn + l.deliveryPriceTiyn;

/// Ids of the listings with the lowest total. Ties all win; nothing is marked when there is one listing.
Set<int> cheapestIds(List<Listing> items) {
  if (items.length < 2) return {};
  final low = items.map(totalTiyn).reduce((a, b) => a < b ? a : b);
  if (items.every((l) => totalTiyn(l) == low)) return {};
  return {
    for (final l in items)
      if (totalTiyn(l) == low) l.id
  };
}

/// Favourites side by side: price with delivery, condition, authenticity, the buyer's size, 360° and the seller.
class CompareScreen extends StatefulWidget {
  const CompareScreen({super.key, required this.items});
  final List<Listing> items;

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  late final List<int> _picked = [for (final l in widget.items.take(2)) l.id];

  /// The compared shoes turn as one, so their shapes can be compared from every side.
  final _together = TurnTogether();

  @override
  void dispose() {
    _together.dispose();
    super.dispose();
  }

  void _toggle(Listing l) {
    setState(() {
      if (_picked.contains(l.id)) {
        _picked.remove(l.id);
      } else if (_picked.length < maxCompared) {
        _picked.add(l.id);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(trf('Бір уақытта ең көбі {0} тауарды салыстыруға болады.', [maxCompared]))));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = [
      for (final id in _picked) ...widget.items.where((l) => l.id == id),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Салыстыру'))),
      body: ListView(padding: contentPadding(context, const EdgeInsets.fromLTRB(16, 4, 16, 32)), children: [
        Text(trf('Таңдаулылардан {0} тауарға дейін таңдаңыз', [maxCompared]),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        SizedBox(
          height: 76,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: widget.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) => _Pick(
              listing: widget.items[i],
              picked: _picked.contains(widget.items[i].id),
              onTap: () => _toggle(widget.items[i]),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (shown.length < 2)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Text(tr('Салыстыру үшін кемінде екі тауар таңдаңыз.'),
                textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
          )
        else
          _Table(items: shown, together: _together),
      ]),
    );
  }
}

class _Pick extends StatelessWidget {
  const _Pick({required this.listing, required this.picked, required this.onTap});
  final Listing listing;
  final bool picked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = listing.coverUrl;
    return GestureDetector(
      key: Key('compare-pick-${listing.id}'),
      onTap: onTap,
      child: Container(
        width: 76,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          gradient: studioGradient,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: picked ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 2),
        ),
        child: Stack(fit: StackFit.expand, children: [
          if (cover != null) Image.network(cover, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox()),
          if (picked)
            Positioned(
              right: 4,
              top: 4,
              child: CircleAvatar(
                radius: 10,
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: Icon(Icons.check_rounded, size: 14, color: Theme.of(context).colorScheme.onPrimary),
              ),
            ),
        ]),
      ),
    );
  }
}

class _Table extends StatelessWidget {
  const _Table({required this.items, required this.together});
  final List<Listing> items;
  final TurnTogether together;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cheapest = cheapestIds(items);
    final strong = weight(theme.textTheme.bodyMedium!, 700);
    return ValueListenableBuilder<String?>(
      valueListenable: mySize,
      builder: (context, size, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Row(items: items, cell: (l) => _Head(listing: l, together: together)),
        if (items.where((l) => CardTurn.framesOf(l).isNotEmpty).length > 1)
          // The turn is a gesture only; screen readers compare on the listing pages.
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(tr('Бір аяқкиімді көлденең сүйресеңіз, 360° барлары бірге айналады'),
                  key: const Key('compare-turn-hint'),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ),
        _Row(
          label: tr('Барлығы, жеткізумен'),
          items: items,
          cell: (l) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(formatTenge(totalTiyn(l)), key: Key('compare-total-${l.id}'), style: strong),
            if (cheapest.contains(l.id))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(tr('Ең тиімді'),
                    key: Key('compare-cheapest-${l.id}'),
                    style: theme.textTheme.labelSmall?.copyWith(color: Brand.accent, fontWeight: FontWeight.w800)),
              ),
          ]),
        ),
        _Row(
          label: tr('Бағасы'),
          items: items,
          cell: (l) => PriceLine(listing: l, style: theme.textTheme.bodyMedium!),
        ),
        _Row(
          label: tr('Жеткізу'),
          items: items,
          cell: (l) => Text(l.deliveryPriceTiyn == 0 ? tr('Тегін') : formatTenge(l.deliveryPriceTiyn)),
        ),
        _Row(label: tr('Жағдайы'), items: items, cell: (l) => Text(label(conditions, l.condition))),
        _Row(label: tr('Түпнұсқалығы'), items: items, cell: (l) => Text(label(authenticity, l.authenticity))),
        _Row(label: tr('Бренд'), items: items, cell: (l) => Text(l.brand ?? '—')),
        _Row(label: tr('Түсі'), items: items, cell: (l) => Text(colorName(l.color))),
        _Row(
          label: size == null ? tr('Бар өлшемдер') : trf('Сіздің өлшеміңіз ({0} см)', [size]),
          items: items,
          cell: (l) {
            if (size == null) {
              final open = [
                for (final s in l.sizes)
                  if (s.available) s.label
              ];
              return Text(open.isEmpty ? tr('Таусылды') : open.join(', '));
            }
            final fit = bestFit(l.sizes, size);
            return Row(children: [
              Icon(fit == null ? Icons.close_rounded : Icons.check_rounded,
                  size: 18, color: fit == null ? theme.colorScheme.error : const Color(0xFF1E8E3E)),
              const SizedBox(width: 4),
              Flexible(child: Text(fit == null ? tr('Жоқ') : fit.label)),
            ]);
          },
        ),
        _Row(
          label: tr('360° витрина'),
          items: items,
          cell: (l) =>
              l.frames.isEmpty ? const Text('—') : const Align(alignment: Alignment.centerLeft, child: Badge360()),
        ),
        _Row(
          label: tr('Сатушы'),
          items: items,
          cell: (l) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.shopName ?? '—', maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(
              [
                if (l.sellerRating != null) '★ ${l.sellerRating!.toStringAsFixed(1)}',
                if (l.sellerCity != null) l.sellerCity!,
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Head extends StatelessWidget {
  const _Head({required this.listing, required this.together});
  final Listing listing;
  final TurnTogether together;

  @override
  Widget build(BuildContext context) {
    final cover = listing.coverUrl;
    return GestureDetector(
      key: Key('compare-open-${listing.id}'),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListingScreen(listingId: listing.id))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 1,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: studioBackdrop(radius: BorderRadius.circular(14)),
            child: cover == null
                ? const Icon(Icons.image_outlined, color: Colors.black26)
                : CardTurn(
                    listing: listing,
                    together: together,
                    cover: CoverPhoto(
                        image: coverImage(cover),
                        cutout: listing.coverIsCutout,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Colors.black26)),
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Text(listing.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

/// One fact for every listing: the label on its own line, then a cell per column.
class _Row extends StatelessWidget {
  const _Row({this.label, required this.items, required this.cell});
  final String? label;
  final List<Listing> items;
  final Widget Function(Listing) cell;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: label == null
          ? null
          : BoxDecoration(border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (label != null) ...[
          Text(label!, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            // Keyed, so a shoe keeps its own state when another is picked or removed.
            Expanded(key: ValueKey(items[i].id), child: cell(items[i])),
          ],
        ]),
      ]),
    );
  }
}
