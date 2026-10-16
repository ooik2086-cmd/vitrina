import 'package:flutter/material.dart';

/// Background per showcase style. Styles change only the backdrop, never the product image.
BoxDecoration showcaseBackground(String style) => switch (style) {
      'premium' => const BoxDecoration(
          gradient: RadialGradient(colors: [Color(0xFF3A3A40), Color(0xFF111114)], radius: 0.9)),
      'dynamic' => const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFE3D3), Color(0xFFD9E6FF)])),
      _ => const BoxDecoration(color: Color(0xFFF4F4F2)),
    };

/// 360° view built from a sequence of real photos taken around the product.
/// Dragging horizontally steps through the frames; nothing is interpolated or generated.
class SpinViewer extends StatefulWidget {
  const SpinViewer({super.key, required this.frameUrls, this.style = 'clean', this.pixelsPerFrame = 12});

  final List<String> frameUrls;
  final String style;
  final double pixelsPerFrame;

  @override
  State<SpinViewer> createState() => _SpinViewerState();
}

class _SpinViewerState extends State<SpinViewer> {
  int _index = 0;
  double _dragAccum = 0;
  bool _precached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_precached) {
      _precached = true;
      for (final url in widget.frameUrls) {
        precacheImage(NetworkImage(url), context, onError: (_, __) {});
      }
    }
  }

  void _onDrag(DragUpdateDetails d) {
    _dragAccum += d.delta.dx;
    final steps = (_dragAccum / widget.pixelsPerFrame).truncate();
    if (steps == 0) return;
    _dragAccum -= steps * widget.pixelsPerFrame;
    final n = widget.frameUrls.length;
    // Dragging right turns the shoe towards the viewer's right, like turning it by hand.
    setState(() => _index = ((_index - steps) % n + n) % n);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.frameUrls.length;
    return Semantics(
      label: '360° көрініс, кадр ${_index + 1} / $n. Айналдыру үшін көлденең сүйреңіз.',
      child: GestureDetector(
        onHorizontalDragUpdate: _onDrag,
        child: Container(
          decoration: showcaseBackground(widget.style),
          child: Stack(fit: StackFit.expand, children: [
            Image.network(widget.frameUrls[_index],
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined, size: 48))),
            Positioned(
              left: 12,
              bottom: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Text('360°  ⟷ сүйреңіз', style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Plain swipeable gallery for listings without a frame sequence.
class PhotoGallery extends StatelessWidget {
  const PhotoGallery({super.key, required this.urls, this.style = 'clean'});
  final List<String> urls;
  final String style;

  @override
  Widget build(BuildContext context) {
    if (urls.isEmpty) {
      return Container(
          decoration: showcaseBackground(style), child: const Center(child: Icon(Icons.image_not_supported_outlined)));
    }
    return Container(
      decoration: showcaseBackground(style),
      child: PageView(children: [
        for (final u in urls)
          Image.network(u,
              fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined))),
      ]),
    );
  }
}
