// Every button on every main screen and sheet, pressed with the connection down: whatever it tries to send or
// fetch, the person is told the connection is down, nothing keeps spinning, and nothing breaks.
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/demo.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/main.dart' show forgetLastTab;
import 'package:vitrina/my_size.dart';
import 'package:vitrina/recent.dart';
import 'package:vitrina/screens/order_screen.dart';
import 'package:vitrina/screens/spin_capture_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';
import 'package:vitrina/widgets/delivery_eta.dart';

import 'support/screens.dart';

/// What a finger can press on screen now: each node with a tap, by its centre and its name.
List<(Offset, String)> _pressable(WidgetTester tester) {
  final found = <(Offset, String)>[];
  final view = tester.view;
  final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  void walk(SemanticsNode node, Matrix4 transform) {
    final t = node.transform == null ? transform : (transform.clone()..multiply(node.transform!));
    final data = node.getSemanticsData();
    if (!node.isMergedIntoParent &&
        !data.flagsCollection.isHidden &&
        data.hasAction(ui.SemanticsAction.tap) &&
        data.flagsCollection.isEnabled != ui.Tristate.isFalse) {
      final rect = MatrixUtils.transformRect(t, node.rect);
      final centre = rect.center / view.devicePixelRatio;
      if (screen.deflate(1).contains(centre)) {
        found.add((centre, (data.label.isEmpty ? data.tooltip : data.label).replaceAll('\n', ' ')));
      }
    }
    node.visitChildren((c) {
      walk(c, t);
      return true;
    });
  }

  for (final v in tester.binding.renderViews) {
    walk(v.owner!.semanticsOwner!.rootSemanticsNode!, Matrix4.identity());
  }
  return found;
}

/// Counts the dialogs, sheets and menus a press opens.
class _Popups extends NavigatorObserver {
  int opened = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) opened++;
  }
}

/// Opens [screen] (or [sheet] over a stand-in page) fresh: nothing kept from the last open, as at launch.
Future<(Line, _Popups)> _open(WidgetTester tester, Widget Function() screen, Widget? sheet) async {
  SharedPreferences.setMockInitialValues({});
  await loadFonts(tester);
  appLanguage.value = 'kk';
  forgetLastTab();
  recentlyViewed.value = const [];
  recentSearches.value = const [];
  pickedDeliveryCity.value = null;
  mySize.value = null;
  final client = await tester.runAsync(() => DemoClient.load());
  final line = Line(client!);
  final popups = _Popups();
  final session = Session(Api(base: 'http://demo/api/v1', client: line))..api.token = demoToken;
  session.update((await tester.runAsync(() => session.api.me()))!);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5)); // what the last one left running ends
  await tester.pumpWidget(SessionScope(
      session: session,
      child: MaterialApp(
          theme: buildTheme(Brightness.light),
          navigatorObservers: [popups],
          home: sheet == null
              ? screen()
              : Builder(
                  builder: (context) => Scaffold(
                      body: Center(
                          child: TextButton(
                              onPressed: () => showModalBottomSheet<void>(
                                  context: context, isScrollControlled: true, builder: (_) => sheet),
                              child: const Text('open'))))))));
  await _settle(tester);
  if (sheet != null) {
    await tester.tap(find.text('open'));
    await _settle(tester);
  }
  popups.opened = 0;
  return (line, popups);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Scrolls the biggest page a finger can reach on top by one step; false when it is already at the end.
Future<bool> _scrollOn(WidgetTester tester) async {
  final pages = find
      .byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical)
      .hitTestable()
      .evaluate()
      .map((e) => (e as StatefulElement).state as ScrollableState)
      .where((s) => s.position.hasContentDimensions && s.position.maxScrollExtent > 0)
      .toList()
    ..sort((a, b) => (b.context.size!.height).compareTo(a.context.size!.height));
  if (pages.isEmpty) return false;
  final page = pages.first.position;
  final before = page.pixels;
  page.jumpTo(min(page.pixels + 400, page.maxScrollExtent));
  await tester.pump(const Duration(milliseconds: 300));
  return page.pixels != before;
}

/// Every name a finger can press on the top page, down to its end, in order; a name met twice is pressed once.
Future<List<String>> _names(WidgetTester tester) async {
  final names = <String>[];
  for (var k = 0; k < 30; k++) {
    for (final (_, name) in _pressable(tester)) {
      if (!names.contains(name)) names.add(name);
    }
    if (!await _scrollOn(tester)) break;
  }
  return names;
}

/// Brings the press named [name] on screen from the top of a fresh page and gives where to press.
Future<Offset?> _reach(WidgetTester tester, String name) async {
  for (var k = 0; k < 30; k++) {
    for (final (at, n) in _pressable(tester)) {
      if (n == name) return at;
    }
    if (!await _scrollOn(tester)) break;
  }
  return null;
}

/// Requests whose failure is rightly quiet: hints a page works without, fetched on the side of what was pressed.
const _hints = [
  '/me/todo', // the count on the profile tab; the profile itself says when it cannot load
  '/delivery-estimate', // the arrival guess under the price; a city the buyer picks is said when it fails
];

/// Presses everything on [screen] (or [sheet]) with the connection down, each from a fresh open, and the presses of
/// every dialog, sheet or menu a press opens, down to three steps: the step before is pressed with the line up.
Future<List<String>> pressAll(WidgetTester tester, Widget Function() screen, {Widget? sheet}) async {
  tester.view.physicalSize = const Size(360, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final handle = tester.ensureSemantics();
  final errors = <String>[];
  final old = FlutterError.onError;
  addTearDown(() => FlutterError.onError = old);
  var name = 'opening';
  FlutterError.onError = (d) {
    errors.add('"$name": ${d.exceptionAsString().split('\n').first}');
    if (const bool.fromEnvironment('TRACE')) debugPrint('TRACE "$name" ${d.stack}');
  };
  await _open(tester, screen, sheet); // the first open also loads what later ones find ready
  await _open(tester, screen, sheet);
  final todo = [
    for (final n in await _names(tester))
      if (!(sheet != null && n == 'open')) [n]
  ];
  var pressed = 0;
  while (todo.isNotEmpty) {
    final path = todo.removeAt(0);
    final label = path.join(' › ');
    // Online: the steps before, then the last one, to see whether it opens a dialog, sheet or menu.
    var (line, popups) = await _open(tester, screen, sheet);
    Offset? at;
    for (var i = 0; i < path.length; i++) {
      at = await _reach(tester, path[i]);
      if (at == null) break;
      if (i < path.length - 1) {
        await tester.tapAt(at);
        await _settle(tester);
      }
    }
    if (at == null) {
      errors.add('"$label": not found on a fresh open');
      continue;
    }
    final before = popups.opened;
    await tester.tapAt(at);
    await _settle(tester);
    if (popups.opened > before && path.length < 3) {
      for (final n in await _names(tester)) {
        todo.add([...path, n]);
      }
    }
    // Offline: the same steps, the last one with the line down.
    (line, popups) = await _open(tester, screen, sheet);
    for (var i = 0; i < path.length; i++) {
      final last = i == path.length - 1;
      at = await _reach(tester, path[i]);
      if (at == null) break;
      if (last) line.down = true;
      name = label;
      final dropped = line.dropped.length;
      await tester.tapAt(at);
      for (var j = 0; j < (last ? 10 : 6); j++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      if (!last) continue;
      pressed++;
      final sent = line.dropped.skip(dropped).where((r) => !_hints.any(r.contains)).toSet();
      bool told() =>
          find.textContaining('Байланыс жоқ').evaluate().isNotEmpty ||
          find.byKey(const Key('retry')).evaluate().isNotEmpty;
      // What is said may be further down the page the press opened.
      for (var k = 0; k < 8 && sent.isNotEmpty && !told(); k++) {
        if (!await _scrollOn(tester)) break;
      }
      if (sent.isNotEmpty && !told()) {
        errors.add('"$label": nothing says the connection is down (${sent.join(', ')})');
      }
      // The camera page waits for a camera, which a test has none of; it needs no connection.
      if (find.byType(CircularProgressIndicator).hitTestable().evaluate().isNotEmpty &&
          find.byType(SpinCaptureScreen).evaluate().isEmpty) {
        errors.add('"$label": still spinning');
      }
    }
    if (at == null) errors.add('"$label": not found on a fresh open');
    name = 'after "$label"';
  }
  if (const bool.fromEnvironment('TRACE')) debugPrint('PRESSED $pressed');
  FlutterError.onError = old;
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
  handle.dispose();
  return errors;
}

void main() {
  for (final e in screens.entries) {
    testWidgets('every button on ${e.key} copes with no connection', (tester) async {
      expect(await pressAll(tester, e.value), isEmpty);
    });
  }
  testWidgets('a city picked for the arrival guess says when it cannot be asked', (tester) async {
    pickedDeliveryCity.value = null;
    addTearDown(() => pickedDeliveryCity.value = null);
    var down = false;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (down) throw http.ClientException('down');
          return http.Response(
              jsonEncode({
                'estimate': null,
                'cities': ['Алматы', 'Астана']
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    await tester.pumpWidget(
        SessionScope(session: Session(api), child: const MaterialApp(home: Scaffold(body: DeliveryEta(listingId: 5)))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delivery-eta')));
    await tester.pumpAndSettle();
    down = true;
    await tester.tap(find.byKey(const Key('eta-city-Астана')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Байланыс жоқ'), findsOneWidget);
    expect(pickedDeliveryCity.value, isNull, reason: 'the next listing would quietly ask for a city not shown here');
  });
  testWidgets('an order placed with the connection down is said, and nothing opens as if it went through',
      (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (line, _) = await _open(tester, screens['listing1']!, null);
    await tester.scrollUntilVisible(find.text('42'), 300,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first);
    // Mid-screen, clear of the buy bar.
    Scrollable.ensureVisible(tester.element(find.text('42').first), alignment: 0.4);
    await tester.pump();
    await tester.tap(find.text('42').first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('buy')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('delivery-name')), 'Аза Сапар');
    await tester.enterText(find.byKey(const Key('delivery-phone')), '+7 701 000 00 00');
    await tester.enterText(find.byKey(const Key('delivery-city')), 'Алматы');
    await tester.enterText(find.byKey(const Key('delivery-address')), 'Абай даңғылы 10');
    await tester.ensureVisible(find.byKey(const Key('delivery-continue')));
    await tester.pump();
    line.down = true;
    final before = line.dropped.length;
    await tester.tap(find.byKey(const Key('delivery-continue')));
    await _settle(tester);
    expect(line.dropped.skip(before), contains('POST /orders'));
    expect(find.textContaining('Байланыс жоқ'), findsOneWidget);
    expect(find.byType(OrderScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
  for (final e in sheets.entries) {
    testWidgets('every button on the ${e.key} sheet copes with no connection', (tester) async {
      expect(await pressAll(tester, () => const SizedBox(), sheet: e.value()), isEmpty);
    });
  }
}
