import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../i18n.dart';
import '../theme.dart';
import 'spin_viewer.dart' show showcaseBackground;

/// One stop of the showcase: the turn made of 360° frames, then the top, the sole and a close-up.
class ShowcaseStep {
  ShowcaseStep(this.kind, this.media, this.weight) : cut = media.every((m) => m.processedUrl != null);
  final String kind; // spin | top | sole | close
  final List<MediaItem> media;

  /// Share of the scroll this step takes, in frame units.
  final double weight;

  /// Cut-outs are shown only when every photo of the step has one, so the shoe never jumps between a cut-out on
  /// the backdrop and a photo with its own background in the middle of a turn.
  final bool cut;

  String get label => switch (kind) {
        'spin' => '360°',
        'top' => tr('Үстінен'),
        'sole' => tr('Табаны'),
        _ => tr('Жақыннан'),
      };
}

/// Which photo shows at a given scroll position. Only real photos are shown: nothing is generated or blended.
class ShowcasePlan {
  ShowcasePlan(this.steps) : total = steps.fold(0.0, (sum, s) => sum + s.weight);

  /// The frames in order, then the top and sole photos and the close-up (stitching, logo), each only when the
  /// seller took it.
  factory ShowcasePlan.of(Listing l) {
    final frames = l.frames;
    MediaItem? first(String angle) => l.media.where((m) => m.angle == angle).firstOrNull;
    final detail = math.max(6.0, frames.length / 6);
    return ShowcasePlan([
      ShowcaseStep('spin', frames, frames.length.toDouble()),
      if (first('top') case final m?) ShowcaseStep('top', [m], detail),
      if (first('sole') case final m?) ShowcaseStep('sole', [m], detail),
      if (first('detail') case final m?) ShowcaseStep('close', [m], detail),
    ]);
  }

  final List<ShowcaseStep> steps;
  final double total;

  /// Step and photo index for scroll progress 0..1.
  ({int step, int frame}) at(double progress) {
    var t = progress.clamp(0.0, 1.0) * total;
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (t < s.weight || i == steps.length - 1) {
        final n = s.media.length;
        return (step: i, frame: math.min(n - 1, (t / s.weight * n).floor()).clamp(0, n - 1));
      }
      t -= s.weight;
    }
    return (step: 0, frame: 0);
  }

  /// Scroll progress at which [step] begins.
  double startOf(int step) => steps.take(step).fold(0.0, (sum, s) => sum + s.weight) / total;

  /// Scroll progress in the middle of one photo, so moving there shows exactly that photo.
  double centreOf(int step, int frame) =>
      startOf(step) + steps[step].weight * (frame + 0.5) / steps[step].media.length / total;

  /// Every photo in showing order.
  late final List<({int step, int frame})> photos = [
    for (var i = 0; i < steps.length; i++)
      for (var f = 0; f < steps[i].media.length; f++) (step: i, frame: f)
  ];
}

/// The 360° showcase as a stretch of the page: while it scrolls past, the stage fills the screen and stays in
/// place, and the shoe turns frame by frame, then shows its top, sole and a close-up. Scrolling back turns it back.
/// Two fingers zoom the shoe up to 3× (the page stays put while zoomed, one finger then moves the picture), a
/// double tap zooms in or out, and 1× resets.
///
/// It must be the first thing in the list that [scroll] drives, so its top is at scroll offset 0. Touches reach it
/// through [ScrollShowcaseState.handlePointer] from a Listener around the list: a list that is scrolling ignores
/// the touches of its children, and a pinch usually starts while the first finger is still scrolling.
class ScrollShowcase extends StatefulWidget {
  const ScrollShowcase({
    super.key,
    required this.listing,
    required this.scroll,
    required this.stageHeight,
    this.onPhotos,
    this.onDetails,
    this.onLock,
  });

  final Listing listing;
  final ScrollController scroll;

  /// The visible height of the list: the stage fills it while the shoe turns.
  final double stageHeight;

  /// Switches the page to the photos as taken; the stops row offers it so it is never a long scroll away.
  final VoidCallback? onPhotos;

  /// Skips the rest of the turn to the title, sizes and details below.
  final VoidCallback? onDetails;

  /// True while the page must not scroll: during a pinch and while zoomed in.
  final ValueChanged<bool>? onLock;

  /// How far the page scrolls while the stage stays in place: one screen for the turn, a little more per stop.
  static double travelFor(double stageHeight, int steps) => stageHeight * (1.0 + 0.3 * (steps - 1));

  @override
  State<ScrollShowcase> createState() => ScrollShowcaseState();
}

class ScrollShowcaseState extends State<ScrollShowcase> {
  late ShowcasePlan _plan;
  late bool _light;
  bool _settled = true;
  Timer? _settle;
  ({int step, int frame}) _shown = (step: 0, frame: 0);
  bool _precached = false;
  int? _jumpingTo; // a stop button was tapped: tick once on arrival, not for every stop passed
  /// How often the stage was built; tests check that scrolling within one frame does not rebuild it.
  @visibleForTesting
  int builds = 0;
  static bool _hinted = false; // the short turn that shows scrolling turns the shoe, once per app run

  final _viewer = GlobalKey();
  final _pin = GlobalKey();

  // Zoom and pan. The page is held still while two fingers are down or the picture is zoomed in.
  final _pointers = <int, Offset>{};
  double _scale = 1, _pinchStartScale = 1, _pinchStartDistance = 0;
  Offset _pan = Offset.zero, _pinchStartPan = Offset.zero, _pinchStartMid = Offset.zero;
  double? _lockedOffset;
  Offset? _tapAt;

  double get _travel => ScrollShowcase.travelFor(widget.stageHeight, _plan.steps.length);

  double get _progress {
    final s = widget.scroll;
    return s.hasClients ? (s.offset / _travel).clamp(0.0, 1.0) : 0;
  }

  bool get _zoomed => _scale > 1.05;

  @override
  void initState() {
    super.initState();
    _setUp();
    widget.scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _hint());
  }

  void _setUp() {
    _plan = ShowcasePlan.of(widget.listing);
    _light = widget.listing.backdrop != 'dark';
    _shown = (step: 0, frame: 0);
    _scale = 1;
    _pan = Offset.zero;
  }

  static String _signature(Listing l) => [l.backdrop, for (final m in l.media) '${m.url}|${m.thumbUrl}'].join(',');

  @override
  void didUpdateWidget(ScrollShowcase oldWidget) {
    final old = oldWidget;
    super.didUpdateWidget(oldWidget);
    if (old.scroll != widget.scroll) {
      old.scroll.removeListener(_onScroll);
      widget.scroll.addListener(_onScroll);
    }
    // The listing was reloaded with other photos (the seller replaced them): show the new ones, not the old plan.
    if (_signature(old.listing) != _signature(widget.listing)) {
      _setUp();
      _precached = false;
      _precache();
      _setLock();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precache();
  }

  /// What the stage draws first for a photo: the small copy, or the photo decoded at screen size if there is none.
  /// Precaching asks for exactly this provider, so the cache is hit.
  ImageProvider _base(MediaItem m, ShowcaseStep step) {
    final thumbFits = m.thumbUrl != null && (step.cut || m.processedUrl == null);
    if (thumbFits) return NetworkImage(m.thumbUrl!);
    final width = (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round();
    return ResizeImage.resizeIfNeeded(math.min(2000, width), null, NetworkImage(step.cut ? m.url : m.originalUrl));
  }

  void _precache() {
    if (_precached) return;
    _precached = true;
    // The copies scrolling shows are fetched first, in showing order.
    for (final s in _plan.steps) {
      for (final m in s.media) {
        precacheImage(_base(m, s), context, onError: (_, __) {});
      }
    }
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_onScroll);
    _settle?.cancel();
    if (_lockedOffset != null || _zoomed) widget.onLock?.call(false);
    super.dispose();
  }

  bool get _reduceMotion => MediaQuery.of(context).disableAnimations;

  /// Turns the shoe a few frames and back on first show, so people see that scrolling turns it.
  Future<void> _hint() async {
    if (_hinted || !mounted || _reduceMotion || !widget.scroll.hasClients || widget.scroll.offset > 0) return;
    _hinted = true;
    final spin = _plan.steps.length > 1 ? _plan.startOf(1) * _travel : _travel;
    await widget.scroll.animateTo(spin * 0.12, duration: const Duration(milliseconds: 700), curve: Curves.easeInOut);
    if (!mounted || !widget.scroll.hasClients) return;
    await widget.scroll.animateTo(0, duration: const Duration(milliseconds: 700), curve: Curves.easeInOut);
  }

  void _onScroll() {
    if (_lockedOffset != null) {
      if (widget.scroll.offset != _lockedOffset) widget.scroll.jumpTo(_lockedOffset!); // zooming: page stays
      return;
    }
    final now = _plan.at(_progress);
    if (now != _shown) {
      if (now.step != _shown.step) {
        if (_jumpingTo == null || _jumpingTo == now.step) {
          HapticFeedback.selectionClick();
          _jumpingTo = null;
        }
      }
      _shown = now;
      // Small copies while turning; the full photo once the shoe has stopped on one frame for a moment.
      _settled = false;
      _settle?.cancel();
      _settle = Timer(const Duration(milliseconds: 140), () {
        if (mounted) setState(() => _settled = true);
      });
      setState(() {});
    }
    // Otherwise only the stage's position changes, which _PinStage repaints without rebuilding anything. A screen
    // reader still needs the moved boxes, or its focus frames stay where the stage was.
    if (SemanticsBinding.instance.semanticsEnabled) _pin.currentContext?.findRenderObject()?.markNeedsSemanticsUpdate();
  }

  void _goTo(int step) {
    _resetZoom();
    final target = _plan.startOf(step) * _travel + (step == 0 ? 0 : 1);
    _jumpingTo = step;
    if (_reduceMotion) {
      widget.scroll.jumpTo(target);
    } else {
      widget.scroll.animateTo(target, duration: const Duration(milliseconds: 450), curve: Curves.easeInOut);
    }
  }

  int get _photoIndex => _plan.photos.indexOf(_plan.at(_progress));

  /// A screen reader's swipe moves exactly one photo on or back.
  void _nudge(int delta) {
    final i = (_photoIndex + delta).clamp(0, _plan.photos.length - 1);
    final p = _plan.photos[i];
    widget.scroll.jumpTo(_plan.centreOf(p.step, p.frame) * _travel);
  }

  String _describe(int index) {
    final p = _plan.photos[index.clamp(0, _plan.photos.length - 1)];
    final s = _plan.steps[p.step];
    return s.kind == 'spin' ? trf('кадр {0} / {1}', [p.frame + 1, s.media.length]) : s.label;
  }

  // Touches, relayed from above the list.

  /// Takes a pointer event from the Listener around the page's list; events outside the stage are ignored.
  void handlePointer(PointerEvent e) {
    final box = _viewer.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final local = box.globalToLocal(e.position);
    if (e is PointerDownEvent) {
      if (!(Offset.zero & box.size).contains(local)) return;
      _pointers[e.pointer] = local;
      if (_pointers.length == 2) _startPinch();
    } else if (e is PointerMoveEvent) {
      final was = _pointers[e.pointer];
      if (was == null) return;
      _pointers[e.pointer] = local;
      if (_pointers.length == 2 && _pinchStartDistance >= 1) {
        final p = _pointers.values.toList();
        setState(() {
          _scale = (_pinchStartScale * (p[0] - p[1]).distance / _pinchStartDistance).clamp(1.0, 3.0);
          _pan = _clampPan(_pinchStartPan + ((p[0] + p[1]) / 2 - _pinchStartMid), box.size);
        });
      } else if (_pointers.length == 1 && _zoomed) {
        setState(() => _pan = _clampPan(_pan + (local - was), box.size)); // one finger moves the zoomed shoe
      }
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      if (_pointers.remove(e.pointer) == null) return;
      if (_pointers.length < 2) _pinchStartDistance = 0;
      if (_pointers.isEmpty && !_zoomed) _setLock();
    }
  }

  void _startPinch() {
    final p = _pointers.values.toList();
    _pinchStartDistance = (p[0] - p[1]).distance;
    _pinchStartScale = _scale;
    _pinchStartPan = _pan;
    _pinchStartMid = (p[0] + p[1]) / 2;
    if (widget.scroll.hasClients) widget.scroll.jumpTo(widget.scroll.offset); // stop a scroll still coasting
    _setLock(force: true);
  }

  /// Holds the page still while zoomed or pinching, and lets it go otherwise.
  void _setLock({bool force = false}) {
    final lock = force || _zoomed;
    if (lock == (_lockedOffset != null)) return;
    _lockedOffset = lock && widget.scroll.hasClients ? widget.scroll.offset : null;
    widget.onLock?.call(_lockedOffset != null);
  }

  Offset _clampPan(Offset pan, Size size) {
    final mx = (_scale - 1) * size.width / 2, my = (_scale - 1) * size.height / 2;
    return Offset(pan.dx.clamp(-mx, mx), pan.dy.clamp(-my, my));
  }

  void _resetZoom() {
    if (!_zoomed && _pan == Offset.zero) return;
    setState(() {
      _scale = 1;
      _pan = Offset.zero;
    });
    _lockedOffset = null;
    widget.onLock?.call(false);
  }

  void _doubleTap(Size size) {
    if (_zoomed) return _resetZoom();
    setState(() {
      _scale = 2.5;
      final at = _tapAt ?? size.center(Offset.zero);
      _pan = _clampPan((size.center(Offset.zero) - at) * (_scale - 1), size); // zoom in where tapped
    });
    _setLock();
  }

  /// A sideways drag also turns the shoe, as the old 360° viewer did.
  void _drag(DragUpdateDetails d, double width) {
    if (_zoomed || _shown.step != 0 || !widget.scroll.hasClients) return;
    final spin = _plan.steps.length > 1 ? _plan.startOf(1) * _travel : _travel;
    widget.scroll.jumpTo((widget.scroll.offset - d.delta.dx / (width * 1.5) * spin).clamp(0.0, spin - 1));
  }

  Widget _photo(MediaItem m, ShowcaseStep step, double width) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final base = Image(
      key: const ValueKey('showcase-base'),
      image: _base(m, step),
      fit: BoxFit.contain,
      gaplessPlayback: true, // the last frame stays until the next is decoded: the shoe never blinks out
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined, size: 48)),
    );
    // At rest: the full photo over the small copy, faded in once decoded, at the pixels the zoom needs.
    final bucket = _scale <= 1.05 ? 1 : (_scale <= 2 ? 2 : 3);
    final full = Image.network(
      step.cut ? m.url : m.originalUrl,
      key: ValueKey('showcase-full-${m.url}-$bucket'),
      fit: BoxFit.contain,
      cacheWidth: math.min(6000, (width * dpr * bucket).round()),
      filterQuality: FilterQuality.high,
      frameBuilder: (_, child, frame, sync) =>
          sync || frame != null ? child : const SizedBox.shrink(), // until then the small copy shows through
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    final img = Stack(fit: StackFit.expand, children: [base, if (_settled || _zoomed) full]);
    return step.cut ? Padding(padding: const EdgeInsets.all(20), child: img) : img;
  }

  BoxDecoration get _backdrop {
    if (widget.listing.backdrop == null) return showcaseBackground(widget.listing.showcaseStyle);
    return _light
        ? const BoxDecoration(color: Brand.studio)
        : const BoxDecoration(gradient: RadialGradient(colors: [Color(0xFF3A3A40), Color(0xFF111114)], radius: 0.9));
  }

  Widget _chip({required Key key, required VoidCallback? onTap, required Widget child, Color? fill, Color? border}) =>
      // 36 dp to look at, 48 dp to touch; the Material carries the fill so the press ripple shows on it.
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        child: Center(
          widthFactor: 1,
          child: Material(
            color: fill ?? Colors.transparent,
            shape: StadiumBorder(side: border == null ? BorderSide.none : BorderSide(color: border)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: key,
              onTap: onTap,
              child: Container(
                constraints: const BoxConstraints(minHeight: 36, minWidth: 44),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: child,
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    builds++;
    final travel = _travel;
    final h = widget.stageHeight;
    final now = _plan.at(_progress);
    final step = _plan.steps[now.step];
    final media = step.media[now.frame];
    final ownBackdrop = widget.listing.backdrop != null && step.cut;
    final onDark = ownBackdrop ? !_light : widget.listing.showcaseStyle == 'premium';
    final chipText = onDark ? Colors.white : Brand.ink;
    final index = _photoIndex;
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight; // the shoe stays clear of the app bar
    return SizedBox(
      height: h + travel,
      child: Flow(key: _pin, delegate: _PinStage(widget.scroll, h, travel), children: [
        RepaintBoundary(
          child: DecoratedBox(
            key: const Key('showcase'),
            decoration: ownBackdrop ? _backdrop : showcaseBackground(widget.listing.showcaseStyle),
            child: Column(children: [
              SizedBox(height: top),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Semantics(
                      container: true,
                      slider: true,
                      label: trf('360° көрініс: {0}. Бұру үшін бетті жоғары-төмен жылжытыңыз.', [step.label]),
                      value: _describe(index),
                      increasedValue: index < _plan.photos.length - 1 ? _describe(index + 1) : null,
                      decreasedValue: index > 0 ? _describe(index - 1) : null,
                      onIncrease: index < _plan.photos.length - 1 ? () => _nudge(1) : null,
                      onDecrease: index > 0 ? () => _nudge(-1) : null,
                      child: LayoutBuilder(
                        builder: (context, box) => GestureDetector(
                          key: _viewer,
                          behavior: HitTestBehavior.opaque,
                          onDoubleTapDown: (d) => _tapAt = d.localPosition,
                          onDoubleTap: () => _doubleTap(box.biggest),
                          onHorizontalDragUpdate: (d) => _drag(d, box.maxWidth),
                          child: ClipRect(
                            child: Transform(
                              key: const Key('showcase-zoom'),
                              alignment: Alignment.center,
                              transform: Matrix4.identity()
                                ..translateByDouble(_pan.dx, _pan.dy, 0, 1)
                                ..scaleByDouble(_scale, _scale, 1, 1),
                              filterQuality: _zoomed ? FilterQuality.high : null,
                              // The catalog card's photo flies into place here, as it does on the Photo tab. Not
                              // while zoomed (it would fly from the magnified photo) or with reduced motion.
                              child: HeroMode(
                                enabled: !_zoomed && !_reduceMotion,
                                child: Hero(
                                  tag: 'listing-${widget.listing.id}',
                                  // Going back, the shoe as it is turned now shrinks into the card.
                                  flightShuttleBuilder: (_, __, direction, from, to) =>
                                      (direction == HeroFlightDirection.pop ? from : to).widget,
                                  child: Material(
                                    type: MaterialType.transparency,
                                    child: SizedBox.expand(child: _photo(media, step, box.maxWidth)),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Zoom reset and backdrop switch, on the right above the stops.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (_zoomed)
                    _RoundChip(
                      key: const Key('showcase-reset-zoom'),
                      tooltip: tr('Бастапқы өлшем'),
                      onTap: _resetZoom,
                      child: const Text('1×', style: TextStyle(fontWeight: FontWeight.w700, color: Brand.ink)),
                    ),
                  if (ownBackdrop)
                    _RoundChip(
                      key: const Key('showcase-backdrop'),
                      tooltip: _light ? tr('Қараңғы фон') : tr('Ашық фон'),
                      toggled: !_light,
                      onTap: () => setState(() => _light = !_light),
                      child: const Icon(Icons.contrast, size: 20, color: Brand.ink),
                    ),
                ]),
              ),
              // The stops as dots (Aza's choice: nothing written beside the shoe). Each is a 48 dp button that jumps
              // straight to its view; its name is read out and shown on long press.
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Row(children: [
                  Expanded(
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      for (var i = 0; i < _plan.steps.length; i++)
                        Semantics(
                          button: true,
                          selected: i == now.step,
                          label: _plan.steps[i].label,
                          child: Tooltip(
                            message: _plan.steps[i].label,
                            excludeFromSemantics: true,
                            child: InkWell(
                              key: Key('showcase-step-${_plan.steps[i].kind}'),
                              customBorder: const CircleBorder(),
                              onTap: () => _goTo(i),
                              child: SizedBox(
                                width: 40,
                                height: 48,
                                child: Center(
                                  child: AnimatedContainer(
                                    duration: _reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
                                    width: i == now.step ? 22 : 9,
                                    height: 9,
                                    decoration: BoxDecoration(
                                      color: i == now.step
                                          ? (onDark ? Colors.white : Brand.ink)
                                          : (onDark ? Colors.white38 : Brand.ink.withValues(alpha: 0.25)),
                                      borderRadius: BorderRadius.circular(99),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ]),
                  ),
                  if (widget.onPhotos != null)
                    Semantics(
                      button: true,
                      label: tr('Фото'),
                      child: Tooltip(
                        message: tr('Фото'),
                        excludeFromSemantics: true,
                        child: _chip(
                          key: const Key('showcase-photos'),
                          onTap: () {
                            _resetZoom();
                            widget.onPhotos!();
                          },
                          border: onDark ? Colors.white54 : Colors.black26,
                          child: Icon(Icons.photo_library_outlined, size: 18, color: chipText),
                        ),
                      ),
                    ),
                  if (widget.onDetails != null)
                    Semantics(
                      button: true,
                      label: tr('Толығырақ'),
                      child: Tooltip(
                        message: tr('Толығырақ'),
                        excludeFromSemantics: true,
                        child: _chip(
                          key: const Key('showcase-details'),
                          onTap: () {
                            _resetZoom();
                            widget.onDetails!();
                          },
                          border: onDark ? Colors.white54 : Colors.black26,
                          child: Icon(Icons.keyboard_double_arrow_down_rounded, size: 20, color: chipText),
                        ),
                      ),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Keeps the stage in view while its stretch of the page scrolls past. It moves the painted stage only: nothing is
/// rebuilt or laid out again for each scroll pixel, and touches follow the stage because Flow hit-tests through
/// the same transform.
class _PinStage extends FlowDelegate {
  _PinStage(this.scroll, this.height, this.travel) : super(repaint: scroll);
  final ScrollController scroll;
  final double height, travel;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints.tightFor(width: constraints.maxWidth, height: height);

  @override
  void paintChildren(FlowPaintingContext context) {
    final offset = scroll.hasClients ? scroll.offset.clamp(0.0, travel) : 0.0;
    context.paintChild(0, transform: Matrix4.translationValues(0, offset, 0));
  }

  @override
  bool shouldRepaint(_PinStage old) => old.scroll != scroll || old.height != height || old.travel != travel;

  @override
  bool shouldRelayout(_PinStage old) => old.height != height;
}

class _RoundChip extends StatelessWidget {
  const _RoundChip({super.key, required this.child, required this.onTap, required this.tooltip, this.toggled});
  final Widget child;
  final VoidCallback onTap;
  final String tooltip;
  final bool? toggled;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Semantics(
          button: true,
          toggled: toggled,
          child: Tooltip(
            message: tooltip,
            child: Material(
              color: Colors.white.withValues(alpha: 0.92),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: SizedBox(width: 48, height: 48, child: Center(child: child)),
              ),
            ),
          ),
        ),
      );
}
