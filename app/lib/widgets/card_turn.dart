import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import 'scroll_showcase.dart' show ShowcasePlan, TurnMap;
import 'studio.dart';

/// A catalog card's shoe that turns under a sideways drag, through the same real 360° frames as the listing page.
/// When the finger lifts, the shoe turns back to where it started and the card shows its cover again, so the grid
/// always shows the photos the sellers chose and opening a listing flies from the cover as before. Vertical drags
/// still scroll the catalog.
class CardTurn extends StatefulWidget {
  const CardTurn({super.key, required this.listing, required this.cover, this.together});
  final Listing listing;
  final Widget cover;

  /// Shoes that turn as one: a drag on any of them turns them all to the same point of their turns.
  final TurnTogether? together;

  /// A card shows at most this many frames of the turn, evenly spread: 15° a step is smooth at card size, and a
  /// scan's hundred frames would cost a hundred decoded pictures per card.
  static const maxFrames = 24;

  /// The decoded width of a frame, the same small copy the listing page scrolls with, so the two share the cache.
  static const decodeWidth = 400;

  /// How many frames are fetched at once, nearest the shoe's angle first.
  static const fetchAtOnce = 4;

  /// The shortest drag, in logical pixels, that turns a shoe once round.
  static const minTurnDrag = 240.0;

  /// Where frames are fetched from; tests replace it.
  @visibleForTesting
  static ImageProvider Function(String url) network = NetworkImage.new;

  /// The frames a card turns through, starting at the one that matches the cover; none when the card
  /// cannot turn as the listing page does:
  /// - fewer than 8 frames in the turn (the server asks for 8);
  /// - a frame without its small copy, which would mean fetching full-size photos;
  /// - some frames cut out and others not: the listing page then shows the photos as taken, whose small copies
  ///   are not kept.
  static List<MediaItem> framesOf(Listing l) {
    final turn = _turnOf(l).turn;
    if (turn.length <= maxFrames) return turn;
    return [for (var i = 0; i < maxFrames; i++) turn[i * turn.length ~/ maxFrames]];
  }

  /// The whole turn the card shows, before it is thinned to [maxFrames], and whether it starts at the cover.
  static ({List<MediaItem> turn, bool atCover}) _turnOf(Listing l) {
    const none = (turn: <MediaItem>[], atCover: false);
    if (l.frames.isEmpty) return none;
    final plan = ShowcasePlan.of(l);
    final spin = plan.steps.first;
    final turn = spin.media.take(plan.turn).toList();
    if (turn.length < 8) return none;
    if (!spin.media.every((m) => m.thumbUrl != null && (spin.cut || m.processedUrl == null))) return none;
    // From the frame matching the cover: the one the seller or the server marked, else the cover itself. A scan,
    // like its listing page, keeps to where the camera started unless its cover is one of its frames.
    var start = plan.scan ? -1 : turn.indexWhere((m) => m.originalUrl == l.coverFrame);
    if (start < 0) start = turn.indexWhere((m) => m.url == l.coverUrl);
    return (turn: [...turn.skip(math.max(0, start)), ...turn.take(math.max(0, start))], atCover: start >= 0);
  }

  /// How the shared angle of shoes turning together falls on this card's turn.
  static TurnMap mapOf(Listing l) {
    final (:turn, :atCover) = _turnOf(l);
    return TurnMap.over(l, turn, atCover: atCover);
  }

  @override
  State<CardTurn> createState() => _CardTurnState();
}

/// Where shoes compared side by side are in their turns, as a shared angle (see [TurnMap]), so they show the
/// same side at once; null shows their covers.
class TurnTogether extends ChangeNotifier {
  double? _at;
  double? get at => _at;

  /// The side last picked by name (a key of [TurnMap.sides]), [cover], or null once a drag has turned the shoes
  /// somewhere between.
  final picked = ValueNotifier<String?>(cover);
  static const cover = 'cover';

  /// Whether the shoes are on a side picked by name, which only a turn with known sides can show for sure.
  bool get named => picked.value != null && picked.value != cover;

  /// Turns every shoe to show [side] (a key of [TurnMap.sides]), or their covers when null.
  void showSide(String? side) {
    assert(side == null || TurnMap.sides.containsKey(side), side);
    picked.value = side ?? cover;
    _at = side == null ? null : TurnMap.sides[side];
    notifyListeners(); // even at the same angle: shoes with unknown sides go back to their covers
  }

  void _drag(double? at) {
    picked.value = at == null ? cover : null;
    _set(at);
  }

  void _set(double? at) {
    if (_at == at) return;
    _at = at;
    notifyListeners();
  }

  @override
  void dispose() {
    picked.dispose();
    super.dispose();
  }
}

class _CardTurnState extends State<CardTurn> with SingleTickerProviderStateMixin {
  late List<MediaItem> _frames;
  late TurnMap _map;
  late bool _shadow;
  late String _signature;

  /// Where the turn is, in frames, while the finger is on the card or the shoe turns back; null shows the cover.
  double? _at;

  /// The frame last decoded: it stays while the next one decodes or if the next one fails to load.
  ImageProvider? _lastGood;

  int _fetched = 0;
  int _fetching = 0;
  late final AnimationController _back = AnimationController(vsync: this)..addListener(_followBack);
  Animation<double>? _backPath;

  @override
  void initState() {
    super.initState();
    _plan();
    widget.together?.addListener(_follow);
    _joinTogether();
  }

  /// Side by side, the frames are fetched at once so the shoes follow from the first drag, and a shoe added while
  /// the others are turned takes their angle.
  void _joinTogether() {
    if (widget.together == null || _frames.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fetchMore();
      if (widget.together?.at != null) _follow();
    });
  }

  static String _signatureOf(Listing l) => [
        l.id,
        l.coverUrl,
        l.coverFrame,
        for (final MapEntry(:key, :value) in l.angleFrames.entries) '$key=$value',
        for (final m in l.frames) '${m.originalUrl}|${m.processedUrl}|${m.thumbUrl}'
      ].join(',');

  @override
  void didUpdateWidget(CardTurn old) {
    super.didUpdateWidget(old);
    if (old.together != widget.together) {
      old.together?.removeListener(_follow);
      widget.together?.addListener(_follow);
    }
    // A reused card can be another shoe, or this shoe with new photos (a reshoot, a cut-out finished): start again
    // from its cover.
    if (_signatureOf(widget.listing) != _signature) {
      _back.stop();
      _at = null;
      _lastGood = null;
      _fetched = 0;
      _plan();
      _joinTogether();
    }
  }

  void _plan() {
    _signature = _signatureOf(widget.listing);
    _frames = CardTurn.framesOf(widget.listing);
    _map = CardTurn.mapOf(widget.listing);
    final plan = ShowcasePlan.of(widget.listing);
    // As on the listing page: a shadow under cut-outs, except a scan's, which carry their own.
    _shadow = _frames.isNotEmpty && plan.steps.first.cut && !plan.scan;
  }

  @override
  void dispose() {
    widget.together?.removeListener(_follow);
    _back.dispose();
    super.dispose();
  }

  ImageProvider _image(MediaItem m) =>
      ResizeImage.resizeIfNeeded(CardTurn.decodeWidth, null, CardTurn.network(m.thumbUrl!));

  /// Fetches the frames nearest the start first, a few at a time, so the frames under the finger come first.
  void _fetchMore() {
    final n = _frames.length;
    while (mounted && _fetching < CardTurn.fetchAtOnce && _fetched < n) {
      // 0, 1, n-1, 2, n-2, ...: outward from the start in both directions.
      final k = _fetched++;
      final i = k.isOdd ? (k + 1) ~/ 2 : (n - k ~/ 2) % n;
      final image = _image(_frames[i]);
      _fetching++;
      precacheImage(image, context, onError: (_, __) {}).whenComplete(() {
        _fetching--;
        if (mounted) _fetchMore();
      });
      if (_shadow) ContactShadow.prepare(image, createLocalImageConfiguration(context));
    }
  }

  void _start(DragStartDetails _) {
    _back.stop();
    _put(_at ?? 0);
    _fetchMore();
  }

  /// Moves this shoe, and with it every shoe turning together.
  void _put(double? at) {
    final together = widget.together;
    if (together != null && _frames.isNotEmpty) {
      together._drag(at == null ? null : _map.angle(at / _frames.length));
    } else {
      _show(at);
    }
  }

  /// The frame to show at [at]: the one the finger has reached, as on the listing page; side by side the
  /// nearest, so shoes turned either way keep step.
  int _nearest(double at) => (widget.together == null ? at.floor() : at.round()) % _frames.length;

  /// Shows [at], redrawing only when that is another frame or the cover.
  void _show(double? at) {
    final was = _at;
    if (at != null && was != null && _nearest(at) == _nearest(was)) {
      _at = at; // the same frame: nothing to redraw
    } else {
      setState(() => _at = at);
    }
  }

  /// Another shoe turned: this one goes to the same point of its own turn.
  void _follow() {
    final together = widget.together!;
    if (!mounted || _frames.isEmpty) return;
    // A side picked by name is only shown where the sides are known; a guess could put the heel under "front".
    final at = together.named && !_map.sided ? null : together.at;
    if (at != null && _at == null) _fetchMore();
    final place = at == null ? null : (_map.place(at) * _frames.length) % _frames.length;
    // A tapped side can be the far side of the turn, which the fetching outward from the start reaches last.
    if (place != null && together.named) precacheImage(_image(_frames[_nearest(place)]), context, onError: (_, __) {});
    _show(place);
  }

  /// The same feel as the listing page: one and a half card widths turn the shoe once round, but never less than
  /// [minTurnDrag], so three narrow shoes side by side on a small phone do not spin at a touch.
  double _framesPerPixel(double width) => _frames.length / math.max(width * 1.5, CardTurn.minTurnDrag);

  void _move(DragUpdateDetails d, double width) {
    final at = _at;
    if (at == null) return; // the card became another shoe under the finger
    _put((at - d.delta.dx * _framesPerPixel(width)) % _frames.length);
  }

  /// Turns back the short way round to the start, then shows the cover. Side by side the shoes stay where the
  /// finger left them, to be looked at together.
  void _end([DragEndDetails? _]) {
    final at = _at;
    if (at == null || widget.together != null) return;
    final n = _frames.length;
    final target = at > n / 2 ? n.toDouble() : 0.0;
    final distance = (target - at).abs();
    if (MediaQuery.disableAnimationsOf(context) || distance < 0.5) {
      _put(null);
      return;
    }
    _backPath = Tween(begin: at, end: target).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_back);
    _back.duration = Duration(milliseconds: (120 + 600 * distance / n).round());
    _back.forward(from: 0).whenCompleteOrCancel(() {
      if (mounted && !_back.isAnimating && _at != null && _back.value == 1) _put(null);
    });
  }

  void _followBack() => _put(_backPath!.value % _frames.length);

  @override
  Widget build(BuildContext context) {
    if (_frames.isEmpty) return widget.cover;
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth;
      final at = _at;
      return Listener(
        // A tap while the shoe turns back lands on the cover, so the listing opens from the photo it flies from.
        onPointerDown: (_) {
          if (_back.isAnimating) {
            _back.stop();
            _put(null);
          }
        },
        child: GestureDetector(
          key: const Key('card-turn'),
          behavior: HitTestBehavior.opaque,
          // The card is a plain button to screen readers; the turn they can use is on the listing page.
          excludeFromSemantics: true,
          dragStartBehavior: DragStartBehavior.down, // the shoe follows the whole move of the finger
          onHorizontalDragStart: _start,
          onHorizontalDragUpdate: (d) => _move(d, width),
          onHorizontalDragEnd: _end,
          onHorizontalDragCancel: _end,
          child: at == null ? widget.cover : _frame(_frames[_nearest(at)]),
        ),
      );
    });
  }

  Widget _frame(MediaItem m) {
    final image = _image(m);
    final lastGood = _lastGood;
    // Until a frame is decoded the cover stays, and a frame that fails keeps the last good one: never an empty
    // card, and never two shoes at once.
    Widget fallback() => lastGood == null ? widget.cover : _picture(lastGood, null);
    return _picture(image, fallback);
  }

  Widget _picture(ImageProvider image, Widget Function()? fallback) => Stack(fit: StackFit.expand, children: [
        if (_shadow && _lastGood != null) ContactShadow(image: image, fit: BoxFit.cover, gapless: true),
        Image(
          key: fallback == null ? null : const Key('card-turn-frame'),
          image: image,
          fit: BoxFit.cover,
          gaplessPlayback: true, // the previous frame stays until this one is decoded
          frameBuilder: fallback == null
              ? null
              : (_, child, frame, sync) {
                  if (frame != null || sync) {
                    _lastGood = image;
                    return child;
                  }
                  return _lastGood == null ? widget.cover : child;
                },
          errorBuilder: fallback == null ? null : (_, __, ___) => fallback(),
        ),
      ]);
}
