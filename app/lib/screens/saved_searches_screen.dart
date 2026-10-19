import 'package:flutter/material.dart';

import '../api.dart';
import '../colors.dart';
import '../i18n.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// One readable line for a saved search, e.g. «nike» · Кроссовка · 26,5 см · 50 000 ₸ дейін · қара, ақ.
String savedSearchLabel(SavedSearch s) {
  final parts = <String>[
    if (s.q != null) '«${s.q}»',
    if (s.category != null) tr(categories[s.category] ?? s.category!),
    if (s.sizeCm != null) trf('{0} см', [s.sizeCm]),
    if (s.minPriceTiyn != null && s.maxPriceTiyn != null)
      '${formatTenge(s.minPriceTiyn!)} – ${formatTenge(s.maxPriceTiyn!)}'
    else if (s.maxPriceTiyn != null)
      trf('{0} дейін', [formatTenge(s.maxPriceTiyn!)])
    else if (s.minPriceTiyn != null)
      trf('{0} бастап', [formatTenge(s.minPriceTiyn!)]),
    for (final c in (s.condition ?? '').split(',').where((c) => c.isNotEmpty)) tr(conditions[c] ?? c),
    if (s.colors.isNotEmpty) s.colors.map(colorName).join(', '),
  ];
  return parts.join(' · ');
}

/// Searches the buyer follows. Tapping one runs it in the catalog; the bin stops the alerts.
class SavedSearchesScreen extends StatefulWidget {
  const SavedSearchesScreen({super.key});

  @override
  State<SavedSearchesScreen> createState() => _SavedSearchesScreenState();
}

class _SavedSearchesScreenState extends State<SavedSearchesScreen> {
  late Future<List<SavedSearch>> _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items = shown(SessionScope.of(context).api.savedSearches());
  }

  void _retry() {
    setState(() {
      _items = shown(SessionScope.of(context).api.savedSearches());
    });
  }

  Future<void> _delete(SavedSearch s) async {
    try {
      await SessionScope.of(context).api.deleteSavedSearch(s.id);
      if (!mounted) return;
      setState(() {
        _items = shown(SessionScope.of(context).api.savedSearches());
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Іздеу өшірілді'))));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Сақталған іздеулер'))),
      body: FutureBuilder<List<SavedSearch>>(
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
                  const Icon(Icons.notifications_active_outlined, size: 48, color: Brand.accent),
                  const SizedBox(height: 16),
                  Text(
                    tr('Каталогта іздеп, «Жаңасы шыққанда хабарлау» басыңыз. Сай тауар шыққанда бірден хабарлаймыз.'),
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
            itemBuilder: (context, i) => ListTile(
              key: Key('saved-${items[i].id}'),
              leading: const Icon(Icons.notifications_active_outlined),
              title: Text(savedSearchLabel(items[i])),
              subtitle: Text(tr('Жаңа тауар шыққанда хабарлаймыз')),
              trailing: IconButton(
                key: Key('delete-saved-${items[i].id}'),
                tooltip: tr('Өшіру'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(items[i]),
              ),
              onTap: () => Navigator.pop(context, items[i]),
            ),
          );
        },
      ),
    );
  }
}
