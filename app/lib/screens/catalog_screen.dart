import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/filter_sheet.dart';
import 'image_search_screen.dart';
import 'listing_screen.dart';
import 'notifications_screen.dart';
import 'saved_searches_screen.dart';
import '../i18n.dart';
import '../my_size.dart';
import '../recent.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final _query = TextEditingController();
  String? _sizeCm = mySize.value;
  String? _category;
  CatalogFilter _filter = const CatalogFilter();
  bool _sale = false; // only listings whose price was really cut
  Future<List<Listing>>? _results;
  static const _page = 20;
  final List<Listing> _more = [];
  bool _hasMore = true;
  bool _loadingMore = false;

  int _unread = 0;
  bool? _countedFor;
  String? _savedKey; // the current search, once the buyer asked to be told about it
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _results ??= _load();
    final session = SessionScope.of(context);
    if (_countedFor != session.signedIn) {
      _countedFor = session.signedIn;
      _countUnread();
    }
  }

  Future<void> _countUnread() async {
    final session = SessionScope.of(context);
    if (!session.signedIn) return setState(() => _unread = 0);
    try {
      final (unread, _) = await session.api.notifications();
      if (mounted) setState(() => _unread = unread);
    } catch (_) {
      // The badge is a hint; the list itself shows errors.
    }
  }

  Future<void> _openNotifications() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));
    _countUnread();
  }

  Future<List<Listing>> _load({int offset = 0}) => SessionScope.of(context)
      .api
      .search(
          q: _query.text.trim(), sizeCm: _sizeCm, category: _category, filter: _filter, sale: _sale, offset: offset);

  void _search() => setState(() {
        _more.clear();
        _hasMore = true;
        _results = _load();
      });

  /// Next page when the user nears the end; the first page stays in the FutureBuilder.
  Future<void> _loadMore(int loaded) async {
    if (_loadingMore || !_hasMore) return;
    final current = _results;
    setState(() => _loadingMore = true);
    try {
      final page = await _load(offset: loaded);
      if (!mounted || current != _results) return; // a new search started meanwhile
      setState(() {
        _more.addAll(page);
        _hasMore = page.length == _page;
      });
    } catch (_) {
      // Pulling to refresh or scrolling again retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Map<String, Object> get _current =>
      SavedSearch.body(q: _query.text, category: _category, sizeCm: _sizeCm, filter: _filter);

  Future<void> _saveSearch() async {
    final body = _current;
    setState(() => _saving = true);
    try {
      await SessionScope.of(context).api.saveSearch(body);
      if (!mounted) return;
      setState(() => _savedKey = jsonEncode(body));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Сақталды. Сай тауар шыққанда хабарлаймыз.')),
        action: SnackBarAction(label: tr('Барлығы'), onPressed: _openSaved),
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openSaved() async {
    final picked = await Navigator.of(context)
        .push<SavedSearch>(MaterialPageRoute(builder: (_) => const SavedSearchesScreen()));
    if (picked == null) return;
    _query.text = picked.q ?? '';
    _category = picked.category;
    _sizeCm = picked.sizeCm;
    _filter = CatalogFilter(
        conditions: {...?picked.condition?.split(',').where((c) => c.isNotEmpty)},
        minPriceTiyn: picked.minPriceTiyn,
        maxPriceTiyn: picked.maxPriceTiyn);
    _savedKey = jsonEncode(picked.asBody);
    _search();
  }

  Future<void> _pickSize() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => const _SizeSheet(),
    );
    if (picked == null) return;
    _sizeCm = picked.isEmpty ? null : picked;
    setMySize(_sizeCm); // remembered for the next visit and for product pages
    _search();
  }

  Future<void> _searchByPhoto() async {
    final file = await pickPhoto(context,
        title: tr('Фотомен іздеу'), subtitle: tr('Ұнаған аяқкиімнің суретін түсіріңіз немесе таңдаңыз'));
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImageSearchScreen(bytes: bytes, filename: file.name)));
  }

  Future<void> _pickFilter() async {
    final picked = await showModalBottomSheet<CatalogFilter>(
      context: context,
      isScrollControlled: true,
      builder: (context) => FilterSheet(initial: _filter),
    );
    if (picked == null) return;
    _filter = picked;
    _search();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: () async {
          _countUnread();
          _search();
          await _results;
        },
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text('VITRINA', style: weight(theme.textTheme.labelLarge!, 800).copyWith(letterSpacing: 3)),
                  ),
                  if (SessionScope.of(context).signedIn)
                    IconButton(
                      key: const Key('saved-searches'),
                      tooltip: tr('Сақталған іздеулер'),
                      onPressed: _openSaved,
                      icon: const Icon(Icons.bookmarks_outlined),
                    ),
                  if (SessionScope.of(context).signedIn)
                    IconButton(
                      tooltip: tr('Хабарландырулар'),
                      onPressed: _openNotifications,
                      icon: Badge(
                        isLabelVisible: _unread > 0,
                        backgroundColor: Brand.accent,
                        label: Text('$_unread'),
                        child: const Icon(Icons.notifications_none_rounded),
                      ),
                    ),
                ]),
                const SizedBox(height: 2),
                Text(tr('Аяқкиімді жан-жағынан\nкөріп таңдаңыз'), style: theme.textTheme.headlineMedium),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: IconButton(
                          tooltip: tr('Фотомен іздеу'),
                          icon: const Icon(Icons.photo_camera_outlined),
                          onPressed: _searchByPhoto,
                        ),
                        hintText: tr('Найк, nike, ақ кроссовка…'),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(99)),
                        enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(99),
                            borderSide: BorderSide(color: theme.colorScheme.outlineVariant)),
                        focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(99),
                            borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _SizeButton(sizeCm: _sizeCm, onTap: _pickSize),
                ]),
              ]),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 64,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Badge(
                      isLabelVisible: _filter.active > 0,
                      backgroundColor: Brand.accent,
                      label: Text('${_filter.active}'),
                      child: ActionChip(
                        tooltip: tr('Сүзгі'),
                        avatar: const Icon(Icons.tune_rounded, size: 18),
                        label: Text(_filter.sort == 'new' ? tr('Сүзгі') : tr(sortLabels[_filter.sort]!)),
                        onPressed: _pickFilter,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      key: const Key('sale'),
                      avatar: Icon(Icons.local_fire_department_rounded,
                          size: 18, color: _sale ? Colors.white : Brand.accent),
                      label: Text(tr('Жеңілдік')),
                      selected: _sale,
                      showCheckmark: false,
                      selectedColor: Brand.accent,
                      labelStyle: TextStyle(color: _sale ? Colors.white : null, fontWeight: FontWeight.w600),
                      onSelected: (v) {
                        _sale = v;
                        _search();
                      },
                    ),
                  ),
                  for (final e in {null: tr('Барлығы'), ...categories}.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(tr(e.value)),
                        selected: _category == e.key,
                        onSelected: (_) {
                          _category = e.key;
                          _search();
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (SessionScope.of(context).signedIn && _current.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 20, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: jsonEncode(_current) == _savedKey
                      ? TextButton.icon(
                          key: const Key('search-saved'),
                          onPressed: _openSaved,
                          icon: const Icon(Icons.notifications_active_rounded, color: Brand.accent),
                          label: Text(tr('Хабарлау қосулы')),
                        )
                      : TextButton.icon(
                          key: const Key('save-search'),
                          onPressed: _saving ? null : _saveSearch,
                          icon: const Icon(Icons.notifications_none_rounded),
                          label: Text(tr('Жаңасы шыққанда хабарлау')),
                        ),
                ),
              ),
            ),
          ValueListenableBuilder<List<RecentItem>>(
            valueListenable: recentlyViewed,
            builder: (context, recent, _) => recent.isEmpty || _query.text.trim().isNotEmpty || _category != null
                ? const SliverToBoxAdapter(child: SizedBox.shrink())
                : SliverToBoxAdapter(child: _RecentRow(items: recent)),
          ),
          FutureBuilder<List<Listing>>(
            future: _results,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SliverFillRemaining(child: Center(child: CircularProgressIndicator()));
              }
              if (snap.hasError) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: _Empty(
                    icon: Icons.wifi_off_rounded,
                    text: snap.error is ApiException ? '${snap.error}' : tr('Серверге қосылу мүмкін болмады.'),
                    action: TextButton(onPressed: _search, child: Text(tr('Қайта көру'))),
                  ),
                );
              }
              final items = [...snap.data!, ..._more];
              if (snap.data!.length < _page) _hasMore = false;
              if (items.isEmpty) {
                return SliverFillRemaining(
                    hasScrollBody: false, child: _Empty(icon: Icons.search_off_rounded, text: tr('Ештеңе табылмады.')));
              }
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 240, mainAxisSpacing: 22, crossAxisSpacing: 14, childAspectRatio: 0.64),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    if (i >= items.length - 6 && _hasMore) {
                      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore(items.length));
                    }
                    return ListingTile(listing: items[i]);
                  },
                ),
              );
            },
          ),
          if (_loadingMore)
            const SliverToBoxAdapter(
              child: Padding(padding: EdgeInsets.only(bottom: 32), child: Center(child: CircularProgressIndicator())),
            ),
        ]),
      ),
    );
  }
}

class _SizeButton extends StatelessWidget {
  const _SizeButton({required this.sizeCm, required this.onTap});
  final String? sizeCm;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = sizeCm != null;
    return Material(
      color: active ? scheme.primary : scheme.surface,
      shape: StadiumBorder(side: BorderSide(color: active ? scheme.primary : scheme.outlineVariant)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(children: [
            Icon(Icons.straighten_rounded, size: 20, color: active ? scheme.onPrimary : scheme.onSurface),
            const SizedBox(width: 6),
            Text(active ? trf('{0} см', [sizeCm]) : tr('Өлшем'),
                style: TextStyle(color: active ? scheme.onPrimary : scheme.onSurface, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// Size is chosen by insole length, the one measure that means the same across brands.
class _SizeSheet extends StatelessWidget {
  const _SizeSheet();

  static const _cm = ['22', '23', '24', '24,5', '25', '25,5', '26', '26,5', '27', '27,5', '28', '28,5', '29', '30'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Ұлтарақ ұзындығы'), style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(tr('Өкшеден бас бармақтың ұшына дейін өлшеңіз. ±0,5 см аралығы көрсетіледі. Өлшеміңіз телефонда сақталады.'),
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final cm in _cm) ActionChip(label: Text(trf('{0} см', [cm])), onPressed: () => Navigator.pop(context, cm)),
          ]),
          const SizedBox(height: 12),
          TextButton(onPressed: () => Navigator.pop(context, ''), child: Text(tr('Өлшемді алып тастау'))),
        ]),
      ),
    );
  }
}

/// Listings opened lately, so a shoe seen yesterday is one tap away.
class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.items});
  final List<RecentItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
        child: Row(children: [
          Expanded(child: Text(tr('Жуырда қаралғандар'), style: theme.textTheme.titleMedium)),
          TextButton(onPressed: forgetRecent, child: Text(tr('Тазарту'))),
        ]),
      ),
      SizedBox(
        height: 166,
        child: ListView.separated(
          key: const Key('recent'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (context, i) {
            final r = items[i];
            return GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListingScreen(listingId: r.id))),
              child: SizedBox(
                width: 104,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 104,
                    height: 92,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(color: Brand.studio, borderRadius: BorderRadius.circular(16)),
                    child: r.coverUrl == null
                        ? const Icon(Icons.image_outlined)
                        : Image.network(r.coverUrl!,
                            fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
                  ),
                  const SizedBox(height: 6),
                  Text(formatTenge(r.priceTiyn), style: weight(theme.textTheme.labelLarge!, 700)),
                  Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(height: 12),
        Text(text, style: theme.textTheme.bodyLarge),
        if (action != null) action!,
      ]),
    );
  }
}
