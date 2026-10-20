import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../i18n.dart';

const _kinds = {
  'completion': 'Сатылды',
  'partial_refund': 'Ішінара қайтарылды',
  'refund_full': 'Толық қайтарылды',
};

/// Seller's money as the ledger records it, and payouts of what is owed to the seller's bank account.
class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  Future<void> _export() async {
    final days = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr('Қай кезеңнің сатылымы?')),
        children: [
          for (final d in const [30, 90, 365])
            SimpleDialogOption(
              key: Key('export-$d'),
              onPressed: () => Navigator.pop(context, d),
              child: Text(trf('Соңғы {0} күн', [d])),
            ),
        ],
      ),
    );
    if (days == null || !mounted) return;
    try {
      final bytes = await SessionScope.of(context).api.salesCsv(days: days);
      final name = 'vitrina-sales-${DateTime.now().toIso8601String().substring(0, 10)}.csv';
      // On a phone this opens the share sheet (Drive, Telegram, email); in a browser it downloads the file.
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(Uint8List.fromList(bytes), mimeType: 'text/csv', name: name)],
        fileNameOverrides: [name],
        downloadFallbackEnabled: true,
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<(Earnings, Payouts?)>? _data;

  Future<(Earnings, Payouts?)> _load() async {
    final api = SessionScope.of(context).api;
    final payouts = api.payouts().then<Payouts?>((p) => p, onError: (_) => null); // the money view works without it
    return (await api.earnings(), await payouts);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= shown(_load());
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() {
      _data = shown(f);
    });
    await settled(f);
  }

  Future<bool> _editAccount() async {
    final saved = await showModalBottomSheet<bool>(
        context: context, isScrollControlled: true, builder: (_) => const PayoutAccountSheet());
    if (saved == true) await _reload();
    return saved == true;
  }

  Future<void> _payout(Payouts p) async {
    if (!p.hasAccount && !await _editAccount()) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trf('{0} шотыңызға шығарылсын ба?', [formatTenge(p.payableTiyn)])),
        content: Text(tr('Қолдау қызметі банк аударымымен жібереді. Аударылғанда хабарлама келеді.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Жоқ'))),
          FilledButton(
              key: const Key('payout-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Шығару'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await SessionScope.of(context).api.requestPayout();
      await _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Табыс')), actions: [
        IconButton(
          key: const Key('export-sales'),
          tooltip: tr('Сатылымды Excel-ге жүктеу'),
          icon: const Icon(Icons.file_download_outlined),
          onPressed: _export,
        ),
      ]),
      body: FutureBuilder<(Earnings, Payouts?)>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError && snap.connectionState == ConnectionState.done) {
            return ErrorRetry(error: snap.error, onRetry: _reload);
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final (e, p) = snap.data!;
          // The balance card is the primary colour: ink on the light canvas, white on the dark one.
          final scheme = theme.colorScheme;
          final muted = scheme.onPrimary.withValues(alpha: 0.7);
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 8, 20, 24)), children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(Brand.radius)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Сізге тиесілі'), style: TextStyle(color: muted)),
                  const SizedBox(height: 4),
                  Text(formatTenge(e.payableTiyn),
                      style: weight(theme.textTheme.headlineMedium!, 750).copyWith(color: scheme.onPrimary)),
                  const SizedBox(height: 4),
                  if (p == null)
                    Text(tr('Төлем серіктесі қосылғанда банк шотыңызға шығарып алуға болады.'),
                        style: TextStyle(color: muted, fontSize: 13))
                  else ...[
                    Text(
                        p.open
                            ? tr('Шығару сұрауыңыз қаралуда.')
                            : p.payableTiyn < p.minTiyn
                                ? trf('Ең аз шығару сомасы — {0}.', [formatTenge(p.minTiyn)])
                                : tr('Банк шотыңызға шығарып алуға болады.'),
                        style: TextStyle(color: muted, fontSize: 13)),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const Key('payout'),
                      style: FilledButton.styleFrom(backgroundColor: scheme.onPrimary, foregroundColor: scheme.primary),
                      onPressed: p.open || p.payableTiyn < p.minTiyn ? null : () => _payout(p),
                      icon: const Icon(Icons.account_balance_outlined),
                      label: Text(tr('Шотқа шығару')),
                    ),
                  ],
                ]),
              ),
              if (p != null)
                ListTile(
                  key: const Key('payout-account'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.account_balance_outlined),
                  title: Text(p.hasAccount ? tr('Банк шоты') : tr('Банк шотын қосу')),
                  subtitle: Text(p.hasAccount
                      ? tr('Ақша осы шотқа аударылады.')
                      : tr('IBAN және ЖСН/БСН: ақшаны шығару үшін керек.')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _editAccount,
                ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _Stat(label: tr('Ұсталып тұр'), value: formatTenge(e.heldTiyn))),
                const SizedBox(width: 12),
                Expanded(child: _Stat(label: tr('Комиссия'), value: formatTenge(e.feesTiyn))),
              ]),
              const SizedBox(height: 8),
              Text(
                  tr('«Ұсталып тұр» — сатып алушы тауарды алғанын растағанша не тексеру мерзімі өткенше сақталатын ақша. Содан кейін ол комиссия шегеріліп, сізге тиесілі сомаға қосылады.'),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              if (p != null && p.items.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(tr('Шығарулар'), style: theme.textTheme.titleMedium),
                for (final i in p.items) _PayoutTile(payout: i),
              ],
              const SizedBox(height: 24),
              Text(tr('Есеп айырысулар'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              if (e.items.isEmpty)
                Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Text(tr('Әзірге аяқталған сатылым жоқ.'))),
              for (final i in e.items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(i.listingTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('№${i.orderId} · ${tr(_kinds[i.kind] ?? i.kind)} · '
                      '${i.at.toLocal().day.toString().padLeft(2, '0')}.${i.at.toLocal().month.toString().padLeft(2, '0')}'
                      '${i.feeTiyn > 0 ? ' · комиссия ${formatTenge(i.feeTiyn)}' : ''}'),
                  trailing: Text(formatTenge(i.netTiyn),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontVariations: [FontVariation('wght', 700)])),
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

const _payoutStatuses = {'requested': 'Қаралуда', 'paid': 'Аударылды', 'rejected': 'Қайтарылды'};

class _PayoutTile extends StatelessWidget {
  const _PayoutTile({required this.payout});
  final PayoutInfo payout;

  @override
  Widget build(BuildContext context) {
    final p = payout;
    final at = p.createdAt.toLocal();
    final day = '${at.day.toString().padLeft(2, '0')}.${at.month.toString().padLeft(2, '0')}';
    final color = switch (p.status) {
      'paid' => const Color(0xFF1E8E3E),
      'rejected' => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return ListTile(
      key: Key('payout-${p.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text.rich(TextSpan(children: [
        TextSpan(
            text: tr(_payoutStatuses[p.status] ?? p.status),
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontVariations: const [FontVariation('wght', 700)])),
        TextSpan(text: ' · $day · ${p.ibanMasked}'),
      ])),
      subtitle: p.status == 'rejected' && p.reason != null
          ? Text(p.reason!)
          : p.bankRef != null
              ? Text(trf('Төлем тапсырмасы {0}', [p.bankRef]))
              : null,
      trailing: Text(formatTenge(p.amountTiyn),
          style: const TextStyle(fontWeight: FontWeight.w700, fontVariations: [FontVariation('wght', 700)])),
    );
  }
}

/// The seller's bank details. The server checks the IBAN and the IIN/BIN check digits.
class PayoutAccountSheet extends StatefulWidget {
  const PayoutAccountSheet({super.key});

  @override
  State<PayoutAccountSheet> createState() => _PayoutAccountSheetState();
}

class _PayoutAccountSheetState extends State<PayoutAccountSheet> {
  final _holder = TextEditingController();
  final _iban = TextEditingController();
  final _tax = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _requested = false;
  Object? _loadError;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_requested) _load();
  }

  /// Fills the fields with the saved account. A failure is said above them, so empty fields are not taken for
  /// «no account saved»; it stays apart from a save's own error.
  Future<void> _load() async {
    _requested = true;
    if (_loadError != null) setState(() => _loading = true);
    try {
      final a = await SessionScope.of(context).api.payoutAccount();
      if (!mounted) return;
      setState(() {
        _loadError = null;
        // What the seller already typed while it loaded is kept.
        if (a != null && _holder.text.isEmpty && _iban.text.isEmpty && _tax.text.isEmpty) {
          _holder.text = a.holderName;
          _iban.text = a.iban;
          _tax.text = a.taxId;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    } finally {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _holder.dispose();
    _iban.dispose();
    _tax.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SessionScope.of(context)
          .api
          .setPayoutAccount(holderName: _holder.text.trim(), iban: _iban.text, taxId: _tax.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Банк шоты'), style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(tr('Шот сіздің не ЖК-ңыздың атында болуы керек. Деректемені тек қолдау қызметі көреді.'),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        if (_loadError != null) ...[
          const SizedBox(height: 12),
          Card(child: RetryLine(what: tr('Сақталған деректеме'), error: _loadError, busy: _loading, onRetry: _load)),
        ],
        const SizedBox(height: 16),
        TextField(
            key: const Key('payout-holder'),
            controller: _holder,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr('Шот иесі (аты-жөні не ЖК атауы)'))),
        const SizedBox(height: 12),
        TextField(
            key: const Key('payout-iban'),
            controller: _iban,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'IBAN', hintText: 'KZ00 0000 0000 0000 0000')),
        const SizedBox(height: 12),
        TextField(
            key: const Key('payout-tax'),
            controller: _tax,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('ЖСН не БСН (12 цифр)'))),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, key: const Key('payout-error'), style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 16),
        FilledButton(key: const Key('payout-save'), onPressed: _busy ? null : _save, child: Text(tr('Сақтау'))),
      ]),
    );
  }
}
