import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../i18n.dart';

/// Results of a search by photo: the buyer's picture on top, look-alike listings below.
class ImageSearchScreen extends StatefulWidget {
  const ImageSearchScreen({super.key, required this.bytes, required this.filename});
  final Uint8List bytes;
  final String filename;

  @override
  State<ImageSearchScreen> createState() => _ImageSearchScreenState();
}

class _ImageSearchScreenState extends State<ImageSearchScreen> {
  Future<List<Listing>>? _results;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _results ??= SessionScope.of(context).api.searchByImage(widget.bytes, widget.filename);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Фотомен іздеу'))),
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.memory(widget.bytes, width: 72, height: 72, fit: BoxFit.cover),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(tr('Пішіні мен түсі ұқсас тауарлар. Фотоңыз серверде сақталмайды.'),
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ]),
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
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(snap.error is ApiException ? '${snap.error}' : tr('Серверге қосылу мүмкін болмады.'),
                        textAlign: TextAlign.center),
                  ),
                ),
              );
            }
            final items = snap.data!;
            if (items.isEmpty) {
              return SliverFillRemaining(
                  hasScrollBody: false, child: Center(child: Text(tr('Ұқсас тауар табылмады.'))));
            }
            return SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
    );
  }
}
