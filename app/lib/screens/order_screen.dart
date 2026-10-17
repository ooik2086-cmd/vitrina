import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// An action the current user may offer on an order. The server still checks every move.
class _Action {
  const _Action(this.label, this.endpoint, {this.needs, this.destructive = false});
  final String label;
  final String endpoint;
  final String? needs; // 'reason' or 'tracking'
  final bool destructive;
}

List<_Action> _actionsFor(OrderInfo o, {required bool isBuyer}) {
  if (isBuyer) {
    return switch (o.status) {
      'CREATED' => const [_Action('Төлеу', 'pay'), _Action('Бас тарту', 'cancel', destructive: true)],
      'PAYMENT_PENDING' => const [_Action('Бас тарту', 'cancel', destructive: true)],
      'PAID' => const [_Action('Бас тарту, ақшаны қайтару', 'cancel', destructive: true)],
      'SHIPPED' || 'IN_TRANSIT' => const [_Action('Дау ашу', 'dispute', needs: 'reason', destructive: true)],
      'DELIVERED_PENDING_CONFIRMATION' => const [
          _Action('Алдым, бәрі дұрыс', 'confirm'),
          _Action('Қайтару', 'return', needs: 'reason'),
          _Action('Дау ашу', 'dispute', needs: 'reason', destructive: true),
        ],
      _ => const [],
    };
  }
  return switch (o.status) {
    'PAID' => const [
        _Action('Қабылдау', 'accept'),
        _Action('Бас тарту', 'decline', needs: 'reason', destructive: true)
      ],
    'SELLER_ACCEPTED' || 'PREPARING' => const [
        _Action('Жібердім', 'ship', needs: 'tracking'),
        _Action('Бас тарту', 'decline', needs: 'reason', destructive: true),
      ],
    'RETURN_REQUESTED' => const [_Action('Қайтаруды мақұлдау', 'approve-return')],
    _ => const [],
  };
}

class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.orderId});
  final int orderId;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  OrderInfo? _order;
  Object? _error;
  bool _busy = false;
  bool _paymentStarted = false;
  bool _reviewed = false;

  Api get _api => SessionScope.of(context).api;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_order == null && _error == null) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final o = await _api.order(widget.orderId);
      if (mounted) setState(() => _order = o);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<String?> _ask(String title, String hint) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, autofocus: true, maxLines: 3, decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Жабу')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Жіберу')),
        ],
      ),
    );
  }

  Future<void> _do(_Action a) async {
    String? reason, tracking;
    if (a.needs == 'reason') {
      reason = await _ask(a.label, 'Себебін жазыңыз');
      if (reason == null || reason.isEmpty) return;
    } else if (a.needs == 'tracking') {
      tracking = await _ask('Трек-нөмір', 'Мысалы, KZ123456789');
      if (tracking == null || tracking.isEmpty) return;
    }
    setState(() => _busy = true);
    try {
      if (a.endpoint == 'pay') {
        await _api.startPayment(widget.orderId);
        _paymentStarted = true;
        await _refresh();
      } else {
        await _api.action(widget.orderId, a.endpoint, reason: reason, trackingNumber: tracking);
        await _refresh(); // the action reply has no history or photo; reload the full view
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = SessionScope.of(context).me;
    final o = _order;
    return Scaffold(
      appBar: AppBar(title: Text('Тапсырыс №${widget.orderId}')),
      body: o == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text('$_error'))
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
                _OrderHeader(order: o),
                const SizedBox(height: 16),
                _Timeline(order: o),
                const SizedBox(height: 16),
                const _ProtectionNote(),
                if (_paymentStarted && o.status == 'PAYMENT_PENDING')
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('Төлем провайдері әлі қосылмаған: сынақ режимінде төлем расталмайды.'),
                  ),
                const SizedBox(height: 16),
                if (me?.id == o.buyerId && o.status == 'COMPLETED' && !o.reviewed && !_reviewed)
                  _ReviewForm(orderId: o.id, onDone: () => setState(() => _reviewed = true)),
                if (_reviewed)
                  const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('Пікіріңіз үшін рақмет!')),
                for (final a in _actionsFor(o, isBuyer: me?.id == o.buyerId))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: a.destructive
                        ? OutlinedButton(onPressed: _busy ? null : () => _do(a), child: Text(a.label))
                        : FilledButton(onPressed: _busy ? null : () => _do(a), child: Text(a.label)),
                  ),
              ]),
            ),
    );
  }
}

class _OrderHeader extends StatelessWidget {
  const _OrderHeader({required this.order});
  final OrderInfo order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = order;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 76,
              height: 76,
              color: Brand.studio,
              child: o.listingCover == null
                  ? const Icon(Icons.image_outlined)
                  : Image.network(o.listingCover!,
                      fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(o.listingTitle ?? '',
                  style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (o.sizeLabel != null) Text('Өлшем ${o.sizeLabel} · ${o.sizeCm} см', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(formatTenge(o.totalTiyn), style: weight(theme.textTheme.titleMedium!, 750)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The happy path as five steps; disputes, returns and cancellations show as a banner instead.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.order});
  final OrderInfo order;

  static const _steps = [
    ('PAID', 'Төленді', Icons.lock_outline_rounded),
    ('SELLER_ACCEPTED', 'Сатушы қабылдады', Icons.storefront_outlined),
    ('SHIPPED', 'Жіберілді', Icons.local_shipping_outlined),
    ('DELIVERED_PENDING_CONFIRMATION', 'Жеткізілді', Icons.inventory_2_outlined),
    ('COMPLETED', 'Аяқталды', Icons.check_circle_outline_rounded),
  ];
  static const _off = {'DISPUTED', 'RETURN_REQUESTED', 'REFUND_PENDING', 'REFUNDED', 'CANCELLED'};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final o = order;
    final reached = {for (final h in o.history) h.status: h.at};
    String when(DateTime t) =>
        '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}, ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_off.contains(o.status))
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(14)),
              child: Text(label(orderStatuses, o.status),
                  style: weight(theme.textTheme.bodyMedium!, 650).copyWith(color: scheme.onErrorContainer)),
            )
          else if (!reached.containsKey('PAID'))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(label(orderStatuses, o.status), style: theme.textTheme.titleSmall),
            ),
          for (final (i, (code, title, icon)) in _steps.indexed)
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Column(children: [
                  CircleAvatar(
                    radius: 15,
                    backgroundColor: reached.containsKey(code) ? scheme.primary : scheme.surfaceContainerHighest,
                    child: Icon(icon,
                        size: 16, color: reached.containsKey(code) ? scheme.onPrimary : scheme.onSurfaceVariant),
                  ),
                  if (i < _steps.length - 1)
                    Expanded(
                      child: Container(
                        width: 2,
                        margin: const EdgeInsets.symmetric(vertical: 2),
                        color: reached.containsKey(_steps[i + 1].$1) ? scheme.primary : scheme.outlineVariant,
                      ),
                    ),
                ]),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 5, bottom: 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title,
                          style: weight(theme.textTheme.bodyMedium!, reached.containsKey(code) ? 650 : 450)
                              .copyWith(color: reached.containsKey(code) ? scheme.onSurface : scheme.onSurfaceVariant)),
                      if (reached[code] != null) Text(when(reached[code]!), style: theme.textTheme.labelSmall),
                      if (code == 'SHIPPED' && o.trackingNumber != null)
                        SelectableText('Трек-нөмір: ${o.trackingNumber}', style: theme.textTheme.labelMedium),
                    ]),
                  ),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _ProtectionNote extends StatelessWidget {
  const _ProtectionNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Brand.radius)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.shield_outlined),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Ақша сатушыға сіз тауарды алып, растағаннан кейін ғана өтеді. '
            'Бұл схема лицензиясы бар төлем серіктесі қосылғаннан кейін ғана іске қосылады.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ]),
    );
  }
}

class _ReviewForm extends StatefulWidget {
  const _ReviewForm({required this.orderId, required this.onDone});
  final int orderId;
  final VoidCallback onDone;

  @override
  State<_ReviewForm> createState() => _ReviewFormState();
}

class _ReviewFormState extends State<_ReviewForm> {
  int _rating = 0;
  final _text = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await SessionScope.of(context).api.review(widget.orderId, _rating, _text.text.trim());
      widget.onDone();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Сатушыны бағалаңыз', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(children: [
            for (var i = 1; i <= 5; i++)
              IconButton(
                tooltip: '$i жұлдыз',
                onPressed: () => setState(() => _rating = i),
                icon: Icon(i <= _rating ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: 32, color: const Color(0xFFFFB020)),
              ),
          ]),
          TextField(
            controller: _text,
            maxLines: 3,
            maxLength: 1000,
            decoration: const InputDecoration(hintText: 'Тауар сипаттамаға сәйкес пе? Жеткізу қалай болды?'),
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _rating == 0 || _busy ? null : _submit,
              child: const Text('Пікір қалдыру'),
            ),
          ),
        ]),
      ),
    );
  }
}
