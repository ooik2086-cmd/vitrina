import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import 'listing_editor_screen.dart';
import 'listing_screen.dart';

const _listingStatuses = {
  'draft': 'Жоба',
  'moderation': 'Тексерілуде',
  'published': 'Сатылымда',
  'sold': 'Сатылды',
  'hidden': 'Жасырылған',
};

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
    final created = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const ListingEditorScreen()));
    if (created == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Менің тауарларым')),
      floatingActionButton:
          FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('Тауар қосу')),
      body: FutureBuilder<List<Listing>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          return RefreshIndicator(
            onRefresh: _reload,
            child: items.isEmpty
                ? ListView(children: const [SizedBox(height: 120), Center(child: Text('Әзірге тауар жоқ.'))])
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
                                  fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
                        ),
                        title: Text(l.title),
                        subtitle: Text('${_listingStatuses[l.status] ?? l.status} · ${formatTenge(l.priceTiyn)}'
                            '${l.frames.isNotEmpty ? ' · 360°' : ''}'),
                        onTap: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => ListingScreen(listingId: l.id))),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}
