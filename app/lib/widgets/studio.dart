import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The studio backdrop shoe cards are shown on, in the catalog, favourites and comparison, and the 360° view of a
/// dark shoe (a light shoe turns on the dark backdrop, which the buyer can switch): light falling
/// on the middle, where the shoe stands, and fading a little toward the edges, so the card reads apart from the
/// page around it and the shoe stands out from the card.
const studioGradient = RadialGradient(
  center: Alignment(0, -0.1),
  radius: 0.75, // of the shortest side: every edge, the top one too, ends darker than the page around the card
  colors: [Color(0xFFFCFBF9), Color(0xFFF1EFEB), Color(0xFFE4E1DB)],
  stops: [0, 0.5, 1],
);

BoxDecoration studioBackdrop({BorderRadius? radius}) => BoxDecoration(gradient: studioGradient, borderRadius: radius);

/// A listing photo as cards show it: a cut-out shoe stands on its shadow.
class CoverPhoto extends StatelessWidget {
  const CoverPhoto({super.key, required this.image, required this.cutout, required this.fit, this.errorBuilder});
  final ImageProvider image;
  final bool cutout;
  final BoxFit fit;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        if (cutout) ContactShadow(image: image, fit: fit),
        Image(image: image, fit: fit, errorBuilder: errorBuilder),
      ]);
}

/// A shadow made from a photo, and the size of that photo, so it is drawn exactly where the photo is.
typedef MadeShadow = ({ui.Image image, Size photo});

/// A soft shadow under a cut-out shoe, so it stands on the floor instead of floating on the backdrop.
///
/// It is made from the photo already on screen: the shoe's outline, shrunk to [width] pixels and drawn large
/// again, so the scaling itself softens it. No second download, and no blur pass on every frame of a scroll.
/// Lay it under the photo with the same [fit]: it is drawn where the photo is, a little lower, so it shows below
/// the sole.
class ContactShadow extends StatefulWidget {
  const ContactShadow({super.key, required this.image, required this.fit, this.gapless = false});

  /// The provider the photo itself is drawn from, so the decoded picture is reused from the cache.
  final ImageProvider image;
  final BoxFit fit;

  /// Keep the last shadow until the next is made, for frames of one turning shoe. Elsewhere a new photo starts
  /// with no shadow, so a reused card never shows the previous shoe's.
  final bool gapless;

  static const width = 32;
  static const opacity = 0.24;

  /// How far below the photo the shadow sits: a share of the photo's drawn height, at most [maxDrop].
  static const drop = 0.03;
  static const maxDrop = 8.0;

  // Least recently used first. Evicted shadows are not disposed: a card may still be drawing one; the engine frees
  // each 32 px image once nothing holds it.
  static final _made = <ImageProvider, MadeShadow>{};
  static const _keep = 160; // a few hundred kilobytes at most

  /// Who waits for a photo's shadow; several cards with one photo share one making. Told by a plain call, not a
  /// future, so a card hears as soon as the shadow is there.
  static final _waiting = <ImageProvider, List<void Function(MadeShadow?)>>{};

  @visibleForTesting
  static void clearCache() => _made.clear();

  @visibleForTesting
  static bool isMade(ImageProvider image) => _made.containsKey(image);

  static MadeShadow? _cached(ImageProvider image) {
    final made = _made.remove(image);
    if (made != null) _made[image] = made; // now the most recent
    return made;
  }

  /// Makes [image]'s shadow ahead of time, so it is there when the photo first shows.
  static void prepare(ImageProvider image, ImageConfiguration config) {
    if (_cached(image) == null) _make(image, config, (_) {});
  }

  static void _make(ImageProvider image, ImageConfiguration config, void Function(MadeShadow?) then) {
    final waiting = _waiting[image];
    if (waiting != null) return waiting.add(then);
    _waiting[image] = [then];
    final stream = image.resolve(config);
    late final ImageStreamListener listener;
    var started = false;
    void finish(MadeShadow? made) {
      stream.removeListener(listener);
      if (made != null) {
        _made[image] = made;
        while (_made.length > _keep) {
          _made.remove(_made.keys.first);
        }
      }
      for (final tell in _waiting.remove(image) ?? const <void Function(MadeShadow?)>[]) {
        tell(made);
      }
    }

    listener = ImageStreamListener((info, _) {
      if (started) return info.dispose(); // one frame is enough
      started = true;
      _shadowOf(info).then(finish);
    }, onError: (_, __) => finish(null)); // no photo, no shadow; the photo itself reports the error
    stream.addListener(listener);
  }

  static Future<MadeShadow?> _shadowOf(ImageInfo info) async {
    try {
      final src = info.image;
      // An empty or extreme photo is not a shoe on a floor.
      if (src.width <= 0 || src.height <= 0 || src.width > src.height * 8 || src.height > src.width * 8) return null;
      return (image: await silhouette(src), photo: Size(src.width.toDouble(), src.height.toDouble()));
    } catch (e, stack) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: stack, library: 'contact shadow'));
      return null;
    } finally {
      info.dispose();
    }
  }

  @override
  State<ContactShadow> createState() => _ContactShadowState();
}

/// The outline of [src] in black at [opacity], [width] pixels across.
Future<ui.Image> silhouette(ui.Image src, {int width = ContactShadow.width, double opacity = ContactShadow.opacity}) {
  final height = math.max(1, (width * src.height / src.width).round());
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    src,
    Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()
      ..filterQuality = FilterQuality.medium // averages the shrunk pixels instead of picking a few
      ..colorFilter = ColorFilter.mode(Colors.black.withValues(alpha: opacity), BlendMode.srcIn),
  );
  final picture = recorder.endRecording();
  return picture.toImage(width, height).whenComplete(picture.dispose);
}

class _ContactShadowState extends State<ContactShadow> {
  MadeShadow? _shadow;
  ImageProvider? _asked;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(ContactShadow old) {
    super.didUpdateWidget(old);
    _resolve();
  }

  void _resolve() {
    final image = widget.image;
    if (image == _asked) return;
    _asked = image;
    final made = ContactShadow._cached(image);
    if (made != null) {
      _shadow = made;
      return;
    }
    if (!widget.gapless) _shadow = null;
    ContactShadow._make(image, createLocalImageConfiguration(context), (made) {
      if (mounted && _asked == image) setState(() => _shadow = made);
    });
  }

  @override
  Widget build(BuildContext context) {
    final shadow = _shadow;
    if (shadow == null) return const SizedBox.shrink();
    return SizedBox.expand(child: CustomPaint(painter: _ShadowPainter(shadow, widget.fit)));
  }
}

/// Draws [shadow] where its photo is drawn in [size] with [fit] (centred, as Image lays it out), a little lower.
void paintShadow(Canvas canvas, Size size, MadeShadow shadow, BoxFit fit) {
  final fitted = applyBoxFit(fit, shadow.photo, size);
  final scale = fitted.destination.width / fitted.source.width;
  final photo = Alignment.center.inscribe(shadow.photo * scale, Offset.zero & size);
  final drop = math.min(photo.height * ContactShadow.drop, ContactShadow.maxDrop);
  final img = shadow.image;
  canvas
    ..save()
    ..clipRect(Offset.zero & size)
    ..drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        photo.shift(Offset(0, drop)), Paint()..filterQuality = FilterQuality.high) // drawn large, a soft edge
    ..restore();
}

class _ShadowPainter extends CustomPainter {
  _ShadowPainter(this.shadow, this.fit);
  final MadeShadow shadow;
  final BoxFit fit;

  @override
  void paint(Canvas canvas, Size size) => paintShadow(canvas, size, shadow, fit);

  @override
  bool shouldRepaint(_ShadowPainter old) => old.shadow != shadow || old.fit != fit;
}
