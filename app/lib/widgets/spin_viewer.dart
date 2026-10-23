import 'dart:async';
import 'dart:math' as math;

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

/// One photo that zooms as on the approved demo: two fingers up to 3×, a double tap to 2.5× where tapped and back,
/// eased; zoomed in, one finger moves it. Another page shown, it is back at 1×. The [backdrop] stays still behind it,
/// painted once rather than on every frame of a zoom.
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
  final _view = TransformationController();
  late final _ease = AnimationController(vsync: this, duration: const Duration(milliseconds: 260))
    ..addListener(() => _view.value = _anim!.value);
  Animation<Matrix4>? _anim;
  Offset _tap = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    // Told the moment the zoom crosses 1×, by fingers or by the eased double tap alike.
    _view.addListener(() {
      final z = _view.value.getMaxScaleOnAxis() > 1.01;
      if (z == _zoomed) return;
      setState(() => _zoomed = z);
      widget.onZoomed(z);
    });
  }

  @override
  void didUpdateWidget(_ZoomPhoto old) {
    super.didUpdateWidget(old);
    if (old.active && !widget.active) {
      _ease.stop();
      _view.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _ease.dispose();
    _view.dispose();
    super.dispose();
  }

  void _toggle() {
    final Matrix4 end;
    if (_zoomed) {
      end = Matrix4.identity();
    } else {
      const s = 2.5;
      end = Matrix4.identity()
        ..translateByDouble(-_tap.dx * (s - 1), -_tap.dy * (s - 1), 0, 1)
        ..scaleByDouble(s, s, 1, 1);
    }
    _anim = Matrix4Tween(begin: _view.value, end: end).animate(CurvedAnimation(parent: _ease, curve: Curves.easeOut));
    if (MediaQuery.of(context).disableAnimations) {
      _view.value = end;
    } else {
      _ease.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        if (widget.backdrop != null) RepaintBoundary(child: widget.backdrop),
        GestureDetector(
          onDoubleTapDown: (d) => _tap = d.localPosition,
          onDoubleTap: _toggle,
          child: InteractiveViewer(
            transformationController: _view,
            minScale: 1,
            maxScale: 3,
            panEnabled: _zoomed,
            clipBehavior: Clip.hardEdge,
            onInteractionStart: (_) => _ease.stop(),
            child: SizedBox.expand(child: widget.photo),
          ),
        ),
      ]);
}
