import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../i18n.dart';
import 'compare_screen.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  Future<List<Listing>>? _items;
  bool? _loadedSignedIn;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (_loadedSignedIn != session.signedIn) {
      _loadedSignedIn = session.signedIn;
      _items = session.signedIn ? session.api.favorites() : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items == null) return SignInPrompt(text: tr('Ұнаған тауарларды сақтау үшін кіріңіз.'));
    return FutureBuilder<List<Listing>>(
      future: _items,
      builder: (context, snap) => Scaffold(
        appBar: AppBar(title: Text(tr('Таңдаулылар')), actions: [
          if ((snap.data?.length ?? 0) >= 2)
            IconButton(
              key: const Key('compare'),
              tooltip: tr('Салыстыру'),
              icon: const Icon(Icons.compare_arrows_rounded),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => CompareScreen(items: snap.data!))),
            ),
        ]),
        body: Builder(builder: (context) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          if (snap.data!.isEmpty) return Center(child: Text(tr('Таңдаулы тауар әлі жоқ.')));
          return RefreshIndicator(
            onRefresh: () async {
              final f = SessionScope.of(context).api.favorites();
              setState(() {
                _items = f;
              });
              await f;
            },
            child: ListingGrid(items: snap.data!),
          );
        }),
      ),
    );
  }
}
