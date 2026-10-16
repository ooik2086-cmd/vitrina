import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../widgets/common.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final _query = TextEditingController();
  final _size = TextEditingController();
  String? _category;
  Future<List<Listing>>? _results;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _results ??= _load();
  }

  Future<List<Listing>> _load() =>
      SessionScope.of(context).api.search(q: _query.text.trim(), sizeCm: _size.text.trim(), category: _category);

  void _search() => setState(() => _results = _load());

  @override
  void dispose() {
    _query.dispose();
    _size.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search), hintText: 'Найк, nike, ақ кроссовка…', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 110,
              child: TextField(
                controller: _size,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onSubmitted: (_) => _search(),
                decoration: const InputDecoration(labelText: 'Өлшем, см', border: OutlineInputBorder()),
              ),
            ),
          ]),
        ),
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              for (final e in categories.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(e.value),
                    selected: _category == e.key,
                    onSelected: (on) {
                      _category = on ? e.key : null;
                      _search();
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Listing>>(
            future: _results,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(snap.error is ApiException ? '${snap.error}' : 'Серверге қосылу мүмкін болмады.'),
                    TextButton(onPressed: _search, child: const Text('Қайта көру')),
                  ]),
                );
              }
              final items = snap.data!;
              if (items.isEmpty) return const Center(child: Text('Ештеңе табылмады.'));
              return RefreshIndicator(onRefresh: () async => _search(), child: ListingGrid(items: items));
            },
          ),
        ),
      ]),
    );
  }
}
