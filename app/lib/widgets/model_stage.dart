import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../api.dart';
import '../demo.dart' show carriedAsset;
import '../i18n.dart';
import '../net_image.dart';
import '../viewer_host_web.dart' if (dart.library.io) '../viewer_host_io.dart';
import 'scroll_showcase.dart' show ShowcaseScene;

/// What the stage draws the shoe with: a WebView on a phone (the page in assets/viewer, three.js inside the app);
/// tests give their own.
abstract class ModelView {
  Widget get widget;

  /// Runs [script] in the page; never throws.
  Future<void> run(String script);

  /// The value of [script] in the page, as the platform returns it; null when it could not be read.
  Future<Object?> read(String script);

  /// The stage is gone: the view is not used again.
  void dispose();
}

/// Makes the view, calling [onMessage] with each message the page posts (JSON: page, ready, error, lost); null where
/// there is no 3D (the web, tests without a phone), and the listing then shows its photos.
typedef ModelViewMaker = Future<ModelView?> Function(Brightness scene, void Function(String message) onMessage);

/// The listing page's 3D stage: the shoe turns every way under the finger and zooms, on the light or dark scene. No
/// photo stands in front of it (Aza, 2026-10-24), and no wait shows (Aza, the same day: "3d ашылғанда ортада кішкене
/// күтіп загрузка бар"): until the 3D draws, the 3D's own first picture ([ListingModel.firstUrl]) stands exactly where
/// the shoe will be, and the 3D fades in over it; without one, a quiet line says the 3D is opening. The [cover] photo
/// shows only if the 3D cannot open ([onBroken] is told, so the page can show the photos instead).
class ModelStage extends StatefulWidget {
  const ModelStage(
      {super.key,
      required this.model,
      required this.dark,
      required this.paused,
      required this.cover,
      this.view,
      this.onReady,
      this.onBroken});

  final ListingModel model;

  /// The dark scene; the light one otherwise.
  final bool dark;

  /// Something covers the stage (the photos): nothing is drawn, and the shoe stays as it was for when it comes back.
  final bool paused;

  final Widget cover;

  /// The turn (a quaternion) and zoom to open at: another colour of this model showed it.
  final List<double>? view;

  /// The first 3D picture is drawn.
  final VoidCallback? onReady;

  final VoidCallback? onBroken;

  /// How the view is made; tests replace it.
  @visibleForTesting
  static ModelViewMaker maker = _webView;

  /// How long the first 3D picture may take before the stage gives up and the photos are shown; a model whose bytes
  /// are still coming in is waited for longer, up to [longest].
  static const patience = Duration(seconds: 25);
  static const longest = Duration(seconds: 90);

  /// Gets [model]'s first picture ready before its page opens (a finger on its card): a small file, so a touch that
  /// turns into a scroll costs little. The model itself comes down once the page opens.
  static void prepare(BuildContext context, ListingModel model) {
    if (model.firstUrl case final first?) precacheImage(firstImage(first, context), context, onError: (_, __) {});
  }

  /// Opens a stage's page ahead of time, hidden, so the next listing's 3D needs only its model: the page, three.js
  /// and the phone's web engine are already up. Only once a 3D has been looked at, only while no stage is open, and
  /// one at a time; given up while the app is in the background or the phone is short of memory, and for good where
  /// the phone cannot draw 3D.
  static Future<void> keepOneReady() async {
    if (_spare != null || _making != null || _live > 0 || _noSpare || !_real) return;
    _guardSpare();
    final making = _making = _open(Brightness.light).catchError((Object e) {
      debugPrint('3D stage: $e');
      return null;
    });
    final view = await making;
    _making = null;
    // Opened only as the next stage asked: it took this one already.
    if (_taken.remove(view)) return;
    _spare = view;
  }

  /// The stage draws with a phone's WebView, not a test's stand-in.
  static bool get _real => maker == _webView && !kIsWeb && WebViewPlatform.instance != null;

  /// Whether a 3D that gave up may open if asked again: it ran out of time on a weak line, say. Not on a phone with
  /// no WebGL or no web engine, where it would fail the same way.
  static bool get mayRetry => !_noSpare && (maker != _webView || _real);

  static _WebModelView? _spare;
  static Future<_WebModelView?>? _making;
  static final _taken = <_WebModelView?>{};
  static int _live = 0; // stages open now
  static bool _noSpare = false; // this phone cannot draw 3D: no page is opened ahead
  static _SpareGuard? _spareGuard;

  static void _guardSpare() {
    if (_spareGuard != null) return;
    WidgetsBinding.instance.addObserver(_spareGuard = _SpareGuard());
  }

  /// Lets go of the page kept ready (the app went to the background, or the phone is short of memory).
  static void _dropSpare() {
    _spare?.dispose();
    _spare = null;
  }

  @override
  State<ModelStage> createState() => ModelStageState();
}

class ModelStageState extends State<ModelStage> {
  ModelView? _view;
  bool _ready = false;
  bool _broken = false;
  bool _page = false; // the page has loaded and can be told what to show
  Timer? _patience;
  ViewerHost? _host;
  int _loads = 0; // which load the page works on: a late answer about an earlier one is not taken for it

  @override
  void initState() {
    super.initState();
    ModelStage._live++;
    _wait();
    final scene = widget.dark ? Brightness.dark : Brightness.light;
    ModelStage.maker(scene, _message).then((view) {
      if (!mounted) return view?.dispose();
      if (view == null) return _fail('no 3D here');
      setState(() => _view = view);
      if (view is _WebModelView) {
        // The model comes down while the page and three.js are still opening.
        ViewerHost.instance.then((host) {
          _host = host;
          if (mounted) host?.warm(widget.model.url);
        });
      }
      if (_page) _load();
    }, onError: (Object e) => _fail('$e'));
  }

  @override
  void dispose() {
    _patience?.cancel();
    _settle?.cancel();
    _view?.dispose();
    _first?.evict();
    ModelStage._live--;
    // The next listing opened finds a page ready, made once this one has gone and no other stage has opened.
    if (ModelStage._real) Timer(const Duration(seconds: 1), ModelStage.keepOneReady);
    super.dispose();
  }

  /// Gives the first picture its patience, and longer while the model's bytes are still coming in.
  void _wait() {
    _patience?.cancel();
    final started = DateTime.now();
    void check() {
      if (DateTime.now().difference(started) < ModelStage.longest && (_host?.arriving(widget.model.url) ?? false)) {
        _patience = Timer(const Duration(seconds: 5), check);
      } else {
        _fail('no 3D picture in ${DateTime.now().difference(started).inSeconds} s');
      }
    }

    _patience = Timer(ModelStage.patience, check);
  }

  void _fail(String why) {
    if (!mounted || _broken || _ready) return;
    _lose(why);
  }

  /// The 3D cannot be shown (any more): the photos take its place.
  void _lose(String why) {
    if (!mounted || _broken) return;
    debugPrint('3D stage: $why');
    _patience?.cancel();
    setState(() => _broken = true);
    widget.onBroken?.call();
  }

  void _message(String raw) {
    if (!mounted) return;
    final Object? m;
    try {
      m = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (m is! Map) return;
    final load = m['load'];
    if (load is num && load != _loads) return; // about a model no longer wanted
    switch (m['type']) {
      case 'page':
        _page = true;
        if (_view != null) _load();
      case 'ready':
        if (_broken) return;
        _patience?.cancel();
        setState(() => _ready = true);
        // Once the 3D has faded in over it, the first picture goes.
        _settle?.cancel();
        _settle = Timer(_fade(context) + const Duration(milliseconds: 60), () {
          if (mounted && _ready) setState(() => _settled = true);
        });
        if (widget.paused || _covered) _view?.run('vitrina.setPaused(true)');
        widget.onReady?.call();
      case 'error':
        if (_ready) return; // a sharper copy that did not come: the light one stays
        _fail('${m['message']}');
      case 'lost':
        // No WebGL, the phone took the drawing back, or the page's process was stopped: the photos, never an empty
        // stage, even after the shoe was shown.
        _lose('${m['message']}');
    }
  }

  /// Shows [widget.model] at [view], or at the view the stage was opened with.
  Future<void> _load([List<double>? view]) async {
    final host = await ViewerHost.instance;
    if (host == null || !mounted) return _fail('no viewer host');
    final model = widget.model;
    final args = {
      'load': ++_loads,
      'url': host.modelAt(model.url),
      'hq': model.hqUrl == null ? null : host.modelAt(model.hqUrl!),
      'variant': model.variant,
      'tint': model.tint,
      'dark': widget.dark,
      'reduceMotion': MediaQuery.of(context).disableAnimations,
      'view': view ?? widget.view,
    };
    await _view?.run('vitrina.load(${jsonEncode(args)})');
  }

  bool _covered = false; // another page lies over this one: nothing is drawn, as under the photos

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covered = !TickerMode.valuesOf(context).enabled;
    if (covered == _covered) return;
    _covered = covered;
    if (_page && !_broken && !widget.paused) _view?.run('vitrina.setPaused($covered)');
  }

  @override
  void didUpdateWidget(ModelStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    final view = _view;
    if (view == null || !_page || _broken) return;
    if (old.model.url != widget.model.url) {
      _host?.warm(widget.model.url);
      _swap();
    } else if (old.model.variant != widget.model.variant || !listEquals(old.model.tint, widget.model.tint)) {
      view.run('vitrina.setVariant(${jsonEncode(widget.model.variant)}, ${jsonEncode(widget.model.tint)})');
    }
    if (old.dark != widget.dark) view.run('vitrina.setBackground(${widget.dark})');
    if (old.paused != widget.paused) view.run('vitrina.setPaused(${widget.paused || _covered})');
  }

  /// Another model in place of this one (another colour made as its own model), at the turn and zoom shown now; the
  /// quiet line shows until it is drawn, as when the stage opened.
  Future<void> _swap() async {
    final kept = await view();
    if (!mounted) return;
    _wait();
    setState(() => _ready = false);
    await _load(kept);
  }

  /// The turn, zoom and spot zoomed in on shown now, to open another colour of this model the same; null before the shoe is shown.
  Future<List<double>?> view() async {
    if (!_ready) return null;
    var value = await _view?.read('vitrina.view()');
    // Android hands back a JavaScript string still quoted.
    if (value is String && value.startsWith('"')) value = jsonDecode(value);
    try {
      final list = value is String ? jsonDecode(value) : value;
      if (list is List && (list.length == 5 || list.length == 7)) return [for (final x in list) (x as num).toDouble()];
    } catch (_) {}
    return null;
  }

  bool _settled = false; // the 3D has faded in over the first picture, which then goes
  ImageProvider? _first; // the first picture as shown, let go of with the stage
  Timer? _settle;

  static Duration _fade(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 240);

  @override
  Widget build(BuildContext context) {
    final scene = widget.dark ? ShowcaseScene.dark : ShowcaseScene.light;
    final view = _view;
    final firstUrl = _broken || _settled ? null : widget.model.firstUrl;
    final first = firstUrl == null ? null : _first = firstImage(firstUrl, context);
    return Semantics(
      // Names what is there, not finger gestures a screen reader's user cannot make; the Фото tab is beside it.
      label: tr('Аяқкиімнің 3D көрінісі'),
      child: ColoredBox(
        color: scene.ink,
        // Only the 3D itself on the stage, no photo in front of it (Aza, 2026-10-24): its own first picture, or a quiet
        // line, until it draws, then the shoe fades in. The photos stand in only when the 3D cannot open.
        child: Stack(fit: StackFit.expand, children: [
          if (first != null) IgnorePointer(child: FirstPicture(image: first, scene: scene, loading: _loading(scene))),
          if (view != null && !_broken)
            AnimatedOpacity(
              opacity: _ready ? 1 : 0,
              duration: _fade(context),
              child: ExcludeSemantics(child: view.widget),
            ),
          if (_broken) IgnorePointer(child: widget.cover),
          if (!_ready && !_broken && first == null) _loading(scene),
        ]),
      ),
    );
  }

  Widget _loading(ShowcaseScene scene) => Center(
        child: Text(tr('3D ашылуда…'),
            key: const Key('model-loading'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scene.muted)),
      );
}

/// The 3D's first picture: carried inside the demo app, else from the internet and kept; decoded no larger than the
/// screen's narrower side needs (the stage is as wide as the screen).
ImageProvider firstImage(String url, BuildContext context) {
  final side =
      math.min(1080, (MediaQuery.sizeOf(context).shortestSide * MediaQuery.devicePixelRatioOf(context)).round());
  return ResizeImage.resizeIfNeeded(
      side,
      null,
      switch (carriedAsset(url)) {
        final asset? => AssetImage(asset),
        null => netImage(url),
      });
}

/// The 3D's own first picture on the scene and its halo, at the very size and place the stage's 3D draws the shoe:
/// the viewer's camera sees 30° across the stage's narrower side from a fixed distance, so a square picture made the
/// same way is the shoe exactly, at the narrower side's size. [loading] shows until the picture first comes; another
/// colour's picture then takes its place without a gap.
class FirstPicture extends StatefulWidget {
  const FirstPicture({super.key, required this.image, required this.scene, required this.loading});
  final ImageProvider image;
  final ShowcaseScene scene;
  final Widget loading;

  @override
  State<FirstPicture> createState() => _FirstPictureState();
}

class _FirstPictureState extends State<FirstPicture> {
  bool _came = false;

  @override
  Widget build(BuildContext context) {
    final scene = widget.scene;
    return DecoratedBox(
      key: const Key('model-first'),
      // The viewer page's halo: radial-gradient(circle closest-side, halo 0%, transparent 88%).
      decoration: BoxDecoration(
          gradient: RadialGradient(
              radius: 0.5, colors: [scene.halo, scene.halo.withValues(alpha: 0)], stops: const [0, 0.88])),
      child: LayoutBuilder(builder: (context, box) {
        final side = math.min(box.maxWidth, box.maxHeight);
        return Center(
          child: Image(
            image: widget.image,
            width: side,
            height: side,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            excludeFromSemantics: true,
            frameBuilder: (_, child, frame, sync) {
              if (frame != null || sync) _came = true;
              return _came ? child : widget.loading;
            },
            errorBuilder: (_, __, ___) => widget.loading,
          ),
        );
      }),
    );
  }
}

/// Lets go of the page kept ready when the app goes to the background or the phone is short of memory.
class _SpareGuard with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) ModelStage._dropSpare();
  }

  @override
  void didHaveMemoryPressure() => ModelStage._dropSpare();
}

/// Tells the stage when Android stopped its WebView's page process (low memory): without this the whole app would
/// close (MainActivity's RendererGuard).
const _guard = MethodChannel('vitrina/webview');
final _gone = <int, VoidCallback>{};

Future<ModelView?> _webView(Brightness scene, void Function(String message) onMessage) async {
  // No WebView here (the web, widget tests): the listing shows its photos.
  if (kIsWeb || WebViewPlatform.instance == null) return null;
  // The page kept ready (waited for while it is still opening), when it is still whole; else one opened now.
  var view = ModelStage._spare;
  ModelStage._spare = null;
  final making = ModelStage._making;
  if (view == null && making != null) {
    view = await making;
    // Whichever of the two heard first: the page is this stage's, not kept for the next.
    if (ModelStage._spare == view) {
      ModelStage._spare = null;
    } else {
      ModelStage._taken.add(view);
    }
  }
  if (view != null && (view._dead || view._lost)) {
    view.dispose();
    view = null;
  }
  if (view != null) {
    await view._controller
        .setBackgroundColor((scene == Brightness.dark ? ShowcaseScene.dark : ShowcaseScene.light).ink);
  } else {
    view = await _open(scene);
  }
  if (view == null) return null;
  view._listener = onMessage;
  // Its page loaded before the stage listened: told now, after the stage has the view.
  if (view._paged) scheduleMicrotask(() => onMessage(jsonEncode({'type': 'page'})));
  return view;
}

/// A WebView with the stage's page opening in it; what the page says goes to whoever listens by then.
Future<_WebModelView?> _open(Brightness scene) async {
  final host = await ViewerHost.instance;
  if (host == null) return null;
  final page = host.page;
  final controller = WebViewController();
  final view = _WebModelView(controller);
  await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
  await controller.setBackgroundColor((scene == Brightness.dark ? ShowcaseScene.dark : ShowcaseScene.light).ink);
  await controller.addJavaScriptChannel('Vitrina', onMessageReceived: (m) => view._heard(m.message));
  // Only the stage's own page (the same origin exactly): a link never opens inside it. Set before the guard below,
  // which wraps this very client.
  await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (r) =>
          Uri.tryParse(r.url)?.origin == page.origin ? NavigationDecision.navigate : NavigationDecision.prevent,
      onWebResourceError: (e) {
        if (e.isForMainFrame ?? false) view._heard(jsonEncode({'type': 'error', 'message': e.description}));
      }));
  if (controller.platform case final AndroidWebViewController android) {
    final id = android.webViewIdentifier;
    _guard.setMethodCallHandler((call) async {
      if (call.method == 'gone') _gone.remove(call.arguments)?.call();
    });
    _gone[id] = () {
      view._dead = true;
      view._heard(jsonEncode({'type': 'lost', 'message': 'page process gone'}));
    };
    view._id = id;
    try {
      await _guard.invokeMethod<bool>('guard', id);
    } catch (e) {
      debugPrint('3D stage: $e');
    }
  }
  await controller.loadRequest(page);
  return view;
}

class _WebModelView implements ModelView {
  _WebModelView(this._controller);
  final WebViewController _controller;
  bool _dead = false; // its page process is gone: Android forbids using it again
  int? _id;
  void Function(String message)? _listener; // the stage showing it; none while it is kept ready
  bool _paged = false; // its page has loaded
  bool _lost = false; // its page cannot draw (no WebGL): not given to a stage

  void _heard(String message) {
    try {
      final m = jsonDecode(message) as Map;
      switch (m['type']) {
        case 'page':
          _paged = true;
        case 'lost':
          _lost = true;
          // This phone has no WebGL: no page is opened ahead again (each would fail the same).
          if (m['message'] == 'no webgl') ModelStage._noSpare = true;
        case 'error' when _listener == null:
          _lost = true; // a page that did not load is not given to a stage
      }
    } catch (_) {}
    _listener?.call(message);
  }

  @override
  void dispose() {
    _dead = true;
    if (_id != null) _gone.remove(_id);
  }

  @override
  late final Widget widget = WebViewWidget(
    controller: _controller,
    // Every finger on the stage turns the shoe: the page scrolls from outside it.
    gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer())},
  );

  @override
  Future<void> run(String script) async {
    if (_dead) return;
    try {
      await _controller.runJavaScript(script);
    } catch (e) {
      debugPrint('3D stage: $e');
    }
  }

  @override
  Future<Object?> read(String script) async {
    if (_dead) return null;
    try {
      return await _controller.runJavaScriptReturningResult(script);
    } catch (_) {
      return null;
    }
  }
}
