import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../i18n.dart';
import '../theme.dart';
import 'spin_viewer.dart' show showcaseBackground;

/// One stop of the showcase: the turn made of 360° frames, then the top, the sole and a close-up.
class ShowcaseStep {
  const ShowcaseStep(this.kind, this.media, this.weight);
  final String kind; // spin | top | sole | close
  final List<MediaItem> media;

  /// Share of the scroll this step takes, in frame units.
  final double weight;

  String get label => switch (kind) {
        'spin' => '360°',
        'top' => tr('Үстінен'),
        'sole' => tr('Табаны'),
        _ => tr('Жақын'),
      };
}

/// Which photo shows at a given scroll position. Only real photos are shown: nothing is generated or blended.
class ShowcasePlan {
  ShowcasePlan(this.steps) : total = steps.fold(0.0, (sum, s) => sum + s.weight);

  /// The frames in order, then the top and sole photos and a close-up (the label, else the front), each only
  /// when the seller took it.
  factory ShowcasePlan.of(Listing l) {
    final frames = l.frames;
    MediaItem? first(String angle) => l.media.where((m) => m.angle == angle).firstOrNull;
    final detail = math.max(6.0, frames.length / 6);
    final close = first('label') ?? first('front');
    return ShowcasePlan([
      ShowcaseStep('spin', frames, frames.length.toDouble()),
      if (first('top') case final m?) ShowcaseStep('top', [m], detail),
      if (first('sole') case final m?) ShowcaseStep('sole', [m], detail),
      if (close != null) ShowcaseStep('close', [close], detail),
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
}

/// The 360° showcase as a stretch of the page: while it scrolls past, the viewer stays in place and the shoe
/// turns frame by frame, then shows its top, sole and a close-up. Scrolling back turns it back. Two fingers zoom
/// the shoe up to 3× (the page stays put), a double tap zooms in or out, and 1× resets.
///
/// It must be the first thing in the list that [scroll] drives, so its top is at scroll offset 0.
class ScrollShowcase extends StatefulWidget {
  const ScrollShowcase(
      {super.key, required this.listing, required this.scroll, required this.viewerHeight, this.onPhotos});

  final Listing listing;

  /// Switches the page to the photos as taken; the stops row offers it so it is never a long scroll away.
  final VoidCallback? onPhotos;
  final ScrollController scroll;
  final double viewerHeight;

  /// How far the page scrolls while the viewer stays in place, per screen height.
  static double travelFor(double screenHeight, int steps) => screenHeight * (1.4 + 0.35 * (steps - 1));

  @override
  State<ScrollShowcase> createState() => _ScrollShowcaseState();
}

class _ScrollShowcaseState extends State<ScrollShowcase> {
  late final ShowcasePlan _plan = ShowcasePlan.of(widget.listing);
  late bool _light = widget.listing.backdrop != 'dark';
  bool _settled = true;
  Timer? _settle;
  int _lastStep = 0;
  bool _precached = false;

  // Zoom, driven by raw pointers so one finger keeps scrolling the page.
  final _pointers = <int, Offset>{};
  late final _chipKeys = [for (final _ in _plan.steps) GlobalKey()];
  final _chipRow = GlobalKey();
  final _chips = ScrollController();
  double _scale = 1, _pinchStartScale = 1, _pinchStartDistance = 0;
  Offset _focal = Offset.zero;
  double? _lockedOffset;
  Offset? _tapAt;

  double get _travel => ScrollShowcase.travelFor(MediaQuery.sizeOf(context).height, _plan.steps.length);

  double get _progress {
    final s = widget.scroll;
    return s.hasClients ? (s.offset / _travel).clamp(0.0, 1.0) : 0;
  }

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_precached) return;
    _precached = true;
    // The small copies are what scrolling shows, so they are fetched first, in order.
    for (final s in _plan.steps) {
      for (final m in s.media) {
        if (m.thumbUrl != null) precacheImage(NetworkImage(m.thumbUrl!), context, onError: (_, __) {});
      }
    }
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_onScroll);
    _settle?.cancel();
    _chips.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_lockedOffset != null) {
      if (widget.scroll.offset != _lockedOffset) widget.scroll.jumpTo(_lockedOffset!); // pinching: page stays
      return;
    }
    final now = _plan.at(_progress);
    if (now.step != _lastStep) {
      _lastStep = now.step;
      HapticFeedback.selectionClick();
      // On a narrow phone the stops row scrolls; keep the stop being shown in view.
      // Only this row moves: Scrollable.ensureVisible would also scroll the page and undo the turn.
      final chip = _chipKeys[now.step].currentContext?.findRenderObject() as RenderBox?;
      final row = _chipRow.currentContext?.findRenderObject();
      if (chip != null && row != null && _chips.hasClients) {
        final x = chip.localToGlobal(Offset.zero, ancestor: row).dx + chip.size.width / 2;
        final p = _chips.position;
        final to = (x - p.viewportDimension / 2).clamp(0.0, p.maxScrollExtent);
        if (MediaQuery.of(context).disableAnimations) {
          _chips.jumpTo(to);
        } else {
          _chips.animateTo(to, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
        }
      }
    }
    _settle?.cancel();
    if (_settled) _settled = false;
    // Small copies while moving; the full photo once the shoe has stopped for a moment.
    _settle = Timer(const Duration(milliseconds: 140), () {
      if (mounted) setState(() => _settled = true);
    });
    setState(() {});
  }

  void _goTo(int step) {
    final target = _plan.startOf(step) * _travel + (step == 0 ? 0 : 1);
    if (MediaQuery.of(context).disableAnimations) {
      widget.scroll.jumpTo(target);
    } else {
      widget.scroll.animateTo(target, duration: const Duration(milliseconds: 450), curve: Curves.easeInOut);
    }
  }

  /// Scroll share of one photo, so a screen reader's swipe moves one photo on or back.
  double get _nudgeShare => 1 / math.max(1, _plan.steps.fold<int>(0, (n, s) => n + s.media.length));

  void _nudge(int delta) => widget.scroll.jumpTo(((_progress + delta * _nudgeShare) * _travel).clamp(0.0, _travel));

  String _describe(double progress) {
    final at = _plan.at(progress);
    final s = _plan.steps[at.step];
    return s.kind == 'spin' ? trf('кадр {0} / {1}', [at.frame + 1, s.media.length]) : s.label;
  }

  void _pointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2) {
      final p = _pointers.values.toList();
      _pinchStartDistance = (p[0] - p[1]).distance;
      _pinchStartScale = _scale;
      _lockedOffset = widget.scroll.hasClients ? widget.scroll.offset : null;
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length != 2 || _pinchStartDistance < 1) return;
    final p = _pointers.values.toList();
    setState(() {
      _scale = (_pinchStartScale * (p[0] - p[1]).distance / _pinchStartDistance).clamp(1.0, 3.0);
      _focal = (p[0] + p[1]) / 2;
    });
  }

  void _pointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) _lockedOffset = null;
  }

  void _doubleTap() {
    setState(() {
      if (_scale > 1.05) {
        _scale = 1;
      } else {
        _scale = 2.5;
        _focal = _tapAt ?? _focal;
      }
    });
  }

  Widget _photo(MediaItem m, {required double width, required bool close}) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final zoomed = _scale > 1.05 || close;
    final cut = m.processedUrl != null && !close;
    // While moving: the 480 px copy. At rest: the full photo decoded at the screen's own pixels; zoomed: all of it.
    final url = !_settled && !zoomed && m.thumbUrl != null ? m.thumbUrl! : (close ? m.originalUrl : m.url);
    final decodeWidth = zoomed ? null : math.min(2000, (width * dpr).round());
    Widget img = Image.network(url,
        key: ValueKey('showcase-$url'),
        fit: cut ? BoxFit.contain : BoxFit.cover,
        cacheWidth: decodeWidth,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined, size: 48)));
    if (close && m.angle == 'front') {
      img = Transform.scale(scale: 1.8, filterQuality: FilterQuality.high, child: img); // a close look at the front
    }
    return cut ? Padding(padding: const EdgeInsets.all(20), child: img) : img;
  }

  BoxDecoration get _backdrop {
    if (widget.listing.backdrop == null) return showcaseBackground(widget.listing.showcaseStyle);
    return _light
        ? const BoxDecoration(color: Brand.studio)
        : const BoxDecoration(gradient: RadialGradient(colors: [Color(0xFF3A3A40), Color(0xFF111114)], radius: 0.9));
  }

  @override
  Widget build(BuildContext context) {
    final travel = _travel;
    final h = widget.viewerHeight;
    final now = _plan.at(_progress);
    final step = _plan.steps[now.step];
    final media = step.media[now.frame];
    final offset = widget.scroll.hasClients ? widget.scroll.offset.clamp(0.0, travel) : 0.0;
    final onDark = widget.listing.backdrop != null ? !_light : widget.listing.showcaseStyle == 'premium';
    final chipText = onDark ? Colors.white : Brand.ink;
    return SizedBox(
      height: h + travel,
      child: Stack(children: [
        Positioned(
          top: offset,
          left: 0,
          right: 0,
          height: h,
          child: Semantics(
            container: true,
            slider: true,
            label: trf('360° көрініс: {0}. Бұру үшін бетті жоғары-төмен жылжытыңыз.', [step.label]),
            value: _describe(_progress),
            increasedValue: _describe(_progress + _nudgeShare),
            decreasedValue: _describe(_progress - _nudgeShare),
            onIncrease: () => _nudge(1),
            onDecrease: () => _nudge(-1),
            child: DecoratedBox(
              key: const Key('showcase'),
              decoration: _backdrop,
              child: LayoutBuilder(
                builder: (context, box) => Listener(
                  behavior: HitTestBehavior.opaque, // the whole viewer, not only where the shoe is
                  onPointerDown: _pointerDown,
                  onPointerMove: _pointerMove,
                  onPointerUp: _pointerUp,
                  onPointerCancel: _pointerUp,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTapDown: (d) => _tapAt = d.localPosition,
                    onDoubleTap: _doubleTap,
                    child: ClipRect(
                      child: Transform(
                        transform: Matrix4.identity()
                          ..translateByDouble(_focal.dx, _focal.dy, 0, 1)
                          ..scaleByDouble(_scale, _scale, 1, 1)
                          ..translateByDouble(-_focal.dx, -_focal.dy, 0, 1),
                        filterQuality: _scale > 1.05 ? FilterQuality.high : null,
                        child: SizedBox.expand(
                            child: _photo(media, width: box.maxWidth * _scale, close: step.kind == 'close')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // The stops, as buttons: jump straight to the top, sole or close-up without scrolling there.
        Positioned(
          top: offset + h - 52,
          left: 12,
          right: 12,
          child: Row(children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _chips,
                scrollDirection: Axis.horizontal,
                child: Row(key: _chipRow, children: [
                  for (var i = 0; i < _plan.steps.length; i++)
                    Padding(
                      key: _chipKeys[i],
                      padding: const EdgeInsets.only(right: 6),
                      child: Semantics(
                        button: true,
                        selected: i == now.step,
                        child: InkWell(
                          key: Key('showcase-step-${_plan.steps[i].kind}'),
                          borderRadius: BorderRadius.circular(99),
                          onTap: () => _goTo(i),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 36, minWidth: 48),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: i == now.step
                                  ? (onDark ? Colors.white : Brand.ink)
                                  : (onDark ? Colors.white24 : Colors.white.withValues(alpha: 0.85)),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(_plan.steps[i].label,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: i == now.step ? (onDark ? Brand.ink : Colors.white) : chipText)),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
            // Kept outside the scrolling stops so it is always on screen, however many stops there are.
            if (widget.onPhotos != null)
              Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Semantics(
                    button: true,
                    label: tr('Фото'),
                    child: InkWell(
                      key: const Key('showcase-photos'),
                      borderRadius: BorderRadius.circular(99),
                      onTap: widget.onPhotos,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 36, minWidth: 48),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          border: Border.all(color: onDark ? Colors.white54 : Colors.black26),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        // An icon only, so the stops keep the width; the label is read out and shown on long press.
                        child: Tooltip(
                            message: tr('Фото'),
                            excludeFromSemantics: true,
                            child: Icon(Icons.photo_library_outlined, size: 18, color: chipText)),
                      ),
                    ),
                  )),
          ]),
        ),
        // Zoom reset and backdrop switch, on the right above the stops.
        Positioned(
          top: offset + h - 52 - 52,
          right: 12,
          child: Row(children: [
            if (_scale > 1.05)
              _RoundChip(
                key: const Key('showcase-reset-zoom'),
                tooltip: tr('Бастапқы өлшем'),
                onTap: () => setState(() => _scale = 1),
                child: const Text('1×', style: TextStyle(fontWeight: FontWeight.w700, color: Brand.ink)),
              ),
            if (widget.listing.backdrop != null) ...[
              const SizedBox(width: 6),
              _RoundChip(
                key: const Key('showcase-backdrop'),
                tooltip: _light ? tr('Қараңғы фон') : tr('Ашық фон'),
                onTap: () => setState(() => _light = !_light),
                child: const Icon(Icons.contrast, size: 20, color: Brand.ink),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

class _RoundChip extends StatelessWidget {
  const _RoundChip({super.key, required this.child, required this.onTap, required this.tooltip});
  final Widget child;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.white.withValues(alpha: 0.92),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 44, height: 44, child: Center(child: child)),
          ),
        ),
      );
}
