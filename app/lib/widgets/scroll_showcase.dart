import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

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
      Color(0xFF66637A), Color(0xFF6D5BD0), Color(0xF2FFFFFF));
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
  /// How many widths of the shoe's picture a sideways drag goes to turn it once round, here and on the cards.
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
    return ResizeImage.resizeIfNeeded(ScrollShowcaseState.thumbSide, null, NetworkImage(m.thumbUrl!));
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

class ScrollShowcaseState extends State<ScrollShowcase> {
  late ShowcasePlan _plan;
  late bool _light;
  bool _settled = true;
  Timer? _settle;
  ({int step, int frame}) _shown = (step: 0, frame: 0);
  bool _precached = false;
  // The last few full photos shown, newest last. Older ones are dropped from memory so they cannot push the small
  // scrolling copies out of the image cache, but going back to a photo just seen, or zooming out, finds it ready.
  final _recentFull = <ImageProvider>[];
  static const _keepFull = 3;
  int? _jumpingTo; // a stop button was tapped: tick once on arrival, not for every stop passed
  bool _jumping = false; // while a stop button's jump animates the page there
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
    _setUp();
    widget.scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hint();
      _reportTop();
    });
  }

  void _setUp() {
    _plan = ShowcasePlan.of(widget.listing);
    _light = widget.listing.backdrop != 'dark';
    _shown = (step: 0, frame: 0);
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
    _precache();
  }

  /// What the stage draws first for a photo: the small copy, or the photo decoded at screen size if there is none.
  /// Precaching asks for exactly this provider, so the cache is hit.
  static const thumbSide = 400;

  /// Where a photo is fetched at screen size when it has no small copy to scroll with; tests replace it.
  @visibleForTesting
  static ImageProvider Function(String url) screenSize = NetworkImage.new;

  /// How many frames either side of the one shown are fetched ahead when they have no small copy. Fetching every
  /// one of them at screen size on arrival cost megabytes of mobile data, and the decoded photos, a few megabytes
  /// each, did not fit the image cache anyway: most were dropped again before they were shown.
  static const fullAhead = 3;

  ImageProvider _base(MediaItem m, ShowcaseStep step) {
    // 400 px, as the demo page's scrolling copies: a scan's hundred or so frames then fit the image cache.
    if (_small(m, step)) return ResizeImage.resizeIfNeeded(thumbSide, null, NetworkImage(m.thumbUrl!));
    final width = (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round();
    return ResizeImage.resizeIfNeeded(math.min(2000, width), null, screenSize(step.cut ? m.url : m.originalUrl));
  }

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
    // The small copies scrolling shows are fetched first, in showing order. Of photos without one: the first of
    // each stop, where scrolling on or a stop button lands (a stop is one photo, a scan's a few), and those near
    // the shoe where the page actually is (a colour opened at the same side starts part way round).
    for (final s in _plan.steps) {
      for (final m in s.media) {
        if (_small(m, s)) _fetch(m, s);
      }
    }
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
      if (!_small(s.media[frame], s)) _fetch(s.media[frame], s);
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
    _settle?.cancel();
    _stopSampling();
    if (_lockedOffset != null || _zoomed) widget.onLock?.call(false);
    for (final p in _recentFull) {
      p.evict();
    }
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
    final now = _plan.at(_progress);
    _reportTop();
    if (now != _shown) {
      if (now.step != _shown.step) {
        if (_jumpingTo == null || _jumpingTo == now.step) {
          HapticFeedback.selectionClick();
          _jumpingTo = null;
        }
      }
      _shown = now;
      // Not for each frame a stop button's jump only passes: its landing was fetched when it was tapped.
      if (!_jumping) _fetchNear(now);
      // Small copies while turning; the full photo once the shoe has stopped on one frame for a moment.
      _settled = false;
      _settleSoon();
      setState(() {});
    }
    // Otherwise only the stage's position changes, which _PinStage repaints without rebuilding anything. A screen
    // reader still needs the moved boxes, or its focus frames stay where the stage was.
    if (SemanticsBinding.instance.semanticsEnabled) _pin.currentContext?.findRenderObject()?.markNeedsSemanticsUpdate();
  }

  /// The full photo once the shoe has stopped on one photo for a moment: 140 ms after the finger is lifted, or
  /// 450 ms while it rests on the shoe. Decoding one at every short pause mid-drag made the turn stutter; a longer
  /// pause is someone looking closely, who should get the sharp photo.
  void _settleSoon() {
    _settle?.cancel();
    _settle = Timer(Duration(milliseconds: _pointers.isEmpty ? 140 : 450), () {
      if (mounted && !_settled) setState(() => _settled = true);
    });
  }

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

  void _goTo(int step) {
    _resetZoom();
    final target = _plan.startOf(step) * _travel + (step == 0 ? 0 : 1);
    _jumpingTo = step;
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
    widget.scroll.jumpTo(_plan.centreOf(p.step, p.frame) * _travel);
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
    final box = _viewer.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final local = box.globalToLocal(e.position);
    if (e is PointerDownEvent) {
      if (!(Offset.zero & box.size).contains(local)) return;
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
      if (_pointers.isEmpty && !_settled) _settleSoon(); // lifted: the sharp photo comes sooner
    }
  }

  void _startPinch() {
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
    setState(() {
      _scale = 2.5;
      final at = _tapAt ?? size.center(Offset.zero);
      _pan = _clampPan((size.center(Offset.zero) - at) * (_scale - 1), size); // zoom in where tapped
    });
    _setLock();
  }

  double _dragFrame = 0;

  /// A sideways drag also turns the shoe, as the old 360° viewer did, round and round within one turn (a scan's
  /// frames after the turn rise over the shoe, which a drag should not do).
  void _drag(DragUpdateDetails d, double width) {
    if (_zoomed || _shown.step != 0 || !widget.scroll.hasClients) return;
    final turn = _plan.turn;
    if (_shown.frame >= turn || _dragFrame.floor() % turn != _shown.frame) _dragFrame = _shown.frame % turn * 1.0;
    _dragFrame = (_dragFrame - d.delta.dx / (width * ShowcasePlan.turnWidths) * turn) % turn;
    // A tiny negative remainder rounds up to the turn itself, which is a frame past it.
    widget.scroll.jumpTo(_plan.centreOf(0, _dragFrame.floor() % turn) * _travel);
  }

  Widget _photo(MediaItem m, ShowcaseStep step, double width) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final small = _base(m, step);
    final base = Image(
      key: const ValueKey('showcase-base'),
      image: small,
      fit: BoxFit.contain,
      gaplessPlayback: true, // the last frame stays until the next is decoded: the shoe never blinks out
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined, size: 48)),
    );
    // At rest: the full photo over the small copy, faded in once decoded, at the pixels the zoom needs.
    final bucket = _scale <= 1.05 ? 1 : (_scale <= 2 ? 2 : 3);
    final provider = ResizeImage.resizeIfNeeded(
        math.min(6000, (width * dpr * bucket).round()), null, NetworkImage(step.cut ? m.url : m.originalUrl));
    // With no small copy the base is already this photo at screen size: nothing to lay over it, nothing to drop.
    final sharpen = (_settled || _zoomed) && provider != small;
    if (sharpen) _remember(provider, bucket);
    final full = Image(
      image: provider,
      key: ValueKey('showcase-full-${m.url}-$bucket'),
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      frameBuilder: (_, child, frame, sync) =>
          sync || frame != null ? child : const SizedBox.shrink(), // until then the small copy shows through
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    // A seller's cut-out turning on the floor stands on its shadow, made from the small copy. A scan has its own.
    final img = Stack(fit: StackFit.expand, children: [
      if (_shadowed(step) && !_onDark(step) && !_zoomed)
        ContactShadow(image: small, fit: BoxFit.contain, gapless: true),
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
    final report = widget.onStageTop;
    if (report == null || !mounted) return;
    final offset = widget.scroll.hasClients ? widget.scroll.offset : 0.0;
    final covers = offset < _travel + widget.stageHeight - MediaQuery.viewPaddingOf(context).top;
    final now = _plan.at(_progress);
    final top = !covers ? null : (_onDark(_plan.steps[now.step]) ? Brightness.dark : Brightness.light);
    if (_topReported && top == _top) return;
    _top = top;
    _topReported = true;
    report(top);
  }

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
  Widget _stops(ShowcaseScene scene, ({int step, int frame}) now) {
    const width = 240.0; // 48 dp between the closest stops, so their buttons do not overlap
    final filled = _plan.along(now.step, now.frame);
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
        Positioned(
          left: 24,
          top: 22.5,
          height: 3,
          width: width * filled,
          child: DecoratedBox(
              key: const Key('showcase-line-fill'),
              decoration: BoxDecoration(color: scene.glow, borderRadius: BorderRadius.circular(3))),
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
                  child: Center(
                    child: AnimatedContainer(
                      duration: _reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i <= now.step ? scene.glow : scene.ink,
                        // The muted ink, not the line's colour, so a stop not yet reached still shows (3:1).
                        border: Border.all(color: i <= now.step ? scene.glow : scene.muted, width: 2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    builds++;
    final travel = _travel;
    final h = widget.stageHeight;
    final now = _plan.at(_progress);
    final step = _plan.steps[now.step];
    final media = step.media[now.frame];
    final ownBackdrop = widget.listing.backdrop != null && step.cut;
    final onDark = _onDark(step);
    final scene = onDark ? ShowcaseScene.dark : ShowcaseScene.light;
    final index = _photoIndex;
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
                      label: trf('360° көрініс: {0}. Бұру үшін бетті жоғары-төмен жылжытыңыз.', [step.label]),
                      value: _describe(index),
                      increasedValue: index < _plan.photos.length - 1 ? _describe(index + 1) : null,
                      decreasedValue: index > 0 ? _describe(index - 1) : null,
                      onIncrease: index < _plan.photos.length - 1 ? () => _nudge(1) : null,
                      onDecrease: index > 0 ? () => _nudge(-1) : null,
                      child: LayoutBuilder(
                        builder: (context, box) => GestureDetector(
                          key: _viewer,
                          behavior: HitTestBehavior.opaque,
                          onDoubleTapDown: (d) => _tapAt = d.localPosition,
                          onDoubleTap: () => _doubleTap(box.biggest),
                          onHorizontalDragUpdate: (d) => _drag(d, box.maxWidth),
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
                      child: Text('1×', style: TextStyle(fontWeight: FontWeight.w700, color: scene.fg)),
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
              Center(child: _stops(scene, now)),
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
                            child: Icon(Icons.south_rounded, size: 16, color: scene.muted)),
                        TextSpan(text: ' ${tr('Төмен жүргізіңіз · екі саусақпен жақындатыңыз')}'),
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
