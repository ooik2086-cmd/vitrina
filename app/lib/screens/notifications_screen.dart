import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../theme.dart';
import 'chat_screen.dart';
import 'order_screen.dart';

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'жаңа ғана';
  if (d.inHours < 1) return '${d.inMinutes} мин бұрын';
  if (d.inDays < 1) return '${d.inHours} сағ бұрын';
  return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}';
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  Future<List<AppNotification>>? _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items ??= _load();
  }

  Future<List<AppNotification>> _load() async {
    final api = SessionScope.of(context).api;
    final (_, items) = await api.notifications();
    // Opening the list counts as reading it; the dots stay on this visit so new items are still visible.
    if (items.any((n) => !n.read)) api.readAllNotifications().ignore();
    return items;
  }

  void _open(AppNotification n) {
    final route = n.conversationId != null
        ? MaterialPageRoute(builder: (_) => ChatScreen(conversationId: n.conversationId!))
        : n.orderId != null
            ? MaterialPageRoute(builder: (_) => OrderScreen(orderId: n.orderId!))
            : null;
    if (route != null) Navigator.of(context).push(route);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Хабарландырулар')),
      body: FutureBuilder<List<AppNotification>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          if (items.isEmpty) return const Center(child: Text('Хабарландыру жоқ.'));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(indent: 72),
            itemBuilder: (context, i) {
              final n = items[i];
              final icon = switch (n.kind) {
                'message' => Icons.chat_bubble_outline_rounded,
                'review' => Icons.star_outline_rounded,
                _ => Icons.local_shipping_outlined,
              };
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(icon, color: theme.colorScheme.onSurface),
                ),
                title: Text(n.text, style: n.read ? null : weight(theme.textTheme.bodyLarge!, 650)),
                subtitle: Text(_ago(n.createdAt)),
                trailing: n.read ? null : const CircleAvatar(radius: 4, backgroundColor: Brand.accent),
                onTap: () => _open(n),
              );
            },
          );
        },
      ),
    );
  }
}
