import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/spin_viewer.dart';
import 'chat_screen.dart';
import 'login_screen.dart';
import 'offers_screen.dart';
import 'order_screen.dart';
import 'seller_reviews_screen.dart';
import 'shop_screen.dart';
import '../i18n.dart';
import '../my_size.dart';
import '../recent.dart';

const _minSpinFrames = 8;

class ListingScreen extends StatefulWidget {
  const ListingScreen({super.key, required this.listingId});
  final int listingId;

  @override
  State<ListingScreen> createState() => _ListingScreenState();
}

class _ListingScreenState extends State<ListingScreen> {
  late Future<Listing> _listing;
  Future<List<Listing>>? _similar;
  int? _sizeId;
  bool _fitChecked = false;
  bool _favorite = false;
  bool _ordering = false;
  bool _showPhotos = false;
  Offer? _offer; // the signed-in buyer's latest offer on this listing
  // One key per order attempt: a retried tap after a lost response returns the same order.
  String _orderKey = newIdempotencyKey();
  Set<int>? _alerts; // sold-out sizes the buyer waits for, once they tap one

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listing = SessionScope.of(context).api.listing(widget.listingId);
    _listing.then((l) {
      if (l.status == 'published') rememberViewed(l);
    }, onError: (_) {});
    _similar ??= SessionScope.of(context).api.similar(widget.listingId).catchError((_) => <Listing>[]);
    _loadOffer();
  }

  Future<void> _loadOffer() async {
    final session = SessionScope.of(context);
    if (!session.signedIn) return;
    try {
      final mine = await session.api.offers(listingId: widget.listingId);
      if (!mounted || mine.isEmpty) return;
      setState(() {
        _offer = mine.first;
        if (_offerLive) _sizeId = _offer!.sizeId; // the deal is for that size
      });
    } catch (_) {}
  }

  /// An offer the buyer can still act on, or order under.
  bool get _offerLive => const {'pending', 'countered', 'accepted'}.contains(_offer?.status);

  Future<void> _makeOffer(Listing listing, ShoeSize size) async {
    if (!await _ensureSignedIn() || !mounted) return;
    final offer = await showModalBottomSheet<Offer>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => OfferSheet(listing: listing, size: size),
    );
    if (offer == null || !mounted) return;
    setState(() => _offer = offer);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Ұсыныс жіберілді. Сатушы жауап бергенде хабарлаймыз.'))));
  }

  Future<void> _toggleStockAlert(Listing l, ShoeSize size) async {
    if (!await _ensureSignedIn() || !mounted) return;
    final alerts = {...(_alerts ?? l.stockAlerts)};
    final on = !alerts.contains(size.id);
    try {
      await SessionScope.of(context).api.setStockAlert(l.id, size.id, on);
      if (!mounted) return;
      setState(() => _alerts = on ? (alerts..add(size.id)) : (alerts..remove(size.id)));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(on
              ? trf('{0} өлшемі қайта шыққанда хабарлаймыз.', [size.label])
              : trf('{0} өлшемі туралы хабарлама өшірілді.', [size.label]))));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<bool> _ensureSignedIn() async {
    final session = SessionScope.of(context);
    if (session.signedIn) return true;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
    return session.signedIn;
  }

  Future<void> _share() async {
    final l = await _listing;
    await SharePlus.instance.share(ShareParams(
      text: trf('{0} · {1}\n{2}', [l.title, formatTenge(l.priceTiyn), listingShareUrl(l.id)]),
      subject: l.title,
    ));
  }

  Future<void> _toggleFavorite() async {
    if (!await _ensureSignedIn() || !mounted) return;
    final on = !_favorite;
    try {
      await SessionScope.of(context).api.setFavorite(widget.listingId, on);
      setState(() => _favorite = on);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _order(Listing listing) async {
    if (!await _ensureSignedIn() || !mounted) return;
    setState(() => _ordering = true);
    try {
      final offer = _offer?.status == 'accepted' && _offer!.sizeId == _sizeId ? _offer : null;
      final order = await SessionScope.of(context).api.createOrder(listing.id, _sizeId!, _orderKey, offerId: offer?.id);
      if (offer != null) _offer = null;
      _orderKey = newIdempotencyKey();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: order.id)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _ordering = false);
    }
  }

  Future<void> _chat(Listing listing) async {
    if (!await _ensureSignedIn() || !mounted) return;
    try {
      final conv = await SessionScope.of(context).api.openConversation(listing.id);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: conv.id)));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _report(Listing listing) async {
    if (!await _ensureSignedIn() || !mounted) return;
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ReportSheet(listingId: listing.id),
    );
    if (sent == true && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('Шағым жіберілді. Модератор қарап, сізге хабарлайды.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: const Padding(padding: EdgeInsets.all(6), child: _RoundButton(back: true, child: BackButtonIcon())),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _RoundButton(
              key: const Key('share'),
              onTap: _share,
              tooltip: tr('Бөлісу'),
              child: const Icon(Icons.ios_share_rounded, color: Brand.ink),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _RoundButton(
              onTap: _toggleFavorite,
              tooltip: tr('Таңдаулыға'),
              child:
                  Icon(_favorite ? Icons.favorite : Icons.favorite_border, color: _favorite ? Brand.accent : Brand.ink),
            ),
          ),
        ],
      ),
      body: FutureBuilder<Listing>(
        future: _listing,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return _body(context, snap.data!);
        },
      ),
    );
  }

  Widget _body(BuildContext context, Listing l) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final frames = l.frames;
    final hasSpin = frames.length >= _minSpinFrames;
    final fit = bestFit(l.sizes, mySize.value);
    if (!_fitChecked) {
      _fitChecked = true; // pick the buyer's saved size once; after that their taps decide
      _sizeId ??= fit?.id;
    }
    final selected = l.sizes.where((s) => s.id == _sizeId).firstOrNull;
    final me = SessionScope.of(context).me;
    final away = l.sellerAwayUntil;
    final canOffer = l.status == 'published' && me?.id != l.sellerId && !_offerLive && away == null;
    final deal = _offer?.status == 'accepted' && _offer!.sizeId == selected?.id ? _offer : null;
    final itemPrice = deal == null ? l.priceTiyn : (deal.priceTiyn < l.priceTiyn ? deal.priceTiyn : l.priceTiyn);
    return Column(children: [
      Expanded(
        child: ListView(padding: EdgeInsets.zero, children: [
          AspectRatio(
            aspectRatio: 1,
            child: Hero(
              tag: 'listing-${l.id}',
              // The 360° view uses cut-out frames over the seller's showcase style; the photo tab always shows
              // the photos exactly as taken, so buyers can check the unedited originals.
              child: DecoratedBox(
                decoration: showcaseBackground(l.showcaseStyle),
                child: Material(
                  type: MaterialType.transparency,
                  child: hasSpin && !_showPhotos
                      ? SpinViewer(frameUrls: [for (final f in frames) f.url])
                      : ColoredBox(
                          color: Brand.studio,
                          child: PhotoGallery(urls: [for (final p in l.photos) p.originalUrl]),
                        ),
                ),
              ),
            ),
          ),
          if (hasSpin)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: false, icon: Icon(Icons.threesixty), label: Text('360°')),
                  ButtonSegment(value: true, icon: Icon(Icons.photo_library_outlined), label: Text(tr('Фото'))),
                ],
                selected: {_showPhotos},
                onSelectionChanged: (v) => setState(() => _showPhotos = v.first),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 6),
              PriceLine(listing: l, style: weight(theme.textTheme.headlineSmall!, 800)),
              const SizedBox(height: 4),
              Text(
                l.deliveryPriceTiyn == 0 ? tr('Жеткізу тегін') : trf('Жеткізу {0}', [formatTenge(l.deliveryPriceTiyn)]),
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (away != null) ...[
                const SizedBox(height: 12),
                Container(
                  key: const Key('seller-away'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Brand.studio, borderRadius: BorderRadius.circular(Brand.radius)),
                  child: Row(children: [
                    const Icon(Icons.beach_access_outlined),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(trf(
                          'Сатушы {0} дейін демалыста. Тапсырысты ол оралғанда беруге болады, ал қазір таңдаулыға қосып не сатушыға жаза аласыз.',
                          [formatDay(away)])),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(children: [
                    _Fact(
                        icon: Icons.sell_outlined,
                        name: tr('Баға деңгейі'),
                        value: l.segment == null ? tr('Деректер әлі аз') : label(segments, l.segment)),
                    const Divider(),
                    _Fact(
                        icon: Icons.auto_awesome_outlined, name: tr('Жағдайы'), value: label(conditions, l.condition)),
                    const Divider(),
                    _Fact(
                        icon: Icons.verified_outlined,
                        name: tr('Түпнұсқалығы'),
                        value: label(authenticity, l.authenticity)),
                    const Divider(),
                    _Fact(icon: Icons.palette_outlined, name: tr('Түсі'), value: l.color),
                  ]),
                ),
              ),
              if ((l.defects ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration:
                      BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(Brand.radius)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.report_outlined, color: scheme.onErrorContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(trf('Ақаулары: {0}', [l.defects]), style: TextStyle(color: scheme.onErrorContainer)),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 24),
              Row(children: [
                Expanded(child: Text(tr('Өлшем'), style: theme.textTheme.titleMedium)),
                Text(tr('ұлтарақ ұзындығы'),
                    style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final s in l.sizes)
                  _SizeTile(
                    size: s,
                    selected: _sizeId == s.id,
                    alerted: (_alerts ?? l.stockAlerts).contains(s.id),
                    onTap: () => setState(() => _sizeId = s.id),
                    onSoldOutTap: me?.id == l.sellerId ? null : () => _toggleStockAlert(l, s),
                  ),
              ]),
              if (me?.id != l.sellerId && l.sizes.any((s) => !s.available)) ...[
                const SizedBox(height: 8),
                Text(tr('Қалмаған өлшемді басыңыз: қайта шыққанда хабарлаймыз.'),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
              if (l.sizeFit != null) ...[const SizedBox(height: 12), SizeFitNote(fit: l.sizeFit!)],
              if (mySize.value != null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  Icon(fit == null ? Icons.info_outline : Icons.check_circle_outline,
                      size: 18, color: fit == null ? scheme.onSurfaceVariant : Brand.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      fit == null
                          ? trf('Сіздің өлшеміңізге ({0} см) сай өлшем жоқ', [mySize.value])
                          : trf('Сіздің өлшеміңізге ({0} см) сай: {1}', [mySize.value, fit.label]),
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ]),
              ],
              if (_offer != null && _offer!.status != 'ordered' && _offer!.status != 'withdrawn') ...[
                const SizedBox(height: 16),
                OfferStatusCard(offer: _offer!, onChanged: (o) => setState(() => _offer = o)),
              ],
              if (canOffer) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: const Key('make-offer'),
                    onPressed: selected == null ? null : () => _makeOffer(l, selected),
                    icon: const Icon(Icons.local_offer_outlined),
                    label: Text(selected == null ? tr('Баға ұсыну үшін өлшемді таңдаңыз') : tr('Баға ұсыну')),
                  ),
                ),
              ],
              if ((l.description ?? '').isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(tr('Сипаттама'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(l.description!, style: theme.textTheme.bodyLarge),
              ],
              const SizedBox(height: 24),
              Card(
                child: Column(children: [
                  ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 0),
                    leading: CircleAvatar(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      child: Text((l.shopName ?? tr('С')).characters.first.toUpperCase()),
                    ),
                    title: Text(l.shopName ?? tr('Сатушы'), style: theme.textTheme.titleSmall),
                    subtitle: Row(children: [
                      if (l.sellerRating != null) ...[
                        Stars(value: l.sellerRating!, size: 14),
                        const SizedBox(width: 6),
                        Text('${l.sellerRating!.toStringAsFixed(1)} · '),
                      ],
                      Flexible(
                        child: Text(
                          [
                            if (l.sellerCity != null) l.sellerCity!,
                            trf('{0} пікір', [l.sellerReviews])
                          ].join(' · '),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ]),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShopScreen(sellerId: l.sellerId))),
                  ),
                  if (SessionScope.of(context).me?.id != l.sellerId)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _chat(l),
                          icon: const Icon(Icons.chat_bubble_outline_rounded),
                          label: Text(tr('Сатушыға жазу')),
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 8),
                ]),
              ),
              if (SessionScope.of(context).me?.id != l.sellerId)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _report(l),
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    label: Text(tr('Тауар туралы шағымдану')),
                    style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Brand.radius)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.shield_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tr('Ақша сатушыға сіз тауарды алып, растағаннан кейін ғана өтеді. Бұл қорғау лицензиясы бар төлем серіктесі қосылғанда іске қосылады.'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ]),
              ),
              _SimilarRow(items: _similar),
            ]),
          ),
        ]),
      ),
      Material(
        color: scheme.surface,
        child: SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant))),
            child: Row(children: [
              Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Жиыны'), style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                Text(formatTenge(itemPrice + l.deliveryPriceTiyn),
                    key: const Key('total'), style: weight(theme.textTheme.titleLarge!, 800)),
              ]),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Brand.accent, foregroundColor: Colors.white),
                  onPressed: l.status == 'published' && selected != null && !_ordering && away == null
                      ? () => _order(l)
                      : null,
                  child: Text(l.status != 'published'
                      ? tr('Сатылған')
                      : away != null
                          ? trf('{0} бастап', [formatDay(away.add(const Duration(days: 1)))])
                          : selected == null
                              ? tr('Өлшемді таңдаңыз')
                              : deal != null
                                  ? tr('Келісілген бағамен алу')
                                  : tr('Тапсырыс беру')),
                ),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.child, this.onTap, this.tooltip, this.back = false});
  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool back;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip ?? (back ? tr('Артқа') : null),
        color: Brand.ink,
        onPressed: back ? () => Navigator.maybePop(context) : onTap,
        icon: child,
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.name, required this.value});
  final IconData icon;
  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Text(name, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(width: 12),
        Expanded(child: Text(value, textAlign: TextAlign.end, style: weight(theme.textTheme.bodyMedium!, 600))),
      ]),
    );
  }
}

class _SizeTile extends StatelessWidget {
  const _SizeTile(
      {required this.size, required this.selected, required this.onTap, this.alerted = false, this.onSoldOutTap});
  final ShoeSize size;
  final bool selected;
  final VoidCallback onTap;

  /// A sold-out size the buyer asked to hear about; tapping a sold-out size toggles that.
  final bool alerted;
  final VoidCallback? onSoldOutTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onPrimary : (size.available ? scheme.onSurface : scheme.onSurfaceVariant);
    return Semantics(
      button: true,
      selected: selected,
      enabled: size.available || onSoldOutTap != null,
      label: trf('Өлшем {0}, {1} см{2}', [size.label, size.insoleCm, size.available ? '' : tr(', қалмады')]),
      child: Material(
        color: selected ? scheme.primary : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: size.available ? onTap : onSoldOutTap,
          child: SizedBox(
            width: 76,
            height: 58,
            child: Stack(children: [
              Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(size.label,
                      style: weight(theme.textTheme.titleSmall!, 700)
                          .copyWith(color: fg, decoration: size.available ? null : TextDecoration.lineThrough)),
                  Text(trf('{0} см', [size.insoleCm]), style: theme.textTheme.labelSmall?.copyWith(color: fg)),
                ]),
              ),
              if (!size.available && onSoldOutTap != null)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(alerted ? Icons.notifications_active : Icons.notifications_none_rounded,
                      key: Key('alert-${size.id}'), size: 14, color: alerted ? Brand.accent : scheme.onSurfaceVariant),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

const reportReasons = {
  'fake': 'Жалған немесе көшірме тауар',
  'wrong_photos': 'Фото тауарға сәйкес емес',
  'prohibited': 'Сатуға тыйым салынған',
  'contact_details': 'Телефон не сілтеме жазылған',
  'other': 'Басқа себеп',
};

/// Report form. A report only queues the listing for a moderator; it never hides it by itself.
class ReportSheet extends StatefulWidget {
  const ReportSheet({super.key, required this.listingId});
  final int listingId;

  @override
  State<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<ReportSheet> {
  String? _reason;
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      await SessionScope.of(context).api.reportListing(widget.listingId, _reason!, text: _text.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needsText = _reason == 'other' && _text.text.trim().isEmpty;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Шағым себебі'), style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(tr('Модератор тексереді. Сатушы шағым кімнен екенін көрмейді.'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: _reason,
              onChanged: (v) => setState(() => _reason = v),
              child: Column(children: [
                for (final e in reportReasons.entries)
                  RadioListTile<String>(contentPadding: EdgeInsets.zero, value: e.key, title: Text(tr(e.value))),
              ]),
            ),
            TextField(
              controller: _text,
              maxLines: 3,
              maxLength: 1000,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: tr('Толығырақ (міндетті емес)')),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('send-report'),
                onPressed: _reason == null || needsText || _sending ? null : _send,
                child: Text(tr('Жіберу')),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Look-alike listings found by their photos; hidden when there are none.
class _SimilarRow extends StatelessWidget {
  const _SimilarRow({required this.items});
  final Future<List<Listing>>? items;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Listing>>(
      future: items,
      builder: (context, snap) {
        final list = snap.data ?? const <Listing>[];
        if (list.isEmpty) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 28),
          Text(tr('Ұқсас тауарлар'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          SizedBox(
            height: 270,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) => SizedBox(width: 160, child: ListingTile(listing: list[i])),
            ),
          ),
        ]);
      },
    );
  }
}

/// What buyers said about the size, with a three-part bar so the split is visible at a glance.
class SizeFitNote extends StatelessWidget {
  const SizeFitNote({super.key, required this.fit});
  final SizeFit fit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (headline, advice) = switch (fit.verdict) {
      'small' => (tr('Кішілеу келеді'), tr('Жарты өлшем үлкенін алыңыз')),
      'large' => (tr('Үлкендеу келеді'), tr('Жарты өлшем кішісін алыңыз')),
      _ => (tr('Өлшеміне сай келеді'), tr('Әдеттегі өлшеміңізді алыңыз')),
    };
    Widget part(int n, Color color) =>
        n == 0 ? const SizedBox.shrink() : Expanded(flex: n, child: Container(height: 6, color: color));
    Widget legend(String label, int n) =>
        Text('${tr(label)} $n', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant));
    return Container(
      key: const Key('size-fit'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.straighten_rounded, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(headline, style: weight(theme.textTheme.titleSmall!, 700))),
          Text(trf('{0} сатып алушы', [fit.answers]),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 4),
        Text(advice, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Row(children: [
            part(fit.small, const Color(0xFFE8A23A)),
            if (fit.small > 0 && fit.trueToSize > 0) const SizedBox(width: 2),
            part(fit.trueToSize, const Color(0xFF2E9E6A)),
            if (fit.large > 0 && fit.small + fit.trueToSize > 0) const SizedBox(width: 2),
            part(fit.large, const Color(0xFF5B7FD6)),
          ]),
        ),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          legend('Кішілеу', fit.small),
          legend('Сай', fit.trueToSize),
          legend('Үлкендеу', fit.large),
        ]),
      ]),
    );
  }
}
