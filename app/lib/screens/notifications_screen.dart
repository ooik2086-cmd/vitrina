import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../theme.dart';
import 'chat_screen.dart';
import 'listing_screen.dart';
import 'notification_settings_screen.dart';
import 'offers_screen.dart';
import 'order_screen.dart';
import '../widgets/questions.dart';
import '../i18n.dart';

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return tr('жаңа ғана');
  if (d.inHours < 1) return trf('{0} мин бұрын', [d.inMinutes]);
  if (d.inDays < 1) return trf('{0} сағ бұрын', [d.inHours]);
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
    final route = n.kind == 'offer'
        ? MaterialPageRoute(builder: (_) => const OffersScreen())
        : n.kind == 'question' && n.listingId != null
            ? MaterialPageRoute(builder: (_) => QuestionsScreen(listingId: n.listingId!, seller: true))
            : n.conversationId != null
                ? MaterialPageRoute(builder: (_) => ChatScreen(conversationId: n.conversationId!))
                : n.orderId != null
                    ? MaterialPageRoute(builder: (_) => OrderScreen(orderId: n.orderId!))
                    : n.listingId != null
                        ? MaterialPageRoute(builder: (_) => ListingScreen(listingId: n.listingId!))
                        : null;
    if (route != null) Navigator.of(context).push(route);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Хабарландырулар')), actions: [
        IconButton(
          key: const Key('alert-settings'),
          tooltip: tr('Хабарлама баптаулары'),
          icon: const Icon(Icons.tune),
          onPressed: () =>
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationSettingsScreen())),
        ),
      ]),
      body: FutureBuilder<List<AppNotification>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          if (items.isEmpty) return Center(child: Text(tr('Хабарландыру жоқ.')));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(indent: 72),
            itemBuilder: (context, i) {
              final n = items[i];
              final icon = switch (n.kind) {
                'message' => Icons.chat_bubble_outline_rounded,
                'review' || 'review_reply' => Icons.star_outline_rounded,
                'price_drop' => Icons.trending_down_rounded,
                'offer' || 'offer_reply' => Icons.local_offer_outlined,
                'saved_search' => Icons.notifications_active_outlined,
                'followed_shop' => Icons.storefront_outlined,
                'back_in_stock' => Icons.inventory_outlined,
                'moderation' => Icons.fact_check_outlined,
                'listing_hidden' || 'report_closed' => Icons.flag_outlined,
                _ => Icons.local_shipping_outlined,
              };
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(icon, color: theme.colorScheme.onSurface),
                ),
                title: Text(n.shown, style: n.read ? null : weight(theme.textTheme.bodyLarge!, 650)),
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
