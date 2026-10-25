import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../labels.dart';
import '../session.dart';
import '../widgets/common.dart';

/// People this user blocked, with a way to let them back in.
class BlockedScreen extends StatefulWidget {
  const BlockedScreen({super.key});

  @override
  State<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends State<BlockedScreen> {
  late Future<List<BlockedUser>> _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items = shown(SessionScope.of(context).api.blockedUsers());
  }

  void _retry() {
    setState(() {
      _items = shown(SessionScope.of(context).api.blockedUsers());
    });
  }

  /// Asked first, sent once, and said when done; already unblocked (a second tap, another phone) counts as done.
  Future<void> _unblock(BlockedUser b) async {
    if (!await confirmAction(context,
        title: trf('{0} бұғаттан шығарылсын ба?', [personName(b.name)]), action: tr('Бұғаттан шығару'))) {
      return;
    }
    if (!mounted) return;
    final api = SessionScope.of(context).api;
    await once((#unblock, b.userId), () async {
      try {
        await api.unblock(b.userId);
      } on ApiException catch (e) {
        if (e.status != 404) {
          if (mounted) showError(context, e);
          return;
        }
      } catch (e) {
        if (mounted) showError(context, e);
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Бұғаттан шығарылды'))));
      setState(() {
        _items = shown(api.blockedUsers());
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Бұғатталғандар'))),
      body: FutureBuilder<List<BlockedUser>>(
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
                child:
                    Text(tr('Ешкім бұғатталмаған. Чаттағы мәзірден бұғаттауға болады.'), textAlign: TextAlign.center),
              ),
            );
          }
          return ListView(
              padding: contentPadding(context, EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom)),
              children: [
                for (final b in items)
                  ListTile(
                    leading: const Icon(Icons.block),
                    title: Text(personName(b.name)),
                    subtitle: Text(trf('{0} бастап', [formatDay(b.since)])),
                    trailing: TextButton(
                      key: Key('unblock-${b.userId}'),
                      onPressed: () => _unblock(b),
                      child: Text(tr('Бұғаттан шығару')),
                    ),
                  ),
              ]);
        },
      ),
    );
  }
}
