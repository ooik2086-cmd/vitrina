import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net_image.dart';
import '../theme.dart';
import '../i18n.dart';
import 'blur_fill.dart';
import 'scroll_showcase.dart' show ShowcaseScene;

/// 360° view built from a sequence of real photos taken around the product.
/// Dragging horizontally steps through the frames; nothing is interpolated or generated.
/// On first show it turns once by itself so people see that it can be turned.
class SpinViewer extends StatefulWidget {
  const SpinViewer({
    super.key,
    required this.frameUrls,
    this.pixelsPerFrame = 12,
    this.introSpin = true,
  });

  final List<String> frameUrls;
  final double pixelsPerFrame;
  final bool introSpin;

  @override
  State<SpinViewer> createState() => _SpinViewerState();
}

class _SpinViewerState extends State<SpinViewer> {
  int _index = 0;
  double _dragAccum = 0;
  bool _precached = false;
  Timer? _intro;
  final _focus = FocusNode(debugLabel: 'spin');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_precached) return;
    _precached = true;
    final loads = [
      for (final url in widget.frameUrls) precacheImage(netImage(url), context, onError: (_, __) {}),
    ];
    if (widget.introSpin && widget.frameUrls.length > 1) {
      Future.wait(loads).then((_) {
        if (!mounted || _intro != null) return;
        var steps = 0;
        _intro = Timer.periodic(const Duration(milliseconds: 45), (t) {
          if (!mounted || ++steps > widget.frameUrls.length) return t.cancel();
          setState(() => _index = steps % widget.frameUrls.length);
        });
      });
    }
  }

  @override
  void dispose() {
    _intro?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _onDrag(DragUpdateDetails d) {
    _intro?.cancel();
    _dragAccum += d.delta.dx;
    final steps = (_dragAccum / widget.pixelsPerFrame).truncate();
    if (steps == 0) return;
    _dragAccum -= steps * widget.pixelsPerFrame;
    final n = widget.frameUrls.length;
    // Dragging right turns the shoe towards the viewer's right, like turning it by hand.
    setState(() => _index = ((_index - steps) % n + n) % n);
  }

  /// One frame on or back, for screen readers' swipe up and down and for the arrow keys.
  void _step(int delta) {
    _intro?.cancel();
    final n = widget.frameUrls.length;
    setState(() => _index = ((_index + delta) % n + n) % n);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      _step(1);
    } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _step(-1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.frameUrls.length;
    String frame(int i) => trf('кадр {0} / {1}', [(i % n + n) % n + 1, n]);
    return Semantics(
      container: true,
      slider: true,
      label: trf('360° көрініс, кадр {0} / {1}. Айналдыру үшін көлденең сүйреңіз.', [_index + 1, n]),
      value: frame(_index),
      increasedValue: frame(_index + 1),
      decreasedValue: frame(_index - 1),
      onIncrease: () => _step(1),
      onDecrease: () => _step(-1),
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: GestureDetector(
          onTapDown: (_) => _focus.requestFocus(), // so the arrow keys turn it after a click
          onHorizontalDragDown: (_) => _intro?.cancel(),
          onHorizontalDragUpdate: _onDrag,
          child: Stack(fit: StackFit.expand, children: [
            Image(
                image: netImage(widget.frameUrls[_index]),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined, size: 48))),
            Positioned(
              left: 0,
              right: 0,
              bottom: 18,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(99)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.threesixty, size: 18, color: Brand.ink),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 72,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: (_index + 1) / n,
                            minHeight: 4,
                            color: Brand.ink,
                            backgroundColor: Colors.black12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(tr('сүйреңіз'),
                          style: TextStyle(
                              color: Brand.ink,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              fontVariations: const [FontVariation('wght', 600)])),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Swipeable gallery with page dots, for the angle photos and for listings without a frame sequence.
class PhotoGallery extends StatefulWidget {
  const PhotoGallery({super.key, required this.urls, this.dark = false, this.cutout = false});
  final List<String> urls;
  final bool dark; // the photos stand on a dark scene: the page dots go light

  /// Cut-out photos stand on the scene; photos as taken stand on their own colours (see BlurFill). Either way a
  /// photo of any shape shows whole, nothing cut off.
  final bool cutout;

  @override
  State<PhotoGallery> createState() => _PhotoGalleryState();
}

class _PhotoGalleryState extends State<PhotoGallery> {
  int _page = 0;
  bool _zoomed = false; // a photo zoomed in pans under the finger instead of turning the page
  final _pages = PageController();

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty) {
      return const ColoredBox(color: Brand.studio, child: Center(child: Icon(Icons.image_not_supported_outlined)));
    }
    // Decoded at the size shown: a 3200 px photo decoded whole is 40 MB. Only the photo zoomed in is decoded at twice
    // that (up to 2000 px), so it stays sharp at 3×.
    final side = MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context);
    return Stack(children: [
      PageView(
        controller: _pages,
        physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
        onPageChanged: (p) => setState(() {
          _page = p;
          _zoomed = false;
        }),
        children: [
          for (final (n, u) in widget.urls.indexed)
            _ZoomPhoto(
              active: n == _page,
              onZoomed: (z) {
                if (z != _zoomed) setState(() => _zoomed = z);
              },
              backdrop: widget.cutout ? null : BlurFill(url: u),
              photo: Image(
                  image: ResizeImage.resizeIfNeeded(
                      math.min((side * (n == _page && _zoomed ? 2 : 1)).round(), 2000), null, netImage(u)),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined))),
            ),
        ],
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 18,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var i = 0; i < widget.urls.length; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == _page ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                  color: i == _page
                      ? (widget.dark ? ShowcaseScene.dark.fg : Brand.ink)
                      : (widget.dark ? Colors.white30 : Colors.black26),
                  borderRadius: BorderRadius.circular(99)),
            ),
        ]),
      ),
    ]);
  }
}

/// One photo that zooms as on the approved demo: two fingers up to 3× round the spot between them, a double tap to
/// 2.5× where tapped and back, eased; zoomed in, one finger moves it. Another page shown, it is back at 1×. The
/// [backdrop] stays still behind it, painted once rather than on every frame of a zoom.
///
/// Its own fingers' reading rather than InteractiveViewer's: on a phone the page's scroll and the photo row took the
/// fingers first, as the second finger lands a moment after the first (Aza, 2026-10-25: "суретке екі саусақпен
/// жақындатуға болатындай"). Two fingers on a photo are always its zoom; zoomed in, one finger is its own too.
class _ZoomPhoto extends StatefulWidget {
  const _ZoomPhoto({required this.photo, this.backdrop, required this.active, required this.onZoomed});
  final Widget photo;
  final Widget? backdrop;
  final bool active;
  final ValueChanged<bool> onZoomed;

  @override
  State<_ZoomPhoto> createState() => _ZoomPhotoState();
}

class _ZoomPhotoState extends State<_ZoomPhoto> with SingleTickerProviderStateMixin {
  static const maxZoom = 3.0;

  final _view = ValueNotifier<Matrix4>(Matrix4.identity());
  late final _ease = AnimationController(vsync: this, duration: const Duration(milliseconds: 260))
    ..addListener(() => _set(_anim!.value));
  Animation<Matrix4>? _anim;
  bool _zoomed = false;
  Size _size = Size.zero;

  // The gesture in hand: the matrix it started from and the spot of the photo under the fingers then.
  Matrix4 _from = Matrix4.identity();
  Offset _spot = Offset.zero;

  // The fingers on the photo, read straight from the screen (outside the gesture arena): for taps, and for a pinch
  // the page's scroll or the photo row took before the second finger landed. Read from every touch on the screen
  // while a hand is on the photo: a scrolling page lets no new touch through to what it scrolls.
  final _raw = <int, Offset>{};
  bool _routed = false;
  bool _scaling = false; // the zoom recognizer has the fingers
  List<(ScrollPosition, double)> _scrolls = const [];
  double? _rawSpan;

  // Taps: a tap is short and still; a double tap is two, the second down within 300 ms of the first's lift and
  // within 100 px of it, as the phone counts one.
  Offset? _down;
  Duration _downAt = Duration.zero;
  bool _many = false;
  Offset? _lastTap;
  Duration _lastTapAt = Duration.zero;

  @override
  void didUpdateWidget(_ZoomPhoto old) {
    super.didUpdateWidget(old);
    if (old.active && !widget.active) {
      _ease.stop();
      _set(Matrix4.identity());
    }
  }

  @override
  void dispose() {
    _unroute();
    _ease.dispose();
    _view.dispose();
    super.dispose();
  }

  double get _scale => _view.value.getMaxScaleOnAxis();

  /// Shows [m], told to the gallery the moment the zoom crosses 1×.
  void _set(Matrix4 m) {
    _view.value = m;
    final z = _scale > 1.01;
    if (z == _zoomed) return;
    setState(() => _zoomed = z);
    widget.onZoomed(z);
  }

  /// [s]× with the photo's spot [spot] under the screen point [at], kept so the photo always fills the stage.
  Matrix4 _at(double s, Offset spot, Offset at) {
    s = s.clamp(1.0, maxZoom);
    final dx = (at.dx - spot.dx * s).clamp(_size.width * (1 - s), 0.0);
    final dy = (at.dy - spot.dy * s).clamp(_size.height * (1 - s), 0.0);
    return Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  Offset _spotUnder(Matrix4 m, Offset at) {
    final s = m.getMaxScaleOnAxis(), t = m.getTranslation();
    return Offset((at.dx - t.x) / s, (at.dy - t.y) / s);
  }

  void _start(ScaleStartDetails d) {
    _scaling = true;
    _ease.stop();
    _from = _view.value.clone();
    _spot = _spotUnder(_from, d.localFocalPoint);
  }

  void _update(ScaleUpdateDetails d) =>
      _set(_at(_from.getMaxScaleOnAxis() * (d.pointerCount > 1 ? d.scale : 1), _spot, d.localFocalPoint));

  void _toggle(Offset at) {
    final end = _zoomed ? Matrix4.identity() : _at(2.5, _spotUnder(_view.value, at), at);
    _anim = Matrix4Tween(begin: _view.value, end: end).animate(CurvedAnimation(parent: _ease, curve: Curves.easeOut));
    if (MediaQuery.of(context).disableAnimations) {
      _set(end);
    } else {
      _ease.forward(from: 0);
    }
  }

  void _route() {
    if (_routed) return;
    _routed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  void _unroute() {
    if (!_routed) return;
    _routed = false;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
  }

  void _onPointer(PointerEvent e) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final at = box.globalToLocal(e.position);
    switch (e) {
      case PointerDownEvent() when !_raw.containsKey(e.pointer) && (box.size.contains(at) || _raw.isEmpty):
        _pointerDown(e, at);
      case PointerMoveEvent():
        _pointerMove(e, at);
      case PointerUpEvent():
        _pointerUp(e, at);
      case PointerCancelEvent():
        _lift(e.pointer);
        _down = null;
      default:
    }
  }

  void _pointerDown(PointerDownEvent e, Offset at) {
    if (_raw.isEmpty) {
      // Where every scroll round the photo stands as the hand lands, to put back if it took the first finger.
      final scrolls = <(ScrollPosition, double)>[];
      for (var s = Scrollable.maybeOf(context); s != null; s = Scrollable.maybeOf(s.context)) {
        if (s.position.hasPixels) scrolls.add((s.position, s.position.pixels));
      }
      _scrolls = scrolls;
    }
    _raw[e.pointer] = at;
    _many = _raw.length > 1;
    if (_many) {
      _down = null;
      return;
    }
    _down = e.position;
    _downAt = e.timeStamp;
    final last = _lastTap;
    if (last != null &&
        (e.timeStamp - _lastTapAt > kDoubleTapTimeout || (e.position - last).distance > kDoubleTapSlop)) {
      _lastTap = null;
    }
  }

  void _pointerMove(PointerMoveEvent e, Offset at) {
    if (!_raw.containsKey(e.pointer)) return;
    _raw[e.pointer] = at;
    if (_down != null && (e.position - _down!).distance > kTouchSlop) {
      _down = null; // moved: not a tap, and the next tap starts afresh
      _lastTap = null;
    }
    if (_raw.length < 2 || _scaling) return;
    // Two fingers, and the zoom recognizer lost the first to the page's scroll or the photo row (on a phone that takes
    // a finger after 8 dp; an unsteady hand moves that much before the second lands): zoom from the fingers anyway and
    // put the scroll back where it stood.
    final [a, b] = _raw.values.take(2).toList();
    final span = (a - b).distance, focal = (a + b) / 2;
    if (_rawSpan == null) {
      for (final (position, pixels) in _scrolls) {
        if (position.hasPixels && (position.isScrollingNotifier.value || position.pixels != pixels)) {
          position.jumpTo(pixels);
        }
      }
      _ease.stop();
      _from = _view.value.clone();
      _spot = _spotUnder(_from, focal);
      _rawSpan = span;
      return;
    }
    if (_rawSpan! > 0) _set(_at(_from.getMaxScaleOnAxis() * span / _rawSpan!, _spot, focal));
  }

  void _pointerUp(PointerUpEvent e, Offset at) {
    if (!_raw.containsKey(e.pointer)) return;
    _lift(e.pointer);
    final down = _down;
    _down = null;
    if (down == null || _many || _raw.isNotEmpty) return;
    if (e.timeStamp - _downAt > kLongPressTimeout) {
      _lastTap = null;
      return;
    }
    final last = _lastTap;
    if (last != null && _downAt - _lastTapAt <= kDoubleTapTimeout && (down - last).distance <= kDoubleTapSlop) {
      _lastTap = null;
      _toggle(at);
    } else {
      _lastTap = e.position;
      _lastTapAt = e.timeStamp;
    }
  }

  void _lift(int pointer) {
    _raw.remove(pointer);
    if (_raw.length < 2) _rawSpan = null;
    if (_raw.isEmpty) {
      _scrolls = const [];
      _scaling = false;
      _unroute();
    }
  }

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        if (widget.backdrop != null) RepaintBoundary(child: widget.backdrop),
        LayoutBuilder(builder: (context, box) {
          _size = box.biggest;
          return Listener(
            // The whole stage, also where the photo is not (zoomed and moved aside, or not loaded).
            behavior: HitTestBehavior.opaque,
            // A hand on the photo: from now till it lifts, every touch is read (the down itself among them).
            onPointerDown: (_) => _route(),
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: {
                _PhotoZoomRecognizer: GestureRecognizerFactoryWithHandlers<_PhotoZoomRecognizer>(
                  () => _PhotoZoomRecognizer(),
                  (r) => r
                    ..zoomed = _zoomed
                    ..onStart = _start
                    ..onUpdate = _update
                    ..onEnd = (_) => _scaling = false,
                ),
              },
              child: ClipRect(
                child: ValueListenableBuilder<Matrix4>(
                  valueListenable: _view,
                  builder: (_, m, child) => Transform(key: const Key('photo-zoom'), transform: m, child: child),
                  child: SizedBox.expand(child: widget.photo),
                ),
              ),
            ),
          );
        }),
      ]);
}

/// A photo's zoom: wins at once when a second finger lands on the photo (the page's scroll and the photo row take
/// one finger only), and, while the photo is zoomed in, from the first finger, so moving it never scrolls the page.
class _PhotoZoomRecognizer extends ScaleGestureRecognizer {
  bool zoomed = false;
  final _fingers = <int>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _fingers.add(event.pointer);
    if (_fingers.length > 1 || zoomed) resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    if (event is PointerUpEvent || event is PointerCancelEvent) _fingers.remove(event.pointer);
  }

  @override
  void rejectGesture(int pointer) {
    _fingers.remove(pointer);
    super.rejectGesture(pointer);
  }
}
