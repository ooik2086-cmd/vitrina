import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../widgets/common.dart';

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
    if (_items == null) return const SignInPrompt(text: 'Ұнаған тауарларды сақтау үшін кіріңіз.');
    return Scaffold(
      appBar: AppBar(title: const Text('Таңдаулылар')),
      body: FutureBuilder<List<Listing>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          if (snap.data!.isEmpty) return const Center(child: Text('Таңдаулы тауар әлі жоқ.'));
          return RefreshIndicator(
            onRefresh: () async {
              final f = SessionScope.of(context).api.favorites();
              setState(() => _items = f);
              await f;
            },
            child: ListingGrid(items: snap.data!),
          );
        },
      ),
    );
  }
}
