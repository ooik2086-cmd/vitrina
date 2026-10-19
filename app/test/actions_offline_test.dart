// Every button on every main screen and sheet, pressed with the connection down: whatever it tries to send or
// fetch, the person is told the connection is down, nothing keeps spinning, and nothing breaks.
import 'dart:convert';
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

Future<Line> _open(WidgetTester tester, Widget Function() screen, Widget? sheet) async {
  SharedPreferences.setMockInitialValues({});
  await loadFonts(tester);
  appLanguage.value = 'kk';
  final client = await tester.runAsync(() => DemoClient.load());
  final line = Line(client!);
  final session = Session(Api(base: 'http://demo/api/v1', client: line))..api.token = demoToken;
  session.update((await tester.runAsync(() => session.api.me()))!);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5)); // what the last one left running ends
  await tester.pumpWidget(SessionScope(
      session: session,
      child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: sheet == null
              ? screen()
              : Builder(
                  builder: (context) => Scaffold(
                      body: Center(
                          child: TextButton(
                              onPressed: () => showModalBottomSheet<void>(
                                  context: context, isScrollControlled: true, builder: (_) => sheet),
                              child: const Text('open'))))))));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  if (sheet != null) {
    await tester.tap(find.text('open'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }
  return line;
}

/// Requests whose failure is rightly quiet: hints a page works without, fetched on the side of what was pressed.
const _hints = [
  '/me/todo', // the count on the profile tab; the profile itself says when it cannot load
  '/delivery-estimate', // the arrival guess under the price; a city the buyer picks is said when it fails
];

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
  await _open(tester, screen, sheet);
  final buttons = _pressable(tester);
  for (var i = 0; i < buttons.length; i++) {
    final line = await _open(tester, screen, sheet);
    final now = _pressable(tester);
    if (i >= now.length) break;
    final (at, label) = now[i];
    name = label;
    if (sheet != null && name == 'open') continue;
    line.down = true;
    final before = line.dropped.length;
    await tester.tapAt(at);
    for (var j = 0; j < 10; j++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    final sent = line.dropped.skip(before).where((r) => !_hints.any(r.contains)).toSet();
    bool told() =>
        find.textContaining('Байланыс жоқ').evaluate().isNotEmpty ||
        find.byKey(const Key('retry')).evaluate().isNotEmpty;
    // What is said may be further down the page the press opened.
    for (var k = 0; k < 8 && sent.isNotEmpty && !told(); k++) {
      final page = find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).hitTestable();
      if (page.evaluate().isEmpty) break;
      await tester.drag(page.first, const Offset(0, -400), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (sent.isNotEmpty && !told()) errors.add('"$name": nothing says the connection is down (${sent.join(', ')})');
    // The camera page waits for a camera, which a test has none of; it needs no connection.
    if (find.byType(CircularProgressIndicator).hitTestable().evaluate().isNotEmpty &&
        find.byType(SpinCaptureScreen).evaluate().isEmpty) {
      errors.add('"$name": still spinning');
    }
    name = 'after "$label"';
  }
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
  });
  for (final e in sheets.entries) {
    testWidgets('every button on the ${e.key} sheet copes with no connection', (tester) async {
      expect(await pressAll(tester, () => const SizedBox(), sheet: e.value()), isEmpty);
    });
  }
}
