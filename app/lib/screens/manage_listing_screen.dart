import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/listing_contents.dart';
import '../widgets/questions.dart';
import 'listing_editor_screen.dart';
import 'listing_screen.dart';
import '../i18n.dart';
import '../listing_quality.dart';

const listingStatuses = {
  'draft': 'Жоба',
  'moderation': 'Тексерілуде',
  'published': 'Сатылымда',
  'paused': 'Тоқтатылған',
  'sold': 'Сатылды',
  'hidden': 'Модератор жасырды',
  'rejected': 'Қайтарылды',
};

/// Seller's own listing: change price, stock, name, photos and sizes, pause or put back on sale.
/// Once on sale the shoe itself (brand, model, category, photos buyers saw) is fixed, so buyers get what they chose.
class ManageListingScreen extends StatefulWidget {
  const ManageListingScreen({super.key, required this.listing, this.showPhotos = false});
  final Listing listing;

  /// Opens on the photos section, as a note about a photo to retake does, instead of the name fields.
  final bool showPhotos;

  @override
  State<ManageListingScreen> createState() => _ManageListingScreenState();
}

class _ManageListingScreenState extends State<ManageListingScreen> {
  final _form = GlobalKey<FormState>();
  late Listing _l = widget.listing;
  late final _price = TextEditingController(text: '${_l.priceTiyn ~/ 100}');
  late final _delivery = TextEditingController(text: '${_l.deliveryPriceTiyn ~/ 100}');
  late final _description = TextEditingController(text: _l.description ?? '');
  late final _defects = TextEditingController(text: _l.defects ?? '');
  late final _title = TextEditingController(text: _l.title);
  late final _brand = TextEditingController(text: _l.brand ?? '');
  late final _model = TextEditingController(text: _l.modelName ?? '');
  late final _color = TextEditingController(text: _l.color);
  late String _category = _l.category;
  late String _condition = _l.condition;
  late final Map<int, int> _stock = {for (final s in _l.sizes) s.id: _count(s)};

  /// Whether the pending card found the photos ready, and for which photo set.
  bool _photosReady = false;
  String? _photosReadyFor;
  bool _busy = false;
  bool _changed = false;
  final _photos = GlobalKey();
  final _scroll = ScrollController();
  int _tries = 0;

  @override
  void initState() {
    super.initState();
    if (widget.showPhotos && !_locked(widget.listing)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bringPhotos());
    }
  }

  void _bringPhotos() {
    if (!mounted) return;
    final at = _photos.currentContext;
    if (at != null) {
      Scrollable.ensureVisible(at);
    } else if (_scroll.hasClients && _tries++ < 20) {
      // The list builds only what is near the screen: go down until the photos are built.
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      WidgetsBinding.instance.addPostFrameCallback((_) => _bringPhotos());
    } else if (_scroll.hasClients) {
      _scroll.jumpTo(0); // not found: the page opens from the top as usual
    }
  }

  /// A hidden listing is only shown, not edited: it has no photos section.
  static bool _locked(Listing l) => l.status == 'hidden';

  @override
  void dispose() {
    _scroll.dispose();
    for (final c in [_price, _delivery, _description, _defects, _title, _brand, _model, _color]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _tiyn(String text) {
    final v = int.tryParse(text.replaceAll(RegExp(r'\s'), ''));
    return v == null ? null : v * 100;
  }

  /// Returns the error, or null once done.
  Future<Object?> _run(Future<Listing> Function(Api api) action, String done) async {
    setState(() => _busy = true);
    try {
      final l = await action(SessionScope.of(context).api);
      if (!mounted) return null;
      setState(() {
        _l = l;
        _changed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      return null;
    } catch (e) {
      if (mounted) showError(context, e);
      return e;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The new value of a name field, or null when it is unchanged, so Save never touches what the seller left alone.
  String? _edited(TextEditingController c, String? was) {
    final v = c.text.trim();
    return v == (was ?? '') ? null : v;
  }

  static int _count(ShoeSize s) => s.quantity ?? (s.available ? 1 : 0);

  /// Only the sizes the seller changed, each with the count it was changed from: a pair bought while the screen was
  /// open is not put back by a Save, and a count changed by a sale meanwhile is shown again before it is saved.
  Map<int, int> get _was => {
        for (final s in _l.sizes)
          if (_stock[s.id] != null && _stock[s.id] != _count(s)) s.id: _count(s)
      };

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final fresh = !_l.everOnSale;
    final was = _was;
    final saved = await _run(
      (api) => api.editListing(_l.id,
          priceTiyn: _tiyn(_price.text),
          deliveryPriceTiyn: _tiyn(_delivery.text) ?? 0,
          description: _description.text,
          defects: _defects.text,
          stock: was.isEmpty ? null : {for (final id in was.keys) id: _stock[id]!},
          stockWas: was,
          title: _edited(_title, _l.title),
          brand: fresh ? _edited(_brand, _l.brand) : null,
          modelName: fresh ? _edited(_model, _l.modelName) : null,
          color: _edited(_color, _l.color),
          category: fresh && _category != _l.category ? _category : null,
          condition: _condition != _l.condition ? _condition : null),
      tr('Сақталды'),
    );
    final soldMeanwhile = saved is ApiException && saved.code == 'stock_changed';
    if (!mounted || saved != null && !soldMeanwhile) return;
    if (soldMeanwhile) {
      try {
        final l = await SessionScope.of(context).api.listing(_l.id);
        if (!mounted) return;
        _l = l;
      } catch (_) {
        return; // the counts stay as the seller set them, and Save tries again
      }
    }
    // The counts as the server keeps them now, sales included.
    setState(() => _stock
      ..clear()
      ..addAll({for (final s in _l.sizes) s.id: _count(s)}));
  }

  Future<void> _publish() async {
    setState(() => _busy = true);
    try {
      final l = await SessionScope.of(context).api.publishListing(_l.id);
      if (!mounted) return;
      setState(() {
        _l = l;
        _changed = true;
      });
      final queued = l.status == 'moderation';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(queued ? tr('Тексеруге жіберілді') : tr('Сатылымға шықты'))));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locked = _locked(_l);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(tr('Тауарды басқару')), actions: [
          IconButton(
            key: const Key('duplicate'),
            tooltip: tr('Ұқсас тауар қосу'),
            icon: const Icon(Icons.content_copy_rounded),
            onPressed: () async {
              final created = await Navigator.of(context)
                  .push<bool>(MaterialPageRoute(builder: (_) => ListingEditorScreen(template: _l)));
              if (created == true) _changed = true; // the seller's list reloads on the way back
            },
          ),
          IconButton(
            tooltip: tr('Сатып алушы көретіндей ашу'),
            icon: const Icon(Icons.visibility_outlined),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListingScreen(listingId: _l.id))),
          ),
        ]),
        body: Form(
          key: _form,
          child: ListView(
              controller: _scroll,
              padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 8, 20, 120)),
              children: [
                Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: 72,
                      height: 72,
                      color: Brand.studio,
                      child: _l.coverUrl == null
                          ? const Icon(Icons.image_outlined)
                          : Image.network(_l.coverUrl!,
                              fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_l.title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      _StatusPill(status: _l.status),
                    ]),
                  ),
                ]),
                if (locked) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(tr('Тауарды модератор жасырды. Өзгерту үшін қолдау қызметіне жазыңыз.')),
                    ),
                  ),
                ],
                if (_l.status == 'moderation' || _l.status == 'rejected') ...[
                  const SizedBox(height: 16),
                  ModerationCard(listing: _l),
                ],
                if (_l.photosPending && !(_photosReady && _photosReadyFor == _l.photosVersion) && !locked) ...[
                  const SizedBox(height: 16),
                  PhotosPendingCard(
                    listing: _l,
                    // Only the card goes: the listing on screen is kept, so stock the seller is changing is still
                    // compared with the counts they saw (a fresh copy would hide a pair sold meanwhile).
                    onReady: () {
                      setState(() {
                        _photosReady = true;
                        _photosReadyFor = _l.photosVersion;
                        _changed = true;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Фотолар дайын'))));
                    },
                  ),
                ],
                if (_l.stats != null) ...[
                  const SizedBox(height: 20),
                  _StatsRow(stats: _l.stats!),
                ],
                if (!locked) ...[
                  const SizedBox(height: 16),
                  QualityCard(quality: listingQuality(_l)),
                ],
                if (_l.status == 'published' || _l.status == 'sold') ...[
                  const SizedBox(height: 12),
                  ListTile(
                    key: const Key('listing-questions'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.forum_outlined),
                    title: Text(tr('Сұрақ-жауап')),
                    subtitle: Text(tr('Сатып алушылардың сұрақтарына жауап беру')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => QuestionsScreen(listingId: _l.id, seller: true))),
                  ),
                ],
                if (!locked) ...[
                  const SizedBox(height: 16),
                  AuthenticityCard(listingId: _l.id, onChanged: () => _changed = true),
                ],
                if (!locked) ...[
                  const SizedBox(height: 16),
                  PromoCard(
                    listing: _l,
                    onChanged: (l) => setState(() {
                      _l = l;
                      _changed = true;
                    }),
                  ),
                ],
                const SizedBox(height: 24),
                Text(tr('Баға'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      key: const Key('price'),
                      controller: _price,
                      enabled: !locked,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: tr('Бағасы'), suffixText: '₸'),
                      validator: (v) => (_tiyn(v ?? '') ?? 0) <= 0 ? tr('Бағаны енгізіңіз') : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _delivery,
                      enabled: !locked,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: tr('Жеткізу'), suffixText: '₸'),
                    ),
                  ),
                ]),
                const SizedBox(height: 24),
                Text(tr('Қалдық'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                for (final s in _l.sizes)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(s.label),
                    subtitle: Text(trf('{0} см', [s.insoleCm])),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton.outlined(
                        tooltip: tr('Азайту'),
                        icon: const Icon(Icons.remove),
                        onPressed: locked || (_stock[s.id] ?? 0) == 0
                            ? null
                            : () => setState(() => _stock[s.id] = _stock[s.id]! - 1),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text('${_stock[s.id]}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontVariations: [FontVariation('wght', 700)])),
                      ),
                      IconButton.outlined(
                        tooltip: tr('Көбейту'),
                        icon: const Icon(Icons.add),
                        onPressed: locked ? null : () => setState(() => _stock[s.id] = (_stock[s.id] ?? 0) + 1),
                      ),
                    ]),
                  ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _description,
                  enabled: !locked,
                  maxLines: 4,
                  decoration: InputDecoration(labelText: tr('Сипаттамасы')),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _defects,
                  enabled: !locked,
                  maxLines: 3,
                  decoration: InputDecoration(labelText: tr('Ақаулары')),
                ),
                if (!locked) ...[
                  const SizedBox(height: 24),
                  ListingNameFields(
                    listing: _l,
                    title: _title,
                    brand: _brand,
                    model: _model,
                    color: _color,
                    category: _category,
                    condition: _condition,
                    onCategory: (v) => setState(() => _category = v),
                    onCondition: (v) => setState(() => _condition = v),
                  ),
                  const SizedBox(height: 24),
                  ListingContentsCard(
                    key: _photos,
                    listing: _l,
                    showNoShoe: widget.showPhotos,
                    onChanged: (l) => setState(() {
                      _l = l;
                      for (final s in l.sizes) {
                        _stock.putIfAbsent(s.id, () => s.quantity ?? (s.available ? 1 : 0));
                      }
                      _changed = true;
                    }),
                  ),
                ],
              ]),
        ),
        bottomNavigationBar: locked
            ? null
            : SafeArea(
                child: Padding(
                  padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 8, 20, 12)),
                  child: Row(children: [
                    if (_l.status == 'published')
                      Expanded(
                        child: OutlinedButton(
                          onPressed:
                              _busy ? null : () => _run((api) => api.pauseListing(_l.id), tr('Сатылым тоқтатылды')),
                          child: Text(tr('Тоқтату')),
                        ),
                      ),
                    if (_l.status == 'draft' || _l.status == 'paused' || _l.status == 'rejected')
                      Expanded(
                        child: OutlinedButton(
                          key: const Key('publish'),
                          onPressed: _busy ? null : _publish,
                          child: Text(_l.status == 'rejected' ? tr('Қайта жіберу') : tr('Сатылымға шығару')),
                        ),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const Key('save'),
                        onPressed: _busy ? null : _save,
                        child: Text(tr('Сақтау')),
                      ),
                    ),
                  ]),
                ),
              ),
      ),
    );
  }
}

/// Where the seller proves the pair is genuine: receipt, box label or tag photos that only staff see.
class AuthenticityCard extends StatefulWidget {
  const AuthenticityCard({super.key, required this.listingId, this.onChanged});
  final int listingId;
  final VoidCallback? onChanged;

  @override
  State<AuthenticityCard> createState() => _AuthenticityCardState();
}

class _AuthenticityCardState extends State<AuthenticityCard> with WidgetsBindingObserver {
  Proofs? _p;
  Object? _error;
  bool _retrying = false;
  DateTime? _loadedAt;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_p == null) _load();
  }

  // Links to the receipts stop working an hour after they are given: back in the app after that, fetch new ones.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _loadedAt != null &&
        clock.now().difference(_loadedAt!) > const Duration(minutes: 50)) {
      _load();
    }
  }

  Future<void> _load() async {
    if (_error != null) setState(() => _retrying = true);
    try {
      final p = await SessionScope.of(context).api.proofs(widget.listingId);
      if (mounted) {
        setState(() {
          _p = p;
          _error = null;
          _loadedAt = clock.now();
        });
      }
    } catch (e) {
      // The rest of the page works without the card; a line says it did not load, so the seller can try again. A
      // refusal (not this seller's, not found) hides it.
      if (mounted && _p == null) setState(() => _error = e is ApiException && e.passing ? e : null);
    } finally {
      if (mounted && _retrying) setState(() => _retrying = false);
    }
  }

  Future<void> _run(Future<Proofs> Function(Api api) action) async {
    setState(() => _busy = true);
    try {
      final p = await action(SessionScope.of(context).api);
      if (!mounted) return;
      setState(() {
        _p = p;
        _loadedAt = clock.now();
      });
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final file = await pickPhoto(context, title: tr('Чек, қорап жапсырмасы не бирка'));
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    await _run((api) => api.addProof(widget.listingId, bytes, file.name));
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) {
      return _error == null
          ? const SizedBox.shrink()
          : Card(child: RetryLine(what: tr('Түпнұсқалығын дәлелдеу'), error: _error, busy: _retrying, onRetry: _load));
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = p.authenticity == 'documented' || p.authenticity == 'verified';
    final status = switch (p.authenticity) {
      'seller_evidence' => tr('Дәлел жіберілді, қызметкер тексереді.'),
      'documented' ||
      'verified' =>
        trf('Тексерілді: тауарда «{0}» белгісі тұр.', [label(authenticity, p.authenticity)]),
      _ => tr('Чек, қорап жапсырмасы не бирка фотосын қосыңыз. Тексерілген тауарға сенім көбірек.'),
    };
    return Card(
      key: const Key('authenticity-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(done ? Icons.verified_rounded : Icons.verified_outlined,
                color: done ? const Color(0xFF2E9E6A) : scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(child: Text(tr('Түпнұсқалығын дәлелдеу'), style: theme.textTheme.titleSmall)),
          ]),
          const SizedBox(height: 8),
          Text(status, style: theme.textTheme.bodyMedium),
          if (p.note != null) ...[
            const SizedBox(height: 8),
            Text(trf('Қызметкер: {0}', [p.note]), style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final item in p.items)
              Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(item.url,
                      width: 72,
                      height: 72,
                      cacheWidth: 216,
                      gaplessPlayback: true,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(width: 72, height: 72, color: Brand.studio)),
                ),
                if (!done)
                  // 48 by 48 to tap and named for screen readers; the mark itself stays small in the corner.
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton(
                      tooltip: tr('Фотоны өшіру'),
                      alignment: Alignment.topRight,
                      padding: const EdgeInsets.all(2),
                      onPressed: _busy ? null : () => _run((api) => api.deleteProof(widget.listingId, item.id)),
                      icon: const CircleAvatar(radius: 11, child: Icon(Icons.close, size: 14)),
                    ),
                  ),
              ]),
            if (!done && p.items.length < 4)
              SizedBox(
                width: 72,
                height: 72,
                child: OutlinedButton(
                  key: const Key('add-proof'),
                  style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  onPressed: _busy ? null : _add,
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add_a_photo_outlined),
                ),
              ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.lock_outline_rounded, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(tr('Бұл фотоларды сатып алушылар көрмейді, тек VITRINA қызметкері.'),
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Tells the seller why a listing is waiting for staff, or why staff sent it back and what to fix.
class ModerationCard extends StatelessWidget {
  const ModerationCard({super.key, required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rejected = listing.status == 'rejected';
    final m = listing.moderation;
    final reasons = m?.reasons(appLanguage.value) ?? const <String>[];
    return Card(
      key: const Key('moderation-card'),
      color: rejected ? theme.colorScheme.errorContainer : theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(rejected ? Icons.reply_rounded : Icons.hourglass_top_rounded, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(rejected ? tr('Тауар қайтарылды') : tr('Тауар тексерілуде'),
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700, fontVariations: const [FontVariation('wght', 700)])),
            ),
          ]),
          const SizedBox(height: 8),
          if (rejected && (m?.note ?? '').isNotEmpty) ...[
            Text(trf('Қызметкердің жазбасы: {0}', [m!.note!])),
            const SizedBox(height: 8),
          ],
          for (final r in reasons)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('•  '),
                Expanded(child: Text(r)),
              ]),
            ),
          const SizedBox(height: 4),
          Text(
            rejected
                ? tr('Сипаттаманы түзетіп, «Қайта жіберу» басыңыз.')
                : tr('Қызметкер қарап шыққанша сатып алушылар көрмейді. Нәтижесі хабарландыруда келеді.'),
            style: theme.textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

/// Makes and hands out the 8-second promo video: the seller's 360° photos, the price and music,
/// sized for Instagram, TikTok and WhatsApp statuses.
/// Says the photos just given are still being prepared, and looks again now and then so it goes away by itself
/// once they are ready.
class PhotosPendingCard extends StatefulWidget {
  const PhotosPendingCard(
      {super.key, required this.listing, required this.onReady, this.pollEvery = const Duration(seconds: 20)});
  final Listing listing;
  final VoidCallback onReady;
  final Duration pollEvery;

  @override
  State<PhotosPendingCard> createState() => _PhotosPendingCardState();
}

class _PhotosPendingCardState extends State<PhotosPendingCard> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _schedule() {
    _poll?.cancel();
    _poll = Timer(widget.pollEvery, () async {
      try {
        final l = await SessionScope.of(context).api.listing(widget.listing.id);
        if (!mounted) return;
        if (l.photosPending) {
          _schedule();
        } else {
          widget.onReady();
        }
      } catch (_) {
        if (mounted) _schedule();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('photos-pending'),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_fix_high_rounded, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(tr('Фотолар өңделуде'),
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700, fontVariations: const [FontVariation('wght', 700)])),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
              tr('Фотолардың фоны алынып жатыр, бұл біраз уақыт алуы мүмкін. Оған дейін сатып алушылар фотоларды түсірілген күйінде көреді.'),
              style: theme.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class PromoCard extends StatefulWidget {
  const PromoCard(
      {super.key, required this.listing, required this.onChanged, this.pollEvery = const Duration(seconds: 2)});
  final Listing listing;
  final ValueChanged<Listing> onChanged;
  final Duration pollEvery;

  @override
  State<PromoCard> createState() => _PromoCardState();
}

class _PromoCardState extends State<PromoCard> {
  Timer? _poll;
  bool _starting = false;

  String? get _state => widget.listing.promo?.state;

  @override
  void initState() {
    super.initState();
    if (_state == 'rendering') _schedule();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _schedule() {
    _poll?.cancel();
    _poll = Timer(widget.pollEvery, () async {
      try {
        final l = await SessionScope.of(context).api.listing(widget.listing.id);
        if (!mounted) return;
        widget.onChanged(l);
        if (l.promo?.state == 'rendering') _schedule();
      } catch (_) {
        if (mounted) _schedule();
      }
    });
  }

  Future<void> _make() async {
    setState(() => _starting = true);
    try {
      final l = await SessionScope.of(context).api.makePromo(widget.listing.id, appLanguage.value);
      if (!mounted) return;
      widget.onChanged(l);
      _schedule();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = widget.listing.promo?.url;
    final rendering = _state == 'rendering' || _starting;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Brand.ink,
        borderRadius: BorderRadius.circular(Brand.radius),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.movie_creation_outlined, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Text(tr('Жарнама видео'),
                style: weight(theme.textTheme.titleMedium!, 700).copyWith(color: Colors.white)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(
          switch (_state) {
            'ready' => tr('Дайын. Видеоны ашып, телефонға сақтаңыз немесе сілтемесін жіберіңіз.'),
            'failed' => tr('Видео жасалмады. Қайта көріңіз.'),
            _ when rendering => tr('Видео жасалуда, бұл бірнеше секунд алады…'),
            _ => tr('8 секундтық тік видео: 360° айналым, баға және музыка. Instagram, TikTok және WhatsApp үшін.'),
          },
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
        ),
        const SizedBox(height: 12),
        if (rendering)
          const LinearProgressIndicator(color: Brand.accent, backgroundColor: Colors.white24)
        else if (_state == 'ready' && url != null)
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              key: const Key('open-promo'),
              style: FilledButton.styleFrom(backgroundColor: Brand.accentStrong, foregroundColor: Colors.white),
              onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(tr('Ашу')),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Сілтеме көшірілді'))));
                }
              },
              icon: const Icon(Icons.link_rounded),
              label: Text(tr('Сілтемені көшіру')),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              onPressed: _make,
              child: Text(tr('Қайта жасау')),
            ),
          ])
        else
          FilledButton.icon(
            key: const Key('make-promo'),
            style: FilledButton.styleFrom(backgroundColor: Brand.accentStrong, foregroundColor: Colors.white),
            onPressed: _make,
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(tr('Видео жасау')),
          ),
      ]),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.stats});
  final ListingStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(IconData icon, int value, String label) => Expanded(
          child: Column(children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 4),
            Text('$value', style: weight(theme.textTheme.titleMedium!, 700)),
            Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(Brand.radius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(children: [
        cell(Icons.visibility_outlined, stats.views, tr('қаралым')),
        cell(Icons.favorite_border_rounded, stats.favorites, tr('таңдаулы')),
        cell(Icons.chat_bubble_outline_rounded, stats.chats, tr('чат')),
        cell(Icons.shopping_bag_outlined, stats.orders, tr('тапсырыс')),
      ]),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final live = status == 'published';
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: live ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(tr(listingStatuses[status] ?? status),
            style: TextStyle(
                color: live ? scheme.onPrimary : scheme.onSurface,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontVariations: const [FontVariation('wght', 600)])),
      ),
    );
  }
}

/// One-line stock summary for list rows, e.g. "3 дана".
String stockSummary(Listing l) {
  final total = l.sizes.fold<int>(0, (n, s) => n + (s.quantity ?? 0));
  final views = l.stats == null ? '' : trf(' · {0} қаралым', [l.stats!.views]);
  return trf('{0} дана · {1}{2}', [total, formatTenge(l.priceTiyn), views]);
}

/// The page's completeness score and the few things that would raise it most.
class QualityCard extends StatelessWidget {
  const QualityCard({super.key, required this.quality});
  final ListingQuality quality;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final q = quality;
    final light = theme.brightness == Brightness.light;
    final color = q.score >= 85
        ? const Color(0xFF2E9E6A)
        : q.score >= 60
            ? Brand.accent
            : scheme.error;
    // The verdict is small text, so it takes a deeper shade of the bar's colour where the card is white.
    final verdictColor = q.score >= 85
        ? (light ? const Color(0xFF1F7A50) : color)
        : q.score >= 60
            ? accentText(context)
            : color;
    return Card(
      key: const Key('listing-quality'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(tr('Тауар бетінің толықтығы'), style: theme.textTheme.titleSmall)),
            Text('${q.score}/100', key: const Key('quality-score'), style: weight(theme.textTheme.titleMedium!, 750)),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: q.score / 100,
              minHeight: 8,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 8),
          Text(q.verdict,
              style: theme.textTheme.labelMedium?.copyWith(
                  color: verdictColor,
                  fontWeight: FontWeight.w700,
                  fontVariations: const [FontVariation('wght', 700)])),
          for (final t in q.tips.take(3)) ...[
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.add_circle_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(t.text, style: theme.textTheme.bodyMedium)),
              const SizedBox(width: 8),
              Text('+${t.points}', style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ],
        ]),
      ),
    );
  }
}
