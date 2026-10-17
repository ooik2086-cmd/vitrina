import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';

const _kinds = {
  'completion': 'Сатылды',
  'partial_refund': 'Ішінара қайтарылды',
  'refund_full': 'Толық қайтарылды',
};

/// Seller's money as the ledger records it. Payouts to a bank card come with the payment partner.
class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  Future<Earnings>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= SessionScope.of(context).api.earnings();
  }

  Future<void> _reload() async {
    final f = SessionScope.of(context).api.earnings();
    setState(() => _data = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Табыс')),
      body: FutureBuilder<Earnings>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final e = snap.data!;
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Brand.ink, borderRadius: BorderRadius.circular(Brand.radius)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Сізге тиесілі', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 4),
                  Text(formatTenge(e.payableTiyn),
                      style: weight(theme.textTheme.headlineMedium!, 750).copyWith(color: Colors.white)),
                  const SizedBox(height: 4),
                  const Text('Төлем серіктесі қосылғанда картаңызға аударылады.',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                ]),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _Stat(label: 'Ұсталып тұр', value: formatTenge(e.heldTiyn))),
                const SizedBox(width: 12),
                Expanded(child: _Stat(label: 'Комиссия', value: formatTenge(e.feesTiyn))),
              ]),
              const SizedBox(height: 8),
              Text('«Ұсталып тұр» — сатып алушы тауарды алып, растағанша сақталатын ақша.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 24),
              Text('Есеп айырысулар', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              if (e.items.isEmpty)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24), child: Text('Әзірге аяқталған сатылым жоқ.')),
              for (final i in e.items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(i.listingTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('№${i.orderId} · ${_kinds[i.kind] ?? i.kind} · '
                      '${i.at.toLocal().day.toString().padLeft(2, '0')}.${i.at.toLocal().month.toString().padLeft(2, '0')}'
                      '${i.feeTiyn > 0 ? ' · комиссия ${formatTenge(i.feeTiyn)}' : ''}'),
                  trailing: Text(formatTenge(i.netTiyn), style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
            ]),
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(Brand.radius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(value, style: weight(theme.textTheme.titleMedium!, 700)),
      ]),
    );
  }
}
