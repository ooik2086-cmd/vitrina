import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../i18n.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'listing_screen.dart';

const offerStatuses = {
  'pending': 'Жауап күтуде',
  'countered': 'Сатушы баға ұсынды',
  'accepted': 'Қабылданды',
  'declined': 'Қабылданбады',
  'withdrawn': 'Қайтарып алынды',
  'ordered': 'Тапсырыс берілді',
  'expired': 'Мерзімі өтті',
};

/// Same floor as the server: offers under half the price are not sent.
int minOfferTiyn(int priceTiyn) => ((priceTiyn / 2 / 100).ceil()) * 100;

String _until(DateTime at) {
  final local = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)} ${two(local.hour)}:${two(local.minute)}';
}

/// Bottom sheet where a buyer names their price for the chosen size.
class OfferSheet extends StatefulWidget {
  const OfferSheet({super.key, required this.listing, required this.size});
  final Listing listing;
  final ShoeSize size;

  @override
  State<OfferSheet> createState() => _OfferSheetState();
}

class _OfferSheetState extends State<OfferSheet> {
  final _amount = TextEditingController();
  bool _busy = false;
  String? _error;

  int get _price => widget.listing.priceTiyn;
  int? get _tiyn {
    final v = int.tryParse(_amount.text.replaceAll(RegExp(r'\s'), ''));
    return v == null ? null : v * 100;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _preset(int percent) {
    final tenge = (_price * (100 - percent) / 100 / 100).round();
    setState(() {
      _amount.text = '$tenge';
      _error = null;
    });
  }

  Future<void> _send() async {
    final v = _tiyn;
    if (v == null || v >= _price) {
      setState(() => _error = tr('Ұсыныс бағадан төмен болуы керек.'));
      return;
    }
    if (v < minOfferTiyn(_price)) {
      setState(() => _error = trf('Кемінде {0} ұсыныңыз.', [formatTenge(minOfferTiyn(_price))]));
      return;
    }
    setState(() => _busy = true);
    try {
      final offer = await SessionScope.of(context).api.makeOffer(widget.listing.id, widget.size.id, v);
      if (mounted) Navigator.pop(context, offer);
    } catch (e) {
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
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Баға ұсыну'), style: weight(theme.textTheme.titleLarge!, 800)),
        const SizedBox(height: 4),
        Text(trf('{0} · өлшем {1} · бағасы {2}', [widget.listing.title, widget.size.label, formatTenge(_price)]),
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, children: [
          for (final p in const [5, 10, 15])
            ActionChip(
              key: Key('offer-$p'),
              label: Text(trf('−{0}% · {1}', [p, formatTenge(((_price * (100 - p) / 100 / 100).round()) * 100)])),
              onPressed: () => _preset(p),
            ),
        ]),
        const SizedBox(height: 12),
        TextField(
          key: const Key('offer-amount'),
          controller: _amount,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: tr('Сіздің бағаңыз'), suffixText: '₸', errorText: _error),
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: 8),
        Text(
          tr('Сатушы қабылдаса, тәулік ішінде осы бағамен тапсырыс бере аласыз. Төлем бұрынғыдай қорғалады.'),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('offer-send'),
            style: FilledButton.styleFrom(backgroundColor: Brand.accent, foregroundColor: Colors.white),
            onPressed: _busy ? null : _send,
            child: Text(tr('Ұсыныс жіберу')),
          ),
        ),
      ]),
    );
  }
}

/// The buyer's latest offer on a listing, with the step that is theirs to take.
class OfferStatusCard extends StatelessWidget {
  const OfferStatusCard({super.key, required this.offer, required this.onChanged});
  final Offer offer;
  final ValueChanged<Offer> onChanged;

  Future<void> _act(BuildContext context, String action) async {
    try {
      onChanged(await SessionScope.of(context).api.answerOffer(offer.id, action));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = offer;
    final (icon, title, line) = switch (o.status) {
      'pending' => (
          Icons.schedule_rounded,
          trf('Сіздің ұсынысыңыз: {0}', [formatTenge(o.amountTiyn)]),
          trf('Сатушының жауабын күтуде, {0} дейін.', [_until(o.expiresAt)])
        ),
      'countered' => (
          Icons.swap_horiz_rounded,
          trf('Сатушы {0} ұсынады', [formatTenge(o.priceTiyn)]),
          trf('Сіз {0} ұсындыңыз. Жауап беріңіз, {1} дейін.', [formatTenge(o.amountTiyn), _until(o.expiresAt)])
        ),
      'accepted' => (
          Icons.check_circle_rounded,
          trf('{0} бағасы қабылданды', [formatTenge(o.priceTiyn)]),
          trf('Өлшем {0}. Тапсырысты {1} дейін рәсімдеңіз.', [o.sizeLabel, _until(o.expiresAt)])
        ),
      'declined' => (Icons.do_not_disturb_on_outlined, tr('Ұсыныс қабылданбады'), tr('Басқа баға ұсына аласыз.')),
      'expired' => (Icons.timer_off_outlined, tr('Ұсыныстың мерзімі өтті'), tr('Жаңа ұсыныс жіберуге болады.')),
      _ => (Icons.info_outline, tr(offerStatuses[o.status] ?? o.status), ''),
    };
    final good = o.status == 'accepted' || o.status == 'countered';
    // Scheme colours, not fixed ink and studio: the card stays readable on the dark canvas too.
    final scheme = theme.colorScheme;
    final fg = good ? scheme.onPrimary : scheme.onSurface;
    return Container(
      key: const Key('offer-card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: good ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Brand.radius),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: good ? Brand.accent : fg, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title, style: weight(theme.textTheme.titleMedium!, 700).copyWith(color: fg)),
          ),
        ]),
        if (line.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(line, style: theme.textTheme.bodyMedium?.copyWith(color: good ? fg.withValues(alpha: 0.7) : null)),
        ],
        if (o.status == 'countered') ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                style:
                    OutlinedButton.styleFrom(foregroundColor: fg, side: BorderSide(color: fg.withValues(alpha: 0.38))),
                onPressed: () => _act(context, 'decline'),
                child: Text(tr('Бас тарту')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                key: const Key('offer-accept'),
                style: FilledButton.styleFrom(backgroundColor: Brand.accentStrong, foregroundColor: Colors.white),
                onPressed: () => _act(context, 'accept'),
                child: Text(tr('Келісемін')),
              ),
            ),
          ]),
        ],
        if (o.status == 'pending')
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => _act(context, 'withdraw'),
              child: Text(tr('Ұсынысты қайтару')),
            ),
          ),
      ]),
    );
  }
}

/// Offers in and out: sellers answer the ones on their listings, buyers follow their own.
class OffersScreen extends StatefulWidget {
  const OffersScreen({super.key, this.seller = true});
  final bool seller;

  @override
  State<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends State<OffersScreen> {
  late bool _seller = widget.seller;
  late Future<List<Offer>> _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  void _load() {
    _items = SessionScope.of(context).api.offers(role: _seller ? 'seller' : 'buyer');
  }

  Future<void> _run(Future<Offer> Function(Api api) action, String done) async {
    try {
      await action(SessionScope.of(context).api);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      setState(_load);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _counter(Offer o) async {
    final tenge = await showDialog<int>(context: context, builder: (_) => _CounterDialog(offer: o));
    if (tenge == null) return;
    await _run((api) => api.counterOffer(o.id, tenge * 100), tr('Бағаңыз жіберілді'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Баға ұсыныстары'))),
      body: Column(children: [
        Padding(
          padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 4, 20, 8)),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: true, label: Text(tr('Маған келген'))),
                ButtonSegment(value: false, label: Text(tr('Менің ұсыныстарым'))),
              ],
              selected: {_seller},
              onSelectionChanged: (v) => setState(() {
                _seller = v.first;
                _load();
              }),
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Offer>>(
            future: _items,
            builder: (context, snap) {
              if (snap.hasError && snap.connectionState == ConnectionState.done) {
                return ErrorRetry(error: snap.error, onRetry: () => setState(_load));
              }
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final items = snap.data!;
              if (items.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      _seller
                          ? tr('Әзірге ұсыныс жоқ. Сатып алушылар тауар бетінде баға ұсына алады.')
                          : tr('Сіз әлі баға ұсынбадыңыз.'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                );
              }
              return RefreshIndicator(
                onRefresh: () async {
                  setState(_load);
                  await _items;
                },
                child: ListView.separated(
                  padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 4, 20, 24)),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) => _OfferTile(
                    offer: items[i],
                    seller: _seller,
                    onAccept: () => _run((api) => api.answerOffer(items[i].id, 'accept'), tr('Ұсыныс қабылданды')),
                    onDecline: () => _run((api) => api.answerOffer(items[i].id, 'decline'), tr('Ұсыныс қабылданбады')),
                    onCounter: () => _counter(items[i]),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// Owns its text controller, so it is disposed only after the closing animation.
class _CounterDialog extends StatefulWidget {
  const _CounterDialog({required this.offer});
  final Offer offer;

  @override
  State<_CounterDialog> createState() => _CounterDialogState();
}

class _CounterDialogState extends State<_CounterDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.offer;
    return AlertDialog(
      title: Text(tr('Өз бағаңыз')),
      content: TextField(
        key: const Key('counter-amount'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          suffixText: '₸',
          helperText: trf('{0} мен {1} аралығында', [formatTenge(o.amountTiyn), formatTenge(o.listPriceTiyn)]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Болдырмау'))),
        FilledButton(
          key: const Key('counter-send'),
          onPressed: () => Navigator.pop(context, int.tryParse(_controller.text)),
          child: Text(tr('Жіберу')),
        ),
      ],
    );
  }
}

/// Three answers side by side on a phone: no wide theme padding, one line each.
final _compact = ButtonStyle(
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6, vertical: 12)),
  minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
  textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
);

class _OfferTile extends StatelessWidget {
  const _OfferTile({
    required this.offer,
    required this.seller,
    required this.onAccept,
    required this.onDecline,
    required this.onCounter,
  });
  final Offer offer;
  final bool seller;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onCounter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = offer;
    final off = ((1 - o.amountTiyn / o.listPriceTiyn) * 100).round();
    final myTurn = seller ? o.status == 'pending' : o.status == 'countered';
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(Brand.radius),
        onTap: () =>
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListingScreen(listingId: o.listingId))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 56,
                  height: 56,
                  color: Brand.studio,
                  child: o.listingCover == null
                      ? const Icon(Icons.image_outlined)
                      : Image.network(o.listingCover!,
                          fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(o.listingTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(trf('Өлшем {0} · бағасы {1}', [o.sizeLabel, formatTenge(o.listPriceTiyn)]),
                      style: theme.textTheme.bodySmall),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            // Wraps instead of overflowing on a narrow phone or with large text.
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 8, children: [
                  Text(formatTenge(o.amountTiyn), style: weight(theme.textTheme.titleLarge!, 800)),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('−$off%', style: theme.textTheme.labelLarge?.copyWith(color: accentText(context))),
                  ),
                  if (o.counterTiyn != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(trf('→ {0}', [formatTenge(o.counterTiyn!)]), style: theme.textTheme.labelLarge),
                    ),
                ]),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(tr(offerStatuses[o.status] ?? o.status),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ]),
            if (myTurn) ...[
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child:
                      OutlinedButton(style: _compact, onPressed: onDecline, child: Text(tr('Бас тарту'), maxLines: 1)),
                ),
                if (seller) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                        key: Key('counter-${o.id}'),
                        style: _compact,
                        onPressed: onCounter,
                        child: Text(tr('Өз бағам'), maxLines: 1)),
                  ),
                ],
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: Key('accept-${o.id}'),
                    style: _compact,
                    onPressed: onAccept,
                    child: Text(tr('Қабылдау'), maxLines: 1),
                  ),
                ),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}
