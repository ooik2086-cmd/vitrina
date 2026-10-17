import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'notifications_screen.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final _query = TextEditingController();
  String? _sizeCm;
  String? _category;
  Future<List<Listing>>? _results;

  int _unread = 0;
  bool? _countedFor;

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

  Future<List<Listing>> _load() =>
      SessionScope.of(context).api.search(q: _query.text.trim(), sizeCm: _sizeCm, category: _category);

  void _search() => setState(() => _results = _load());

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _pickSize() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => const _SizeSheet(),
    );
    if (picked == null) return;
    _sizeCm = picked.isEmpty ? null : picked;
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
                      tooltip: 'Хабарландырулар',
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
                Text('Аяқкиімді жан-жағынан\nкөріп таңдаңыз', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'Найк, nike, ақ кроссовка…',
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
                  for (final e in {null: 'Барлығы', ...categories}.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(e.value),
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
                    text: snap.error is ApiException ? '${snap.error}' : 'Серверге қосылу мүмкін болмады.',
                    action: TextButton(onPressed: _search, child: const Text('Қайта көру')),
                  ),
                );
              }
              final items = snap.data!;
              if (items.isEmpty) {
                return const SliverFillRemaining(
                    hasScrollBody: false, child: _Empty(icon: Icons.search_off_rounded, text: 'Ештеңе табылмады.'));
              }
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 240, mainAxisSpacing: 22, crossAxisSpacing: 14, childAspectRatio: 0.64),
                  itemCount: items.length,
                  itemBuilder: (_, i) => ListingTile(listing: items[i]),
                ),
              );
            },
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
            Text(active ? '$sizeCm см' : 'Өлшем',
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
          Text('Ұлтарақ ұзындығы', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Өкшеден бас бармақтың ұшына дейін өлшеңіз. ±0,5 см аралығы көрсетіледі.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final cm in _cm) ActionChip(label: Text('$cm см'), onPressed: () => Navigator.pop(context, cm)),
          ]),
          const SizedBox(height: 12),
          TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Өлшемді алып тастау')),
        ]),
      ),
    );
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
