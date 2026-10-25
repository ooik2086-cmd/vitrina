import 'dart:async';

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
  StreamSubscription<int>? _changes;
  Timer? _later; // hearts tapped one after another reload the list once

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (_loadedSignedIn != session.signedIn) {
      _loadedSignedIn = session.signedIn;
      _items = session.signedIn ? shown(session.api.favorites()) : null;
    }
    _changes ??= session.api.favoritesChanged.listen((_) {
      _later?.cancel();
      _later = Timer(const Duration(milliseconds: 600), () {
        if (mounted && _items != null) _retry();
      });
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    _later?.cancel();
    super.dispose();
  }

  void _retry() {
    setState(() {
      _items = shown(SessionScope.of(context).api.favorites());
    });
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
          if (snap.hasError && snap.connectionState == ConnectionState.done) {
            return ErrorRetry(error: snap.error, onRetry: _retry);
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return RefreshIndicator(
            onRefresh: () async {
              final f = SessionScope.of(context).api.favorites();
              setState(() {
                _items = shown(f);
              });
              await settled(f);
            },
            // Empty, it still pulls down to look again.
            child: snap.data!.isEmpty
                ? LayoutBuilder(
                    builder: (context, box) => SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      // At least the screen's height, more with big text or a phone on its side.
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: box.maxHeight),
                        child: EmptyState(
                          icon: Icons.favorite_border,
                          text: tr(
                              'Таңдаулы тауар әлі жоқ. Ұнаған тауардың бетінде ♡ белгісін басыңыз, ол осында сақталады.'),
                        ),
                      ),
                    ),
                  )
                : ListingGrid(items: snap.data!),
          );
        }),
      ),
    );
  }
}
