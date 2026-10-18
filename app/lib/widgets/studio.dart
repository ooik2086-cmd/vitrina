import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The studio backdrop shoes are shown on, the same in the catalog, favourites and the 360° view: light falling
/// on the middle, where the shoe stands, and fading a little toward the edges, so the card reads apart from the
/// page around it and the shoe stands out from the card.
const studioGradient = RadialGradient(
  center: Alignment(0, -0.2),
  radius: 0.95,
  colors: [Color(0xFFFCFBF9), Color(0xFFF1EFEB), Color(0xFFE8E6E1)],
  stops: [0, 0.6, 1],
);

BoxDecoration studioBackdrop({BorderRadius? radius}) => BoxDecoration(gradient: studioGradient, borderRadius: radius);

/// A soft shadow under a cut-out shoe, so it stands on the floor instead of floating on the backdrop.
///
/// It is made from the photo already on screen: the shoe's outline, shrunk to [width] pixels and drawn large
/// again, so the scaling itself softens it. No second download, and no blur pass on every frame of a scroll.
/// Lay it under the photo with the same [fit]: it sits a little lower, so it shows below the sole.
class ContactShadow extends StatefulWidget {
  const ContactShadow({super.key, required this.image, required this.fit});

  /// The provider the photo itself is drawn from, so the decoded picture is reused from the cache.
  final ImageProvider image;
  final BoxFit fit;

  static const width = 32;
  static const opacity = 0.24;

  /// How far below the photo the shadow sits, as a share of the box's height.
  static const drop = 0.035;

  static final _made = <ImageProvider, ui.Image>{}; // in the order used, least recent first
  static const _keep = 160; // 32 × 32 px each: a few hundred kilobytes at most

  @visibleForTesting
  static void clearCache() => _made.clear();

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
  ImageStream? _stream;
  late final _listener = ImageStreamListener(_got, onError: (_, __) {}); // no photo, no shadow
  ui.Image? _shadow; // kept while the next one is made, so a turning shoe's shadow never blinks

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(ContactShadow old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _resolve();
  }

  void _resolve() {
    final made = ContactShadow._made.remove(widget.image);
    if (made != null) {
      ContactShadow._made[widget.image] = made; // most recently used last
      _stopListening();
      _shadow = made;
      return;
    }
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return; // the same picture
    _stopListening();
    _stream = stream..addListener(_listener);
  }

  void _stopListening() {
    _stream?.removeListener(_listener);
    _stream = null;
  }

  void _got(ImageInfo info, bool _) {
    final image = widget.image;
    silhouette(info.image).then((shadow) {
      info.dispose();
      ContactShadow._made[image] = shadow;
      while (ContactShadow._made.length > ContactShadow._keep) {
        ContactShadow._made.remove(ContactShadow._made.keys.first); // still drawn elsewhere: let it go, not dispose
      }
      if (mounted && widget.image == image) setState(() => _shadow = shadow);
    }, onError: (_) => info.dispose());
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shadow = _shadow;
    if (shadow == null) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: FractionalTranslation(
        translation: const Offset(0, ContactShadow.drop),
        child: RawImage(
          image: shadow,
          fit: widget.fit,
          width: double.infinity,
          height: double.infinity,
          filterQuality: FilterQuality.medium, // drawn large, the few pixels blend into a soft edge
        ),
      ),
    );
  }
}
