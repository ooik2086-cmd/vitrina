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
    _items = SessionScope.of(context).api.blockedUsers();
  }

  Future<void> _unblock(BlockedUser b) async {
    final api = SessionScope.of(context).api;
    try {
      await api.unblock(b.userId);
      if (!mounted) return;
      setState(() {
        _items = api.blockedUsers();
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Бұғатталғандар'))),
      body: FutureBuilder<List<BlockedUser>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
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
          return ListView(children: [
            for (final b in items)
              ListTile(
                leading: const Icon(Icons.block),
                title: Text(b.name),
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
