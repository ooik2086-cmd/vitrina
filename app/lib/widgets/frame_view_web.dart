import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'model_stage.dart' show ModelView;

int _views = 0;

/// The 3D stage in a browser: its page in a frame of the app's own site, spoken to by window messages (bridge.js).
Future<ModelView?> openFrameView(Uri page, Color ink, void Function(String message) onMessage) async =>
    _FrameView(page, ink, onMessage);

/// Whether [view]'s frame takes clicks: not while a page or sheet lies over it (the browser would give the click to
/// the frame under it, not to what is drawn on top).
void setFrameTouchable(ModelView view, bool on) {
  if (view is _FrameView) view._frame.style.pointerEvents = on ? 'auto' : 'none';
}

/// `vitrina.name(a, b)` as the stage writes its calls: the name and its JSON arguments.
final _call = RegExp(r'^vitrina\.(\w+)\((.*)\)$', dotAll: true);

class _FrameView implements ModelView {
  _FrameView(Uri page, Color ink, this._onMessage) {
    final hex = (ink.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    _frame
      ..src = page.toString()
      ..title = '3D'
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.background = '#$hex';
    ui_web.platformViewRegistry.registerViewFactory(_type, (int _) => _frame);
    _heard = web.EventStreamProviders.messageEvent.forTarget(web.window).listen(_receive);
  }

  final _type = 'vitrina-3d-${_views++}';
  final _frame = web.HTMLIFrameElement();
  final void Function(String message) _onMessage;
  late final StreamSubscription<web.MessageEvent> _heard;
  final _asked = <int, Completer<Object?>>{};
  int _nextAsk = 0;
  bool _gone = false;

  void _receive(web.MessageEvent e) {
    final from = _frame.contentWindow;
    if (_gone || from == null || !e.source.strictEquals(from).toDart) return;
    final data = e.data.dartify();
    if (data is! Map) return;
    if (data['vitrina'] case final String message) _onMessage(message);
    if (data['answer'] case final num id) _asked.remove(id.toInt())?.complete(data['value']);
  }

  /// Sends one of the stage's calls to the page; false when [script] is not one.
  bool _send(String script, [int? id]) {
    final m = _call.firstMatch(script.trim());
    final to = _frame.contentWindow;
    if (m == null || to == null) return false;
    final List<Object?> args;
    try {
      args = jsonDecode('[${m[2]}]') as List<Object?>;
    } catch (_) {
      return false;
    }
    to.postMessage({'call': m[1], 'args': args, 'id': id}.jsify(), '*'.toJS);
    return true;
  }

  @override
  late final Widget widget = HtmlElementView(viewType: _type);

  @override
  Future<void> run(String script) async {
    if (!_gone) _send(script);
  }

  @override
  Future<Object?> read(String script) async {
    if (_gone) return null;
    final id = _nextAsk++;
    final answer = _asked[id] = Completer<Object?>();
    if (!_send(script, id)) {
      _asked.remove(id);
      return null;
    }
    return answer.future.timeout(const Duration(seconds: 2), onTimeout: () {
      _asked.remove(id);
      return null;
    });
  }

  @override
  void dispose() {
    _gone = true;
    _heard.cancel();
    for (final a in _asked.values) {
      a.complete(null);
    }
    _asked.clear();
  }
}
