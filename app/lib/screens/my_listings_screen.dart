import 'package:flutter/material.dart';

import '../net_image.dart';
import '../api.dart';
import '../colors.dart';
import '../session.dart';
import '../theme.dart';
import 'listing_editor_screen.dart';
import 'manage_listing_screen.dart';
import '../i18n.dart';
import '../widgets/common.dart';
import '../widgets/questions.dart';
import '../widgets/shop_sale.dart';

class MyListingsScreen extends StatefulWidget {
  const MyListingsScreen({super.key, this.status = 'all'});

  /// The filter it opens on: the to-do card's questions line opens on 'questions'.
  final String status;

  @override
  State<MyListingsScreen> createState() => _MyListingsScreenState();
}

/// Which listings the seller wants to see. 'low' is on sale with one pair or none left; 'questions' has buyers'
/// questions waiting for an answer ([waiting] of them).
bool listingMatches(Listing l, {required String status, required String query, int waiting = 0}) {
  final left = l.sizes.fold<int>(0, (n, s) => n + (s.quantity ?? 0));
  final okStatus = switch (status) {
    'all' => true,
    'low' => l.status == 'published' && left <= 1,
    'questions' => waiting > 0,
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
  late String _status = widget.status;

  /// Questions waiting, read again for one listing after the seller comes back from it (they may have answered
  /// there), so the whole list is not downloaded again for one number.
  final _waiting = <int, int>{};
  final _asks = <int, int>{}; // the latest ask per listing: an older answer arriving late is dropped

  int _waitingOn(Listing l) => _waiting[l.id] ?? l.stats?.unanswered ?? 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items ??= shown(SessionScope.of(context).api.myListings());
  }

  Future<void> _reload() async {
    final f = SessionScope.of(context).api.myListings();
    final loading = shown(f);
    setState(() {
      _items = loading;
    });
    // The numbers read since stay until the new list, which has them all, is in: a slow load shows no older ones.
    f.then((_) {
      if (mounted && identical(_items, loading)) setState(_waiting.clear);
    }, onError: (_) {});
    await settled(f);
  }

  Future<void> _create() async {
    final created =
        await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ListingEditorScreen()));
    if (created == true) _reload();
  }

  /// Back from a listing whose buyers were waiting: its number may have changed. A failed ask keeps the old one.
  Future<void> _recount(Listing l) async {
    if (_waitingOn(l) == 0 || (l.status != 'published' && l.status != 'sold')) return;
    final api = SessionScope.of(context).api;
    final items = _items;
    final ask = _asks[l.id] = (_asks[l.id] ?? 0) + 1;
    try {
      final n = await api.unansweredQuestions(l.id);
      if (mounted && identical(items, _items) && _asks[l.id] == ask) setState(() => _waiting[l.id] = n);
    } catch (_) {}
  }

  /// A listing on «Сұрақ күтеді» opens straight on its questions, the reason the seller came; any other one opens
  /// its page.
  Future<void> _open(Listing l) async {
    final answerable = l.status == 'published' || l.status == 'sold';
    if (_status == 'questions' && answerable) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => QuestionsScreen(listingId: l.id, seller: true)));
      if (mounted) _recount(l);
      return;
    }
    final changed =
        await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ManageListingScreen(listing: l)));
    if (!mounted) return;
    if (changed == true) {
      _reload();
    } else {
      _recount(l);
    }
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
          // A server from before the per-listing number sends none: then there is no questions filter to open on.
          final known = all.any((l) => l.stats?.unanswered != null);
          final status = _status == 'questions' && !known ? 'all' : _status;
          int count(String status) =>
              all.where((l) => listingMatches(l, status: status, query: '', waiting: _waitingOn(l))).length;
          // The questions chip counts questions, as the to-do line that leads to it does; the others count listings.
          int number(String code) => code == 'questions' ? all.fold(0, (n, l) => n + _waitingOn(l)) : count(code);
          final filters = [
            ('all', tr('Барлығы')),
            ('questions', tr('Сұрақ күтеді')),
            ('published', tr('Сатылымда')),
            ('low', tr('Қалдығы аз')),
            ('moderation', tr('Тексерілуде')),
            ('paused', tr('Тоқтатылған')),
            ('sold', tr('Сатылды')),
            ('rejected', tr('Қайтарылды')),
          ]
              .where((f) => f.$1 == 'all' || (f.$1 == status || count(f.$1) > 0) && (f.$1 != 'questions' || known))
              .toList();
          final items =
              all.where((l) => listingMatches(l, status: status, query: _query.text, waiting: _waitingOn(l))).toList();
          return Column(children: [
            if (all.length > 5)
              Padding(
                padding: contentPadding(context, const EdgeInsets.fromLTRB(16, 4, 16, 0)),
                child: TextField(
                  key: const Key('my-listings-search'),
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: tr('Атауы, бренді не үлгісі'),
                    hintMaxLines: 2, // whole at large text, in Russian too
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
              height: 60, // a chip's 48 tap height and the padding
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: contentPadding(context, const EdgeInsets.fromLTRB(16, 8, 16, 4)),
                children: [
                  for (final (code, name) in filters)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: Key('status-$code'),
                        label: Text('$name ${number(code)}'),
                        selected: status == code,
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
                    ? ListView(children: [
                        SizedBox(height: 80),
                        Center(
                            child: Text(
                                tr(status == 'questions' && count('questions') == 0
                                    ? 'Жауап күтетін сұрақ жоқ.'
                                    : 'Сай тауар жоқ.'),
                                textAlign: TextAlign.center)),
                      ])
                    : ListView.separated(
                        padding: contentPadding(context, const EdgeInsets.only(bottom: 88)),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final l = items[i];
                          final cover = l.coverUrl;
                          final waiting = _waitingOn(l);
                          final theme = Theme.of(context);
                          return ListTile(
                            leading: SizedBox(
                              width: 56,
                              height: 56,
                              child: cover == null
                                  ? const Icon(Icons.image_outlined)
                                  : Image(
                                      image: netImage(cover),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
                            ),
                            title: Text(namedWithColor(l)),
                            subtitle: Text.rich(TextSpan(children: [
                              // A listing sent back or hidden needs the seller: its word stands out, the rest stays calm.
                              TextSpan(
                                  text: tr(listingStatuses[l.status] ?? l.status),
                                  style: l.status == 'rejected' || l.status == 'hidden'
                                      ? TextStyle(color: Theme.of(context).colorScheme.error)
                                      : null),
                              TextSpan(
                                  text: ' · ${stockSummary(l)}'
                                      '${l.model != null ? ' · 360°' : ''}'
                                      '${l.photosPending ? ' · ${tr('фото өңделуде')}' : ''}'),
                              // Buyers waiting on an answer: the one thing on the line that asks the seller to act.
                              if (waiting > 0)
                                TextSpan(
                                    text: '\n${trf('Жауапсыз сұрақ: {0}', [waiting])}',
                                    style: weight(theme.textTheme.bodyMedium!, 700)
                                        .copyWith(color: theme.colorScheme.onSurface)),
                            ])),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _open(l),
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

/// A listing's title with its colour after it, unless the title already says it: one model in many colours reads as
/// many rows, not one title over and over.
String namedWithColor(Listing l) {
  final color = colorName(l.color);
  return color.isEmpty || l.title.toLowerCase().contains(color.toLowerCase()) ? l.title : '${l.title}, $color';
}
