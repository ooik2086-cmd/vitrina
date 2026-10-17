import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import 'listing_editor_screen.dart';
import 'manage_listing_screen.dart';
import '../i18n.dart';
import '../widgets/common.dart';
import '../widgets/shop_sale.dart';

class MyListingsScreen extends StatefulWidget {
  const MyListingsScreen({super.key});

  @override
  State<MyListingsScreen> createState() => _MyListingsScreenState();
}

/// Which listings the seller wants to see. 'low' is on sale with one pair or none left.
bool listingMatches(Listing l, {required String status, required String query}) {
  final left = l.sizes.fold<int>(0, (n, s) => n + (s.quantity ?? 0));
  final okStatus = switch (status) {
    'all' => true,
    'low' => l.status == 'published' && left <= 1,
    _ => l.status == status,
  };
  if (!okStatus) return false;
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return [l.title, l.brand, l.modelName].any((t) => (t ?? '').toLowerCase().contains(q));
}

class _MyListingsScreenState extends State<MyListingsScreen> {
  Future<List<Listing>>? _items;
  final _query = TextEditingController();
  String _status = 'all';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items ??= SessionScope.of(context).api.myListings();
  }

  Future<void> _reload() async {
    final f = SessionScope.of(context).api.myListings();
    setState(() {
      _items = f;
    });
    await f;
  }

  Future<void> _create() async {
    final created =
        await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ListingEditorScreen()));
    if (created == true) _reload();
  }

  Future<void> _sale() async {
    final items = await _items;
    if (items == null || !mounted) return;
    if (await showShopSale(context, items) == true && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Менің тауарларым')), actions: [
        IconButton(
          key: const Key('shop-sale'),
          tooltip: tr('Дүкен жеңілдігі'),
          icon: const Icon(Icons.percent_rounded),
          onPressed: _sale,
        ),
      ]),
      floatingActionButton:
          FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: Text(tr('Тауар қосу'))),
      body: FutureBuilder<List<Listing>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError && snap.connectionState == ConnectionState.done) {
            return ErrorRetry(error: snap.error, onRetry: _reload);
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final all = snap.data!;
          if (all.isEmpty) {
            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView(children: [SizedBox(height: 120), Center(child: Text(tr('Әзірге тауар жоқ.')))]),
            );
          }
          int count(String status) => all.where((l) => listingMatches(l, status: status, query: '')).length;
          final filters = [
            ('all', tr('Барлығы')),
            ('published', tr('Сатылымда')),
            ('low', tr('Қалдығы аз')),
            ('moderation', tr('Тексерілуде')),
            ('paused', tr('Тоқтатылған')),
            ('sold', tr('Сатылды')),
            ('rejected', tr('Қайтарылды')),
          ].where((f) => f.$1 == 'all' || f.$1 == _status || count(f.$1) > 0).toList();
          final items = all.where((l) => listingMatches(l, status: _status, query: _query.text)).toList();
          return Column(children: [
            if (all.length > 5)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: TextField(
                  key: const Key('my-listings-search'),
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: tr('Атауы, бренді не үлгісі'),
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    suffixIcon: _query.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(_query.clear),
                          ),
                  ),
                ),
              ),
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                children: [
                  for (final (code, name) in filters)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: Key('status-$code'),
                        label: Text('$name ${count(code)}'),
                        selected: _status == code,
                        onSelected: (_) => setState(() => _status = code),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _reload,
                child: items.isEmpty
                    ? ListView(children: [SizedBox(height: 80), Center(child: Text(tr('Сай тауар жоқ.')))])
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final l = items[i];
                          final cover = l.coverUrl;
                          return ListTile(
                            leading: SizedBox(
                              width: 56,
                              height: 56,
                              child: cover == null
                                  ? const Icon(Icons.image_outlined)
                                  : Image.network(cover,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
                            ),
                            title: Text(l.title),
                            subtitle: Text('${tr(listingStatuses[l.status] ?? l.status)} · ${stockSummary(l)}'
                                '${l.frames.isNotEmpty ? ' · 360°' : ''}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () async {
                              final changed = await Navigator.of(context)
                                  .push<bool>(MaterialPageRoute(builder: (_) => ManageListingScreen(listing: l)));
                              if (changed == true) _reload();
                            },
                          );
                        },
                      ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
