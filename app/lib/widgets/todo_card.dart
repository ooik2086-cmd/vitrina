import 'package:flutter/material.dart';

import '../i18n.dart';
import '../screens/my_listings_screen.dart';
import '../screens/offers_screen.dart';
import '../screens/orders_screen.dart';
import '../session.dart';
import '../theme.dart';

/// One line of the to-do card: the server's count key, what it says, and where a tap goes.
typedef TodoLine = ({String key, IconData icon, String label, Widget Function() open});

final List<TodoLine> todoLines = [
  (
    key: 'to_accept',
    icon: Icons.inventory_2_outlined,
    label: 'Қабылдауды күтетін тапсырыс',
    open: () => const OrdersScreen(sellerTab: true, onlyMine: true),
  ),
  (
    key: 'to_ship',
    icon: Icons.local_shipping_outlined,
    label: 'Жіберуді күтетін тапсырыс',
    open: () => const OrdersScreen(sellerTab: true, onlyMine: true),
  ),
  (
    key: 'returns',
    icon: Icons.assignment_return_outlined,
    label: 'Қайтару сұрауы',
    open: () => const OrdersScreen(sellerTab: true, onlyMine: true),
  ),
  (key: 'offers', icon: Icons.local_offer_outlined, label: 'Жауапсыз баға ұсынысы', open: () => const OffersScreen()),
  (key: 'questions', icon: Icons.help_outline_rounded, label: 'Жауапсыз сұрақ', open: () => const MyListingsScreen()),
  (
    key: 'to_pay',
    icon: Icons.payments_outlined,
    label: 'Төлемді күтетін тапсырыс',
    open: () => const OrdersScreen(onlyMine: true),
  ),
  (
    key: 'to_confirm',
    icon: Icons.task_alt_rounded,
    label: 'Алғаныңызды растау',
    open: () => const OrdersScreen(onlyMine: true),
  ),
  (
    key: 'offers_answered',
    icon: Icons.mark_email_unread_outlined,
    label: 'Сатушы жауап берген ұсыныс',
    open: () => const OffersScreen(seller: false),
  ),
];

/// The top of the profile: everything that waits on this person, one tap from where it is done.
/// Nothing is shown when nothing waits.
class TodoCard extends StatefulWidget {
  const TodoCard({super.key});

  @override
  State<TodoCard> createState() => _TodoCardState();
}

class _TodoCardState extends State<TodoCard> {
  Map<String, int>? _counts;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_counts == null) _load();
  }

  Future<void> _load() async {
    try {
      final counts = await SessionScope.of(context).api.todo();
      if (mounted) setState(() => _counts = counts);
    } catch (_) {
      // The card is a shortcut; the profile works without it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counts = _counts ?? const <String, int>{};
    final lines = [
      for (final l in todoLines)
        if ((counts[l.key] ?? 0) > 0) l
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Card(
      key: const Key('todo'),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text(tr('Сізді күтеді'), style: weight(theme.textTheme.titleSmall!, 700)),
        ),
        for (final l in lines)
          ListTile(
            key: Key('todo-${l.key}'),
            leading: Icon(l.icon),
            title: Text(tr(l.label)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: Brand.accent,
                child: Text('${counts[l.key]}',
                    style: theme.textTheme.labelMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              const Icon(Icons.chevron_right),
            ]),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => l.open()));
              _load();
            },
          ),
        const SizedBox(height: 4),
      ]),
    );
  }
}
