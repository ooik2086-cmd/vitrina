import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'login_screen.dart';
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
  (bool, int)? _follow; // what the last follow tap returned, ahead of a reload
  bool _busy = false;

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

  Future<void> _toggleFollow(Shop shop) async {
    final session = SessionScope.of(context);
    if (!session.signedIn) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
      if (!mounted || !session.signedIn) return;
    }
    final now = _follow?.$1 ?? shop.following;
    setState(() => _busy = true);
    try {
      final result = await session.api.setFollowing(shop.id, !now);
      if (!mounted) return;
      setState(() => _follow = result);
      if (result.$1) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr('Жазылдыңыз. Дүкен жаңа тауар қойғанда хабарлаймыз.'))));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final me = SessionScope.of(context).me;
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
                  if (shop.replyBucket != null) ...[
                    const SizedBox(height: 14),
                    Row(key: const Key('reply-time'), children: [
                      Icon(Icons.bolt_rounded,
                          size: 18,
                          color: shop.replyBucket == 'hour' ? const Color(0xFF2E9E6A) : scheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          tr(switch (shop.replyBucket) {
                            'hour' => 'Әдетте бір сағат ішінде жауап береді',
                            'hours' => 'Әдетте бірнеше сағатта жауап береді',
                            'day' => 'Әдетте бір күн ішінде жауап береді',
                            _ => 'Жауап беруі бір күннен ұзаққа созылады',
                          }),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ]),
                  ],
                  if (shop.about != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      key: const Key('shop-about'),
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration:
                          BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
                      child: Text(shop.about!, style: theme.textTheme.bodyMedium),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(children: [
                    Icon(Icons.people_outline, size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(trf('{0} жазылушы', [_follow?.$2 ?? shop.followers]),
                          key: const Key('followers'),
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                    if (me?.id != shop.id)
                      (_follow?.$1 ?? shop.following)
                          ? OutlinedButton.icon(
                              key: const Key('unfollow'),
                              onPressed: _busy ? null : () => _toggleFollow(shop),
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: Text(tr('Жазылдыңыз')),
                            )
                          : FilledButton.icon(
                              key: const Key('follow'),
                              onPressed: _busy ? null : () => _toggleFollow(shop),
                              icon: const Icon(Icons.add_rounded, size: 18),
                              label: Text(tr('Жазылу')),
                            ),
                  ]),
                  const SizedBox(height: 16),
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
