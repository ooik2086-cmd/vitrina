import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import 'listing_editor_screen.dart';
import 'manage_listing_screen.dart';
import '../i18n.dart';

class MyListingsScreen extends StatefulWidget {
  const MyListingsScreen({super.key});

  @override
  State<MyListingsScreen> createState() => _MyListingsScreenState();
}

class _MyListingsScreenState extends State<MyListingsScreen> {
  Future<List<Listing>>? _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items ??= SessionScope.of(context).api.myListings();
  }

  Future<void> _reload() async {
    final f = SessionScope.of(context).api.myListings();
    setState(() => _items = f);
    await f;
  }

  Future<void> _create() async {
    final created =
        await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ListingEditorScreen()));
    if (created == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Менің тауарларым'))),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _create, icon: const Icon(Icons.add), label: Text(tr('Тауар қосу'))),
      body: FutureBuilder<List<Listing>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          return RefreshIndicator(
            onRefresh: _reload,
            child: items.isEmpty
                ? ListView(children: [SizedBox(height: 120), Center(child: Text(tr('Әзірге тауар жоқ.')))])
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
          );
        },
      ),
    );
  }
}
