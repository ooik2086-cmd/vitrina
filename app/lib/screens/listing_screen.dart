import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../labels.dart';
import '../net_image.dart';
import '../push.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/color_choice.dart';
import '../widgets/common.dart';
import '../widgets/delivery_sheet.dart';
import '../widgets/listing_lines.dart';
import '../widgets/questions.dart';
import '../widgets/model_stage.dart';
import '../widgets/scroll_showcase.dart' show ShowcaseScene;
import '../widgets/spin_viewer.dart';
import '../widgets/video_pane.dart';
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

class ListingScreen extends StatefulWidget {
  const ListingScreen({super.key, required this.listingId, this.listing, this.pending});
  final int listingId;

  /// The listing, already fetched: the page shows it at once.
  final Listing? listing;

  /// The listing's request, already sent: the page waits for it instead of sending another.
  final Future<Listing>? pending;

  @override
  State<ListingScreen> createState() => _ListingScreenState();
}

class _ListingScreenState extends State<ListingScreen> {
  /// The listing shown: another colour of the model takes its place on this page (see [_openColor]).
  late int _id = widget.listingId;
  late Future<Listing> _listing;
  late Listing? _ready = widget.listing;
  late Future<Listing>? _pending = widget.pending;

  /// Why the buyer's own offer did not load, while that may pass; buying waits until it is known.
  Object? _offerError;
  bool _offerRetrying = false;
  int? _sizeId;
  bool _fitChecked = false;
  bool _favorite = false;
  bool _ordering = false;
  _Pane _pane = _Pane.turn;

  /// The video is built at the first tap on its tab, then kept (paused) while another tab shows.
  bool _videoOpened = false;

  /// The 3D could not open: the stage shows the photos, with no switch to a 3D that is not there.
  bool _noModel = false;
  final _scroll = ScrollController();
  final _model = GlobalKey<ModelStageState>();
  final _sizesKey = GlobalKey();
  Brightness? _stageTop; // how dark the stage under the status bar is, while it is there

  /// The stage's scene, light or dark, the same for the 3D and the photos; the buyer's choice holds for the app run.
  static bool? _darkChoice;
  bool _dark = false;

  /// The stage's height, from the last build.
  double _stage = 0;

  /// The page has moved under the bar: the bar takes the page's canvas, so the details do not run under its round
  /// buttons. Only the bar listens: the page is not built again for it.
  final _barSolid = ValueNotifier<bool>(false);
  Offer? _offer; // the signed-in buyer's latest offer on this listing
  // One key per order attempt: a retried tap after a lost response returns the same order.
  String _orderKey = newIdempotencyKey();
  String? _orderFor; // what [_orderKey] was last sent for
  Checkout? _unanswered; // the last order sent whose answer never came
  Set<int>? _alerts; // sold-out sizes the buyer waits for, once they tap one
  // Off until a payment partner is signed: the buy button then opens the chat with the seller and offers are hidden.
  bool _payments = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_followStage);
  }

  /// The bar goes solid once the page moves under it, and its icons follow the scene of the stage under them.
  void _followStage() {
    if (!mounted) return;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    _barSolid.value = offset > 0.5;
    final under = offset < _stage - MediaQuery.viewPaddingOf(context).top;
    final top = under ? (_dark ? Brightness.dark : Brightness.light) : null;
    if (top != _stageTop) setState(() => _stageTop = top);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadListing();
    _loadOffer();
    _loadPayments();
  }

  /// Asked once per app run; after a failed check «Try again» asks again.
  void _loadPayments() => SessionScope.of(context).api.paymentsOn().then((on) {
        if (mounted && on != _payments) setState(() => _payments = on);
      });

  @override
  void dispose() {
    _scroll.dispose();
    _barSolid.dispose();
    super.dispose();
  }

  void _loadListing() {
    final ready = _ready;
    _ready = null; // a reload fetches again
    final pending = _pending;
    _pending = null;
    _listing = shown(ready != null ? Future.value(ready) : pending ?? SessionScope.of(context).api.listing(_id));
    _listing.then((l) {
      if (l.status == 'published') rememberViewed(l);
    }, onError: (_) {});
  }

  /// After a failed load, «Try again» fetches every part of the page, not only the listing.
  void _reload() {
    setState(() {
      _loadListing();
    });
    _loadPayments();
    if (_offer == null) _loadOffer();
  }

  Future<void> _loadOffer() async {
    final session = SessionScope.of(context);
    if (!session.signedIn) return;
    if (_offerError != null) setState(() => _offerRetrying = true);
    final id = _id;
    try {
      final mine = await session.api.offers(listingId: id);
      if (!mounted || id != _id) return; // another colour opened meanwhile: its own offers are asked for
      setState(() {
        _offerError = null;
        if (mine.isEmpty) return;
        _offer = mine.first;
        if (_offerLive) _sizeId = _offer!.sizeId; // the deal is for that size
      });
    } catch (e) {
      // An agreed price that did not load must not be lost without a word: the buyer would pay the full price.
      if (mounted && id == _id && _offer == null) {
        setState(() => _offerError = e is ApiException && e.passing ? e : null);
      }
    } finally {
      if (mounted && _offerRetrying) setState(() => _offerRetrying = false);
    }
  }

  /// An offer the buyer can still act on, or order under.
  bool get _offerLive => const {'pending', 'countered', 'accepted'}.contains(_offer?.status);

  Future<void> _makeOffer(Listing listing, ShoeSize size) async {
    if (!await _ensureSignedIn() || !mounted) return;
    final offer = await showSheet<Offer>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => OfferSheet(listing: listing, size: size),
    );
    if (offer == null || !mounted) return;
    setState(() => _offer = offer);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Ұсыныс жіберілді. Сатушы жауап бергенде хабарлаймыз.'))));
    unawaited(Push.offer(context));
  }

  Future<void> _toggleStockAlert(Listing l, ShoeSize size) async {
    if (!await _ensureSignedIn() || !mounted) return;
    final alerts = {...(_alerts ?? l.stockAlerts)};
    final on = !alerts.contains(size.id);
    try {
      await SessionScope.of(context).api.setStockAlert(l.id, size.id, on);
      if (!mounted || l.id != _id) return;
      setState(() => _alerts = on ? (alerts..add(size.id)) : (alerts..remove(size.id)));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(on
              ? trf('{0} өлшемі қайта шыққанда хабарлаймыз.', [size.label])
              : trf('{0} өлшемі туралы хабарлама өшірілді.', [size.label]))));
      if (on) unawaited(Push.offer(context));
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

  Future<void> _toggleFavorite() => once((this, #favorite), () async {
        if (!await _ensureSignedIn() || !mounted) return;
        final on = !_favorite, id = _id;
        try {
          await SessionScope.of(context).api.setFavorite(id, on);
          if (mounted && id == _id) setState(() => _favorite = on);
        } catch (e) {
          if (mounted) showError(context, e);
        }
      });

  /// Once at a time: a second tap while the agreed price or sign-in is awaited would open a second order sheet.
  Future<void> _order(Listing listing) => once((this, #order), () => _orderNow(listing));

  Future<void> _orderNow(Listing listing) async {
    if (!await _ensureSignedIn() || !mounted) return;
    // Whether the buyer has an agreed price is known first.
    if (_offerError != null) {
      await _loadOffer();
      if (!mounted) return;
      if (_offerError != null) return showError(context, _offerError!);
    }
    final offer = _offer?.status == 'accepted' && _offer!.sizeId == _sizeId ? _offer : null;
    final checkout = await showSheet<Checkout>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // An agreed price is already the seller's discount, so a promo code is not offered on top of it.
      builder: (_) => DeliverySheet(
          initial: _unanswered,
          listingId: offer == null ? listing.id : null,
          itemPriceTiyn: offer == null ? listing.priceTiyn : min(offer.priceTiyn, listing.priceTiyn),
          deliveryPriceTiyn: listing.deliveryPriceTiyn),
    );
    // Another colour opened meanwhile: its size is not this pair's, so nothing is ordered.
    if (checkout == null || !mounted || listing.id != _id) return;
    // A retry of the same order keeps its key, so an answer lost on a weak line never makes two orders. Another size,
    // address, price or code is another order: it gets its own key, or the server would hand back the first one.
    final what = jsonEncode([listing.id, _sizeId, offer?.id, checkout.promoCode, checkout.delivery.toJson()]);
    if (what != _orderFor) _orderKey = newIdempotencyKey();
    _orderFor = what;
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
      _unanswered = null;
      if (!mounted) return;
      // The order screen opens on its "now pay" banner: paying is the one step left.
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: order.id)));
    } catch (e) {
      // No answer (a weak line): the order may be made. The next try fills in the same and keeps the key, so it is
      // the same order. A plain refusal made nothing, and anything may be changed.
      _unanswered = e is! ApiException || e.passing ? checkout : null;
      if (mounted) showError(context, e);
      // Online payment was switched off after this page asked: from now on the button writes to the seller.
      if (e is ApiException && e.code == 'payments_off' && mounted) {
        SessionScope.of(context).api.paymentsTurnedOff();
        setState(() => _payments = false);
      }
      // The seller changed the photos meanwhile, or another buyer took the last pair: show the listing as it is now,
      // nothing was ordered. A size that is gone is picked again.
      if (e is ApiException && (e.code == 'photos_changed' || e.code == 'out_of_stock') && mounted) {
        setState(() {
          if (e.code == 'out_of_stock') _sizeId = null;
          _loadListing();
        });
      }
    } finally {
      if (mounted) setState(() => _ordering = false);
    }
  }

  Future<void> _chat(Listing listing, {String? draft}) => once((this, #chat), () async {
        if (!await _ensureSignedIn() || !mounted) return;
        try {
          final conv = await SessionScope.of(context).api.openConversation(listing.id);
          if (!mounted) return;
          await Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: conv.id, draft: draft)));
        } catch (e) {
          if (mounted) showError(context, e);
        }
      });

  Future<void> _report(Listing listing) => once((this, #report), () => _reportNow(listing));

  Future<void> _reportNow(Listing listing) async {
    if (!await _ensureSignedIn() || !mounted) return;
    final sent = await showSheet<bool>(
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
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ValueListenableBuilder<bool>(
          valueListenable: _barSolid,
          builder: (context, solid, _) {
            // On the stage, its scene's look; on the bar's canvas, the theme's.
            final dark = solid ? Theme.of(context).brightness == Brightness.dark : _stageTop == Brightness.dark;
            return AppBar(
              backgroundColor: Colors.transparent,
              flexibleSpace: IgnorePointer(child: _BarCanvas(solid: solid)),
              // Icons that read on the stage under them, whatever the app's theme; on the bar's canvas, the theme's.
              systemOverlayStyle: solid
                  ? null
                  : switch (_stageTop) {
                      Brightness.dark => SystemUiOverlayStyle.light,
                      Brightness.light => SystemUiOverlayStyle.dark,
                      null => null,
                    },
              leading: Padding(
                  padding: const EdgeInsets.all(4), // the button keeps a finger's 48 in the bar's 56
                  child: _RoundButton(dark: dark, back: true, child: const BackButtonIcon())),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _RoundButton(
                    key: const Key('share'),
                    dark: dark,
                    onTap: _share,
                    tooltip: tr('Бөлісу'),
                    child: const Icon(Icons.ios_share_rounded),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _RoundButton(
                    dark: dark,
                    onTap: _toggleFavorite,
                    tooltip: tr('Таңдаулыға'),
                    child: Icon(_favorite ? Icons.favorite : Icons.favorite_border,
                        color: _favorite ? Brand.accent : null),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      body: FutureBuilder<Listing>(
        future: _listing,
        initialData: widget.listing,
        builder: (context, snap) {
          if (snap.hasError && snap.connectionState == ConnectionState.done) {
            return SafeArea(child: ErrorRetry(error: snap.error, onRetry: _reload));
          }
          // Only the page's own 3D shows the shoe, no photo before it (Aza, 2026-10-24).
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return _body(context, snap.data!);
        },
      ),
    );
  }

  /// The colour picked and being fetched; a later pick takes its place.
  int? _pendingColor;

  /// Another colour of this model, in place of this one, on this same page: the 3D stays open and only the shoe's
  /// colour changes, at the same turn and zoom, and the page stays where it was. The size the buyer picked comes
  /// along when that colour has it.
  Future<void> _openColor(Listing l, Colorway c) async {
    if (_pendingColor == c.id) return;
    setState(() => _pendingColor = c.id); // the ring moves to it at once
    final Listing next;
    try {
      next = await SessionScope.of(context).api.listing(c.id);
    } catch (e) {
      if (!mounted || _pendingColor != c.id) return;
      setState(() => _pendingColor = null);
      showError(context, e);
      return;
    }
    if (!mounted || _pendingColor != c.id) return; // gone, or a later pick took over
    final size = l.sizes.where((s) => s.id == _sizeId).firstOrNull?.label;
    setState(() {
      _id = next.id;
      _pendingColor = null;
      _listing = Future.value(next);
      // The size picked here, or else the buyer's own saved size, as when a page opens.
      _sizeId = size == null
          ? bestFit(next.sizes, mySize.value)?.id
          : next.sizes.where((s) => s.available && s.label == size).firstOrNull?.id;
      _photosReady = null;
      // What belonged to the other colour: its offer, its stock alerts, its order attempt.
      _offer = null;
      _offerError = null;
      _unanswered = null;
      _alerts = null;
      _favorite = false;
      _noModel = false;
      _videoOpened = false; // another colour, another video (or none)
      _orderKey = newIdempotencyKey();
    });
    if (next.status == 'published') rememberViewed(next);
    // The same model in another colour is shown at once, with no new "ready": its photos come down now.
    if (l.model != null && l.model?.url == next.model?.url) _readyPhotos(next);
    _loadOffer();
  }

  /// This pair's sizes with the insole length the seller measured; a tap picks one.
  Future<void> _sizeChart(Listing l) => showPageSheet<void>(context,
      title: tr('Өлшем кестесі'),
      builder: (sheet) => ListingSizeChart(
            sizes: l.sizes,
            selected: _sizeId,
            onPick: (s) {
              setState(() => _sizeId = s.id);
              Navigator.of(sheet).pop();
            },
          ));

  /// The seller's reviews in a sheet over the page, as on the approved demo.
  Future<void> _reviews(Listing l) => showSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        clipBehavior: Clip.antiAlias,
        builder: (_) => FractionallySizedBox(
          heightFactor: 0.86,
          child: SellerReviewsScreen(
              sellerId: l.sellerId, shopName: l.shopName ?? tr('Сатушы'), rating: l.sellerRating, inSheet: true),
        ),
      );

  void _toSizes(Listing l) {
    final sizes = _sizesKey.currentContext;
    if (sizes == null || !mounted) return;
    Scrollable.ensureVisible(sizes,
        alignment: 0.3,
        duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 500));
  }

  /// What the stage shows now: the tab picked, while this colour has it; else the 3D, else the photos.
  _Pane _shown(Listing l) => switch (_pane) {
        _Pane.video when (l.video?.ready ?? false) || (l.model != null && !_noModel) => _Pane.video,
        _Pane.photos => _Pane.photos,
        _ => l.model != null && !_noModel ? _Pane.turn : _Pane.photos,
      };

  /// The stage: the shoe in 3D, or its photos, on the light or dark scene, with the switch between the scenes.
  Widget _stageView(Listing l, double height) {
    final model = _noModel ? null : l.model;
    final shown = _shown(l);
    final video = l.video?.ready ?? false ? l.video : null;
    // Built once the Видео tab is first shown (also after a colour change made on it), never before: no data spent.
    final videoPane = video != null && (_videoOpened || shown == _Pane.video)
        ? VideoPane(
            key: ValueKey(video.url),
            url: video.url!,
            posterUrl: video.posterUrl,
            seconds: video.seconds,
            active: shown == _Pane.video,
            background: (_dark ? ShowcaseScene.dark : ShowcaseScene.light).ink)
        : null;
    final scene = _dark ? ShowcaseScene.dark : ShowcaseScene.light;
    // A scan's photos are themselves cut out: they stand on the scene; photos as taken fill the square.
    final scan = l.backdrop != null && l.photos.every((p) => p.processedUrl == p.originalUrl);
    final photos = ColoredBox(
      color: scan ? scene.ink : Brand.studio,
      // Its own per colour: another colour's photos start at their first, not at the page the last one was on.
      child: PhotoGallery(
          key: ValueKey(l.id), dark: scan && _dark, cutout: scan, urls: [for (final p in l.photos) p.originalUrl]),
    );
    final first = l.photos.firstOrNull;
    // The photos stand in for the 3D only when it cannot open on this phone.
    final cover = first == null
        ? const SizedBox.shrink()
        : CoverPhoto(
            image: coverImage(first.processedUrl ?? first.originalUrl),
            cutout: scan || (first.processedUrl ?? first.originalUrl) != first.originalUrl,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox.shrink());
    return SizedBox(
      height: height,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(fit: StackFit.expand, children: [
          if (model == null && videoPane == null)
            photos
          else if (model == null)
            IndexedStack(index: shown == _Pane.video ? 1 : 0, sizing: StackFit.expand, children: [
              photos,
              videoPane!,
            ])
          else
            // The 3D stays alive under the photos, so going back to it shows the shoe at once, as it was.
            IndexedStack(index: shown.index, sizing: StackFit.expand, children: [
              ModelStage(
                key: _model,
                model: model,
                dark: _dark,
                paused: shown != _Pane.turn,
                cover: cover,
                // The photos come down after the shoe, not alongside it on a weak line.
                onReady: () {
                  if (mounted) _readyPhotos(l);
                },
                onBroken: () {
                  if (mounted) setState(() => _noModel = true);
                },
              ),
              photos,
              videoPane ?? (video == null ? _NoVideo(scene: scene) : const SizedBox.shrink()),
            ]),
          if ((model != null || scan) && shown != _Pane.video)
            Positioned(
              right: 12,
              bottom: 12,
              child: _RoundButton(
                key: const Key('scene'),
                dark: _dark,
                tooltip: tr('Фонды ауыстыру: ашық не қараңғы'),
                onTap: () {
                  setState(() => _dark = _darkChoice = !_dark);
                  _followStage();
                },
                child: const Icon(Icons.contrast_rounded),
              ),
            ),
        ]),
      ),
    );
  }

  /// The photos are made ready while the 3D shows, so the Фото tab opens at once.
  void _readyPhotos(Listing l) {
    if (_photosReady == l.id) return;
    _photosReady = l.id;
    final side = min((MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round(), 2000);
    for (final p in l.photos) {
      precacheImage(ResizeImage.resizeIfNeeded(side, null, netImage(p.originalUrl)), context, onError: (_, __) {});
    }
  }

  int? _photosReady;

  /// A part of the stage switch: its word whole, made smaller only where very large text would not fit.
  Widget _switchLabel(String text) => FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1));

  Widget _body(BuildContext context, Listing l) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final fit = bestFit(l.sizes, mySize.value);
    final hasModel = l.model != null && !_noModel;
    final hasVideo = l.video?.ready ?? false;
    // Three parts with very large text: the words alone, so each is read whole; and only then made to fit.
    final roomy = !hasModel || MediaQuery.textScalerOf(context).scale(15) <= 21;
    if (!_fitChecked) {
      _fitChecked = true; // pick the buyer's saved size once; after that their taps decide
      _sizeId ??= fit?.id;
      _dark = _darkChoice ?? l.backdrop == 'dark';
      WidgetsBinding.instance.addPostFrameCallback((_) => _followStage());
    }
    final selected = l.sizes.where((s) => s.id == _sizeId).firstOrNull;
    final me = SessionScope.of(context).me;
    final own = me?.id == l.sellerId;
    final away = l.sellerAwayUntil;
    final canOffer = _payments && l.status == 'published' && me?.id != l.sellerId && !_offerLive && away == null;
    final deal = _offer?.status == 'accepted' && _offer!.sizeId == selected?.id ? _offer : null;
    final itemPrice = deal == null ? l.priceTiyn : (deal.priceTiyn < l.priceTiyn ? deal.priceTiyn : l.priceTiyn);
    return Column(children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, viewport) {
            // Most of the screen, at most 640 high, never under 300: a little taller than the approved demo (Aza: the
            // turned shoe was cut off), so the 3D fits it whole at any angle at its usual size. Always a strip under
            // it to scroll the page by (the stage takes every finger on it), as on a phone held sideways.
            _stage = l.photos.isEmpty && !hasModel
                ? 0
                : min(max(300.0, min(viewport.maxHeight * 0.7, 640.0)), max(160.0, viewport.maxHeight - 140));
            return ListView(controller: _scroll, padding: EdgeInsets.zero, children: [
              // Kept when the page scrolls it away, so scrolling back does not open the 3D again.
              if (_stage > 0) _KeptAlive(child: _stageView(l, _stage)),
              if (hasModel || hasVideo)
                Padding(
                  padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 14, 20, 0)),
                  // As on the approved demo, but 48 high, not 42: the smallest a finger is sure to hit, for every part.
                  child: SizedBox(
                    height: 48,
                    child: SegmentedButton<_Pane>(
                      key: const Key('stage-switch'),
                      showSelectedIcon: false,
                      style: ButtonStyle(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: const VisualDensity(vertical: 2), // 40 + 8
                        iconSize: const WidgetStatePropertyAll(18),
                        padding: roomy ? null : const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
                        textStyle:
                            WidgetStatePropertyAll(weight(theme.textTheme.labelLarge!, 700).copyWith(fontSize: 15)),
                      ),
                      segments: [
                        if (hasModel)
                          ButtonSegment(
                              value: _Pane.turn,
                              icon: roomy ? const Icon(Icons.threesixty) : null,
                              label: _switchLabel('360°')),
                        ButtonSegment(
                            value: _Pane.photos,
                            icon: roomy ? const Icon(Icons.photo_library_outlined) : null,
                            label: _switchLabel(tr('Фото'))),
                        // Always beside the 360°, as on the approved demo: without a video it says so calmly.
                        if (hasModel || hasVideo)
                          ButtonSegment(
                              value: _Pane.video,
                              icon: roomy ? const Icon(Icons.play_circle_outline_rounded) : null,
                              label: _switchLabel(tr('Видео'))),
                      ],
                      selected: {_shown(l)},
                      onSelectionChanged: (v) => setState(() {
                        _pane = v.first;
                        if (_pane == _Pane.video) _videoOpened = true;
                      }),
                    ),
                  ),
                ),
              Padding(
                padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 20, 20, 24)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.title, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  ColorChoice(listing: l, pending: _pendingColor, onPick: (c) => _openColor(l, c)),
                  const SizedBox(height: 8),
                  // The sizes right under the colours, as on the approved demo: one row of small circles.
                  Text.rich(
                    key: _sizesKey,
                    TextSpan(children: [
                      TextSpan(text: '${tr('Өлшемі')}: ', style: TextStyle(color: scheme.onSurfaceVariant)),
                      TextSpan(text: selected?.label ?? tr('таңдаңыз'), style: weight(theme.textTheme.bodyLarge!, 650)),
                      // The pair's own measured insole, as the seller gave it: what the foot will feel.
                      if (selected != null)
                        TextSpan(
                            text: ' · ${trf('{0} см', [selected.insoleCm])}',
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                    ]),
                    style: theme.textTheme.bodyLarge,
                  ),
                  Transform.translate(
                    offset: const Offset(-4, 0), // the first circle lines up with the text, not its touch margin
                    child: SizeCircles(
                      sizes: l.sizes,
                      selected: _sizeId,
                      alerted: _alerts ?? l.stockAlerts,
                      onPick: (s) => setState(() => _sizeId = s.id),
                      onSoldOut: own ? null : (s) => _toggleStockAlert(l, s),
                    ),
                  ),
                  // One small line: what buyers said about the size (the bars in a sheet), and the size chart.
                  Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 16, children: [
                    if (l.sizeFit case final sizeFit?)
                      _SmallLink(
                        key: const Key('fit-line'),
                        text: '${fitWords(sizeFit.verdict)} ›',
                        color: switch ((sizeFit.verdict == 'small' || sizeFit.verdict == 'large', dark)) {
                          (true, false) => const Color(0xFF8A5F00),
                          (true, true) => const Color(0xFFE0B04A),
                          (false, false) => const Color(0xFF276B43), // 5.6:1 on the paper
                          (false, true) => const Color(0xFF6CC48E),
                        },
                        onTap: () => showPageSheet<void>(context,
                            title: fitWords(sizeFit.verdict), builder: (_) => SizeFitNote(fit: sizeFit)),
                      ),
                    _SmallLink(
                      key: const Key('size-guide'),
                      text: tr('Өлшем кестесі'),
                      underline: true,
                      onTap: () => _sizeChart(l),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  // The price alone, as on the approved demo.
                  FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(formatTenge(l.priceTiyn),
                          key: const Key('price'), style: weight(theme.textTheme.headlineSmall!, 800))),
                  // Offering a price only once there is a size to offer it for.
                  if (canOffer && selected != null)
                    _SmallLink(
                        key: const Key('make-offer'),
                        text: tr('Бағаңызды ұсыну'),
                        underline: true,
                        onTap: () => _makeOffer(l, selected)),
                  if (_offer != null && _offer!.status != 'ordered' && _offer!.status != 'withdrawn') ...[
                    const SizedBox(height: 12),
                    OfferStatusCard(offer: _offer!, onChanged: (o) => setState(() => _offer = o)),
                  ],
                  if (_offer == null && _offerError != null) ...[
                    const SizedBox(height: 12),
                    Card(
                      margin: EdgeInsets.zero,
                      child: RetryLine(
                          key: const Key('offer-retry'),
                          what: tr('Сіздің ұсыныстарыңыз'),
                          error: _offerError,
                          busy: _offerRetrying,
                          onRetry: _loadOffer),
                    ),
                  ],
                  if ((l.defects ?? '').isNotEmpty) ...[
                    // Never folded away: what is wrong with the pair is said where the price is.
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                          color: scheme.errorContainer, borderRadius: BorderRadius.circular(Brand.radius)),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.report_outlined, color: scheme.onErrorContainer),
                        const SizedBox(width: 12),
                        Expanded(
                          child:
                              Text(trf('Ақаулары: {0}', [l.defects]), style: TextStyle(color: scheme.onErrorContainer)),
                        ),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 6),
                  // The reviews, the description and the questions, each one calm line that opens a sheet.
                  if (l.sellerRating case final rating? when l.sellerReviews > 0)
                    LineButton(
                      key: const Key('reviews-line'),
                      leading: const Icon(Icons.star_rounded, size: 20, color: Color(0xFFE0A100)),
                      title: ratingText(rating),
                      detail: trf('{0} пікір', [l.sellerReviews]),
                      onTap: () => _reviews(l),
                    ),
                  LineButton(
                    key: const Key('description-line'),
                    title: tr('Сипаттама'),
                    detail: descriptionLine(l),
                    // What the demo has no room for on the page is kept here: the buyer's protection and a report.
                    onTap: () => showPageSheet<void>(context,
                        title: tr('Сипаттама'),
                        builder: (sheet) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              ListingFacts(listing: l),
                              // As on the approved demo, no protection text here (it is at the order); only a deal
                              // straight with the seller is warned of, as the buyer's money is then not held.
                              if (!_payments) ...[
                                const SizedBox(height: 16),
                                Text(tr(directDealText), style: theme.textTheme.bodyMedium),
                              ],
                              if (!own)
                                TextButton.icon(
                                  key: const Key('report'),
                                  onPressed: () {
                                    Navigator.pop(sheet);
                                    _report(l);
                                  },
                                  icon: const Icon(Icons.flag_outlined, size: 18),
                                  label: Text(tr('Тауар туралы шағымдану')),
                                  style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                                ),
                            ])),
                  ),
                  QuestionsLine(listingId: l.id, sellerId: l.sellerId),
                  const SizedBox(height: 6),
                  Text(
                    l.deliveryPriceTiyn == 0
                        ? tr('Жеткізу тегін')
                        : trf('Жеткізу {0}', [formatTenge(l.deliveryPriceTiyn)]),
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (away != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      key: const Key('seller-away'),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Brand.radius)),
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
                  const SizedBox(height: 16),
                  _SellerRow(listing: l, own: own, onMessage: () => _chat(l)),
                ]),
              ),
            ]);
          },
        ),
      ),
      AnnotatedRegion<SystemUiOverlayStyle>(
        // Android's own buttons under the bar take the page's look.
        value: theme.extension<AppCanvas>()?.overlay ??
            (theme.brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark),
        child: Builder(builder: (context) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          return Material(
            color: scheme.surface,
            child: SafeArea(
              top: false,
              child: Container(
                padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 12, 20, 12)),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant))),
                child: LayoutBuilder(builder: (context, box) {
                  final text = own
                      ? tr('Бұл сіздің тауарыңыз')
                      : l.status == 'sold'
                          ? tr('Сатылған')
                          : l.status != 'published'
                              ? tr('Қазір сатылымда жоқ')
                              : away != null
                                  ? trf('{0} бастап', [formatDay(away.add(const Duration(days: 1)))])
                                  : !_payments
                                      ? tr('Сатушыға жазу')
                                      : selected == null
                                          ? tr('Өлшемді таңдаңыз')
                                          // The size picked, on the button: no doubt which pair is bought.
                                          : deal != null
                                              ? '${tr('Келісілген бағамен алу')} · ${selected.label}'
                                              : '${tr('Сатып алу')} · ${selected.label}';
                  final label =
                      Text(tr('Жиыны'), style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant));
                  final price = Text(formatTenge(itemPrice + l.deliveryPriceTiyn),
                      key: const Key('total'), style: weight(theme.textTheme.titleLarge!, 800));
                  // When the button's words do not fit beside the total (large text, a narrow phone, a long label), the
                  // button goes under it, full width, so no word is broken or cut.
                  final big =
                      !_buyFitsBeside(context, text, formatTenge(itemPrice + l.deliveryPriceTiyn), box.maxWidth);
                  final total = big
                      // One line for the total, so the shoe keeps more of the screen.
                      ? Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                          label,
                          const SizedBox(width: 12),
                          Expanded(
                              child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: price)),
                        ])
                      : ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.4),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [label, price]),
                          ),
                        );
                  final buy = FilledButton(
                    key: const Key('buy'),
                    style: FilledButton.styleFrom(backgroundColor: Brand.accentStrong, foregroundColor: Colors.white),
                    onPressed: l.status == 'published' && !own && !_ordering && away == null
                        ? !_payments
                            // The size picked goes with it, so the seller knows which pair the buyer means.
                            ? () => _chat(l,
                                draft: selected == null
                                    ? null
                                    : trf('Сәлеметсіз бе! {0} өлшемі бар ма?', [selected.label]))
                            : selected != null
                                ? () => _order(l)
                                // No size yet: take the buyer to the sizes, past the showcase, instead of a dead button.
                                : l.sizes.any((s) => s.available)
                                    ? () => _toSizes(l)
                                    : null
                        : null,
                    child: Text(text, key: const Key('buy-text'), textAlign: TextAlign.center),
                  );
                  return big
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [total, const SizedBox(height: 8), buy])
                      : Row(children: [total, const SizedBox(width: 16), Expanded(child: buy)]);
                }),
              ),
            ),
          );
        }),
      ),
    ]);
  }
}

/// Whether the buy button's [text] fits in two lines, no word broken, beside the [price] total in [width]: the total
/// takes its width (up to 40%), a 16 gap, and the button pads its text 24 on each side (less with large text).
bool _buyFitsBeside(BuildContext context, String text, String price, double width) {
  final theme = Theme.of(context).textTheme;
  final button = Theme.of(context).filledButtonTheme.style?.textStyle?.resolve(const {}) ?? theme.labelLarge;
  TextPainter measure(String t, TextStyle? style, {int? lines, double room = double.infinity}) => TextPainter(
      text: TextSpan(text: t, style: style),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      maxLines: lines)
    ..layout(maxWidth: room);
  final labels = [measure(tr('Жиыны'), theme.labelMedium), measure(price, weight(theme.titleLarge!, 800))];
  final total = min(width * 0.4, max(labels[0].width, labels[1].width));
  final room = width - total - 16 - 48;
  final words = [for (final w in text.split(' ')) measure(w, button)];
  final all = measure(text, button, lines: 2, room: max(0, room));
  final fits = !all.didExceedMaxLines && words.every((w) => w.width <= room);
  for (final p in [...labels, ...words, all]) {
    p.dispose();
  }
  return fits;
}

/// The Видео part while the seller has added no video: said calmly on the scene, never an empty square.
class _NoVideo extends StatelessWidget {
  const _NoVideo({required this.scene});
  final ShowcaseScene scene;

  @override
  Widget build(BuildContext context) => ColoredBox(
        key: const Key('no-video'),
        color: scene.ink,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(tr('Сатушы әлі видео қоспаған'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: scene.fg.withValues(alpha: 0.7))),
          ),
        ),
      );
}

/// The bar's canvas once the page has moved under it: the page's own, laid out at the screen's size and cut to the
/// bar, so the night gradient and the paper grain run on from the page under it.
class _BarCanvas extends StatelessWidget {
  const _BarCanvas({required this.solid});
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context).height;
    return AnimatedOpacity(
      key: const Key('listing-bar'),
      opacity: solid ? 1 : 0,
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant))),
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: screen,
            maxHeight: screen,
            child: DecoratedBox(
              key: const Key('listing-bar-canvas'),
              decoration: theme.extension<AppCanvas>()?.decoration ?? BoxDecoration(color: theme.colorScheme.surface),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
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

/// What buyers said about the size, with a three-part bar so the split is visible at a glance.
class SizeFitNote extends StatelessWidget {
  const SizeFitNote({super.key, required this.fit});
  final SizeFit fit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final advice = switch (fit.verdict) {
      'small' => '${tr('Жарты өлшем үлкенін алыңыз')}.',
      'large' => '${tr('Жарты өлшем кішісін алыңыз')}.',
      _ => '${tr('Әдеттегі өлшеміңізді алыңыз')}.',
    };
    final parts = [
      (fit.small, const Color(0xFFE0A54A)),
      (fit.trueToSize, const Color(0xFF3E9B6A)),
      (fit.large, const Color(0xFF5B7FD6)),
    ].where((p) => p.$1 > 0);
    return Column(key: const Key('size-fit'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(advice, style: theme.textTheme.bodyLarge),
      const SizedBox(height: 14),
      // As on the approved demo: one 8 px bar, each answer's share in its colour, 3 px apart.
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 8,
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, (n, color)) in parts.indexed) ...[
              if (i > 0) const SizedBox(width: 3),
              Expanded(flex: n, child: ColoredBox(color: color)),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 16, runSpacing: 4, children: [
        Text('${tr('Кіші')}: ${fit.small}', style: muted),
        Text('${tr('Сай')}: ${fit.trueToSize}', style: muted),
        Text('${tr('Үлкен')}: ${fit.large}', style: muted),
      ]),
      const SizedBox(height: 12),
      Text(trf('{0} сатып алушының пікірі бойынша.', [fit.answers]), style: muted),
    ]);
  }
}

/// Keeps [child] alive in a list while it is scrolled out of view.
class _KeptAlive extends StatefulWidget {
  const _KeptAlive({required this.child});
  final Widget child;

  @override
  State<_KeptAlive> createState() => _KeptAliveState();
}

class _KeptAliveState extends State<_KeptAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// A small text button on the page: 15 px, at least 48 high to tap.
class _SmallLink extends StatelessWidget {
  const _SmallLink({super.key, required this.text, required this.onTap, this.color, this.underline = false});
  final String text;
  final VoidCallback onTap;
  final Color? color;
  final bool underline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = color ?? theme.colorScheme.onSurface;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: Text(text,
                style: weight(theme.textTheme.bodyMedium!, 600).copyWith(
                    fontSize: 15,
                    color: ink,
                    decoration: underline ? TextDecoration.underline : null,
                    decorationColor: ink)),
          ),
        ),
      ),
    );
  }
}

/// The seller in one row: who they are (tap for the shop) and a round button to write to them.
class _SellerRow extends StatelessWidget {
  const _SellerRow({required this.listing, required this.own, required this.onMessage});
  final Listing listing;
  final bool own;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = listing;
    final name = l.shopName ?? tr('Сатушы');
    final muted = theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    return Container(
      key: const Key('seller-row'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant))),
      child: Row(children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShopScreen(sellerId: l.sellerId))),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: scheme.onSurface,
                  foregroundColor: scheme.surface,
                  child: Text(name.characters.first.toUpperCase(),
                      style: weight(theme.textTheme.titleMedium!, 800).copyWith(color: scheme.surface)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: weight(theme.textTheme.bodyLarge!, 650)),
                    Text.rich(
                      TextSpan(children: [
                        if (l.sellerRating != null) ...[
                          // The star only marks the number, which says the rating: drawn, not read as a letter.
                          const WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: ExcludeSemantics(
                                  child: Icon(Icons.star_rounded, size: 16, color: Color(0xFFE0A100)))),
                          TextSpan(text: ' ${ratingText(l.sellerRating!)} · '),
                        ],
                        TextSpan(
                            text: [
                          if (l.sellerCity != null) l.sellerCity!,
                          trf('{0} пікір', [l.sellerReviews])
                        ].join(' · ')),
                      ]),
                      style: muted,
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
        if (!own) ...[
          const SizedBox(width: 8),
          IconButton.outlined(
            key: const Key('seller-message'),
            tooltip: tr('Сатушыға жазу'),
            onPressed: onMessage,
            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 20),
          ),
        ],
      ]),
    );
  }
}

/// What the stage shows: the 3D turn, the photos or the seller's video.
enum _Pane { turn, photos, video }
