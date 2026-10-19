import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../widgets/common.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import 'shop_screen.dart';

/// Shops the user follows. Each new listing from them arrives as a notification; tapping a shop opens it.
class FollowingScreen extends StatefulWidget {
  const FollowingScreen({super.key});

  @override
  State<FollowingScreen> createState() => _FollowingScreenState();
}

class _FollowingScreenState extends State<FollowingScreen> {
  Future<List<FollowedShop>>? _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items ??= shown(SessionScope.of(context).api.following());
  }

  void _retry() {
    setState(() {
      _items = shown(SessionScope.of(context).api.following());
    });
  }

  Future<void> _open(FollowedShop shop) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShopScreen(sellerId: shop.id)));
    if (!mounted) return;
    // A block, not an arrow: setState must not be handed the Future. They may have unfollowed.
    setState(() {
      _items = shown(SessionScope.of(context).api.following());
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Жазылымдар'))),
      body: FutureBuilder<List<FollowedShop>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError && snap.connectionState == ConnectionState.done) {
            return ErrorRetry(error: snap.error, onRetry: _retry);
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.storefront_outlined, size: 48, color: Brand.accent),
                  const SizedBox(height: 16),
                  Text(
                    tr('Ұнаған дүкеннің бетінде «Жазылу» басыңыз. Ол жаңа тауар қойғанда бірден хабарлаймыз.'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge,
                  ),
                ]),
              ),
            );
          }
          return ListView.separated(
            padding: contentPadding(context, const EdgeInsets.fromLTRB(12, 8, 12, 24)),
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = items[i];
              return ListTile(
                key: Key('followed-${s.id}'),
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  child: Text(s.shopName.characters.first.toUpperCase()),
                ),
                title: Text(s.shopName),
                subtitle: Text([
                  if (s.city != null) s.city!,
                  trf('{0} тауар', [s.listings]),
                  if (s.rating != null) '★ ${s.rating!.toStringAsFixed(1)}',
                  if (s.awayUntil != null) trf('{0} дейін демалыста', [formatDay(s.awayUntil!)]),
                ].join(' · ')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(s),
              );
            },
          );
        },
      ),
    );
  }
}
