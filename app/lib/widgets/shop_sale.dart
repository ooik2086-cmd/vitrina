import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import 'common.dart';

const salePercents = [10, 15, 20, 30, 40, 50];

/// The sale price the server will set: the cut, rounded to whole tenge.
int salePrice(int tiyn, int percent) {
  final cut = (tiyn * (100 - percent) / 100 / 100).round() * 100;
  return cut < 100 ? 100 : cut;
}

/// One cut for the whole shop, or ending the one that runs. Returns true when prices changed.
Future<bool?> showShopSale(BuildContext context, List<Listing> listings) => showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ShopSaleSheet(listings: listings),
    );

class ShopSaleSheet extends StatefulWidget {
  const ShopSaleSheet({super.key, required this.listings});
  final List<Listing> listings;

  @override
  State<ShopSaleSheet> createState() => _ShopSaleSheetState();
}

class _ShopSaleSheetState extends State<ShopSaleSheet> {
  int _percent = 15;
  bool _busy = false;

  Future<void> _run(Future<int> Function() call, String done) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await call();
      if (!mounted) return;
      Navigator.pop(context, true);
      messenger.showSnackBar(SnackBar(content: Text(trf(done, [n]))));
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final api = SessionScope.of(context).api;
    final live = widget.listings.where((l) => l.status == 'published').toList();
    final onSale = widget.listings.where((l) => l.wasPriceTiyn != null).length;
    final sample = live.isEmpty ? null : live.first;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Дүкен жеңілдігі'), style: weight(theme.textTheme.titleLarge!, 750)),
          const SizedBox(height: 6),
          Text(
            trf('Сатылымдағы {0} тауардың бәрі арзандайды. Ескі бағасы сызылып көрсетіледі, таңдаулыларға қосқандарға хабар барады.',
                [live.length]),
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in salePercents)
              ChoiceChip(
                key: Key('sale-$p'),
                label: Text('−$p%'),
                selected: _percent == p,
                onSelected: _busy ? null : (_) => setState(() => _percent = p),
              ),
          ]),
          if (sample != null) ...[
            const SizedBox(height: 14),
            Text(
              trf('Мысалы: {0} → {1}',
                  [formatTenge(sample.priceTiyn), formatTenge(salePrice(sample.priceTiyn, _percent))]),
              key: const Key('sale-example'),
              style: weight(theme.textTheme.bodyMedium!, 600).copyWith(color: accentText(context)),
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: FilledButton(
              key: const Key('sale-start'),
              onPressed: _busy || live.isEmpty
                  ? null
                  : () => _run(() => api.startShopSale(_percent), 'Жеңілдік {0} тауарға қосылды.'),
              child: Text(trf('Барлығына −{0}%', [_percent])),
            ),
          ),
          if (onSale > 0) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('sale-end'),
              onPressed: _busy ? null : () => _run(api.endShopSale, 'Бұрынғы баға {0} тауарға қайтарылды.'),
              child: Text(trf('Жеңілдікті аяқтау ({0} тауар)', [onSale])),
            ),
          ],
        ]),
      ),
    );
  }
}
