import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../net_image.dart';
import '../api.dart';
import '../i18n.dart';
import 'spin_viewer.dart' show showcaseBackground;
import 'color_choice.dart';
import 'studio.dart';

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

/// A round light, fading out to nothing at its edge, filling the square the shoe is drawn in less 6% on each side.
class _Halo extends CustomPainter {
  _Halo(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide * 0.44;
    final c = size.center(Offset.zero);
    canvas.drawCircle(c, r, Paint()..shader = ui.Gradient.radial(c, r, [color, color.withValues(alpha: 0)]));
  }

  @override
  bool shouldRepaint(_Halo old) => old.color != color;
}

/// One stop of the showcase: the turn made of 360° frames, then the top, the sole and a close-up.
class ShowcaseStep {
  ShowcaseStep(this.kind, this.media, this.weight) : cut = media.every((m) => m.processedUrl != null);
  final String kind; // spin | top | sole | close
  final List<MediaItem> media;

  /// Share of the scroll this step takes, in frame units.
  final double weight;

  /// Cut-outs are shown only when every photo of the step has one, so the shoe never jumps between a cut-out on
  /// the backdrop and a photo with its own background in the middle of a turn.
  final bool cut;

  String get label => switch (kind) {
        'spin' => '360°',
        'top' => tr('Үстінен'),
        'sole' => tr('Табаны'),
        _ => tr('Жақыннан'),
      };
}

/// What the showcase shows, as ShowcasePlan.viewAt describes it.
typedef ShowcaseView = ({String kind, double at});

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

  /// The marks of [listing] on the turn its listing page shows.
  factory TurnMap.of(Listing listing) {
    final plan = ShowcasePlan.of(listing);
    final turn = plan.turnFrames;
    final first = turn.firstOrNull;
    final atCover =
        !plan.scan && first != null && (first.originalUrl == listing.coverFrame || first.url == listing.coverUrl);
    return TurnMap.over(listing, turn, atCover: atCover);
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

/// Which photo shows at a given scroll position. Only real photos are shown: nothing is generated or blended.
class ShowcasePlan {
  /// How many widths of the shoe's picture a sideways drag goes to turn a catalog card's shoe once round, and the
  /// measure of a flick's coast on the listing page. The listing page's drag itself turns at the demo page's rate
  /// (ScrollShowcaseState.turnDrag).
  static const turnWidths = 1.5;

  ShowcasePlan(this.steps, {this.scan = false, int? turn})
      : total = steps.fold(0.0, (sum, s) => sum + s.weight),
        turn = turn ?? turnOf(steps.first.media);

  /// The frames in order, then the top and sole photos and the close-up (stitching, logo), each only when the
  /// seller took it.
  ///
  /// A scan is one continuous camera move: the turn, then on up over the top, under the sole and in close. Its stop
  /// photos are frames of that move, so each stop starts at its own frame and carries the frames that move on
  /// towards the next one, and every frame takes the same share of the scroll.
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
      // The same total as photo stops (2 for the turn, 1 per stop), spread evenly over the frames.
      final perFrame = (2 + stops.length) / frames.length;
      ShowcaseStep part(String kind, int from, int to) =>
          ShowcaseStep(kind, frames.sublist(from, to), (to - from) * perFrame);
      return ShowcasePlan([
        part('spin', 0, at.first),
        for (var i = 0; i < stops.length; i++)
          part(stops[i].kind, at[i], i + 1 < at.length ? at[i + 1] : frames.length),
      ], scan: true);
    }
    // The turn starts at the frame that shows the shoe as the cover does, so the cover flies into the same view. It is
    // found in the order taken, as the server finds it (one_turn): frames taken after it keep their place.
    final k = turnOf(frames);
    final start = math.max(0, frames.take(k).toList().indexWhere((f) => f.originalUrl == l.coverFrame));
    final turn = [...frames.sublist(start, k), ...frames.take(start), ...frames.skip(k)];
    // Twice as much scrolling for the whole turn as for each stop: see ScrollShowcase.travelFor.
    return ShowcasePlan([
      ShowcaseStep('spin', turn, 2),
      for (final s in stops) ShowcaseStep(s.kind, [s.photo], 1),
    ], turn: k);
  }

  /// Made from one continuous scan: its frames carry their own margin and floor shadow.
  final bool scan;

  /// The frames of one full turn, in the order the page shows them.
  List<MediaItem> get turnFrames => steps.first.media.take(turn).toList();

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

  double _upTo(int step, int frame) =>
      steps.take(step).fold(0.0, (sum, s) => sum + s.weight) + steps[step].weight * frame / steps[step].media.length;

  /// Where a photo sits on the stop line: 0 at the first photo, 1 at the last, in the same measure the scroll uses.
  double along(int step, int frame) {
    final end = _upTo(steps.length - 1, steps.last.media.length - 1);
    return end <= 0 ? 0 : _upTo(step, frame) / end;
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

  /// What the stage shows at [progress], so another colour of the model can show the same: on the turn, where in
  /// it the frame shown is (0 to 1 from the turn's first frame; ScrollShowcase.carry finds the same side on the
  /// other colour), else the stop (top, sole, close; on a scan, the move from it to the next).
  ShowcaseView? viewAt(double progress) {
    final shown = at(progress);
    final step = steps[shown.step];
    return (kind: step.kind, at: shown.frame / step.media.length);
  }

  /// The scroll progress that shows [view] here: the middle of the turn's frame nearest that place, or of the same
  /// stop (on a scan, the stop's own frame). Null without a turn or that stop.
  double? progressFor(ShowcaseView view) {
    for (var i = 0; i < steps.length; i++) {
      final n = steps[i].media.length;
      if (steps[i].kind != view.kind || n == 0) continue;
      // On a stop, how far into its move (a scan's stop carries on towards the next one); one photo has none.
      return centreOf(i, i == 0 ? (view.at * n).round() % n : math.min(n - 1, (view.at * n).floor()));
    }
    return null;
  }

  /// Scroll progress at which [step] begins.
  double startOf(int step) => steps.take(step).fold(0.0, (sum, s) => sum + s.weight) / total;

  /// Scroll progress in the middle of one photo, so moving there shows exactly that photo.
  double centreOf(int step, int frame) =>
      startOf(step) + steps[step].weight * (frame + 0.5) / steps[step].media.length / total;

  /// Where on the stop line the turn comes full round, when frames go on past it (a scan moving up to the top): the
  /// demo page marks it with a stop of its own. Null when the turn is all the first step shows.
  double? get turnEnd => turn > 0 && turn < steps.first.media.length ? along(0, turn) : null;

  /// The share of the scroll one full turn of frames takes.
  late final double turnShare =
      total <= 0 || steps.first.media.isEmpty ? 0 : steps.first.weight * turn / steps.first.media.length / total;

  /// The smallest share of the scroll one photo takes: the stage's glide stops within a fiftieth of it.
  late final double photoShare = [
    for (final s in steps)
      if (s.media.isNotEmpty && total > 0) s.weight / s.media.length / total
  ].fold(1.0, math.min);

  /// Every photo in showing order.
  late final List<({int step, int frame})> photos = [
    for (var i = 0; i < steps.length; i++)
      for (var f = 0; f < steps[i].media.length; f++) (step: i, frame: f)
  ];
}

/// The 360° showcase as a stretch of the page: while it scrolls past, the stage fills the screen and stays in
/// place, and the shoe turns frame by frame, then shows its top, sole and a close-up. Scrolling back turns it back.
/// Two fingers zoom the shoe up to 3× (the page stays put while zoomed, one finger then moves the picture), a
/// double tap zooms in or out, and 1× resets.
///
/// It must be the first thing in the list that [scroll] drives, so its top is at scroll offset 0. Touches reach it
/// through [ScrollShowcaseState.handlePointer] from a Listener around the list: a list that is scrolling ignores
/// the touches of its children, and a pinch usually starts while the first finger is still scrolling.
class ScrollShowcase extends StatefulWidget {
  const ScrollShowcase({
    super.key,
    required this.listing,
    required this.scroll,
    required this.stageHeight,
    this.onPhotos,
    this.onDetails,
    this.onLock,
    this.onStageTop,
    this.onStageBottom,
    this.onColor,
    this.pendingColor,
  });

  final Listing listing;
  final ScrollController scroll;

  /// Opens another colour of the model; its swatches sit beside the shoe when there is more than one colour.
  final ValueChanged<Colorway>? onColor;

  /// The colour picked and being fetched: its swatch shows that it is on its way.
  final int? pendingColor;

  /// The visible height of the list: the stage fills it while the shoe turns.
  final double stageHeight;

  /// Switches the page to the photos as taken; the stops row offers it so it is never a long scroll away.
  final VoidCallback? onPhotos;

  /// Skips the rest of the turn to the title, sizes and details below.
  final VoidCallback? onDetails;

  /// True while the page must not scroll: during a pinch and while zoomed in.
  final ValueChanged<bool>? onLock;

  /// How dark the stage under the status bar is; null when the stage has scrolled away from it.
  final ValueChanged<Brightness?>? onStageTop;

  /// How dark the stage is while it reaches down to the page's bottom bar, so the bar can take the scene's panel
  /// colour as on the demo page; null once the details below have come up under it.
  final ValueChanged<Brightness?>? onStageBottom;

  /// How far the page scrolls while the stage stays in place: 0.6 of the stage for the whole turn, so one ordinary
  /// swipe turns the shoe once round (a full screen per turn felt slow and heavy under the finger), and 0.3 per stop.
  static double travelFor(double stageHeight, int steps) => stageHeight * (0.6 + 0.3 * (steps - 1));

  /// The scroll offset at which [listing]'s page, on a stage this high, shows [view]; null when it cannot.
  static double? offsetFor(Listing listing, double stageHeight, ShowcaseView view) {
    final plan = ShowcasePlan.of(listing);
    final progress = plan.progressFor(view);
    return progress == null ? null : progress * travelFor(stageHeight, plan.steps.length);
  }

  /// The small copy the stage draws first for [view], the same provider, so fetching it ahead fills the cache the
  /// stage reads; null when [listing] cannot show it or has no small copy for it.
  static ImageProvider? firstImageAt(Listing listing, ShowcaseView view) {
    final plan = ShowcasePlan.of(listing);
    final progress = plan.progressFor(view);
    if (progress == null) return null;
    final shown = plan.at(progress);
    final step = plan.steps[shown.step];
    final m = step.media[shown.frame];
    if (m.thumbUrl == null || !(step.cut || m.processedUrl == null)) return null;
    return ScrollShowcaseState.smallCopy(m.thumbUrl!, ScrollShowcaseState.smallSide(plan.photos.length));
  }

  /// [view] of [from] as [to] shows it: the same side of the turn when both turns' sides are known, else the
  /// same frame when both turns start at the same side; the same stop. Null when [to] cannot show it. A scan's
  /// turn starts wherever the camera did, so on a scan the turn carries only through known sides.
  static ShowcaseView? carry(ShowcaseView view, Listing from, Listing to) {
    if (view.kind != 'spin') return view;
    final p = ShowcasePlan.of(from), q = ShowcasePlan.of(to);
    final n = q.steps.first.media.length;
    // view.at counts all the turn step's frames; a scan's step carries on past its turn, rising over the top.
    final m = p.steps.first.media.length;
    var frame = (view.at * m).round();
    if (frame > p.turn) {
      final rise = (frame - p.turn) / (m - p.turn);
      // Another scan: the same place on its rise. Photos: still the side early on, the top once well up.
      if (q.scan && n > q.turn) return (kind: 'spin', at: (q.turn + (rise * (n - q.turn)).round()) / n);
      final next = p.steps.length > 1 ? p.steps[1].kind : null;
      if (rise >= 0.5) {
        return next == null || q.progressFor((kind: next, at: 0)) == null ? null : (kind: next, at: 0.0);
      }
      frame = 0;
    }
    if (!mayCarry(view, from) || !TurnMap.of(to).sided || n == 0) {
      return !p.scan && !q.scan && turnsAlike(from, to) ? view : null;
    }
    // In the other turn's own frames, kept within its turn (a scan's step goes on past it).
    final share = (frame % p.turn) / p.turn;
    int inTurn(double s) => (s * q.turn).round() % q.turn;
    final at = inTurn(TurnMap.of(to).place(TurnMap.of(from).angle(share)));
    // Within a frame of the same place, the same place: the side matched on the other colour can sit a frame
    // before its first, which would otherwise send the page to the far end of the turn.
    final same = inTurn(share);
    final apart = (at - same).abs();
    return (kind: 'spin', at: (math.min(apart, q.turn - apart) <= 1 ? same : at) / n);
  }

  /// Whether a turn [view] of [from] can carry to another colour at all: a scan's turn starts wherever the camera
  /// did, so only through its known sides. Otherwise the colour opens at its cover without waiting for it.
  static bool mayCarry(ShowcaseView view, Listing from) =>
      view.kind != 'spin' || !ShowcasePlan.of(from).scan || TurnMap.of(from).sided;

  /// Whether the same place in two colours' turns is the same angle: both turns start at the frame the server or
  /// the seller matched to the cover, and both covers show the same side of the shoe.
  static bool turnsAlike(Listing a, Listing b) {
    bool anchored(Listing l) => l.coverFrame != null && l.frames.any((f) => f.originalUrl == l.coverFrame);
    final side = a.photos.firstOrNull?.angle;
    return anchored(a) && anchored(b) && side != null && side == b.photos.firstOrNull?.angle;
  }

  @override
  State<ScrollShowcase> createState() => ScrollShowcaseState();
}

class ScrollShowcaseState extends State<ScrollShowcase>
    with TickerProviderStateMixin, WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  // Kept while the page scrolls far down to the details, so coming back up finds its small copies decoded.
  @override
  bool get wantKeepAlive => true;

  late ShowcasePlan _plan;
  late bool _light;
  bool _settled = true;

  /// The full photo laid over the small copies now (null while the shoe moves or with no small copy under it), and
  /// that same photo once it has been drawn: from then on the small copy under it is not drawn, its shadow is.
  ImageProvider? _laid;
  ImageProvider? _sharpDrawn;

  /// Tells the small copies' painter the full photo over it came or went, without building anything.
  final _cover = ValueNotifier<int>(0);

  /// Whether the small copy under the full photo is left out now (its shadow stays).
  @visibleForTesting
  bool get smallHidden => _laid != null && _sharpDrawn == _laid;
  Timer? _settle;

  /// The photo on the stage: the one at [_pos], which follows the page with a short glide.
  ({int step, int frame}) _shown = (step: 0, frame: 0);

  /// Where the stage is, in scroll progress. Every screen refresh it eases toward where the page is, as on the demo
  /// page, so uneven scroll events make an even turn; only real frames are drawn, the one at this place.
  double _pos = 0;
  late final Ticker _glide = createTicker(_glideTick);
  Duration? _lastGlide;
  bool _turning = false; // the page jumps because a finger turns the shoe on the stage: that glides too
  bool _seam = false; // a finger took the shoe round its turn's end while the stage glides after it

  /// Tells the stage's painter to draw again: the shoe moved on a frame, or a small copy it waited for arrived.
  final _drawn = ValueNotifier<int>(0);
  bool _precached = false;
  // The last full photos shown, newest last, as on the demo page. Older ones are dropped from memory, but going back
  // to a photo just seen, or zooming out, finds it ready. The image cache's own limit still caps the memory.
  final _recentFull = <ImageProvider>[];
  static const _keepFull = 24;
  int? _jumpingTo; // a stop button was tapped: tick once on arrival, not for every stop passed
  bool _jumping = false; // while a stop button's jump animates the page there
  bool _jumpingToEnd = false; // the jump goes to the turn's end mark, not to the start of [_jumpingTo]
  /// How often the stage was built; tests check that scrolling within one frame does not rebuild it.
  @visibleForTesting
  int builds = 0;
  static bool _hinted = false; // the short turn that shows scrolling turns the shoe, once per app run
  bool _hinting = false;

  final _viewer = GlobalKey();
  final _pin = GlobalKey();

  // Zoom and pan. The page is held still while two fingers are down or the picture is zoomed in.
  final _pointers = <int, Offset>{};
  double _scale = 1, _pinchStartScale = 1, _pinchStartDistance = 0;
  Offset _pan = Offset.zero, _pinchStartPan = Offset.zero, _pinchStartMid = Offset.zero;
  double? _lockedOffset;
  Offset? _tapAt;

  double get _travel => ScrollShowcase.travelFor(widget.stageHeight, _plan.steps.length);

  /// What the stage shows now (ShowcasePlan.viewAt); null before the buyer scrolled, and while the first-show hint
  /// turns the shoe by itself.
  ShowcaseView? get view => _progress > 0 && !_hinting ? _plan.viewAt(_progress) : null;

  double get _progress {
    final s = widget.scroll;
    return s.hasClients ? (s.offset / _travel).clamp(0.0, 1.0) : 0;
  }

  bool get _zoomed => _scale > 1.05;

  @override
  void initState() {
    super.initState();
    _spin; // made now, not on first touch: making it in dispose, after the widget left the tree, is not allowed
    _glide;
    WidgetsBinding.instance.addObserver(this);
    _setUp();
    widget.scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hint();
      _reportTop();
    });
  }

  void _setUp() {
    _plan = ShowcasePlan.of(widget.listing);
    if (_spinSim != null) _stopSpin();
    _tiltBack.stop();
    _tilt = 0;
    _dropSmall(); // another listing or colour: the last one's copies would only take memory
    _light = widget.listing.backdrop != 'dark';
    if (_glide.isActive) _glide.stop();
    _seam = false;
    _pos = _progress;
    _shown = _plan.at(_pos);
    _scale = 1;
    _pan = Offset.zero;
    _photoEdge = null;
  }

  static String _signature(Listing l) =>
      [l.backdrop, l.coverFrame, for (final m in l.media) '${m.url}|${m.thumbUrl}'].join(',');

  @override
  void didUpdateWidget(ScrollShowcase oldWidget) {
    final old = oldWidget;
    super.didUpdateWidget(oldWidget);
    if (old.scroll != widget.scroll) {
      old.scroll.removeListener(_onScroll);
      widget.scroll.addListener(_onScroll);
    }
    // Another height (the phone turned, the window resized): the same scroll offset is another place in the turn.
    if (old.stageHeight != widget.stageHeight) {
      // This runs while the page is laid out, when the page must not be told to change: it hears once that is done.
      _reportLater = true;
      _land();
      _reportLater = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportTop()); // the stage's stretch has a new length
    }
    // The listing was reloaded with other photos (the seller replaced them): show the new ones, not the old plan.
    if (_signature(old.listing) != _signature(widget.listing)) {
      _setUp();
      _precached = false;
      _precache();
      _setLock();
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportTop()); // the page is building now
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Covered by another page: the ticker is muted, and the shoe would jump to the spin's end when it came back. Its
    // small copies are let go meanwhile, and decoded again when it comes back.
    final covered = !TickerMode.valuesOf(context).enabled;
    if (covered) _stopSpin();
    _setHidden(covered || _paused);
    _precache();
  }

  /// How wide the small copies the stage draws while the shoe moves are decoded: 400 px as on the demo page, or
  /// narrower when a very long scan's [photos] would not fit in about 140 MB (four bytes a pixel, square frames).
  /// Once the phone has said it is short of memory, every stage keeps within about 64 MB instead (about 280 px for
  /// a 205-frame scan), as the demo spec asks for weak phones.
  static int smallSide(int photos) {
    final budget = (shortOfMemory ? 64 : 140) << 20;
    return photos <= 0 ? 400 : math.min(400, math.sqrt(budget / 4 / photos).floor());
  }

  /// Set when the phone reported memory pressure, for the rest of the app's run.
  @visibleForTesting
  static bool shortOfMemory = false;

  /// A small copy as the stage decodes it, so fetching it ahead (ScrollShowcase.firstImageAt) is what it finds.
  static ImageProvider smallCopy(String url, int side) => ResizeImage.resizeIfNeeded(side, null, smallSource(url));

  /// Where the small copies come from; tests replace it with pictures that decode.
  @visibleForTesting
  static ImageProvider Function(String url) smallSource = netImage;

  /// Where a photo is fetched at screen size when it has no small copy to scroll with; tests replace it.
  @visibleForTesting
  static ImageProvider Function(String url) screenSize = netImage;

  /// Where the full photo laid over the stage at rest comes from; tests replace it.
  @visibleForTesting
  static ImageProvider Function(String url) fullSource = netImage;

  /// How many frames either side of the one shown are fetched ahead when they have no small copy. Fetching every
  /// one of them at screen size on arrival cost megabytes of mobile data, and the decoded photos, a few megabytes
  /// each, did not fit the image cache anyway: most were dropped again before they were shown.
  static const fullAhead = 3;

  /// What the stage draws for a photo without a small copy: the photo decoded at screen size.
  ImageProvider _base(MediaItem m, ShowcaseStep step) {
    final width = (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round();
    return ResizeImage.resizeIfNeeded(math.min(2000, width), null, screenSize(step.cut ? m.url : m.originalUrl));
  }

  /// The small copies the stage draws while the shoe moves, by address: all decoded when the page opens and held
  /// here, outside the image cache. The cache dropped some of a scan's frames to make room and decoded them again
  /// mid-turn, which is where the turn stuttered; the sharper copies swapped in mid-turn made it flicker. They are let
  /// go, all but the one on the stage, while another page covers this one, the app is in the background or the
  /// phone is short of memory, and decoded again (from the copies kept on the phone) when it comes back.
  final _smalls = <String, ui.Image>{};

  /// The shadows a seller's cut-out turn stands on, made from those copies.
  final _shadows = <String, MadeShadow>{};

  /// Small copies still to ask for, by where each first comes in showing order, and those asked for now.
  final _waiting = <String, int>{};
  final _asking = <String>{};

  /// How many at a time: the frames the buyer reaches next come first instead of sharing a weak connection with two
  /// hundred others, as the catalog cards' turns do.
  static const decodeAtOnce = 6;

  /// Small copies that did not come, with how many tries and when the last one failed. Such a photo is drawn as one
  /// without a small copy (the photo itself at screen size, or the missing-photo mark), never as another photo, and
  /// is asked for again a few seconds later, and again whenever the shoe comes to it.
  final _failedSmall = <String, ({int tries, DateTime at})>{};
  Timer? _retry;
  static const _retryAfter = [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 15)];

  int _smallsFor = 0; // the decoding under way: a reload or another colour starts again and the old one's are let go
  int _side = 400;
  String? _drawnUrl; // the small copy drawn last: it stays until the next one is there, so the shoe never blinks out
  bool _hidden = false; // another page covers this one, or the app is in the background

  /// Lets every small copy go but [keep]'s, and stops asking for more.
  void _dropSmall({String? keep}) {
    _smallsFor++;
    _retry?.cancel();
    _retry = null;
    _waiting.clear();
    _asking.clear();
    _failedSmall.clear();
    for (final e in _smalls.entries) {
      if (e.key != keep) e.value.dispose();
    }
    for (final e in _shadows.entries) {
      if (e.key != keep) e.value.image.dispose();
    }
    _smalls.removeWhere((url, _) => url != keep);
    _shadows.removeWhere((url, _) => url != keep);
    if (_drawnUrl != keep) _drawnUrl = null;
  }

  /// Lets the small copies go, all but the one on the stage so the page still shows its shoe: for another colour
  /// opening in its place, whose own copies would otherwise be decoded while these are still held.
  void release() => _dropSmall(keep: _drawnUrl ?? _smallUrl(_tilted ?? _shown));

  /// Asks for every small copy of the plan not held yet, a few at a time, nearest the shoe first.
  void _decodeSmall() {
    if (_hidden) return;
    final photos = _plan.photos;
    _side = smallSide(photos.length);
    for (var i = photos.length - 1; i >= 0; i--) {
      final s = _plan.steps[photos[i].step];
      final m = s.media[photos[i].frame];
      if (_small(m, s) && !_smalls.containsKey(m.thumbUrl)) _waiting[m.thumbUrl!] = i; // where it first comes
    }
    _askMore();
  }

  /// Starts the next small copies, each time the one nearest where the page is: a buyer who scrolls ahead, or a colour
  /// opened part way round, gets the frames there first.
  void _askMore() {
    if (!mounted || _hidden) return;
    final photos = _plan.photos;
    final here = math.max(0, photos.indexOf(_target));
    final turn = _plan.turn;
    int apart(int i) {
      final d = (i - here).abs();
      // Round the turn too: its last frame is next to its first.
      return here < turn && i < turn && photos[here].step == 0 && photos[i].step == 0 ? math.min(d, turn - d) : d;
    }

    // A scan turns in 80 frames, twice a plain turn's: every other frame of it comes first, so on a slow connection
    // the whole turn is there in half the bytes (the nearest frame there is drawn in a gap) before the rest fill in.
    final coarse = _plan.scan && turn >= 80;
    int order(int i) => apart(i) + (coarse && i < turn && photos[i].step == 0 && i.isOdd ? turn ~/ 2 : 0);

    final config = createLocalImageConfiguration(context);
    while (_asking.length < decodeAtOnce && _waiting.isNotEmpty) {
      final next = _waiting.keys.reduce((a, b) => order(_waiting[a]!) <= order(_waiting[b]!) ? a : b);
      _waiting.remove(next);
      _ask(next, config);
    }
  }

  void _ask(String url, ImageConfiguration config) {
    final run = _smallsFor;
    final shadowed = _shadowed(_plan.steps[_plan.photos[_indexOf(url)].step]);
    final copy = smallCopy(url, _side);
    final cache = PaintingBinding.instance.imageCache;
    _asking.add(url);
    void next() {
      if (run != _smallsFor) return;
      _asking.remove(url);
      _askMore();
    }

    copy.obtainKey(config).then((key) {
      if (!mounted || run != _smallsFor) return;
      // A copy already in the cache is someone else's too (a catalog card turns the same frames): it stays there for
      // them. One this stage brought in is let go there once held here, or it would count twice against the limit.
      final theirs = cache.containsKey(key);
      final stream = copy.resolve(config);
      late final ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        stream.removeListener(listener);
        if (!theirs) cache.evict(key);
        if (!mounted || run != _smallsFor) return info.dispose();
        final image = _smalls[url] = info.image.clone();
        info.dispose();
        // It had failed before: the stage drew that photo itself, and now draws the copy again.
        _failedSmall.remove(url) == null ? _arrived(url) : setState(() {});
        next();
        if (!shadowed) return;
        silhouette(image).then((shadow) {
          if (!mounted || run != _smallsFor || !_smalls.containsKey(url)) return shadow.dispose();
          _shadows[url] = (image: shadow, photo: Size(image.width.toDouble(), image.height.toDouble()));
          _arrived(url);
        }, onError: (Object _) {});
      }, onError: (_, __) {
        stream.removeListener(listener);
        cache.evict(key); // not kept failed: asked again, it is fetched again
        if (!mounted || run != _smallsFor) return;
        final tries = (_failedSmall[url]?.tries ?? 0) + 1;
        _failedSmall[url] = (tries: tries, at: clock.now());
        if (url == _smallUrlOf(_tilted ?? _shown)) setState(() {}); // drawn now as a photo without a small copy
        if (tries <= _retryAfter.length) _retrySoon(_retryAfter[tries - 1]);
        next();
      });
      stream.addListener(listener);
    }, onError: (Object _) => next());
  }

  /// Asks again, after [wait], for the small copies that failed fewer than three times.
  void _retrySoon(Duration wait) {
    if (_retry != null) return;
    _retry = Timer(wait, () {
      _retry = null;
      if (!mounted) return;
      _failedSmall.forEach((url, f) {
        if (f.tries <= _retryAfter.length && !_asking.contains(url)) _waiting[url] = _indexOf(url);
      });
      _askMore();
    });
  }

  /// A copy that failed every try is asked for again when the shoe comes to it, at most every 15 s.
  void _retryShown() {
    final url = _smallUrlOf(_tilted ?? _shown);
    final failed = url == null ? null : _failedSmall[url];
    if (failed == null || failed.tries <= _retryAfter.length || _asking.contains(url) || _waiting.containsKey(url)) {
      return;
    }
    if (clock.now().difference(failed.at) < _retryAfter.last) return;
    _waiting[url!] = _indexOf(url);
    _askMore();
  }

  int _indexOf(String url) {
    final photos = _plan.photos;
    for (var i = 0; i < photos.length; i++) {
      if (_plan.steps[photos[i].step].media[photos[i].frame].thumbUrl == url) return i;
    }
    return 0;
  }

  /// Comes back to the page: covered by another page, or not, as the ticker says.
  void _setHidden(bool hidden) {
    if (hidden == _hidden) return;
    _hidden = hidden;
    if (hidden) return release();
    _decodeSmall();
  }

  @override
  void didHaveMemoryPressure() {
    // Smaller copies from now on, here and on every stage after: decoded again around the shoe at once.
    shortOfMemory = true;
    release();
    _decodeSmall();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _paused = true;
      _setHidden(true);
    } else if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      _setHidden(!TickerMode.valuesOf(context).enabled);
    }
  }

  bool _paused = false;

  /// A small copy came: the stage draws again if it is the one it wants, or it is drawing another one meanwhile.
  void _arrived(String url) {
    final want = _smallUrl(_tilted ?? _shown);
    if (want == url || _drawnUrl != want) _redraw();
  }

  void _redraw() => _drawn.value++;

  /// The address of the small copy for [at], or null when the stage draws that photo itself (it has none, or its
  /// copy did not come).
  String? _smallUrl(({int step, int frame}) at) {
    final url = _smallUrlOf(at);
    return url == null || _failedSmall.containsKey(url) ? null : url;
  }

  /// The address of [at]'s small copy, whether it came or not.
  String? _smallUrlOf(({int step, int frame}) at) {
    final s = _plan.steps[at.step];
    final m = s.media[at.frame];
    return _small(m, s) ? m.thumbUrl : null;
  }

  /// Whether the stage draws [m] from its small copy.
  bool _drawsSmall(MediaItem m, ShowcaseStep s) => _small(m, s) && !_failedSmall.containsKey(m.thumbUrl);

  /// The small copy the stage draws now, with its shadow: the photo's own, or while it is still on its way the
  /// nearest one of the same step that is there, or the one drawn last.
  ({ui.Image image, MadeShadow? shadow})? _drawable() {
    final at = _tilted ?? _shown;
    final s = _plan.steps[at.step];
    String? there(int f) =>
        f >= 0 && f < s.media.length && _smalls.containsKey(s.media[f].thumbUrl) ? s.media[f].thumbUrl : null;
    var url = there(at.frame);
    for (var d = 1; url == null && d < s.media.length; d++) {
      url = there(at.frame - d) ?? there(at.frame + d);
    }
    url ??= _smalls.containsKey(_drawnUrl) ? _drawnUrl : null;
    if (url == null) return null;
    _drawnUrl = url;
    return (image: _smalls[url]!, shadow: castsShadow ? _shadows[url] : null);
  }

  /// Whether the shoe on the stage now stands on a shadow of its own: a seller's cut-out turning on a light floor
  /// (a shadow would not show on a dark one, a scan's frames have theirs in them, the sole stands on nothing).
  @visibleForTesting
  bool get castsShadow {
    final s = _plan.steps[(_tilted ?? _shown).step];
    return _shadowed(s) && !_onDark(s) && !_zoomed;
  }

  /// The small copies the stage holds decoded now, by address.
  @visibleForTesting
  Map<String, ui.Image> get smallImages => Map.unmodifiable(_smalls);

  /// The address of the small copy the painter drew last.
  @visibleForTesting
  String? get paintedSmall => _drawnUrl;

  /// The shadows made from the small copies, by address.
  @visibleForTesting
  Map<String, MadeShadow> get smallShadows => Map.unmodifiable(_shadows);

  /// The address of the small copy the stage draws for the photo on it, even while that copy is on its way; null
  /// when the stage draws the photo itself.
  @visibleForTesting
  String? get drawnSmall => _smallUrl(_tilted ?? _shown);

  /// Whether the stage scrolls through [m]'s small copy rather than the photo itself.
  static bool _small(MediaItem m, ShowcaseStep step) => m.thumbUrl != null && (step.cut || m.processedUrl == null);

  void _fetch(MediaItem m, ShowcaseStep s) {
    precacheImage(_base(m, s), context, onError: (_, __) {});
    // The shadows too, so the first turn does not make one per frame while the finger moves.
    if (_shadowed(s)) ContactShadow.prepare(_base(m, s), createLocalImageConfiguration(context));
  }

  void _precache() {
    if (_precached) return;
    _precached = true;
    // The small copies scrolling shows are decoded first. Of photos without one: the first of each stop, where
    // scrolling on or a stop button lands (a stop is one photo, a scan's a few), and those near the shoe where the
    // page actually is (a colour opened at the same side starts part way round).
    _decodeSmall();
    for (var i = 1; i < _plan.steps.length; i++) {
      _fetchNear((step: i, frame: 0), ahead: 0);
    }
    _fetchNear(_plan.at(_progress));
    final first = _plan.steps.first;
    if (!first.cut && first.media.isNotEmpty) _sampleEdge(_base(first.media.first, first));
  }

  /// The photos without a small copy within [ahead] photos of [at] in showing order, either way, as the shoe may
  /// turn back, across the stops; on the turn also round it, as a sideways drag goes from its first frame
  /// straight to its last.
  void _fetchNear(({int step, int frame}) at, {int ahead = fullAhead}) {
    void fetch(int step, int frame) {
      final s = _plan.steps[step];
      if (!_drawsSmall(s.media[frame], s)) _fetch(s.media[frame], s);
    }

    final all = _plan.photos;
    final i = all.indexOf(at);
    for (var j = math.max(0, i - ahead); j <= math.min(all.length - 1, i + ahead); j++) {
      fetch(all[j].step, all[j].frame);
    }
    final turn = _plan.turn;
    if (at.step == 0 && _plan.steps.first.kind == 'spin' && at.frame < turn) {
      for (var d = 1; d <= ahead; d++) {
        fetch(0, (at.frame + d) % turn);
        fetch(0, (at.frame - d + turn) % turn);
      }
    }
  }

  /// The colour around the edge of the first photo as taken, for the stage behind such photos: on the studio
  /// gradient the photo's own background showed as a box.
  Color? _photoEdge;
  ImageStream? _edgeStream;
  ImageStreamListener? _edgeListener;

  void _sampleEdge(ImageProvider photo) {
    _stopSampling();
    final stream = photo.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      _stopSampling();
      final image = info.image;
      image.toByteData(format: ui.ImageByteFormat.rawRgba).then((data) {
        final colour = data == null ? null : edgeColour(data, image.width, image.height);
        info.dispose();
        if (mounted && colour != null) {
          setState(() => _photoEdge = colour);
          _reportTop();
        }
      }, onError: (Object _) => info.dispose());
    }, onError: (_, __) => _stopSampling());
    _edgeStream = stream..addListener(listener);
    _edgeListener = listener;
  }

  void _stopSampling() {
    if (_edgeListener != null) _edgeStream?.removeListener(_edgeListener!);
    _edgeStream = null;
    _edgeListener = null;
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_onScroll);
    WidgetsBinding.instance.removeObserver(this);
    _spin.dispose();
    _glide.dispose();
    _tiltBack.dispose();
    _pageDrag = null; // the list's position ends its own drag as it goes
    _settle?.cancel();
    _stopSampling();
    if (_lockedOffset != null || _zoomed) widget.onLock?.call(false);
    for (final p in _recentFull) {
      p.evict();
    }
    _dropSmall();
    _drawn.dispose();
    _cover.dispose();
    super.dispose();
  }

  bool get _reduceMotion => MediaQuery.of(context).disableAnimations;

  /// Turns the shoe a few frames and back on first show, so people see that scrolling turns it.
  Future<void> _hint() async {
    if (_hinted || !mounted || _reduceMotion || !widget.scroll.hasClients || widget.scroll.offset > 0) return;
    _hinted = _hinting = true;
    try {
      final spin = _plan.steps.length > 1 ? _plan.startOf(1) * _travel : _travel;
      await widget.scroll.animateTo(spin * 0.12, duration: const Duration(milliseconds: 700), curve: Curves.easeInOut);
      if (!mounted || !widget.scroll.hasClients) return;
      await widget.scroll.animateTo(0, duration: const Duration(milliseconds: 700), curve: Curves.easeInOut);
    } finally {
      _hinting = false;
    }
  }

  void _onScroll() {
    if (_lockedOffset != null) {
      if (widget.scroll.offset != _lockedOffset) widget.scroll.jumpTo(_lockedOffset!); // zooming: page stays
      return;
    }
    // The page moved under a tilted shoe (its strips, a button, a screen reader): the stage follows the page again.
    if (_tilt != 0 && !_tilting && !_tiltBack.isAnimating) {
      _tilt = 0;
      setState(() {});
    }
    // The buyer scrolls, the page coasts or animates to a stop, or a finger turns the shoe: the stage glides after
    // it. A jump nobody watched move (another colour opened at the same view, a screen reader's step) lands at once.
    final want = _progress;
    final glide = !_reduceMotion && (_turning || _scrolling);
    if (!glide || (want - _pos).abs() < _plan.photoShare * 0.02) {
      _land();
    } else if (!_glide.isActive) {
      _lastGlide = null;
      _glide.start();
    }
    _reportTop();
    // Otherwise only the stage's position changes, which _PinStage repaints without rebuilding anything. A screen
    // reader still needs the moved boxes, or its focus frames stay where the stage was.
    if (SemanticsBinding.instance.semanticsEnabled) _pin.currentContext?.findRenderObject()?.markNeedsSemanticsUpdate();
  }

  bool get _scrolling => widget.scroll.hasClients && widget.scroll.position.isScrollingNotifier.value;

  /// One screen refresh of the glide: the stage closes a fifth of the way to the page every 16.7 ms (at any refresh
  /// rate) and stops within a fiftieth of a photo.
  void _glideTick(Duration elapsed) {
    final last = _lastGlide;
    _lastGlide = elapsed;
    final dt = last == null ? 16.7 : math.min(64.0, (elapsed - last).inMicroseconds / 1000);
    final want = _progress;
    _pos += (want - _pos) * (1 - math.pow(0.8, dt / 16.7));
    if ((want - _pos).abs() < _plan.photoShare * 0.02) return _land();
    _show();
  }

  /// The stage comes to where the page is, at once.
  void _land() {
    if (_glide.isActive) _glide.stop();
    _seam = false;
    _pos = _progress;
    _show();
  }

  /// A finger on the shoe takes it where it is seen: the page comes back to the frame the stage shows, so turning,
  /// tilting or zooming starts from it, not from where the glide was heading.
  void _holdShown() {
    if (!_glide.isActive || !widget.scroll.hasClients) return;
    _glide.stop();
    _seam = false;
    widget.scroll.jumpTo(_plan.centreOf(_shown.step, _shown.frame) * _travel);
  }

  /// Shows the photo at [_pos]. Moving on within the small copies only draws the stage again; the page is built
  /// again when the step changes, when the full photo was showing, or for photos drawn without a small copy.
  void _show() {
    var at = _pos;
    if (_seam) {
      // Gone round the turn's end: the stage keeps its distance behind the finger and goes on round with it.
      final turn = _plan.turnShare;
      at = at < 0 ? at + turn : (at >= turn ? at - turn : at);
    }
    final now = _plan.at(at);
    if (now == _shown) return;
    final step = now.step != _shown.step;
    // The turn's end mark lights up or goes out: a tick, as at every stop.
    final turn = _plan.turnEnd == null ? null : _plan.turn;
    final crossed = !step && now.step == 0 && turn != null && (now.frame >= turn) != (_shown.frame >= turn);
    if (step && (_jumpingTo == null || _jumpingTo == now.step)) {
      HapticFeedback.selectionClick();
      // A jump back to the turn's start comes in over the turn's end: one stop, one tick, so passing it stays quiet.
      _jumpingTo = _jumpingTo == 0 && !_jumpingToEnd && turn != null && now.frame >= turn ? 0 : null;
    } else if (crossed) {
      if (_jumpingTo == null || _jumpingToEnd) HapticFeedback.selectionClick();
      if (_jumpingTo == 0) _jumpingTo = null;
    }
    // A screen reader reads the frame from the built page, so with one on every frame builds it.
    final rebuild = step ||
        _settled ||
        _tilt != 0 ||
        _zoomed ||
        SemanticsBinding.instance.semanticsEnabled ||
        _smallUrl(now) == null ||
        _smallUrl(_shown) == null;
    _shown = now;
    _retryShown();
    // Not for each frame a stop button's jump only passes: its landing was fetched when it was tapped.
    if (!_jumping) _fetchNear(now);
    // Small copies while turning; the full photo once the shoe has stopped on one frame for a moment.
    _settled = false;
    _settleSoon();
    if (rebuild) {
      setState(() {});
      _reportTop();
    } else {
      _redraw();
    }
  }

  /// The full photo once the shoe has stopped on one photo for a moment: 160 ms after the last frame change, as on
  /// the demo page.
  void _settleSoon({int waited = 0}) {
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 160), () {
      if (!mounted || _settled) return;
      // Still turning on its own (a flick, or the page coasting after a swipe): decoding now would make the last,
      // slow frames of the turn stutter. Once it stops, the next frame change or the end of the spin comes back here;
      // after 3 s of waiting the sharp photo comes anyway, in case the page never reports itself still.
      // So does the glide while it is still on its way to another photo: its last frame can take longer than 160 ms.
      final heading = _glide.isActive && _plan.at(_progress) != _shown;
      if ((_spin.isTicking || _coasting || heading) && waited < 20) return _settleSoon(waited: waited + 1);
      setState(() => _settled = true);
    });
  }

  bool get _coasting =>
      _pagePointers.isEmpty && widget.scroll.hasClients && widget.scroll.position.isScrollingNotifier.value;

  /// Fingers anywhere on the page: one resting on the page's controls holds the page still, it is not coasting.
  final _pagePointers = <int>{};

  /// Which zoom each remembered full photo was decoded for.
  final _bucketOf = Expando<int>();

  void _remember(ImageProvider full, int bucket) {
    _bucketOf[full] = bucket;
    if (_recentFull.isNotEmpty && _recentFull.last == full) return;
    // The same photo decoded for another zoom: drop it, a 3200 px photo at two sizes is tens of megabytes. The
    // screen-size copy stays, so zooming back out is sharp at once.
    ImageProvider source(ImageProvider p) => p is ResizeImage ? p.imageProvider : p;
    for (final other in [..._recentFull]) {
      if (other != full && _bucketOf[other] != 1 && source(other) == source(full)) {
        _recentFull.remove(other);
        other.evict();
      }
    }
    _recentFull
      ..remove(full)
      ..add(full);
    while (_recentFull.length > _keepFull) {
      _recentFull.removeAt(0).evict();
    }
  }

  /// Moves the page to a stop's view, or with [turnEnd] to where the turn comes full round.
  void _goTo(int step, {bool turnEnd = false}) {
    _resetZoom();
    _stopSpin();
    _tiltBack.stop();
    _setTilt(0);
    final target =
        turnEnd ? _plan.centreOf(0, _plan.turn) * _travel : _plan.startOf(step) * _travel + (step == 0 ? 0 : 1);
    _jumpingTo = step;
    _jumpingToEnd = turnEnd;
    _fetchNear(_plan.at((target / _travel).clamp(0.0, 1.0)));
    if (_reduceMotion) {
      widget.scroll.jumpTo(target);
    } else {
      _jumping = true;
      widget.scroll
          .animateTo(target, duration: const Duration(milliseconds: 450), curve: Curves.easeInOut)
          .whenComplete(() => _jumping = false);
    }
  }

  int get _photoIndex => _plan.photos.indexOf(_plan.at(_progress));

  /// A screen reader's swipe moves exactly one photo on or back.
  void _nudge(int delta) {
    final i = (_photoIndex + delta).clamp(0, _plan.photos.length - 1);
    final p = _plan.photos[i];
    widget.scroll.jumpTo(_plan.centreOf(p.step, p.frame) * _travel); // lands at once: not a scroll to glide after
  }

  String _describe(int index) {
    final p = _plan.photos[index.clamp(0, _plan.photos.length - 1)];
    final s = _plan.steps[p.step];
    if (s.kind == 'spin') return trf('кадр {0} / {1}', [p.frame + 1, s.media.length]);
    // A scan's stop carries frames on towards the next one: each still reads differently.
    return s.media.length > 1 ? trf('{0}, кадр {1} / {2}', [s.label, p.frame + 1, s.media.length]) : s.label;
  }

  // Touches, relayed from above the list.

  /// Takes a pointer event from the Listener around the page's list; events outside the stage are ignored.
  void handlePointer(PointerEvent e) {
    // A finger or a mouse wheel anywhere on the page stops a spinning shoe: its spin would otherwise fight the scroll.
    if (e is PointerDownEvent || e is PointerScrollEvent) {
      _stopSpin();
      _tiltBack.stop();
    }
    if (e is PointerDownEvent) _pagePointers.add(e.pointer);
    if (e is PointerUpEvent || e is PointerCancelEvent) _pagePointers.remove(e.pointer);
    final box = _viewer.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final local = box.globalToLocal(e.position);
    if (e is PointerDownEvent) {
      if (!(Offset.zero & box.size).contains(local)) return;
      if (_pointers.isEmpty) _holdShown();
      _pointers[e.pointer] = local;
      if (_pointers.length == 2) _startPinch();
    } else if (e is PointerMoveEvent) {
      final was = _pointers[e.pointer];
      if (was == null) return;
      _pointers[e.pointer] = local;
      if (_pointers.length == 2 && _pinchStartDistance >= 1) {
        final p = _pointers.values.toList();
        setState(() {
          _scale = (_pinchStartScale * (p[0] - p[1]).distance / _pinchStartDistance).clamp(1.0, 3.0);
          _pan = _clampPan(_pinchStartPan + ((p[0] + p[1]) / 2 - _pinchStartMid), box.size);
        });
      } else if (_pointers.length == 1 && _zoomed) {
        setState(() => _pan = _clampPan(_pan + (local - was), box.size)); // one finger moves the zoomed shoe
      }
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      if (_pointers.remove(e.pointer) == null) return;
      if (_pointers.length < 2) _pinchStartDistance = 0;
      if (_pointers.isEmpty && !_zoomed) _setLock();
    }
  }

  void _startPinch() {
    _holdShown();
    final p = _pointers.values.toList();
    _pinchStartDistance = (p[0] - p[1]).distance;
    _pinchStartScale = _scale;
    _pinchStartPan = _pan;
    _pinchStartMid = (p[0] + p[1]) / 2;
    if (widget.scroll.hasClients) widget.scroll.jumpTo(widget.scroll.offset); // stop a scroll still coasting
    _setLock(force: true);
  }

  /// Holds the page still while zoomed or pinching, and lets it go otherwise.
  void _setLock({bool force = false}) {
    final lock = force || _zoomed;
    if (lock == (_lockedOffset != null)) return;
    _lockedOffset = lock && widget.scroll.hasClients ? widget.scroll.offset : null;
    widget.onLock?.call(_lockedOffset != null);
  }

  Offset _clampPan(Offset pan, Size size) {
    final mx = (_scale - 1) * size.width / 2, my = (_scale - 1) * size.height / 2;
    return Offset(pan.dx.clamp(-mx, mx), pan.dy.clamp(-my, my));
  }

  void _resetZoom() {
    if (!_zoomed && _pan == Offset.zero) return;
    setState(() {
      _scale = 1;
      _pan = Offset.zero;
    });
    _lockedOffset = null;
    widget.onLock?.call(false);
  }

  void _doubleTap(Size size) {
    if (_zoomed) return _resetZoom();
    _holdShown();
    setState(() {
      _scale = 2.5;
      final at = _tapAt ?? size.center(Offset.zero);
      _pan = _clampPan((size.center(Offset.zero) - at) * (_scale - 1), size); // zoom in where tapped
    });
    _setLock();
  }

  double _dragFrame = 0;
  late final Ticker _spin = createTicker(_spinTick);
  FrictionSimulation? _spinSim;

  /// How far a finger goes sideways to turn the shoe once round: the demo page's 3 px a frame over its 80-frame
  /// turn, so every turn goes round at that rate under the finger whatever its number of frames.
  static const turnDrag = 240.0;

  /// Frames the shoe turns for a finger moving [dx] sideways on a stage [width] wide: right turns it towards the
  /// viewer's right, as turning it by hand. A wide stage (a tablet) takes 0.6 of its width, so a swipe across it
  /// does not spin the shoe three times round.
  double _framesFor(double dx, double width) => -dx / math.max(turnDrag, width * 0.6) * _plan.turn;

  /// Where the page is: the photo the stage is gliding to.
  ({int step, int frame}) get _target => _plan.at(_progress);

  /// Whether the page is on the turn, where a drag on the shoe turns and tilts it.
  bool get _onTurn => _target.step == 0 && _target.frame < _plan.turn;

  /// A sideways drag turns the shoe round and round within one turn (a scan's frames after the turn rise over the
  /// shoe, which a sideways drag should not do). A tilted shoe first comes back level, then turns.
  void _drag(DragUpdateDetails d, double width) {
    // Two fingers are a pinch, not a turn.
    if (_pointers.length > 1 || _zoomed || !_onTurn || !widget.scroll.hasClients) return;
    _stopSpin();
    _tiltBack.stop();
    var frames = _framesFor(d.delta.dx, width);
    if (_tilt != 0) {
      // Levelling takes as much finger as tilting did: the share of a full tilt the move is worth.
      final level = d.delta.dx.abs() / _tiltTravel;
      if (level < _tilt.abs()) return _setTilt(_tilt - _tilt.sign * level);
      frames *= 1 - _tilt.abs() / level;
      _setTilt(0);
    }
    final turn = _plan.turn;
    if (_dragFrame.floor() % turn != _target.frame) _dragFrame = _target.frame * 1.0;
    _showFrame(_dragFrame + frames);
  }

  /// Turns the shoe to [frame] of the turn, gliding there; across the turn's ends (from its last frame to its first,
  /// or back) it jumps, as on the demo page, instead of gliding back the whole way round.
  ///
  /// A flick's own spin is already even, a frame per screen refresh at most: it does not glide ([glide] false).
  void _showFrame(double frame, {bool glide = true}) {
    final turn = _plan.turn;
    final was = _dragFrame.floor() % turn;
    _dragFrame = frame % turn;
    // A tiny negative remainder rounds up to the turn itself, which is a frame past it.
    final to = _dragFrame.floor() % turn;
    if (glide && (to - was).abs() > turn / 2) {
      // Round the turn's end: the stage keeps its distance behind the finger and goes on round (see _show).
      _pos += to < was ? -_plan.turnShare : _plan.turnShare;
      _seam = true;
    }
    _turning = glide;
    widget.scroll.jumpTo(_plan.centreOf(0, to) * _travel);
    _turning = false;
  }

  /// The finger lifted mid-turn: the shoe keeps turning and slows to a stop, as a thing spun by hand does.
  void _flick(DragEndDetails d, double width) {
    if (_pointers.isNotEmpty || _zoomed || !_onTurn || _tilt != 0 || !widget.scroll.hasClients || _reduceMotion) {
      return;
    }
    // At most 4 turns a second, and no faster than about a frame per screen refresh: skipping frames looks jumpy.
    final top = math.min(4.0 * _plan.turn, 72.0);
    // The coast keeps the feel it had before the demo's quicker drag: the finger's speed over one and a half widths of
    // the stage a turn, so a careful lift (under about 150 px/s) still leaves the shoe where the finger did.
    final speed = (-d.velocity.pixelsPerSecond.dx / (width * ShowcasePlan.turnWidths) * _plan.turn).clamp(-top, top);
    if (speed.abs() < _plan.turn * 0.25) return; // a slow lift: it stops where the finger left it
    _stopSpin();
    // Keeping 15% of its speed each second, a hard flick goes about two turns and a light one half a turn.
    _spinSim = FrictionSimulation(0.15, _dragFrame, speed, tolerance: Tolerance(velocity: _plan.turn * 0.1));
    _spin.start();
  }

  void _spinTick(Duration elapsed) {
    final sim = _spinSim;
    if (sim == null || !widget.scroll.hasClients || _zoomed || !_onTurn) return _stopSpin();
    final t = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _showFrame(sim.x(t), glide: false);
    if (sim.isDone(t)) {
      _stopSpin();
      _settleSoon(); // at rest now: the sharp photo
    }
  }

  void _stopSpin() {
    if (_spin.isActive) _spin.stop();
    _spinSim = null;
  }

  // Tilting. On the turn, a finger moving up the shoe tips it towards its top and down towards its sole, through
  // real photos only: on a scan, the frames where the camera rises over it and goes under it; otherwise the top and
  // sole photos themselves. Off the turn, the same drag scrolls the page as before.

  /// -1 (the sole) to 1 (the top); 0 is level, on the turn.
  double _tilt = 0;

  /// The turn's frame the shoe was tilted from.
  int _tiltFrom = 0;

  /// How far the finger goes up or down to tilt the shoe all the way.
  double _tiltTravel = 300;

  Drag? _pageDrag; // a vertical drag that started off the turn moves the page itself
  late final AnimationController _tiltBack = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 260))
    ..addListener(
        () => _setTilt(_tiltFromValue + (_tiltTo - _tiltFromValue) * Curves.easeOutCubic.transform(_tiltBack.value)));
  double _tiltFromValue = 0, _tiltTo = 0;

  /// The photos from level to all the way over towards the top ([up]) or the sole, as (step, frame) of the plan.
  /// From a side other than the turn's first, it turns there first, in a few frames, as a scan rises from there.
  List<({int step, int frame})> _tiltPath(bool up) {
    final kind = up ? 'top' : 'sole';
    final at = _plan.steps.indexWhere((s) => s.kind == kind);
    if (at < 0) return const [];
    final from = (step: 0, frame: _tiltFrom);
    if (!_plan.scan) return [from, (step: at, frame: 0)];
    final turn = _plan.turn;
    // The shorter way round to the turn's first frame, in at most 6 steps.
    final back = _tiltFrom <= turn ~/ 2 ? -_tiltFrom : turn - _tiltFrom;
    final steps = math.min(6, back.abs());
    final round = [
      for (var i = 0; i < steps; i++) (step: 0, frame: ((_tiltFrom + back * i / steps).round() % turn + turn) % turn)
    ];
    if (up) {
      // The rise: the frames after the turn in the turn's step, up to the top's own frame.
      return [
        ...round,
        for (var f = turn; f < _plan.steps[0].media.length; f++) (step: 0, frame: f),
        (step: at, frame: 0)
      ];
    }
    // Under the sole: from where the camera, past the top, is level with the shoe again, down to the sole's frame.
    final over = _plan.steps[at - 1];
    if (over.kind != 'top') return [...round, (step: at, frame: 0)];
    return [
      ...round,
      (step: 0, frame: 0),
      for (var f = over.media.length ~/ 2; f < over.media.length; f++) (step: at - 1, frame: f),
      (step: at, frame: 0),
    ];
  }

  // Both ways' photos, made when the shoe leaves level: they depend only on the frame it was tilted from.
  List<({int step, int frame})> _pathUp = const [], _pathDown = const [];

  ({int step, int frame})? get _tilted {
    if (_tilt == 0) return null;
    final path = _tilt > 0 ? _pathUp : _pathDown;
    if (path.isEmpty) return null;
    // Two photos (level and the stop): the stop shows from a third of the way, so it never waits on a long drag.
    final i = path.length == 2 ? (_tilt.abs() >= 0.3 ? 1 : 0) : (_tilt.abs() * (path.length - 1)).round();
    return path[i.clamp(0, path.length - 1)];
  }

  /// Whether the shoe can be tilted at all: a listing with neither a top nor a sole photo has nothing to tip to.
  bool get _canTilt => _plan.steps.any((s) => s.kind == 'top' || s.kind == 'sole');

  void _setTilt(double tilt) {
    final was = _tilted;
    if (_tilt == 0 && tilt != 0) {
      _tiltFrom = _target.frame;
      _pathUp = _tiltPath(true);
      _pathDown = _tiltPath(false);
    }
    // Only as far as there are photos that way.
    _tilt = tilt.clamp(_pathDown.isEmpty ? 0.0 : -1.0, _pathUp.isEmpty ? 0.0 : 1.0);
    if (_tilt.abs() < 1e-3) _tilt = 0;
    if (_tilted != was) {
      _settled = false;
      _settleSoon();
      setState(() {});
      _reportTop();
    }
  }

  bool _tilting = false; // a finger is tilting the shoe now

  void _tiltStart(DragStartDetails d, double height) {
    _tiltBack.stop();
    _stopSpin();
    _tiltTravel = math.max(120, height * 0.45);
    if (_zoomed || !widget.scroll.hasClients) return;
    // The page moves from the stage's top and bottom strips too, and wherever the shoe cannot tilt.
    final edge = d.localPosition.dy < height * 0.15 || d.localPosition.dy > height * 0.85;
    if (edge || (_tilt == 0 && (!_onTurn || !_canTilt || _hinting))) {
      _pageDrag = widget.scroll.position.drag(d, () => _pageDrag = null);
    } else {
      _tilting = true;
    }
  }

  void _tiltUpdate(DragUpdateDetails d) {
    if (_pageDrag != null) return _pageDrag!.update(d);
    if (!_tilting || _pointers.length > 1 || _zoomed) return;
    _setTilt(_tilt - d.delta.dy / _tiltTravel); // the finger up tips the top towards the viewer
  }

  void _tiltEnd(DragEndDetails d) {
    if (_pageDrag != null) return _pageDrag!.end(d);
    _tilting = false;
    if (_tilt == 0) return;
    // A flick carries on to the far end, or back to level; an ordinary lift leaves the shoe as the finger did.
    final v = -d.velocity.pixelsPerSecond.dy / _tiltTravel;
    if (v.abs() < 3) return;
    final to = v.sign == _tilt.sign ? _tilt.sign : 0.0;
    if (_reduceMotion) return _setTilt(to);
    _tiltFromValue = _tilt;
    _tiltTo = to;
    _tiltBack.forward(from: 0);
  }

  void _tiltCancel() {
    _tilting = false;
    _pageDrag?.cancel();
    _pageDrag = null;
  }

  Widget _photo(MediaItem m, ShowcaseStep step, double width) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final small = _drawsSmall(m, step);
    const missing = Center(child: Icon(Icons.broken_image_outlined, size: 48));
    // The small copies are drawn by a painter of their own: moving on a frame draws it again, nothing is rebuilt. Like
    // an Image, it draws them inverted when the phone inverts its colours, so they show as the photos laid over them.
    final invert =
        MediaQuery.maybeInvertColorsOf(context) ?? SemanticsBinding.instance.accessibilityFeatures.invertColors;
    final base = small
        ? RepaintBoundary(
            child: CustomPaint(
                key: const ValueKey('showcase-base'),
                painter: _FramePainter(_drawable, Listenable.merge([_drawn, _cover]),
                    invert: invert, imageHidden: () => smallHidden),
                size: Size.infinite))
        : Image(
            key: const ValueKey('showcase-base'),
            image: _base(m, step),
            fit: BoxFit.contain,
            gaplessPlayback: true, // the last frame stays until the next is decoded: the shoe never blinks out
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => missing,
          );
    // At rest: the full photo over the small copy, faded in once decoded, at the pixels the zoom needs.
    final bucket = _scale <= 1.05 ? 1 : (_scale <= 2 ? 2 : 3);
    final provider = ResizeImage.resizeIfNeeded(
        math.min(6000, (width * dpr * bucket).round()), null, fullSource(step.cut ? m.url : m.originalUrl));
    // With no small copy the base is already this photo at screen size: nothing to lay over it, nothing to drop.
    final sharpen = (_settled || _zoomed) && (small || provider != _base(m, step));
    if (sharpen) _remember(provider, bucket);
    // Once the photo is drawn, the small copy under it is left out: the photos are cut out, so a small copy under them
    // showed through round the shoe, and while the small copy of the frame shown is still on its way the stage draws
    // the nearest one, at another angle, so the shoe was seen twice, one over the other. Counted from the photo
    // actually drawn this time at this size (ResizeImage compares its width too), so coming back to a photo no longer
    // decoded, or a new width, keeps the small copy until the photo is there. With no small copy the base is the same
    // photo at screen size, so nothing else shows round it.
    _laid = sharpen && small ? provider : null;
    if (_laid == null) _sharpDrawn = null;
    final full = Image(
      image: provider,
      key: ValueKey('showcase-full-${m.url}-$bucket'),
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      frameBuilder: (_, child, frame, sync) {
        if (!(sync || frame != null)) return const SizedBox.shrink(); // until then the small copy shows through
        if (_laid == provider && _sharpDrawn != provider) {
          _sharpDrawn = provider;
          _cover.value++; // only the painter listens: it leaves the small copy out in this same frame
        }
        return child;
      },
      errorBuilder: (_, __, ___) {
        if (_sharpDrawn == provider) {
          _sharpDrawn = null;
          _cover.value++;
        }
        return const SizedBox.shrink();
      },
    );
    // A seller's cut-out turning on the floor stands on its shadow, made from the small copy (the painter draws it
    // under a small copy, also while the photo is over it). A scan has its own.
    final img = Stack(fit: StackFit.expand, children: [
      if (!small && castsShadow) ContactShadow(image: _base(m, step), fit: BoxFit.contain, gapless: true),
      base,
      if (sharpen) full,
    ]);
    // A scan's frames have their own margin; a seller's cut-out is often cropped close, so it gets one.
    return step.cut && !_plan.scan ? Padding(padding: const EdgeInsets.all(20), child: img) : img;
  }

  bool _shadowed(ShowcaseStep step) => !_plan.scan && step.kind == 'spin' && step.cut;

  Brightness? _top;
  bool _topReported = false;

  /// Tells the page how dark the stage under the status bar is (null once scrolled past), so its icons can read.
  void _reportTop() {
    if (!mounted || _reportLater) return;
    final offset = widget.scroll.hasClients ? widget.scroll.offset : 0.0;
    final now = _tilted ?? _shown;
    final scene = _onDark(_plan.steps[now.step]) ? Brightness.dark : Brightness.light;
    final report = widget.onStageTop;
    if (report != null) {
      final covers = offset < _travel + widget.stageHeight - MediaQuery.viewPaddingOf(context).top;
      final top = covers ? scene : null;
      if (!_topReported || top != _top) {
        _top = top;
        _topReported = true;
        report(top);
      }
    }
    final bottom = widget.onStageBottom;
    if (bottom != null) {
      // The stage is pinned, its foot on the bar, until the whole stretch has scrolled past.
      final at = offset <= _travel + 0.5 ? scene : null;
      if (!_bottomReported || at != _bottom) {
        _bottom = at;
        _bottomReported = true;
        bottom(at);
      }
    }
  }

  Brightness? _bottom;
  bool _bottomReported = false;
  bool _reportLater = false;

  /// The step's photos stand on a dark backdrop.
  bool _onDark(ShowcaseStep step) {
    if (widget.listing.backdrop != null && step.cut) return !_light;
    final edge = _photoEdge;
    if (!step.cut && edge != null) return darkerScene(edge);
    return widget.listing.showcaseStyle == 'premium';
  }

  BoxDecoration _stage(ShowcaseStep step, bool own) {
    if (own) return _backdrop;
    final edge = _photoEdge;
    if (!step.cut && edge != null) return BoxDecoration(color: edge);
    return showcaseBackground(widget.listing.showcaseStyle);
  }

  BoxDecoration get _backdrop => BoxDecoration(color: (_light ? ShowcaseScene.light : ShowcaseScene.dark).ink);

  /// The stops on a line that fills as the shoe goes round, as on the demo page: a stop lights up once reached.
  /// The line and the stops use the same measure, so the line reaches each stop as its view comes up.
  /// One stop's dot on the line: filled with the glow once reached.
  Widget _stopDot(ShowcaseScene scene, bool on) => AnimatedContainer(
        duration: _reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? scene.glow : scene.ink,
          // The muted ink, not the line's colour, so a stop not yet reached still shows (3:1).
          border: Border.all(color: on ? scene.glow : scene.muted, width: 2),
        ),
      );

  Widget _stops(ShowcaseScene scene, ({int step, int frame}) now) {
    const width = 240.0; // 48 dp between the closest stops, so their buttons do not overlap
    return SizedBox(
      width: width + 48,
      height: 48,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: 24,
          right: 24,
          top: 22.5,
          height: 3,
          child: DecoratedBox(decoration: BoxDecoration(color: scene.line, borderRadius: BorderRadius.circular(3))),
        ),
        // Follows the shoe frame by frame, which draws the stage again without building it.
        ListenableBuilder(
          listenable: _drawn,
          builder: (_, __) {
            final at = _tilted ?? _shown;
            return Positioned(
              left: 24,
              top: 22.5,
              height: 3,
              width: width * _plan.along(at.step, at.frame),
              child: DecoratedBox(
                  key: const Key('showcase-line-fill'),
                  decoration: BoxDecoration(color: scene.glow, borderRadius: BorderRadius.circular(3))),
            );
          },
        ),
        // The turn's end, as the demo page's second stop: lit once the shoe has gone round, and a tap goes there.
        // It comes before the stops, so where its button meets the next stop's, the stop's wins.
        if (_plan.turnEnd case final end?)
          Positioned(
            left: width * end,
            top: 0,
            width: 48,
            height: 48,
            child: Semantics(
              button: true,
              label: tr('Айналым соңы'),
              child: Tooltip(
                message: tr('Айналым соңы'),
                excludeFromSemantics: true,
                child: InkWell(
                  key: const Key('showcase-turn-end'),
                  customBorder: const CircleBorder(),
                  onTap: () => _goTo(0, turnEnd: true),
                  child: Center(
                    child: ListenableBuilder(
                      listenable: _drawn,
                      builder: (_, __) {
                        final at = _tilted ?? _shown;
                        return _stopDot(scene, at.step > 0 || at.frame >= _plan.turn);
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        for (var i = 0; i < _plan.steps.length; i++)
          Positioned(
            left: width * _plan.along(i, 0),
            top: 0,
            width: 48,
            height: 48,
            child: Semantics(
              button: true,
              selected: i == now.step,
              label: _plan.steps[i].label,
              child: Tooltip(
                message: _plan.steps[i].label,
                excludeFromSemantics: true,
                child: InkWell(
                  key: Key('showcase-step-${_plan.steps[i].kind}'),
                  customBorder: const CircleBorder(),
                  onTap: () => _goTo(i),
                  child: Center(child: _stopDot(scene, i <= now.step)),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    builds++;
    final travel = _travel;
    final h = widget.stageHeight;
    final now = _shown;
    final shown = _tilted ?? now;
    final step = _plan.steps[shown.step];
    final media = step.media[shown.frame];
    final ownBackdrop = widget.listing.backdrop != null && step.cut;
    final onDark = _onDark(step);
    final scene = onDark ? ShowcaseScene.dark : ShowcaseScene.light;
    final index = _photoIndex;
    final shownIndex = _tilted == null ? index : math.max(0, _plan.photos.indexOf(shown)); // what is on screen
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight; // the shoe stays clear of the app bar
    return SizedBox(
      height: h + travel,
      child: Flow(key: _pin, delegate: _PinStage(widget.scroll, h, travel), children: [
        RepaintBoundary(
          child: DecoratedBox(
            key: const Key('showcase'),
            decoration: _stage(step, ownBackdrop),
            child: Column(children: [
              SizedBox(height: top),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Semantics(
                      container: true,
                      slider: true,
                      label: trf('360° көрініс: {0}. Оңға-солға сүйресе айналады, жоғары-төмен сүйресе еңкейеді.',
                          [step.label]),
                      value: _describe(shownIndex),
                      increasedValue: index < _plan.photos.length - 1 ? _describe(index + 1) : null,
                      decreasedValue: index > 0 ? _describe(index - 1) : null,
                      onIncrease: index < _plan.photos.length - 1 ? () => _nudge(1) : null,
                      onDecrease: index > 0 ? () => _nudge(-1) : null,
                      child: LayoutBuilder(
                        builder: (context, box) => GestureDetector(
                          key: _viewer,
                          // The slider around it is what a screen reader uses; the drags' own scroll actions would
                          // tilt the shoe at a jump.
                          excludeFromSemantics: true,
                          behavior: HitTestBehavior.opaque,
                          onDoubleTapDown: (d) => _tapAt = d.localPosition,
                          onDoubleTap: () => _doubleTap(box.biggest),
                          dragStartBehavior: DragStartBehavior.down, // the shoe follows from the first pixel
                          onHorizontalDragUpdate: (d) => _drag(d, box.maxWidth),
                          onHorizontalDragEnd: (d) => _flick(d, box.maxWidth),
                          // Up and down on the shoe tilts it; the page scrolls from the stage's edges and controls.
                          onVerticalDragStart: (d) => _tiltStart(d, box.maxHeight),
                          onVerticalDragUpdate: _tiltUpdate,
                          onVerticalDragEnd: _tiltEnd,
                          onVerticalDragCancel: _tiltCancel,
                          // The soft light behind the shoe stays put while the shoe zooms, as on the approved demo page.
                          child: CustomPaint(
                            painter: ownBackdrop ? _Halo(scene.halo) : null,
                            child: ClipRect(
                              child: Transform(
                                key: const Key('showcase-zoom'),
                                alignment: Alignment.center,
                                transform: Matrix4.identity()
                                  ..translateByDouble(_pan.dx, _pan.dy, 0, 1)
                                  ..scaleByDouble(_scale, _scale, 1, 1),
                                filterQuality: _zoomed ? FilterQuality.high : null,
                                // The catalog card's photo flies into place here, as it does on the Photo tab. Not
                                // while zoomed (it would fly from the magnified photo) or with reduced motion.
                                child: HeroMode(
                                  enabled: !_zoomed && !_reduceMotion,
                                  child: Hero(
                                    tag: 'listing-${widget.listing.id}',
                                    // Going back, the shoe as it is turned now shrinks into the card.
                                    flightShuttleBuilder: (_, __, direction, from, to) =>
                                        (direction == HeroFlightDirection.pop ? from : to).widget,
                                    child: Material(
                                      type: MaterialType.transparency,
                                      child: SizedBox.expand(child: _photo(media, step, box.maxWidth)),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // The model's other colours on the left (no words beside the shoe, as for the stops); zoom reset, backdrop
              // switch, the photos as taken and the details on the right, above the stops.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  Expanded(
                    child: widget.onColor != null && widget.listing.colors.length > 1
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: ColorSwatches(
                                colors: widget.listing.colors,
                                ring: scene.fg,
                                edge: scene.line,
                                pending: widget.pendingColor,
                                onPick: widget.onColor!),
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (_zoomed)
                    _RoundChip(
                      key: const Key('showcase-reset-zoom'),
                      scene: scene,
                      tooltip: tr('Бастапқы өлшем'),
                      onTap: _resetZoom,
                      child: Text('1×',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontVariations: const [FontVariation('wght', 700)],
                              color: scene.fg)),
                    ),
                  if (ownBackdrop)
                    _RoundChip(
                      key: const Key('showcase-backdrop'),
                      scene: scene,
                      tooltip: _light ? tr('Қараңғы фон') : tr('Ашық фон'),
                      toggled: !_light,
                      onTap: () {
                        setState(() => _light = !_light);
                        _reportTop();
                      },
                      child: Icon(Icons.contrast, size: 20, color: scene.fg),
                    ),
                  if (widget.onPhotos != null)
                    _RoundChip(
                      key: const Key('showcase-photos'),
                      scene: scene,
                      tooltip: tr('Фото'),
                      onTap: () {
                        _resetZoom();
                        widget.onPhotos!();
                      },
                      child: Icon(Icons.photo_library_outlined, size: 18, color: scene.fg),
                    ),
                  if (widget.onDetails != null)
                    _RoundChip(
                      key: const Key('showcase-details'),
                      scene: scene,
                      tooltip: tr('Толығырақ'),
                      onTap: () {
                        _resetZoom();
                        widget.onDetails!();
                      },
                      child: Icon(Icons.keyboard_double_arrow_down_rounded, size: 20, color: scene.fg),
                    ),
                ]),
              ),
              // The stops on a thin line that fills as the shoe turns (Aza's choice: nothing written beside the
              // shoe). Each stop is a 48 dp button that jumps straight to its view; its name is read out and shown on
              // long press.
              // Its own layer: the line fills frame by frame without the whole stage being painted again.
              Center(child: RepaintBoundary(child: _stops(scene, shown))),
              // How to use it, until the shoe starts turning; not on a short stage (a short screen, or large text making
              // the bar under it tall), where the shoe needs the room.
              if (h + MediaQuery.paddingOf(context).bottom >= 480)
                AnimatedOpacity(
                  opacity: index == 0 ? 1 : 0,
                  duration: _reduceMotion ? Duration.zero : const Duration(milliseconds: 300),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text.rich(
                      TextSpan(children: [
                        WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Icon(Icons.threesixty, size: 16, color: scene.muted)),
                        TextSpan(
                            text:
                                ' ${tr('Оңға-солға айналдырыңыз · жоғары-төмен еңкейтіңіз · екі саусақпен жақындатыңыз')}'),
                      ]),
                      key: const Key('showcase-hint'),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: scene.muted),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Keeps the stage in view while its stretch of the page scrolls past. It moves the painted stage only: nothing is
/// rebuilt or laid out again for each scroll pixel, and touches follow the stage because Flow hit-tests through
/// the same transform.
class _PinStage extends FlowDelegate {
  _PinStage(this.scroll, this.height, this.travel) : super(repaint: scroll);
  final ScrollController scroll;
  final double height, travel;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints.tightFor(width: constraints.maxWidth, height: height);

  @override
  void paintChildren(FlowPaintingContext context) {
    final offset = scroll.hasClients ? scroll.offset.clamp(0.0, travel) : 0.0;
    context.paintChild(0, transform: Matrix4.translationValues(0, offset, 0));
  }

  @override
  bool shouldRepaint(_PinStage old) => old.scroll != scroll || old.height != height || old.travel != travel;

  @override
  bool shouldRelayout(_PinStage old) => old.height != height;
}

/// Draws the small copy the stage shows now, with the shadow a seller's cut-out stands on, whenever [repaint] says
/// the shoe moved or a copy arrived.
class _FramePainter extends CustomPainter {
  _FramePainter(this.frame, Listenable repaint, {this.invert = false, required this.imageHidden})
      : super(repaint: repaint);
  final ({ui.Image image, MadeShadow? shadow})? Function() frame;
  final bool invert;

  /// The full photo is drawn over it: only the shadow is drawn.
  final bool Function() imageHidden;

  @override
  void paint(Canvas canvas, Size size) {
    final now = frame();
    if (now == null) return;
    if (now.shadow case final shadow?) paintShadow(canvas, size, shadow, BoxFit.contain);
    if (imageHidden()) return;
    paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: now.image,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        invertColors: invert);
  }

  @override
  bool shouldRepaint(_FramePainter old) => true; // built again only when the step, tilt or zoom changed
}

class _RoundChip extends StatelessWidget {
  const _RoundChip(
      {super.key, required this.child, required this.onTap, required this.tooltip, required this.scene, this.toggled});
  final Widget child;
  final ShowcaseScene scene;
  final VoidCallback onTap;
  final String tooltip;
  final bool? toggled;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Semantics(
          button: true,
          toggled: toggled,
          child: Tooltip(
            message: tooltip,
            child: Material(
              color: scene.panel,
              shape: CircleBorder(side: BorderSide(color: scene.line)),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: SizedBox(width: 48, height: 48, child: Center(child: child)),
              ),
            ),
          ),
        ),
      );
}
