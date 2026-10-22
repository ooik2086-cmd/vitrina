import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../api.dart';

/// The colours of the stage, taken from the approved Scroll 3D demo page: a light studio for dark shoes and a dark
/// one for light shoes. [ink] is the backdrop, [halo] the soft light behind the shoe, the rest are for the controls.
class ShowcaseScene {
  const ShowcaseScene._(this.ink, this.panel, this.line, this.fg, this.muted, this.glow, this.halo);
  final Color ink, panel, line, fg, muted, glow, halo;

  static const light = ShowcaseScene._(Color(0xFFE8E6EE), Color(0xFFF7F6FA), Color(0xFFD3D0DE), Color(0xFF17161D),
      Color(0xFF5E5B72), Color(0xFF6D5BD0), Color(0xF2FFFFFF)); // muted: 4.5:1 on the photo's light backdrop too
  static const dark = ShowcaseScene._(Color(0xFF0E0E14), Color(0xFF17161F), Color(0xFF2A2836), Color(0xFFECEBF3),
      Color(0xFF9A97AB), Color(0xFFB9A8FF), Color(0x4D9684E6));
}

/// Whether controls on [ground] read better in the dark scene's light ink than in the light scene's dark ink: the
/// pair with the higher contrast ratio wins, so a mid-tone ground never gets ink that hardly shows.
bool darkerScene(Color ground) {
  double ratio(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  return ratio(ShowcaseScene.dark.fg, ground) > ratio(ShowcaseScene.light.fg, ground);
}

/// The average colour of the outermost two pixels of an RGBA image: the background a photo was taken on.
Color edgeColour(ByteData rgba, int width, int height) {
  var r = 0, g = 0, b = 0, n = 0;
  void add(int x, int y) {
    final i = (y * width + x) * 4;
    r += rgba.getUint8(i);
    g += rgba.getUint8(i + 1);
    b += rgba.getUint8(i + 2);
    n++;
  }

  for (var d = 0; d < 2 && d < height && d < width; d++) {
    for (var x = 0; x < width; x++) {
      add(x, d);
      add(x, height - 1 - d);
    }
    for (var y = 2; y < height - 2; y++) {
      add(d, y);
      add(width - 1 - d, y);
    }
  }
  if (n == 0) return const Color(0xFFFFFFFF);
  return Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
}

/// One part of a listing's frames: the turn, then the top, the sole and a close-up.
class ShowcaseStep {
  ShowcaseStep(this.kind, this.media) : cut = media.every((m) => m.processedUrl != null);
  final String kind; // spin | top | sole | close
  final List<MediaItem> media;

  /// Cut-outs are shown only when every photo of the step has one, so the shoe never jumps between a cut-out on
  /// the backdrop and a photo with its own background in the middle of a turn.
  final bool cut;
}

/// How a shared angle, where 0 is the outer side, 0.25 the toe, 0.5 the inner side and 0.75 the heel, falls on
/// one shoe's turn (as a share of it, from its first frame). Sellers turn the shoe either way and not always
/// evenly, so the turn is laid through the frames known to show a side square on ([marks]: angle to share), the
/// way round they come; between them it is spread evenly. Without marks, the turn is taken to start at the outer
/// side and go the usual way.
class TurnMap {
  factory TurnMap(Map<double, double> marks) {
    final angles = marks.keys.toList()..sort();
    if (angles.length < 2) {
      final a = angles.firstOrNull ?? 0;
      return TurnMap._([a], [marks[a] ?? 0], 1, sided: false);
    }
    final shares = [for (final a in angles) marks[a]!];
    // The way round in which the marks come in the order of their sides; when both fit (two marks), the one
    // whose spacing is nearer the sides' own. Two opposite sides fit both ways equally: the way is then a guess.
    double? bestCost;
    var way = 0, tied = false;
    for (final w in [1, -1]) {
      var total = 0.0, cost = 0.0;
      for (var k = 0; k < angles.length; k++) {
        final n = (k + 1) % angles.length;
        final gap = (w * (shares[n] - shares[k])) % 1;
        total += gap;
        cost += (gap - (angles[n] - angles[k]) % 1).abs();
      }
      if ((total - 1).abs() > 1e-9) continue;
      if (bestCost != null && (cost - bestCost).abs() < 1e-6) {
        tied = true;
      } else if (bestCost == null || cost < bestCost) {
        (bestCost, way, tied) = (cost, w, false);
      }
    }
    // Marks that contradict each other (a front matched to the heel): only the first is kept.
    if (way == 0) return TurnMap._([angles.first], [shares.first], 1, sided: false);
    return TurnMap._(angles, shares, way, sided: !tied);
  }

  /// The marks of [listing] on [turn] (its frames from the first shown): the frames the server matched to its side
  /// photos, else the cover where the turn starts [atCover].
  factory TurnMap.over(Listing listing, List<MediaItem> turn, {required bool atCover}) {
    final marks = <double, double>{};
    for (final MapEntry(key: side, value: url) in listing.angleFrames.entries) {
      final angle = sides[side];
      final i = turn.indexWhere((m) => m.originalUrl == url);
      if (angle != null && i >= 0) marks[angle] = i / turn.length;
    }
    final cover = sides[listing.media.where((m) => m.angle != 'frame').firstOrNull?.angle];
    if (atCover && cover != null) marks.putIfAbsent(cover, () => 0);
    return TurnMap(marks);
  }

  const TurnMap._(this._angles, this._shares, this._way, {required this.sided});
  final List<double> _angles;
  final List<double> _shares;
  final int _way;

  /// Whether at least two sides are known that settle which way the turn goes (two opposite sides do not), so
  /// the way and how evenly it goes are known, not assumed. The cover's side counts when the turn starts at it.
  final bool sided;

  static const sides = {'outer': 0.0, 'front': 0.25, 'inner': 0.5, 'back': 0.75};

  double _angleGap(int k) => _angles.length == 1 ? 1 : (_angles[(k + 1) % _angles.length] - _angles[k]) % 1;
  double _shareGap(int k) => _angles.length == 1 ? 1 : (_way * (_shares[(k + 1) % _shares.length] - _shares[k])) % 1;

  /// Where in the turn (a share from its first frame) the shared [angle] falls.
  double place(double angle) {
    for (var k = 0; k < _angles.length; k++) {
      final d = (angle - _angles[k]) % 1;
      if (d < _angleGap(k) || k == _angles.length - 1) {
        return (_shares[k] + _way * d / _angleGap(k) * _shareGap(k)) % 1;
      }
    }
    return angle % 1;
  }

  /// The shared angle at [share] of the turn: the inverse of [place].
  double angle(double share) {
    for (var k = 0; k < _angles.length; k++) {
      final d = (_way * (share - _shares[k])) % 1;
      if (d < _shareGap(k) || k == _angles.length - 1) {
        return (_angles[k] + d / _shareGap(k) * _angleGap(k)) % 1;
      }
    }
    return share % 1;
  }
}

/// How a listing's frames make its turn (a catalog card turns its shoe through them, the order page too): the frames
/// in order, then the top and sole photos and the close-up. Only real photos: nothing is generated or blended.
class ShowcasePlan {
  /// How many widths of the shoe's picture a sideways drag goes to turn a catalog card's shoe once round.
  static const turnWidths = 1.5;

  ShowcasePlan(this.steps, {this.scan = false, int? turn}) : turn = turn ?? turnOf(steps.first.media);

  /// The frames in order, then the top and sole photos and the close-up (stitching, logo), each only when the
  /// seller took it.
  ///
  /// A scan is one continuous camera move: the turn, then on up over the top, under the sole and in close. Its stop
  /// photos are frames of that move, so each stop starts at its own frame and carries the frames that move on
  /// towards the next one.
  factory ShowcasePlan.of(Listing l) {
    final frames = l.frames;
    MediaItem? first(String angle) => l.media.where((m) => m.angle == angle).firstOrNull;
    final stops = [
      for (final (kind, angle) in const [('top', 'top'), ('sole', 'sole'), ('close', 'detail')])
        if (first(angle) case final m?) (kind: kind, photo: m),
    ];
    final at = [for (final s in stops) frames.indexWhere((f) => f.originalUrl == s.photo.originalUrl)];
    var scan = stops.isNotEmpty && at.first > 0;
    for (var i = 1; i < at.length && scan; i++) {
      scan = at[i] > at[i - 1];
    }
    if (scan) {
      ShowcaseStep part(String kind, int from, int to) => ShowcaseStep(kind, frames.sublist(from, to));
      return ShowcasePlan([
        part('spin', 0, at.first),
        for (var i = 0; i < stops.length; i++)
          part(stops[i].kind, at[i], i + 1 < at.length ? at[i + 1] : frames.length),
      ], scan: true);
    }
    // The turn starts at the frame that shows the shoe as the cover does, so the cover turns on from the same view.
    // It is found in the order taken, as the server finds it (one_turn): frames taken after it keep their place.
    final k = turnOf(frames);
    final start = math.max(0, frames.take(k).toList().indexWhere((f) => f.originalUrl == l.coverFrame));
    final turn = [...frames.sublist(start, k), ...frames.take(start), ...frames.skip(k)];
    return ShowcasePlan([
      ShowcaseStep('spin', turn),
      for (final s in stops) ShowcaseStep(s.kind, [s.photo]),
    ], turn: k);
  }

  /// Made from one continuous scan: its frames carry their own margin and floor shadow.
  final bool scan;

  /// Frames in one full turn, at the start of the first step.
  final int turn;

  /// Frames in one full turn of frames as taken: up to where the first comes round again (a scan carries on past it
  /// to the stops), or all of them.
  static int turnOf(List<MediaItem> f) {
    for (var k = 1; k < f.length; k++) {
      if (f[k].originalUrl == f.first.originalUrl) return k;
    }
    return f.length;
  }

  final List<ShowcaseStep> steps;
}
