// Pressing everything on a screen, one press at a time from a fresh open: shared by the press tests.
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/demo.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/main.dart' show forgetLastTab;
import 'package:vitrina/my_size.dart';
import 'package:vitrina/recent.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';
import 'package:vitrina/widgets/delivery_eta.dart';

import 'screens.dart';

/// What a finger can press on screen now: each node with a tap, by its centre and its name.
List<(Offset, String)> pressable(WidgetTester tester) {
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

/// Counts the dialogs, sheets and menus a press opens, and the pages.
class Popups extends NavigatorObserver {
  int opened = 0, pages = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      opened++;
    } else {
      pages++;
    }
  }
}

/// Opens [screen] (or [sheet] over a stand-in page) fresh: nothing kept from the last open, as at launch.
Future<(Line, Popups)> openFresh(WidgetTester tester, Widget Function() screen, Widget? sheet) async {
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
  final popups = Popups();
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
  await settle(tester);
  if (sheet != null) {
    await tester.tap(find.text('open'));
    await settle(tester);
  }
  popups.opened = 0;
  return (line, popups);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Scrolls the biggest page a finger can reach on top by one step; false when it is already at the end.
Future<bool> scrollOn(WidgetTester tester) async {
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
Future<List<String>> pressNames(WidgetTester tester) async {
  final names = <String>[];
  for (var k = 0; k < 30; k++) {
    for (final (_, name) in pressable(tester)) {
      if (!names.contains(name)) names.add(name);
    }
    if (!await scrollOn(tester)) break;
  }
  return names;
}

/// Brings the press named [name] on screen from the top of a fresh page and gives where to press.
Future<Offset?> reach(WidgetTester tester, String name) async {
  for (var k = 0; k < 30; k++) {
    for (final (at, n) in pressable(tester)) {
      if (n == name) return at;
    }
    if (!await scrollOn(tester)) break;
  }
  return null;
}

/// Visits every press on [screen] (or [sheet] over a stand-in page) at 360×720, and the presses of every dialog,
/// sheet or menu a press opens, down to three steps. Each is reached on a fresh open, the steps before it pressed
/// with the line up; [press] then does the last press itself and adds what it finds wrong to the errors. Flutter's
/// own errors are added too, named by the press they followed.
Future<List<String>> forEveryPress(WidgetTester tester, Widget Function() screen, Widget? sheet,
    Future<void> Function(String label, Line line, Popups popups, Offset at, List<String> errors) press) async {
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
  await openFresh(tester, screen, sheet); // the first open also loads what later ones find ready
  await openFresh(tester, screen, sheet);
  final todo = [
    for (final n in await pressNames(tester))
      if (!(sheet != null && n == 'open')) [n]
  ];
  var pressed = 0;
  while (todo.isNotEmpty) {
    final path = todo.removeAt(0);
    final label = path.join(' › ');
    // The steps before, then the last one, to see whether it opens a dialog, sheet or menu.
    var (line, popups) = await openFresh(tester, screen, sheet);
    Offset? at;
    for (var i = 0; i < path.length; i++) {
      at = await reach(tester, path[i]);
      if (at == null) break;
      if (i < path.length - 1) {
        await tester.tapAt(at);
        await settle(tester);
      }
    }
    if (at == null) {
      errors.add('"$label": not found on a fresh open');
      continue;
    }
    final before = popups.opened;
    await tester.tapAt(at);
    await settle(tester);
    if (popups.opened > before && path.length < 3) {
      for (final n in await pressNames(tester)) {
        todo.add([...path, n]);
      }
    }
    // Again from a fresh open, the last press done by [press].
    (line, popups) = await openFresh(tester, screen, sheet);
    for (var i = 0; i < path.length; i++) {
      at = await reach(tester, path[i]);
      if (at == null) break;
      name = label;
      if (i == path.length - 1) {
        popups.opened = 0;
        popups.pages = 0;
        await press(label, line, popups, at, errors);
        pressed++;
      } else {
        await tester.tapAt(at);
        await settle(tester);
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
