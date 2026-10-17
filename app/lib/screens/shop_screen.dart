import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'seller_reviews_screen.dart';
import '../i18n.dart';

const _months = ['қаң', 'ақп', 'нау', 'сәу', 'мам', 'мау', 'шіл', 'там', 'қыр', 'қаз', 'қар', 'жел'];

/// A seller's shop: who they are, what the platform knows about them, and everything they sell now.
class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key, required this.sellerId});
  final int sellerId;

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  Future<(Shop, List<Listing>)>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= _load();
  }

  Future<(Shop, List<Listing>)> _load() async {
    final api = SessionScope.of(context).api;
    final (shop, items) = await (api.shop(widget.sellerId), api.search(sellerId: widget.sellerId, limit: 50)).wait;
    return (shop, items);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Дүкен'))),
      body: FutureBuilder<(Shop, List<Listing>)>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final (shop, items) = snap.data!;
          return CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: Brand.ink,
                      foregroundColor: Colors.white,
                      child: Text(shop.shopName.characters.first.toUpperCase(),
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(shop.shopName, style: theme.textTheme.titleLarge),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (shop.city != null) shop.city!,
                            trf('VITRINA-да {0} {1} бастап', [tr(_months[shop.since.month - 1]), shop.since.year]),
                          ].join(' · '),
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 20),
                  Row(children: [
                    _Fact(
                      value: shop.rating?.toStringAsFixed(1) ?? '—',
                      label: trf('{0} пікір', [shop.reviews]),
                      icon: Icons.star_rounded,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) =>
                              SellerReviewsScreen(sellerId: shop.id, shopName: shop.shopName, rating: shop.rating))),
                    ),
                    const SizedBox(width: 10),
                    _Fact(value: '${shop.completedSales}', label: tr('сатылым'), icon: Icons.verified_outlined),
                    const SizedBox(width: 10),
                    _Fact(value: '${shop.listings}', label: tr('тауар'), icon: Icons.inventory_2_outlined),
                  ]),
                  const SizedBox(height: 8),
                  Text(tr('Сатылым саны тек аяқталған, VITRINA арқылы төленген тапсырыстардан саналады.'),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ),
            ),
            if (items.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: Center(child: Text(tr('Қазір сатылымда тауар жоқ.'))))
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 240, mainAxisSpacing: 22, crossAxisSpacing: 14, childAspectRatio: 0.64),
                  itemCount: items.length,
                  itemBuilder: (_, i) => ListingTile(listing: items[i]),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.value, required this.label, required this.icon, this.onTap});
  final String value;
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Material(
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16), side: BorderSide(color: theme.colorScheme.outlineVariant)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, size: 18, color: icon == Icons.star_rounded ? const Color(0xFFFFB020) : null),
                const SizedBox(width: 6),
                Text(value, style: weight(theme.textTheme.titleMedium!, 700)),
              ]),
              const SizedBox(height: 2),
              Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}
