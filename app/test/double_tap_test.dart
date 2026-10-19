// What a second tap on a slow connection must not do, where the press suites (test/presses_*_test.dart) cannot see it:
// notification switches saved in order, and the once() guard itself.
import 'dart:async';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/notification_settings_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/common.dart';

/// Notification settings whose saves wait for [answers], one per save, and fail when one completes with false.
Future<List<bool>> _settings(WidgetTester tester, List<Completer<bool>> answers) async {
  final on = {'price_drop': true, 'saved_search': true};
  final saved = <bool>[];
  var asked = 0;
  http.Response items() => http.Response(
      jsonEncode({
        'items': [
          for (final e in on.entries) {'kind': e.key, 'on': e.value}
        ]
      }),
      200,
      headers: {'content-type': 'application/json'});
  final api = Api(
      base: 'http://x/api/v1',
      client: MockClient((req) async {
        if (req.method == 'GET') return items();
        final change = (jsonDecode(req.body) as Map).entries.single;
        final (kind, wish) = (change.key as String, change.value as bool);
        if (!await answers[asked++].future) throw http.ClientException('down');
        saved.add(wish);
        on[kind] = wish;
        return items();
      }));
  await tester
      .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: NotificationSettingsScreen())));
  await tester.pumpAndSettle();
  return saved;
}

bool _switch(WidgetTester tester, [String kind = 'price_drop']) =>
    tester.widget<SwitchListTile>(find.byKey(Key('alert-$kind'))).value;

void main() {
  testWidgets('a switch flipped twice on a slow connection is saved in order and ends as last flipped', (tester) async {
    final answers = [Completer<bool>(), Completer<bool>()];
    final saved = await _settings(tester, answers);
    await tester.tap(find.byKey(const Key('alert-price_drop')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('alert-price_drop')));
    await tester.pump();
    expect(_switch(tester), isTrue, reason: 'it moves at once each time');
    answers[0].complete(true);
    await tester.pump();
    expect(_switch(tester), isTrue, reason: 'the first answer does not undo the later flip');
    answers[1].complete(true);
    await tester.pumpAndSettle();
    expect(saved, [false, true], reason: 'one save at a time, the last wish last');
    expect(_switch(tester), isTrue);
  });

  testWidgets('when that save fails, the switch shows what the server last kept', (tester) async {
    final answers = [Completer<bool>(), Completer<bool>()];
    final saved = await _settings(tester, answers);
    await tester.tap(find.byKey(const Key('alert-price_drop')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('alert-price_drop')));
    await tester.pump();
    answers[0].complete(true); // off is saved
    await tester.pump();
    answers[1].complete(false); // on again is not
    await tester.pumpAndSettle();
    expect(saved, [false]);
    expect(_switch(tester), isFalse);
    expect(find.textContaining('Байланыс жоқ'), findsOneWidget);
  });

  testWidgets('a switch answered while another still saves leaves the other as flipped', (tester) async {
    final answers = [Completer<bool>(), Completer<bool>()];
    await _settings(tester, answers);
    await tester.tap(find.byKey(const Key('alert-price_drop')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('alert-saved_search')));
    await tester.pump();
    answers[0].complete(true);
    await tester.pump();
    expect(_switch(tester, 'saved_search'), isFalse, reason: 'its save is still on the way');
    answers[1].complete(true);
    await tester.pumpAndSettle();
    expect(_switch(tester), isFalse);
    expect(_switch(tester, 'saved_search'), isFalse);
  });

  testWidgets('once lets a second run go while the first still runs, and runs again after', (tester) async {
    final gate = Completer<void>();
    var runs = 0;
    final first = once('k', () async {
      runs++;
      await gate.future;
    });
    await once('k', () async => runs++);
    expect(runs, 1);
    gate.complete();
    await first;
    await once('k', () async => runs++);
    expect(runs, 2);
    await expectLater(once('k', () async => throw StateError('x')), throwsStateError);
    await once('k', () async => runs++);
    expect(runs, 3, reason: 'a failed run lets the next one go');
  });
}
