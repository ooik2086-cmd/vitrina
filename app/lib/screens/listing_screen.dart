import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/spin_viewer.dart';
import 'chat_screen.dart';
import 'login_screen.dart';
import 'order_screen.dart';
import 'seller_reviews_screen.dart';
import 'shop_screen.dart';

const _minSpinFrames = 8;

class ListingScreen extends StatefulWidget {
  const ListingScreen({super.key, required this.listingId});
  final int listingId;

  @override
  State<ListingScreen> createState() => _ListingScreenState();
}

class _ListingScreenState extends State<ListingScreen> {
  late Future<Listing> _listing;
  int? _sizeId;
  bool _favorite = false;
  bool _ordering = false;
  bool _showPhotos = false;
  // One key per order attempt: a retried tap after a lost response returns the same order.
  String _orderKey = newIdempotencyKey();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listing = SessionScope.of(context).api.listing(widget.listingId);
  }

  Future<bool> _ensureSignedIn() async {
    final session = SessionScope.of(context);
    if (session.signedIn) return true;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
    return session.signedIn;
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
      final order = await SessionScope.of(context).api.createOrder(listing.id, _sizeId!, _orderKey);
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
          .showSnackBar(const SnackBar(content: Text('Шағым жіберілді. Модератор қарап, сізге хабарлайды.')));
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
            padding: const EdgeInsets.only(right: 10),
            child: _RoundButton(
              onTap: _toggleFavorite,
              tooltip: 'Таңдаулыға',
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
    final selected = l.sizes.where((s) => s.id == _sizeId).firstOrNull;
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
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.threesixty), label: Text('360°')),
                  ButtonSegment(value: true, icon: Icon(Icons.photo_library_outlined), label: Text('Фото')),
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
              Text(formatTenge(l.priceTiyn), style: weight(theme.textTheme.headlineSmall!, 800)),
              const SizedBox(height: 4),
              Text(
                l.deliveryPriceTiyn == 0 ? 'Жеткізу тегін' : 'Жеткізу ${formatTenge(l.deliveryPriceTiyn)}',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(children: [
                    _Fact(
                        icon: Icons.sell_outlined,
                        name: 'Баға деңгейі',
                        value: l.segment == null ? 'Деректер әлі аз' : label(segments, l.segment)),
                    const Divider(),
                    _Fact(icon: Icons.auto_awesome_outlined, name: 'Жағдайы', value: label(conditions, l.condition)),
                    const Divider(),
                    _Fact(
                        icon: Icons.verified_outlined,
                        name: 'Түпнұсқалығы',
                        value: label(authenticity, l.authenticity)),
                    const Divider(),
                    _Fact(icon: Icons.palette_outlined, name: 'Түсі', value: l.color),
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
                      child: Text('Ақаулары: ${l.defects}', style: TextStyle(color: scheme.onErrorContainer)),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 24),
              Row(children: [
                Expanded(child: Text('Өлшем', style: theme.textTheme.titleMedium)),
                Text('ұлтарақ ұзындығы', style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final s in l.sizes)
                  _SizeTile(size: s, selected: _sizeId == s.id, onTap: () => setState(() => _sizeId = s.id)),
              ]),
              if ((l.description ?? '').isNotEmpty) ...[
                const SizedBox(height: 24),
                Text('Сипаттама', style: theme.textTheme.titleMedium),
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
                      child: Text((l.shopName ?? 'С').characters.first.toUpperCase()),
                    ),
                    title: Text(l.shopName ?? 'Сатушы', style: theme.textTheme.titleSmall),
                    subtitle: Row(children: [
                      if (l.sellerRating != null) ...[
                        Stars(value: l.sellerRating!, size: 14),
                        const SizedBox(width: 6),
                        Text('${l.sellerRating!.toStringAsFixed(1)} · '),
                      ],
                      Flexible(
                        child: Text(
                          [if (l.sellerCity != null) l.sellerCity!, '${l.sellerReviews} пікір'].join(' · '),
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
                          label: const Text('Сатушыға жазу'),
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
                    label: const Text('Тауар туралы шағымдану'),
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
                      'Ақша сатушыға сіз тауарды алып, растағаннан кейін ғана өтеді. '
                      'Бұл қорғау лицензиясы бар төлем серіктесі қосылғанда іске қосылады.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ]),
              ),
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
                Text('Барлығы', style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                Text(formatTenge(l.priceTiyn + l.deliveryPriceTiyn), style: weight(theme.textTheme.titleLarge!, 800)),
              ]),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Brand.accent, foregroundColor: Colors.white),
                  onPressed: l.status == 'published' && selected != null && !_ordering ? () => _order(l) : null,
                  child: Text(l.status != 'published'
                      ? 'Сатылған'
                      : selected == null
                          ? 'Өлшемді таңдаңыз'
                          : 'Тапсырыс беру'),
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
  const _RoundButton({required this.child, this.onTap, this.tooltip, this.back = false});
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
        tooltip: tooltip ?? (back ? 'Артқа' : null),
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
  const _SizeTile({required this.size, required this.selected, required this.onTap});
  final ShoeSize size;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onPrimary : (size.available ? scheme.onSurface : scheme.onSurfaceVariant);
    return Semantics(
      button: true,
      selected: selected,
      enabled: size.available,
      label: 'Өлшем ${size.label}, ${size.insoleCm} см${size.available ? '' : ', қалмады'}',
      child: Material(
        color: selected ? scheme.primary : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: size.available ? onTap : null,
          child: SizedBox(
            width: 76,
            height: 58,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(size.label,
                  style: weight(theme.textTheme.titleSmall!, 700)
                      .copyWith(color: fg, decoration: size.available ? null : TextDecoration.lineThrough)),
              Text('${size.insoleCm} см', style: theme.textTheme.labelSmall?.copyWith(color: fg)),
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
            Text('Шағым себебі', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Модератор тексереді. Сатушы шағым кімнен екенін көрмейді.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: _reason,
              onChanged: (v) => setState(() => _reason = v),
              child: Column(children: [
                for (final e in reportReasons.entries)
                  RadioListTile<String>(contentPadding: EdgeInsets.zero, value: e.key, title: Text(e.value)),
              ]),
            ),
            TextField(
              controller: _text,
              maxLines: 3,
              maxLength: 1000,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Толығырақ (міндетті емес)'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('send-report'),
                onPressed: _reason == null || needsText || _sending ? null : _send,
                child: const Text('Жіберу'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
