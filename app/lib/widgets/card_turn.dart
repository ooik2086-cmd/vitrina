import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../api.dart';
import 'scroll_showcase.dart' show ShowcasePlan;
import 'studio.dart';

/// A catalog card's shoe that turns under a sideways drag, through the same real 360° frames as the listing page,
/// and coasts on after a flick. It stays at the angle it was left at, as a real shoe on a shelf would; [cover] shows
/// until the first drag and wherever a frame is not decoded yet. Vertical drags still scroll the catalog.
class CardTurn extends StatefulWidget {
  const CardTurn({super.key, required this.listing, required this.cover});
  final Listing listing;
  final Widget cover;

  /// A card shows at most this many frames of the turn, evenly spread: a scan's hundred frames would cost a
  /// hundred decoded pictures per card for no visible gain at card size.
  static const maxFrames = 36;

  /// The decoded width of a frame; a card is at most 240 wide, so this is sharp at about 1.7x.
  static const decodeWidth = 400;

  /// The frames a card turns through, or none when there are too few to make a turn (the server asks for 8).
  static List<MediaItem> framesOf(Listing l) {
    if (l.frames.length < 8) return const [];
    final plan = ShowcasePlan.of(l);
    final turn = plan.steps.first.media.take(plan.turn).toList();
    if (turn.length <= maxFrames) return turn;
    return [for (var i = 0; i < maxFrames; i++) turn[i * turn.length ~/ maxFrames]];
  }

  @override
  State<CardTurn> createState() => _CardTurnState();
}

class _CardTurnState extends State<CardTurn> with SingleTickerProviderStateMixin {
  late List<MediaItem> _frames;
  late bool _cut;
  late bool _shadow;

  /// Where the turn is, in frames; null until the first drag.
  double? _at;

  /// A frame has been decoded: from then on the last one stays while the next decodes.
  bool _decoded = false;
  bool _precached = false;
  late final AnimationController _coast = AnimationController.unbounded(vsync: this)..addListener(_follow);

  @override
  void initState() {
    super.initState();
    _plan();
  }

  @override
  void didUpdateWidget(CardTurn old) {
    super.didUpdateWidget(old);
    if (old.listing.id != widget.listing.id || old.listing.media.length != widget.listing.media.length) {
      // A reused card is another shoe: back to its cover.
      _coast.stop();
      _at = null;
      _decoded = false;
      _precached = false;
      _plan();
    }
  }

  void _plan() {
    _frames = CardTurn.framesOf(widget.listing);
    // As on the listing page: cut-outs only when every frame has one, so the shoe never changes look mid-turn.
    _cut = _frames.isNotEmpty && _frames.every((m) => m.processedUrl != null);
    _shadow = _cut && !ShowcasePlan.of(widget.listing).scan; // a scan's frames carry their own floor shadow
  }

  @override
  void dispose() {
    _coast.dispose();
    super.dispose();
  }

  ImageProvider _image(MediaItem m) {
    final small = m.thumbUrl != null && (_cut || m.processedUrl == null);
    return ResizeImage.resizeIfNeeded(
        CardTurn.decodeWidth, null, NetworkImage(small ? m.thumbUrl! : (_cut ? m.url : m.originalUrl)));
  }

  void _start(DragStartDetails _) {
    _coast.stop();
    _at ??= 0;
    if (!_precached) {
      _precached = true;
      for (final m in _frames) {
        precacheImage(_image(m), context, onError: (_, __) {});
      }
    }
  }

  /// The same feel as the listing page: one and a half card widths turn the shoe once round.
  double _framesPerPixel(double width) => _frames.length / (width * 1.5);

  void _move(DragUpdateDetails d, double width) {
    setState(() => _at = (_at! - d.delta.dx * _framesPerPixel(width)) % _frames.length);
  }

  void _end(DragEndDetails d, double width) {
    final speed = -d.velocity.pixelsPerSecond.dx * _framesPerPixel(width); // frames per second
    if (speed.abs() < 4) return;
    _coast.value = _at!;
    _coast.animateWith(FrictionSimulation(0.12, _at!, speed.clamp(-90, 90)));
  }

  void _follow() => setState(() => _at = _coast.value % _frames.length);

  @override
  Widget build(BuildContext context) {
    if (_frames.isEmpty) return widget.cover;
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth;
      final at = _at;
      return GestureDetector(
        key: const Key('card-turn'),
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down, // the shoe follows the whole move of the finger
        onHorizontalDragStart: _start,
        onHorizontalDragUpdate: (d) => _move(d, width),
        onHorizontalDragEnd: (d) => _end(d, width),
        child: at == null ? widget.cover : _frame(_frames[math.min(at.floor(), _frames.length - 1)]),
      );
    });
  }

  Widget _frame(MediaItem m) {
    final image = _image(m);
    return Stack(fit: StackFit.expand, children: [
      if (_shadow) ContactShadow(image: image, fit: BoxFit.cover, gapless: true),
      Image(
        key: const Key('card-turn-frame'),
        image: image,
        fit: BoxFit.cover,
        gaplessPlayback: true, // the last frame stays until the next is decoded: the shoe never blinks out
        // Until the first frame is decoded the cover stays, so there is never an empty card or two shoes at once.
        // Later frames may report no frame while decoding, but gapless playback still draws the previous one.
        frameBuilder: (_, child, frame, sync) {
          if (frame != null || sync) _decoded = true;
          return _decoded ? child : widget.cover;
        },
        errorBuilder: (_, __, ___) => widget.cover,
      ),
    ]);
  }
}
