import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../api.dart';
import '../i18n.dart';
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

/// The listing page's 3D stage: the shoe turns every way under the finger and zooms, on the light or dark scene. The
/// [cover] photo stands in until the first 3D picture is drawn, and stays if the 3D cannot open ([onBroken] is told,
/// so the page can show the photos instead): the stage is never empty.
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
    _view?.dispose();
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
  /// cover stands in until it is drawn, as when the stage opened.
  Future<void> _swap() async {
    final kept = await view();
    if (!mounted) return;
    _wait();
    setState(() => _ready = false);
    await _load(kept);
  }

  /// The turn and zoom shown now, to open another colour of this model the same; null before the shoe is shown.
  Future<List<double>?> view() async {
    if (!_ready) return null;
    var value = await _view?.read('vitrina.view()');
    // Android hands back a JavaScript string still quoted.
    if (value is String && value.startsWith('"')) value = jsonDecode(value);
    try {
      final list = value is String ? jsonDecode(value) : value;
      if (list is List && list.length == 5) return [for (final x in list) (x as num).toDouble()];
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.dark ? ShowcaseScene.dark : ShowcaseScene.light;
    final view = _view;
    return Semantics(
      // Names what is there, not finger gestures a screen reader's user cannot make; the Фото tab is beside it.
      label: tr('Аяқкиімнің 3D көрінісі'),
      child: ColoredBox(
        color: scene.ink,
        child: Stack(fit: StackFit.expand, children: [
          if (view != null && !_broken)
            // Kept under the cover until its first picture, so the cover never blinks to an empty scene.
            Opacity(opacity: _ready ? 1 : 0, child: ExcludeSemantics(child: view.widget)),
          if (!_ready || _broken)
            IgnorePointer(
              child: Stack(fit: StackFit.expand, children: [
                widget.cover,
                if (!_broken)
                  Align(
                    alignment: const Alignment(0, 0.86),
                    child: Text(tr('3D ашылуда…'),
                        key: const Key('model-loading'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scene.muted)),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// Tells the stage when Android stopped its WebView's page process (low memory): without this the whole app would
/// close (MainActivity's RendererGuard).
const _guard = MethodChannel('vitrina/webview');
final _gone = <int, VoidCallback>{};

Future<ModelView?> _webView(Brightness scene, void Function(String message) onMessage) async {
  // No WebView here (the web, widget tests): the listing shows its photos.
  if (kIsWeb || WebViewPlatform.instance == null) return null;
  final host = await ViewerHost.instance;
  if (host == null) return null;
  final page = host.page;
  final controller = WebViewController();
  await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
  await controller.setBackgroundColor((scene == Brightness.dark ? ShowcaseScene.dark : ShowcaseScene.light).ink);
  await controller.addJavaScriptChannel('Vitrina', onMessageReceived: (m) => onMessage(m.message));
  // Only the stage's own page (the same origin exactly): a link never opens inside it. Set before the guard below,
  // which wraps this very client.
  await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (r) =>
          Uri.tryParse(r.url)?.origin == page.origin ? NavigationDecision.navigate : NavigationDecision.prevent,
      onWebResourceError: (e) {
        if (e.isForMainFrame ?? false) onMessage(jsonEncode({'type': 'error', 'message': e.description}));
      }));
  final view = _WebModelView(controller);
  if (controller.platform case final AndroidWebViewController android) {
    final id = android.webViewIdentifier;
    _guard.setMethodCallHandler((call) async {
      if (call.method == 'gone') _gone.remove(call.arguments)?.call();
    });
    _gone[id] = () {
      view._dead = true;
      onMessage(jsonEncode({'type': 'lost', 'message': 'page process gone'}));
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
