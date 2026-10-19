import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/color_choice.dart';
import '../widgets/common.dart';
import '../widgets/delivery_eta.dart';
import '../widgets/delivery_sheet.dart';
import '../widgets/questions.dart';
import '../widgets/size_guide.dart';
import '../widgets/scroll_showcase.dart';
import '../widgets/spin_viewer.dart';
import '../widgets/studio.dart';
import 'chat_screen.dart';
import 'help_screen.dart';
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
  const ListingScreen(
      {super.key,
      required this.listingId,
      this.cover,
      this.coverIsCutout = false,
      this.sizeLabel,
      this.atDetails = false,
      this.listing,
      this.pending,
      this.view});
  final int listingId;

  /// The listing, already fetched: the page shows it at once.
  final Listing? listing;

  /// The listing's request, already sent: the page waits for it instead of sending another.
  final Future<Listing>? pending;

  /// What the showcase opens showing (ShowcasePlan.viewAt): another colour picked there shows the same.
  final ShowcaseView? view;

  /// How long a colour picked on the showcase may wait for its listing and photo; slower, it opens at its cover.
  static const switchBudget = Duration(milliseconds: 700);

  /// The size the buyer had picked on another colour of this model: picked here too when it is in stock.
  final String? sizeLabel;

  /// Opens past the showcase, at the title, as when another colour was picked there.
  final bool atDetails;

  /// The photo the catalog card showed: it flies in and stays while the listing loads.
  final String? cover;

  /// The cover is a cut-out: its shadow flies with it.
  final bool coverIsCutout;

  @override
  State<ListingScreen> createState() => _ListingScreenState();
}

class _ListingScreenState extends State<ListingScreen> {
  late Future<Listing> _listing;
  late Listing? _ready = widget.listing;
  late Future<Listing>? _pending = widget.pending;
  Future<List<Listing>>? _similar;
  int? _sizeId;
  bool _fitChecked = false;
  bool _favorite = false;
  bool _ordering = false;
  bool _showPhotos = false;
  final _scroll = ScrollController(); // drives the scroll-turned showcase at the top
  final _showcase = GlobalKey<ScrollShowcaseState>();
  final _sizesKey = GlobalKey();
  bool _scrollLocked = false; // the showcase is zoomed in or being pinched
  Brightness? _stageTop; // how dark the showcase stage under the status bar is, while it is there
  double? _darkPhotos; // the height of the Photo tab's dark scan photos, which run under the status bar too
  Offer? _offer; // the signed-in buyer's latest offer on this listing
  // One key per order attempt: a retried tap after a lost response returns the same order.
  String _orderKey = newIdempotencyKey();
  Set<int>? _alerts; // sold-out sizes the buyer waits for, once they tap one

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_followPhotos);
  }

  /// On the Photo tab a dark scan's photos sit under the status bar until scrolled past: its icons go light there.
  void _followPhotos() {
    if (!_showPhotos || !mounted) return;
    final h = _darkPhotos;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final top = h != null && offset < h - MediaQuery.viewPaddingOf(context).top ? Brightness.dark : null;
    if (top != _stageTop) setState(() => _stageTop = top);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadListing();
    _similar ??= SessionScope.of(context).api.similar(widget.listingId).catchError((_) => <Listing>[]);
    _loadOffer();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _loadListing() {
    final ready = _ready;
    _ready = null; // a reload fetches again
    final pending = _pending;
    _pending = null;
    _listing = ready != null ? Future.value(ready) : pending ?? SessionScope.of(context).api.listing(widget.listingId);
    _listing.then((l) {
      if (l.status == 'published') rememberViewed(l);
    }, onError: (_) {});
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
    final offer = _offer?.status == 'accepted' && _offer!.sizeId == _sizeId ? _offer : null;
    final checkout = await showModalBottomSheet<Checkout>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // An agreed price is already the seller's discount, so a promo code is not offered on top of it.
      builder: (_) => DeliverySheet(
          listingId: offer == null ? listing.id : null,
          itemPriceTiyn: offer == null ? listing.priceTiyn : min(offer.priceTiyn, listing.priceTiyn),
          deliveryPriceTiyn: listing.deliveryPriceTiyn),
    );
    if (checkout == null || !mounted) return;
    setState(() => _ordering = true);
    try {
      final session = SessionScope.of(context);
      final order = await session.api.createOrder(listing.id, _sizeId!, _orderKey,
          delivery: checkout.delivery,
          offerId: offer?.id,
          promoCode: checkout.promoCode,
          photosVersion: listing.photosVersion);
      session.api.me().then(session.update, onError: (_) {}); // the address is remembered for next time
      if (offer != null) _offer = null;
      _orderKey = newIdempotencyKey();
      if (!mounted) return;
      // The order screen opens on its "now pay" banner: paying is the one step left.
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: order.id)));
    } catch (e) {
      if (mounted) showError(context, e);
      // The seller changed the photos meanwhile: show the new ones, nothing was ordered.
      if (e is ApiException && e.code == 'photos_changed' && mounted) setState(_loadListing);
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
        // Icons that read on the stage under them, whatever the app's theme.
        systemOverlayStyle: switch (_stageTop) {
          Brightness.dark => SystemUiOverlayStyle.light,
          Brightness.light => SystemUiOverlayStyle.dark,
          null => null,
        },
        leading: Padding(
            padding: const EdgeInsets.all(6),
            child: _RoundButton(dark: _stageTop == Brightness.dark, back: true, child: const BackButtonIcon())),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _RoundButton(
              key: const Key('share'),
              dark: _stageTop == Brightness.dark,
              onTap: _share,
              tooltip: tr('Бөлісу'),
              child: const Icon(Icons.ios_share_rounded),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _RoundButton(
              dark: _stageTop == Brightness.dark,
              onTap: _toggleFavorite,
              tooltip: tr('Таңдаулыға'),
              child: Icon(_favorite ? Icons.favorite : Icons.favorite_border, color: _favorite ? Brand.accent : null),
            ),
          ),
        ],
      ),
      body: FutureBuilder<Listing>(
        future: _listing,
        initialData: widget.listing,
        builder: (context, snap) {
          if (snap.hasError && snap.connectionState == ConnectionState.done) {
            return SafeArea(child: ErrorRetry(error: snap.error, onRetry: () => setState(_loadListing)));
          }
          if (!snap.hasData) {
            final cover = widget.cover;
            if (cover == null || MediaQuery.of(context).disableAnimations) {
              return const Center(child: CircularProgressIndicator());
            }
            return Stack(children: [
              Hero(
                tag: 'listing-${widget.listingId}',
                // Only the shoe: the page may open on a dark stage or the photos as taken, so no backdrop flashes.
                child: CoverPhoto(
                    image: coverImage(cover),
                    cutout: widget.coverIsCutout,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              ),
              const Center(child: CircularProgressIndicator()),
            ]);
          }
          return _body(context, snap.data!);
        },
      ),
    );
  }

  void _relay(PointerEvent e) => _showcase.currentState?.handlePointer(e);

  /// Past the turning shoe to the title and details.
  /// Height of the showcase's stage, from the last build that showed it; null without one.
  double? _stage;

  /// Scroll offset where the details begin below the showcase, just under the app bar.
  double? _detailsAt(Listing l) => _stage == null
      ? null
      : ScrollShowcase.travelFor(_stage!, ShowcasePlan.of(l).steps.length) +
          _stage! -
          MediaQuery.paddingOf(context).top -
          kToolbarHeight;

  /// The colour picked and being fetched; a later pick takes its place.
  int? _pendingColor;

  /// Another colour of this model, in place of this one: back still leads where the buyer came from. The size they
  /// picked comes along, and from the details they land at the details again. Picked on the showcase, it opens
  /// showing what this one shows (the same angle of the turn, or the same stop) when it arrives in time.
  Future<void> _openColor(Listing l, Colorway c, {required bool atDetails}) async {
    if (_pendingColor == c.id) return;
    final route = ModalRoute.of(context);
    final thumb = c.thumbUrl;
    var view = atDetails ? null : _showcase.currentState?.view;
    Listing? next;
    Future<Listing>? pending;
    if (view != null) {
      setState(() => _pendingColor = c.id); // the ring moves to it at once
      final api = SessionScope.of(context).api;
      final watch = Stopwatch()..start();
      final fetch = api.listing(c.id);
      try {
        next = await fetch.timeout(ListingScreen.switchBudget);
        final carried = ScrollShowcase.carry(view, l, next);
        final image = carried == null ? null : ScrollShowcase.firstImageAt(next, carried);
        final left = ListingScreen.switchBudget - watch.elapsed;
        if (image != null && mounted && left > Duration.zero) {
          await precacheImage(image, context, onError: (_, __) {}).timeout(left, onTimeout: () {});
        }
      } on TimeoutException {
        pending = fetch; // the page waits for the request already made instead of making another
      } catch (e) {
        debugPrint('colour ${c.id} could not be fetched ahead: $e');
        pending = fetch; // the page shows the error and its retry
      }
      if (!mounted || _pendingColor != c.id) return; // gone, or a later pick took over
      // Back pressed, or a sheet or the login opened meanwhile: replacing now would replace that instead.
      if (route?.isCurrent != true) {
        setState(() => _pendingColor = null);
        return;
      }
      view = _showcase.currentState?.view ?? view; // the buyer may have scrolled on while it came
      // A slow colour opens at its cover rather than jumping there later; the other colour's turn shows the same
      // side, when it can tell which of its frames that is.
      view = next == null ? null : ScrollShowcase.carry(view, l, next);
    }
    final size = l.sizes.where((s) => s.id == _sizeId).firstOrNull?.label;
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => ListingScreen(
          listingId: c.id,
          listing: next,
          pending: pending,
          cover: thumb,
          coverIsCutout: c.cutout && thumb != null,
          sizeLabel: size,
          atDetails: atDetails,
          view: view),
      // The same shoe in another colour: a quick fade, not a new page sliding in.
      transitionsBuilder: (_, animation, __, child) => FadeTransition(opacity: animation, child: child),
    ));
  }

  void _toDetails(Listing l) {
    final at = _detailsAt(l);
    if (!_scroll.hasClients || at == null) return;
    final to = min(_scroll.position.maxScrollExtent, at);
    if (MediaQuery.of(context).disableAnimations) {
      _scroll.jumpTo(to);
    } else {
      _scroll.animateTo(to, duration: const Duration(milliseconds: 500), curve: Curves.easeInOut);
    }
  }

  void _toSizes(Listing l) {
    void show() {
      final sizes = _sizesKey.currentContext;
      if (sizes == null || !mounted) return;
      Scrollable.ensureVisible(sizes,
          alignment: 0.3,
          duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 500));
    }

    // Behind a long showcase the sizes are not built yet: go past it first, then bring them into view.
    final at = _detailsAt(l);
    if (_sizesKey.currentContext == null && at != null && _scroll.hasClients) {
      _scroll.jumpTo(min(_scroll.position.maxScrollExtent, at));
      WidgetsBinding.instance.addPostFrameCallback((_) => show());
    } else {
      show();
    }
  }

  Widget _body(BuildContext context, Listing l) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final frames = l.frames;
    final hasSpin = frames.length >= _minSpinFrames;
    final scan = l.backdrop != null && l.photos.every((p) => p.processedUrl == p.originalUrl);
    final darkScan = scan && l.backdrop == 'dark';
    final fit = bestFit(l.sizes, mySize.value);
    if (!_fitChecked) {
      _fitChecked = true; // pick the buyer's saved size once; after that their taps decide
      final kept = l.sizes.where((s) => s.available && s.label == widget.sizeLabel).firstOrNull;
      _sizeId ??= kept?.id ?? fit?.id;
      if (widget.atDetails) {
        // The showcase sets its height while building: go past it once the page is laid out.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final at = mounted ? _detailsAt(l) : null;
          if (at != null && _scroll.hasClients) _scroll.jumpTo(min(_scroll.position.maxScrollExtent, at));
        });
      } else if (widget.view case final view?) {
        // The same, to what the other colour showed.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final stage = _stage;
          final at = mounted && stage != null ? ScrollShowcase.offsetFor(l, stage, view) : null;
          if (at != null && _scroll.hasClients) _scroll.jumpTo(min(_scroll.position.maxScrollExtent, at));
        });
      }
    }
    final selected = l.sizes.where((s) => s.id == _sizeId).firstOrNull;
    final me = SessionScope.of(context).me;
    final own = me?.id == l.sellerId;
    final away = l.sellerAwayUntil;
    final canOffer = l.status == 'published' && me?.id != l.sellerId && !_offerLive && away == null;
    final deal = _offer?.status == 'accepted' && _offer!.sizeId == selected?.id ? _offer : null;
    final itemPrice = deal == null ? l.priceTiyn : (deal.priceTiyn < l.priceTiyn ? deal.priceTiyn : l.priceTiyn);
    return Column(children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, viewport) {
            // The Photo tab's square, as laid out below: as wide as the page, at most 560 high.
            _darkPhotos = darkScan ? min(viewport.maxWidth, 560.0) : null;
            return Listener(
              // Above the list, so a second finger reaches the showcase even while the first one is scrolling.
              onPointerDown: _relay,
              onPointerMove: _relay,
              onPointerUp: _relay,
              onPointerCancel: _relay,
              child: ListView(
                  controller: _scroll,
                  padding: EdgeInsets.zero,
                  physics: _scrollLocked ? const NeverScrollableScrollPhysics() : null,
                  children: [
                    if (hasSpin && !_showPhotos)
                      ScrollShowcase(
                          key: _showcase,
                          listing: l,
                          scroll: _scroll,
                          stageHeight: _stage = viewport.maxHeight,
                          onLock: (locked) {
                            if (mounted && locked != _scrollLocked) setState(() => _scrollLocked = locked);
                          },
                          onPhotos: () {
                            if (_scroll.hasClients) _scroll.jumpTo(0);
                            setState(() {
                              _showPhotos = true;
                              _stage = null;
                            });
                            WidgetsBinding.instance.addPostFrameCallback((_) => _followPhotos()); // once laid out
                          },
                          onStageTop: (top) {
                            if (mounted) setState(() => _stageTop = top);
                          },
                          onColor: (c) => _openColor(l, c, atDetails: false),
                          pendingColor: _pendingColor,
                          onDetails: () => _toDetails(l))
                    else
                      // Square on a phone; on a tablet or the web the photo stops growing so the details stay in view.
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 560),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Hero(
                            tag: 'listing-${l.id}',
                            // The photo tab always shows the photos exactly as taken, so buyers can check the unedited originals.
                            child: DecoratedBox(
                              decoration: showcaseBackground(l.showcaseStyle),
                              child: Material(
                                type: MaterialType.transparency,
                                child: ColoredBox(
                                  // A scan's photos are themselves cut out: they stand on the scene the 360° view has.
                                  color:
                                      scan ? (darkScan ? ShowcaseScene.dark : ShowcaseScene.light).ink : Brand.studio,
                                  child: PhotoGallery(dark: darkScan, urls: [for (final p in l.photos) p.originalUrl]),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (hasSpin && _showPhotos) // in the 360° view the switch sits on the viewer itself
                      Padding(
                        padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 14, 20, 0)),
                        child: SegmentedButton<bool>(
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(value: false, icon: Icon(Icons.threesixty), label: Text('360°')),
                            ButtonSegment(
                                value: true, icon: Icon(Icons.photo_library_outlined), label: Text(tr('Фото'))),
                          ],
                          selected: {_showPhotos},
                          onSelectionChanged: (v) {
                            if (_scroll.hasClients) _scroll.jumpTo(0); // the showcase's stretch of page comes or goes
                            setState(() {
                              _showPhotos = v.first;
                              _stage = null; // set again by the showcase when it is built
                            });
                          },
                        ),
                      ),
                    Padding(
                      padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 20, 20, 24)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.title, style: theme.textTheme.headlineSmall),
                        const SizedBox(height: 6),
                        ColorChoice(listing: l, onPick: (c) => _openColor(l, c, atDetails: true)),
                        const SizedBox(height: 6),
                        PriceLine(listing: l, style: weight(theme.textTheme.headlineSmall!, 800)),
                        if (l.wasPriceTiyn != null)
                          Padding(
                            key: const Key('sale-honest'),
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(tr('Сызылған баға: соңғы 30 күндегі ең төмен баға.'),
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                          ),
                        const SizedBox(height: 4),
                        Text(
                          l.deliveryPriceTiyn == 0
                              ? tr('Жеткізу тегін')
                              : trf('Жеткізу {0}', [formatTenge(l.deliveryPriceTiyn)]),
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        DeliveryEta(listingId: l.id),
                        if (l.soldRecently > 0 || l.savedBy > 0)
                          Padding(
                            key: const Key('popularity'),
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(children: [
                              Icon(Icons.local_fire_department_outlined, size: 18, color: Brand.accent),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  [
                                    if (l.soldRecently > 0) trf('30 күнде {0} жұп сатып алынды', [l.soldRecently]),
                                    if (l.savedBy > 0) trf('{0} адам таңдаулыға қосты', [l.savedBy]),
                                  ].join(' · '),
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ]),
                          ),
                        if (away != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            key: const Key('seller-away'),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(Brand.radius)),
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
                                  icon: Icons.auto_awesome_outlined,
                                  name: tr('Жағдайы'),
                                  value: label(conditions, l.condition)),
                              const Divider(),
                              _Fact(
                                  icon: Icons.verified_outlined,
                                  name: tr('Түпнұсқалығы'),
                                  value: label(authenticity, l.authenticity)),
                              const Divider(),
                            ]),
                          ),
                        ),
                        if ((l.defects ?? '').isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                                color: scheme.errorContainer, borderRadius: BorderRadius.circular(Brand.radius)),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Icon(Icons.report_outlined, color: scheme.onErrorContainer),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(trf('Ақаулары: {0}', [l.defects]),
                                    style: TextStyle(color: scheme.onErrorContainer)),
                              ),
                            ]),
                          ),
                        ],
                        const SizedBox(height: 24),
                        Row(key: _sizesKey, children: [
                          Expanded(child: Text(tr('Өлшем'), style: theme.textTheme.titleMedium)),
                          TextButton.icon(
                            key: const Key('size-guide'),
                            onPressed: () async {
                              if (await showSizeGuide(context) != null && mounted) setState(() {});
                            },
                            icon: const Icon(Icons.straighten, size: 18),
                            label: Text(tr('Өлшем кестесі')),
                          ),
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
                        QuestionsSection(listingId: l.id, sellerId: l.sellerId),
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
                              onTap: () => Navigator.of(context)
                                  .push(MaterialPageRoute(builder: (_) => ShopScreen(sellerId: l.sellerId))),
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
                                tr(protectionText),
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ]),
                        ),
                        _SimilarRow(items: _similar),
                      ]),
                    ),
                  ]),
            );
          },
        ),
      ),
      Material(
        color: scheme.surface,
        child: SafeArea(
          top: false,
          child: Container(
            padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 12, 20, 12)),
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
                  key: const Key('buy'),
                  style: FilledButton.styleFrom(backgroundColor: Brand.accentStrong, foregroundColor: Colors.white),
                  onPressed: l.status == 'published' && !own && !_ordering && away == null
                      ? selected != null
                          ? () => _order(l)
                          // No size yet: take the buyer to the sizes, past the showcase, instead of a dead button.
                          : l.sizes.any((s) => s.available)
                              ? () => _toSizes(l)
                              : null
                      : null,
                  child: Text(own
                      ? tr('Бұл сіздің тауарыңыз')
                      : l.status == 'sold'
                          ? tr('Сатылған')
                          : l.status != 'published'
                              ? tr('Қазір сатылымда жоқ')
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
  const _RoundButton({super.key, required this.child, this.onTap, this.tooltip, this.back = false, this.dark = false});
  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool back;

  /// Over the demo page's dark scene: its panel colour, as the stage's own buttons.
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: dark ? ShowcaseScene.dark.panel : Colors.white.withValues(alpha: 0.92),
      shape: CircleBorder(side: dark ? BorderSide(color: ShowcaseScene.dark.line) : BorderSide.none),
      child: IconButton(
        tooltip: tooltip ?? (back ? tr('Артқа') : null),
        color: dark ? ShowcaseScene.dark.fg : Brand.ink,
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
        Flexible(
          child: Text(name, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
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
    // container: the tile is read as one button with this label, not as the two texts inside it.
    return Semantics(
      container: true,
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
          // At least 76 by 58, and taller or wider when large text needs it.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 76, minHeight: 58),
            child: Stack(alignment: Alignment.center, children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            height: 160 + listingTileTextExtent(context),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) => SizedBox(width: 160, child: ListingTile(listing: list[i], turns: false)),
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
          Expanded(flex: 3, child: Text(headline, style: weight(theme.textTheme.titleSmall!, 700))),
          Flexible(
            flex: 2,
            child: Text(trf('{0} сатып алушы', [fit.answers]),
                textAlign: TextAlign.end, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
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
        Wrap(alignment: WrapAlignment.spaceBetween, spacing: 12, children: [
          legend('Кішілеу', fit.small),
          legend('Сай', fit.trueToSize),
          legend('Үлкендеу', fit.large),
        ]),
      ]),
    );
  }
}
