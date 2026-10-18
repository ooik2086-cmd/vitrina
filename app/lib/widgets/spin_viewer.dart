import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../i18n.dart';
import 'studio.dart';
import 'scroll_showcase.dart' show ShowcaseScene;

/// Backdrop per showcase style. Styles change only what surrounds the photos, never the photos.
BoxDecoration showcaseBackground(String style) => switch (style) {
      'premium' =>
        const BoxDecoration(gradient: RadialGradient(colors: [Color(0xFF3A3A40), Color(0xFF111114)], radius: 0.9)),
      'dynamic' => const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFE3D3), Color(0xFFD9E6FF)])),
      _ => studioBackdrop(),
    };

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
      for (final url in widget.frameUrls) precacheImage(NetworkImage(url), context, onError: (_, __) {}),
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
            Image.network(widget.frameUrls[_index],
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
                          style: TextStyle(color: Brand.ink, fontSize: 12, fontWeight: FontWeight.w600)),
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
  const PhotoGallery({super.key, required this.urls, this.dark = false});
  final List<String> urls;
  final bool dark; // the photos stand on a dark scene: the page dots go light

  @override
  State<PhotoGallery> createState() => _PhotoGalleryState();
}

class _PhotoGalleryState extends State<PhotoGallery> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty) {
      return const ColoredBox(color: Brand.studio, child: Center(child: Icon(Icons.image_not_supported_outlined)));
    }
    // Decoded at the size shown: a 3200 px photo decoded whole is 40 MB.
    final side = (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round();
    return Stack(children: [
      PageView(
        onPageChanged: (p) => setState(() => _page = p),
        children: [
          for (final u in widget.urls)
            Image.network(u,
                fit: BoxFit.cover,
                cacheWidth: math.min(side, 2000),
                errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined))),
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
