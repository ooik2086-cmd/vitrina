import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'listing_screen.dart';

const listingStatuses = {
  'draft': 'Жоба',
  'moderation': 'Тексерілуде',
  'published': 'Сатылымда',
  'paused': 'Тоқтатылған',
  'sold': 'Сатылды',
  'hidden': 'Модератор жасырды',
};

/// Seller's own listing: change price, stock and description, pause or put back on sale.
/// Photos, title and condition are fixed once created, so buyers always get what they chose.
class ManageListingScreen extends StatefulWidget {
  const ManageListingScreen({super.key, required this.listing});
  final Listing listing;

  @override
  State<ManageListingScreen> createState() => _ManageListingScreenState();
}

class _ManageListingScreenState extends State<ManageListingScreen> {
  final _form = GlobalKey<FormState>();
  late Listing _l = widget.listing;
  late final _price = TextEditingController(text: '${_l.priceTiyn ~/ 100}');
  late final _delivery = TextEditingController(text: '${_l.deliveryPriceTiyn ~/ 100}');
  late final _description = TextEditingController(text: _l.description ?? '');
  late final _defects = TextEditingController(text: _l.defects ?? '');
  late final Map<int, int> _stock = {for (final s in _l.sizes) s.id: s.quantity ?? (s.available ? 1 : 0)};
  bool _busy = false;
  bool _changed = false;

  @override
  void dispose() {
    for (final c in [_price, _delivery, _description, _defects]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _tiyn(String text) {
    final v = int.tryParse(text.replaceAll(RegExp(r'\s'), ''));
    return v == null ? null : v * 100;
  }

  Future<void> _run(Future<Listing> Function(Api api) action, String done) async {
    setState(() => _busy = true);
    try {
      final l = await action(SessionScope.of(context).api);
      if (!mounted) return;
      setState(() {
        _l = l;
        _changed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    _run(
      (api) => api.editListing(_l.id,
          priceTiyn: _tiyn(_price.text),
          deliveryPriceTiyn: _tiyn(_delivery.text) ?? 0,
          description: _description.text,
          defects: _defects.text,
          stock: _stock),
      'Сақталды',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locked = _l.status == 'hidden';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Тауарды басқару'), actions: [
          IconButton(
            tooltip: 'Сатып алушы көретіндей ашу',
            icon: const Icon(Icons.visibility_outlined),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListingScreen(listingId: _l.id))),
          ),
        ]),
        body: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 120), children: [
            Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: 72,
                  height: 72,
                  color: Brand.studio,
                  child: _l.coverUrl == null
                      ? const Icon(Icons.image_outlined)
                      : Image.network(_l.coverUrl!,
                          fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_l.title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  _StatusPill(status: _l.status),
                ]),
              ),
            ]),
            if (locked) ...[
              const SizedBox(height: 16),
              Card(
                color: theme.colorScheme.errorContainer,
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Тауарды модератор жасырды. Өзгерту үшін қолдау қызметіне жазыңыз.'),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Text('Баға', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextFormField(
                  key: const Key('price'),
                  controller: _price,
                  enabled: !locked,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Бағасы', suffixText: '₸'),
                  validator: (v) => (_tiyn(v ?? '') ?? 0) <= 0 ? 'Бағаны енгізіңіз' : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _delivery,
                  enabled: !locked,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Жеткізу', suffixText: '₸'),
                ),
              ),
            ]),
            const SizedBox(height: 24),
            Text('Қалдық', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final s in _l.sizes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.label),
                subtitle: Text('${s.insoleCm} см'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton.outlined(
                    tooltip: 'Азайту',
                    icon: const Icon(Icons.remove),
                    onPressed: locked || (_stock[s.id] ?? 0) == 0
                        ? null
                        : () => setState(() => _stock[s.id] = _stock[s.id]! - 1),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text('${_stock[s.id]}',
                        textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  IconButton.outlined(
                    tooltip: 'Көбейту',
                    icon: const Icon(Icons.add),
                    onPressed: locked ? null : () => setState(() => _stock[s.id] = (_stock[s.id] ?? 0) + 1),
                  ),
                ]),
              ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _description,
              enabled: !locked,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Сипаттамасы'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _defects,
              enabled: !locked,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Ақаулары'),
            ),
          ]),
        ),
        bottomNavigationBar: locked
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Row(children: [
                    if (_l.status == 'published')
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : () => _run((api) => api.pauseListing(_l.id), 'Сатылым тоқтатылды'),
                          child: const Text('Тоқтату'),
                        ),
                      ),
                    if (_l.status == 'draft' || _l.status == 'paused')
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : () => _run((api) => api.publishListing(_l.id), 'Сатылымға шықты'),
                          child: const Text('Сатылымға шығару'),
                        ),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const Key('save'),
                        onPressed: _busy ? null : _save,
                        child: const Text('Сақтау'),
                      ),
                    ),
                  ]),
                ),
              ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final live = status == 'published';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: live ? Brand.ink : Brand.studio,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(listingStatuses[status] ?? status,
            style: TextStyle(color: live ? Colors.white : Brand.ink, fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// One-line stock summary for list rows, e.g. "3 дана".
String stockSummary(Listing l) {
  final total = l.sizes.fold<int>(0, (n, s) => n + (s.quantity ?? 0));
  return '$total дана · ${formatTenge(l.priceTiyn)}';
}
