import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../net_image.dart';
import 'studio.dart';

/// A catalog card's shoe that turns under a sideways finger, through small pictures of its 3D a full turn round
/// (Aza, 2026-10-24: "кішініде үлкендініде саусақпен бұратындай болу керек"), as the card turned before the 3D came.
/// When the finger lifts, the shoe turns back the short way to its cover, so the grid always shows the covers.
/// An up-and-down drag still scrolls the catalog.
class CardTurn extends StatefulWidget {
  const CardTurn({super.key, required this.frames, required this.cover});

  /// The turn's pictures, the first the same view as the cover.
  final List<String> frames;
  final Widget cover;

  /// The fewest pictures that make a turn: fewer would jump.
  static const minFrames = 8;

  /// The shortest drag, in logical pixels, that turns a shoe once round, so a narrow card does not spin at a touch.
  static const minTurnDrag = 240.0;

  /// The drag that turns a card [width] wide once round.
  static double turnDrag(double width) => math.max(width * 1.5, minTurnDrag);

  /// Where the pictures are fetched from; tests replace it.
  @visibleForTesting
  static ImageProvider Function(String url) network = netImage;

  @override
  State<CardTurn> createState() => _CardTurnState();
}

class _CardTurnState extends State<CardTurn> with SingleTickerProviderStateMixin {
  double? _at; // how far round the shoe is, in turns; null shows the cover
  double _from = 0;
  final _ready = <int>{}; // the pictures decoded and in the cache
  bool _fetched = false;
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 320))
    ..addListener(() => setState(() => _at = _from * (1 - Curves.easeOut.transform(_back.value))))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _rest();
    });

  ImageProvider _frame(int i) => ResizeImage.resizeIfNeeded(400, null, CardTurn.network(widget.frames[i]));

  /// The picture for where the shoe is, or the nearest one already here: the shoe never blinks out while the rest
  /// come down. Null before any has come: the cover stays.
  int? get _shown {
    final n = widget.frames.length;
    final want = ((_at! % 1) * n).round() % n;
    for (var d = 0; d <= n ~/ 2; d++) {
      if (_ready.contains((want + d) % n)) return (want + d) % n;
      if (_ready.contains((want - d) % n)) return (want - d) % n;
    }
    return null;
  }

  @override
  void dispose() {
    _back.dispose();
    _forget();
    super.dispose();
  }

  /// Small pictures, fetched from the first touch: the few next to the cover at once, the rest when the finger
  /// moves sideways, so scrolling past a card costs little. Nearest the cover first.
  final _asked = <int>{};
  void _fetch({required bool all}) {
    _fetched = true;
    final n = widget.frames.length;
    final order = [
      for (var d = 0; d <= n ~/ 2; d++) ...{d % n, (n - d) % n}
    ];
    for (final i in all ? order : order.take(5)) {
      if (!_asked.add(i)) continue;
      var ok = true;
      precacheImage(_frame(i), context, onError: (_, __) => ok = false).then((_) {
        if (ok && mounted && _asked.contains(i)) setState(() => _ready.add(i));
      });
    }
  }

  /// Back at the cover: the turn's pictures leave memory (24 decoded pictures a card would crowd out the grid's
  /// covers); the phone keeps the files, so the next turn decodes them again quickly.
  void _rest() {
    setState(() => _at = null);
    _forget();
  }

  void _forget() {
    if (!_fetched) return;
    _fetched = false;
    _ready.clear();
    for (final i in _asked) {
      _frame(i).evict();
    }
    _asked.clear();
  }

  void _end() {
    final at = _at;
    if (at == null) return;
    _from = at - at.roundToDouble(); // the short way back, at most half a turn
    if (MediaQuery.disableAnimationsOf(context) || _from.abs() < 1e-3) {
      _rest();
    } else {
      _back.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _at == null ? null : _shown;
    return LayoutBuilder(
      builder: (context, box) => Listener(
        onPointerDown: (_) => _fetch(all: false),
        // A tap or a scroll, not a turn: nothing kept.
        onPointerUp: (_) => _at == null ? _forget() : null,
        onPointerCancel: (_) => _at == null ? _forget() : null,
        child: GestureDetector(
          // The card itself is read out and opened as one; turning is for the eye.
          excludeFromSemantics: true,
          onHorizontalDragStart: (_) {
            _back.stop();
            _fetch(all: true);
            setState(() => _at ??= 0);
          },
          onHorizontalDragUpdate: (d) =>
              setState(() => _at = (_at ?? 0) + d.delta.dx / CardTurn.turnDrag(box.maxWidth)),
          onHorizontalDragEnd: (_) => _end(),
          onHorizontalDragCancel: _end,
          child: shown == null
              ? widget.cover
              : Stack(key: const Key('card-turn'), fit: StackFit.expand, children: [
                  ContactShadow(image: _frame(shown), fit: BoxFit.cover, gapless: true),
                  Image(
                      image: _frame(shown),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      excludeFromSemantics: true,
                      errorBuilder: (_, __, ___) => widget.cover),
                ]),
        ),
      ),
    );
  }
}
