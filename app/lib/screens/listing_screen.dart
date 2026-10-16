import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/spin_viewer.dart';
import 'login_screen.dart';
import 'order_screen.dart';

class ListingScreen extends StatefulWidget {
  const ListingScreen({super.key, required this.listingId});
  final int listingId;

  @override
  State<ListingScreen> createState() => _ListingScreenState();
}

class _ListingScreenState extends State<ListingScreen> {
  late Future<Listing> _listing;
  int? _sizeId;
  bool _favorite = false;
  bool _ordering = false;
  // One key per order attempt: a retried tap after a lost response returns the same order.
  String _orderKey = newIdempotencyKey();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listing = SessionScope.of(context).api.listing(widget.listingId);
  }

  Future<bool> _ensureSignedIn() async {
    final session = SessionScope.of(context);
    if (session.signedIn) return true;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
    return session.signedIn;
  }

  Future<void> _toggleFavorite() async {
    if (!await _ensureSignedIn() || !mounted) return;
    final on = !_favorite;
    try {
      await SessionScope.of(context).api.setFavorite(widget.listingId, on);
      setState(() => _favorite = on);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _order(Listing listing) async {
    if (!await _ensureSignedIn() || !mounted) return;
    setState(() => _ordering = true);
    try {
      final order = await SessionScope.of(context).api.createOrder(listing.id, _sizeId!, _orderKey);
      _orderKey = newIdempotencyKey();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: order.id)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _ordering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(actions: [
        IconButton(
          tooltip: 'Таңдаулыға',
          onPressed: _toggleFavorite,
          icon: Icon(_favorite ? Icons.favorite : Icons.favorite_border),
        ),
      ]),
      body: FutureBuilder<Listing>(
        future: _listing,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return _body(context, snap.data!);
        },
      ),
    );
  }

  Widget _body(BuildContext context, Listing l) {
    final theme = Theme.of(context);
    final frames = l.frames;
    final canOrder = l.status == 'published' && _sizeId != null && !_ordering;
    return Column(children: [
      Expanded(
        child: ListView(children: [
          AspectRatio(
            aspectRatio: 1,
            child: frames.length >= 8
                ? SpinViewer(frameUrls: [for (final f in frames) f.url], style: l.showcaseStyle)
                : PhotoGallery(urls: [for (final p in l.photos) p.url], style: l.showcaseStyle),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(formatTenge(l.priceTiyn), style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(l.title, style: theme.textTheme.titleMedium),
              Text([if (l.brand != null) l.brand!, l.color].join(' · '), style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              _fact('Баға деңгейі', l.segment == null ? 'Деректер әлі аз' : label(segments, l.segment)),
              _fact('Жағдайы', label(conditions, l.condition)),
              _fact('Түпнұсқалығы', label(authenticity, l.authenticity)),
              if ((l.defects ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('Ақаулары: ${l.defects}', style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text('Өлшем (ұлтарақ ұзындығы)', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final s in l.sizes)
                  ChoiceChip(
                    label: Text('${s.label} · ${s.insoleCm} см'),
                    selected: _sizeId == s.id,
                    onSelected: s.available ? (on) => setState(() => _sizeId = on ? s.id : null) : null,
                  ),
              ]),
              if ((l.description ?? '').isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(l.description!),
              ],
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.store_outlined),
                title: Text(l.shopName ?? 'Сатушы'),
                subtitle: Text(l.sellerCity ?? ''),
              ),
              Text(
                'Жеткізу: ${l.deliveryPriceTiyn == 0 ? 'тегін' : formatTenge(l.deliveryPriceTiyn)}',
                style: theme.textTheme.bodySmall,
              ),
            ]),
          ),
        ]),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: canOrder ? () => _order(l) : null,
              child: Text(l.status != 'published'
                  ? 'Сатылған'
                  : _sizeId == null
                      ? 'Өлшемді таңдаңыз'
                      : 'Тапсырыс беру · ${formatTenge(l.priceTiyn + l.deliveryPriceTiyn)}'),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _fact(String name, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 130, child: Text(name, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: Text(value)),
        ]),
      );
}
