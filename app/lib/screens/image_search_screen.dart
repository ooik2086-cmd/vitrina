import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../i18n.dart';

/// Camera or gallery, then the results page; [replace] puts it in place of the results already shown.
Future<void> searchByPhoto(BuildContext context, {bool replace = false}) async {
  final file = await pickPhoto(context,
      title: tr('Фотомен іздеу'), subtitle: tr('Ұнаған аяқкиімнің суретін түсіріңіз немесе таңдаңыз'));
  if (file == null || !context.mounted) return;
  final Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (_) {
    // A file the phone would not hand over: said, rather than nothing happening.
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('Фотоны ашу мүмкін болмады. Қайта көріңіз.'))));
    }
    return;
  }
  if (!context.mounted) return;
  final page = MaterialPageRoute<void>(builder: (_) => ImageSearchScreen(bytes: bytes, filename: file.name));
  final nav = Navigator.of(context);
  replace ? nav.pushReplacement(page) : nav.push(page);
}

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
    _results ??= shown(SessionScope.of(context).api.searchByImage(widget.bytes, widget.filename));
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
                child: ErrorRetry(
                  error: snap.error,
                  onRetry: () => setState(() {
                    _results = shown(SessionScope.of(context).api.searchByImage(widget.bytes, widget.filename));
                  }),
                ),
              );
            }
            final items = snap.data!;
            if (items.isEmpty) {
              // Not a dead end: back to the catalog, to try another photo or search in words.
              return SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                      icon: Icons.image_search_outlined,
                      text: tr('Ұқсас тауар табылмады.'),
                      action: OutlinedButton(
                          key: const Key('another-photo'),
                          // The picker again, its results in place of these, as the words promise.
                          onPressed: () => searchByPhoto(context, replace: true),
                          child: Text(tr('Басқа фотомен іздеу')))));
            }
            return SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              sliver: SliverGrid.builder(
                gridDelegate: ListingGridDelegate.of(context),
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
