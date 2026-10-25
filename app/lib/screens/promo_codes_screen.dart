import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../i18n.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The seller's discount codes: share one in Instagram or WhatsApp, the buyer types it at checkout.
class PromoCodesScreen extends StatefulWidget {
  const PromoCodesScreen({super.key});

  @override
  State<PromoCodesScreen> createState() => _PromoCodesScreenState();
}

class _PromoCodesScreenState extends State<PromoCodesScreen> {
  late Future<List<PromoCode>> _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items = shown(SessionScope.of(context).api.promoCodes());
  }

  void _reload() => setState(() {
        _items = shown(SessionScope.of(context).api.promoCodes());
      });

  Future<void> _create() async {
    final made = await showSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const PromoCodeSheet(),
    );
    if (made == true && mounted) _reload();
  }

  Future<void> _end(PromoCode p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trf('{0} промокодын тоқтату керек пе?', [p.code])),
        content: Text(tr('Жаңа тапсырыста жұмыс істемейді. Бұрын жасалған тапсырыстардың жеңілдігі сақталады.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Жабу'))),
          FilledButton(
              key: const Key('confirm-end'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Промокодты тоқтату'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await SessionScope.of(context).api.endPromoCode(p.id);
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Промокодтар'))),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('new-promo'),
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text(tr('Жаңа промокод')),
      ),
      body: FutureBuilder<List<PromoCode>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError && snap.connectionState == ConnectionState.done) {
            return ErrorRetry(error: snap.error, onRetry: _reload);
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  tr('Промокод жасап, Instagram не WhatsApp-та бөлісіңіз. Сатып алушы оны тапсырыс беру кезінде енгізеді, жеңілдік сіздің бағаңыздан шегеріледі.'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: contentPadding(context, const EdgeInsets.fromLTRB(16, 8, 16, 96)),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _PromoCard(promo: items[i], onEnd: () => _end(items[i])),
          );
        },
      ),
    );
  }
}

class _PromoCard extends StatelessWidget {
  const _PromoCard({required this.promo, required this.onEnd});
  final PromoCode promo;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = promo;
    final value = p.percent != null ? '−${p.percent}%' : '−${formatTenge(p.amountTiyn!)}';
    final rules = [
      if (p.minPriceTiyn > 0) trf('{0} бастап', [formatTenge(p.minPriceTiyn)]),
      if (p.endsOn != null) trf('{0} дейін', [formatDay(p.endsOn!)]),
      p.maxUses == null ? trf('{0} рет қолданылды', [p.uses]) : trf('{0} / {1} қолданылды', [p.uses, p.maxUses]),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Brand.accent.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(value, style: weight(theme.textTheme.titleSmall!, 800).copyWith(color: accentText(context))),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(p.code, style: weight(theme.textTheme.titleMedium!, 800).copyWith(letterSpacing: 1)),
              const SizedBox(height: 2),
              Text(rules.join(' · '), style: theme.textTheme.bodySmall),
              if (!p.active)
                Text(tr('Мерзімі өтті'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            ]),
          ),
          IconButton(
            key: Key('end-${p.code}'),
            tooltip: tr('Промокодты тоқтату'),
            icon: const Icon(Icons.block_outlined),
            onPressed: onEnd,
          ),
        ]),
      ),
    );
  }
}

/// New code: a percent or a sum off, with optional limits.
class PromoCodeSheet extends StatefulWidget {
  const PromoCodeSheet({super.key});

  @override
  State<PromoCodeSheet> createState() => _PromoCodeSheetState();
}

class _PromoCodeSheetState extends State<PromoCodeSheet> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController(), _value = TextEditingController();
  final _minPrice = TextEditingController(), _maxUses = TextEditingController();
  bool _percent = true, _busy = false;
  DateTime? _endsOn;
  String? _error;
  static final _digits = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(9)];

  @override
  void dispose() {
    for (final c in [_code, _value, _minPrice, _maxUses]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _int(TextEditingController c) => int.tryParse(c.text.trim());

  Future<void> _pickEnd() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      helpText: tr('Соңғы күні'),
      initialDate: _endsOn ?? today.add(const Duration(days: 14)),
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _endsOn = picked);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final value = _int(_value)!, minPrice = _int(_minPrice), maxUses = _int(_maxUses);
    final end = _endsOn;
    try {
      await SessionScope.of(context).api.createPromoCode({
        'code': _code.text.trim().toUpperCase(),
        if (_percent) 'percent': value else 'amount_tiyn': value * 100,
        if (minPrice != null) 'min_price_tiyn': minPrice * 100,
        if (maxUses != null) 'max_uses': maxUses,
        if (end != null)
          'ends_on': '${end.year}-${end.month.toString().padLeft(2, '0')}-${end.day.toString().padLeft(2, '0')}',
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      // A snackbar would sit behind this sheet, so the reason is written above the button.
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Жаңа промокод'), style: weight(theme.textTheme.titleLarge!, 800)),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('promo-new-code'),
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: tr('Код'), hintText: 'QADAM10', prefixIcon: const Icon(Icons.tag)),
              validator: (v) =>
                  RegExp(r'^[A-Za-z0-9]{4,20}$').hasMatch((v ?? '').trim()) ? null : tr('4–20 латын әрпі не сан'),
            ),
            const SizedBox(height: 14),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: true, label: Text(tr('Пайыз'))),
                ButtonSegment(value: false, label: Text(tr('Сома, ₸'))),
              ],
              selected: {_percent},
              onSelectionChanged: (v) => setState(() => _percent = v.first),
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: const Key('promo-new-value'),
              controller: _value,
              keyboardType: TextInputType.number,
              inputFormatters: _digits,
              decoration: InputDecoration(
                  labelText: _percent ? tr('Жеңілдік, %') : tr('Жеңілдік, ₸'), suffixText: _percent ? '%' : '₸'),
              validator: (_) {
                final v = _int(_value);
                if (_percent) return v == null || v < 5 || v > 50 ? tr('5-тен 50%-ға дейін') : null;
                return v == null || v < 100 ? tr('Кемінде 100 ₸') : null;
              },
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextFormField(
                  key: const Key('promo-new-min-price'),
                  controller: _minPrice,
                  keyboardType: TextInputType.number,
                  inputFormatters: _digits,
                  decoration: InputDecoration(labelText: tr('Ең аз баға, ₸'), helperText: tr('Міндетті емес')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  key: const Key('promo-new-max-uses'),
                  controller: _maxUses,
                  keyboardType: TextInputType.number,
                  inputFormatters: _digits,
                  decoration: InputDecoration(labelText: tr('Қанша рет'), helperText: tr('Міндетті емес')),
                  validator: (_) {
                    final v = _int(_maxUses);
                    if (_maxUses.text.trim().isEmpty) return null;
                    return v == null || v < 1 || v > 100000 ? tr('1-ден 100 000-ға дейін') : null;
                  },
                ),
              ),
            ]),
            const SizedBox(height: 6),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(_endsOn == null ? tr('Мерзімсіз') : trf('{0} дейін', [formatDay(_endsOn!)])),
              trailing: _endsOn == null
                  ? TextButton(onPressed: _pickEnd, child: Text(tr('Мерзім қою')))
                  : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _endsOn = null)),
            ),
            Text(tr('Әр сатып алушы кодты бір рет қолданады. Жеңілдік тауар бағасының жартысынан аспайды.'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (_error != null) ...[
              const SizedBox(height: 12),
              // Read out as it appears, so a screen-reader user hears why nothing was made.
              Semantics(
                liveRegion: true,
                child: Text(_error!,
                    key: const Key('promo-error'),
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('promo-save'),
                onPressed: _busy ? null : _save,
                child: Text(tr('Жасау')),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
