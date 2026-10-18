import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../i18n.dart';
import 'spin_viewer.dart' show showcaseBackground;

/// The colours of the stage, taken from the approved Scroll 3D demo page: a light studio for dark shoes and a dark
/// one for light shoes. [ink] is the backdrop, [halo] the soft light behind the shoe, the rest are for the controls.
class ShowcaseScene {
  const ShowcaseScene._(this.ink, this.panel, this.line, this.fg, this.muted, this.glow, this.halo);
  final Color ink, panel, line, fg, muted, glow, halo;

  static const light = ShowcaseScene._(Color(0xFFE8E6EE), Color(0xFFF7F6FA), Color(0xFFD3D0DE), Color(0xFF17161D),
      Color(0xFF66637A), Color(0xFF6D5BD0), Color(0xF2FFFFFF));
  static const dark = ShowcaseScene._(Color(0xFF0E0E14), Color(0xFF17161F), Color(0xFF2A2836), Color(0xFFECEBF3),
      Color(0xFF9A97AB), Color(0xFFB9A8FF), Color(0x4D9684E6));
}

/// A round light, fading out to nothing at its edge, filling the square the shoe is drawn in less 6% on each side.
class _Halo extends CustomPainter {
  _Halo(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide * 0.44;
    final c = size.center(Offset.zero);
    canvas.drawCircle(c, r, Paint()..shader = ui.Gradient.radial(c, r, [color, color.withValues(alpha: 0)]));
  }

  @override
  bool shouldRepaint(_Halo old) => old.color != color;
}

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
  ShowcasePlan(this.steps, {this.scan = false}) : total = steps.fold(0.0, (sum, s) => sum + s.weight);

  /// The frames in order, then the top and sole photos and the close-up (stitching, logo), each only when the
  /// seller took it.
  ///
  /// A scan is one continuous camera move: the turn, then on up over the top, under the sole and in close. Its stop
  /// photos are frames of that move, so each stop starts at its own frame and carries the frames that move on
  /// towards the next one, and every frame takes the same share of the scroll.
  factory ShowcasePlan.of(Listing l) {
    final frames = l.frames;
    MediaItem? first(String angle) => l.media.where((m) => m.angle == angle).firstOrNull;
    final stops = [
      for (final (kind, angle) in const [('top', 'top'), ('sole', 'sole'), ('close', 'detail')])
        if (first(angle) case final m?) (kind: kind, photo: m),
    ];
    final at = [for (final s in stops) frames.indexWhere((f) => f.url == s.photo.url)];
    var scan = stops.isNotEmpty && at.first > 0;
    for (var i = 1; i < at.length && scan; i++) {
      scan = at[i] > at[i - 1];
    }
    if (scan) {
      // The same total as photo stops (2 for the turn, 1 per stop), spread evenly over the frames.
      final perFrame = (2 + stops.length) / frames.length;
      ShowcaseStep part(String kind, int from, int to) =>
          ShowcaseStep(kind, frames.sublist(from, to), (to - from) * perFrame);
      return ShowcasePlan([
        part('spin', 0, at.first),
        for (var i = 0; i < stops.length; i++)
          part(stops[i].kind, at[i], i + 1 < at.length ? at[i + 1] : frames.length),
      ], scan: true);
    }
    // Twice as much scrolling for the whole turn as for each stop: see ScrollShowcase.travelFor.
    return ShowcasePlan([
      ShowcaseStep('spin', frames, 2),
      for (final s in stops) ShowcaseStep(s.kind, [s.photo], 1),
    ]);
  }

  /// Made from one continuous scan: its frames carry their own margin and floor shadow.
  final bool scan;

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
    this.onDarkTop,
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

  /// True while a dark stage is under the status bar.
  final ValueChanged<bool>? onDarkTop;

  /// How far the page scrolls while the stage stays in place: 0.6 of the stage for the whole turn, so one ordinary
  /// swipe turns the shoe once round (a full screen per turn felt slow and heavy under the finger), and 0.3 per stop.
  static double travelFor(double stageHeight, int steps) => stageHeight * (0.6 + 0.3 * (steps - 1));

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
  // The last few full photos shown, newest last. Older ones are dropped from memory so they cannot push the small
  // scrolling copies out of the image cache, but going back to a photo just seen, or zooming out, finds it ready.
  final _recentFull = <ImageProvider>[];
  static const _keepFull = 3;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hint();
      _reportTop();
    });
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
    for (final p in _recentFull) {
      p.evict();
    }
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
    _reportTop();
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
      _settleSoon();
      setState(() {});
    }
    // Otherwise only the stage's position changes, which _PinStage repaints without rebuilding anything. A screen
    // reader still needs the moved boxes, or its focus frames stay where the stage was.
    if (SemanticsBinding.instance.semanticsEnabled) _pin.currentContext?.findRenderObject()?.markNeedsSemanticsUpdate();
  }

  /// The full photo once the shoe has stopped on one photo for a moment: 140 ms after the finger is lifted, or
  /// 450 ms while it rests on the shoe. Decoding one at every short pause mid-drag made the turn stutter; a longer
  /// pause is someone looking closely, who should get the sharp photo.
  void _settleSoon() {
    _settle?.cancel();
    _settle = Timer(Duration(milliseconds: _pointers.isEmpty ? 140 : 450), () {
      if (mounted && !_settled) setState(() => _settled = true);
    });
  }

  void _remember(ImageProvider full) {
    if (_recentFull.isNotEmpty && _recentFull.last == full) return;
    _recentFull
      ..remove(full)
      ..add(full);
    while (_recentFull.length > _keepFull) {
      _recentFull.removeAt(0).evict();
    }
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
      if (_pointers.isEmpty && !_settled) _settleSoon(); // lifted: the sharp photo comes sooner
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
    final small = _base(m, step);
    final base = Image(
      key: const ValueKey('showcase-base'),
      image: small,
      fit: BoxFit.contain,
      gaplessPlayback: true, // the last frame stays until the next is decoded: the shoe never blinks out
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined, size: 48)),
    );
    // At rest: the full photo over the small copy, faded in once decoded, at the pixels the zoom needs.
    final bucket = _scale <= 1.05 ? 1 : (_scale <= 2 ? 2 : 3);
    final provider = ResizeImage.resizeIfNeeded(
        math.min(6000, (width * dpr * bucket).round()), null, NetworkImage(step.cut ? m.url : m.originalUrl));
    // With no small copy the base is already this photo at screen size: nothing to lay over it, nothing to drop.
    final sharpen = (_settled || _zoomed) && provider != small;
    if (sharpen) _remember(provider);
    final full = Image(
      image: provider,
      key: ValueKey('showcase-full-${m.url}-$bucket'),
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      frameBuilder: (_, child, frame, sync) =>
          sync || frame != null ? child : const SizedBox.shrink(), // until then the small copy shows through
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    final img = Stack(fit: StackFit.expand, children: [base, if (sharpen) full]);
    // A scan's frames have their own margin; a seller's cut-out is often cropped close, so it gets one.
    return step.cut && !_plan.scan ? Padding(padding: const EdgeInsets.all(20), child: img) : img;
  }

  bool? _darkTop;

  /// Tells the page whether a dark stage is under the status bar, so its icons can turn light.
  void _reportTop() {
    final report = widget.onDarkTop;
    if (report == null || !mounted) return;
    final offset = widget.scroll.hasClients ? widget.scroll.offset : 0.0;
    final covers = offset < _travel + widget.stageHeight - MediaQuery.paddingOf(context).top;
    final dark = covers && _onDark(_plan.steps[_shown.step]);
    if (dark == _darkTop) return;
    _darkTop = dark;
    report(dark);
  }

  /// The step's photos stand on a dark backdrop.
  bool _onDark(ShowcaseStep step) =>
      widget.listing.backdrop != null && step.cut ? !_light : widget.listing.showcaseStyle == 'premium';

  BoxDecoration get _backdrop => BoxDecoration(color: (_light ? ShowcaseScene.light : ShowcaseScene.dark).ink);

  /// The stops on a line that fills as the shoe goes round, as on the demo page: a stop lights up once reached.
  Widget _stops(ShowcaseScene scene, int current, int index) {
    const width = 200.0;
    final filled = _plan.photos.length < 2 ? 0.0 : index / (_plan.photos.length - 1);
    return SizedBox(
      width: width + 48,
      height: 48,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: 24,
          right: 24,
          top: 22.5,
          height: 3,
          child: DecoratedBox(decoration: BoxDecoration(color: scene.line, borderRadius: BorderRadius.circular(3))),
        ),
        Positioned(
          left: 24,
          top: 22.5,
          height: 3,
          width: width * filled,
          child: DecoratedBox(decoration: BoxDecoration(color: scene.glow, borderRadius: BorderRadius.circular(3))),
        ),
        for (var i = 0; i < _plan.steps.length; i++)
          Positioned(
            left: width * _plan.startOf(i),
            top: 0,
            width: 48,
            height: 48,
            child: Semantics(
              button: true,
              selected: i == current,
              label: _plan.steps[i].label,
              child: Tooltip(
                message: _plan.steps[i].label,
                excludeFromSemantics: true,
                child: InkWell(
                  key: Key('showcase-step-${_plan.steps[i].kind}'),
                  customBorder: const CircleBorder(),
                  onTap: () => _goTo(i),
                  child: Center(
                    child: AnimatedContainer(
                      duration: _reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i <= current ? scene.glow : scene.ink,
                        border: Border.all(color: i <= current ? scene.glow : scene.line, width: 2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    builds++;
    final travel = _travel;
    final h = widget.stageHeight;
    final now = _plan.at(_progress);
    final step = _plan.steps[now.step];
    final media = step.media[now.frame];
    final ownBackdrop = widget.listing.backdrop != null && step.cut;
    final onDark = _onDark(step);
    final scene = onDark ? ShowcaseScene.dark : ShowcaseScene.light;
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
                          // The soft light behind the shoe stays put while the shoe zooms, as on the approved demo page.
                          child: CustomPaint(
                            painter: ownBackdrop ? _Halo(scene.halo) : null,
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
              ),
              // Zoom reset, backdrop switch, the photos as taken and the details, on the right above the stops.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (_zoomed)
                    _RoundChip(
                      key: const Key('showcase-reset-zoom'),
                      scene: scene,
                      tooltip: tr('Бастапқы өлшем'),
                      onTap: _resetZoom,
                      child: Text('1×', style: TextStyle(fontWeight: FontWeight.w700, color: scene.fg)),
                    ),
                  if (ownBackdrop)
                    _RoundChip(
                      key: const Key('showcase-backdrop'),
                      scene: scene,
                      tooltip: _light ? tr('Қараңғы фон') : tr('Ашық фон'),
                      toggled: !_light,
                      onTap: () {
                        setState(() => _light = !_light);
                        _reportTop();
                      },
                      child: Icon(Icons.contrast, size: 20, color: scene.fg),
                    ),
                  if (widget.onPhotos != null)
                    _RoundChip(
                      key: const Key('showcase-photos'),
                      scene: scene,
                      tooltip: tr('Фото'),
                      onTap: () {
                        _resetZoom();
                        widget.onPhotos!();
                      },
                      child: Icon(Icons.photo_library_outlined, size: 18, color: scene.fg),
                    ),
                  if (widget.onDetails != null)
                    _RoundChip(
                      key: const Key('showcase-details'),
                      scene: scene,
                      tooltip: tr('Толығырақ'),
                      onTap: () {
                        _resetZoom();
                        widget.onDetails!();
                      },
                      child: Icon(Icons.keyboard_double_arrow_down_rounded, size: 20, color: scene.fg),
                    ),
                ]),
              ),
              // The stops on a thin line that fills as the shoe turns (Aza's choice: nothing written beside the
              // shoe). Each stop is a 48 dp button that jumps straight to its view; its name is read out and shown on
              // long press.
              Center(child: _stops(scene, now.step, index)),
              // How to use it, until the shoe starts turning.
              AnimatedOpacity(
                opacity: index == 0 ? 1 : 0,
                duration: _reduceMotion ? Duration.zero : const Duration(milliseconds: 300),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text.rich(
                    TextSpan(children: [
                      WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Icon(Icons.south_rounded, size: 16, color: scene.muted)),
                      TextSpan(text: ' ${tr('Төмен жүргізіңіз · екі саусақпен жақындатыңыз')}'),
                    ]),
                    key: const Key('showcase-hint'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: scene.muted),
                  ),
                ),
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
  const _RoundChip(
      {super.key, required this.child, required this.onTap, required this.tooltip, required this.scene, this.toggled});
  final Widget child;
  final ShowcaseScene scene;
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
              color: scene.panel,
              shape: CircleBorder(side: BorderSide(color: scene.line)),
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
