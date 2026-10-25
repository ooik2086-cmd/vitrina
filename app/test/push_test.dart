// Alerts on the phone while the app is closed: asked at a useful moment, the phone's token sent while signed in and
// taken back on sign-out, and a tapped alert opens what it tells of.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/main.dart';
import 'package:vitrina/push.dart';
import 'package:vitrina/screens/notification_settings_screen.dart';
import 'package:vitrina/session.dart';

class FakePush implements PushPlatform {
  bool granted = false;
  bool phoneSaysYes = true;
  int asked = 0, forgotten = 0;
  String current = 'token-1';
  final tokens = StreamController<String>.broadcast();
  final taps = StreamController<PushTap>.broadcast();
  final messages = StreamController<void>.broadcast();
  PushTap? atStart;

  @override
  Future<bool> allowed() async => granted;

  @override
  Future<bool> ask() async {
    asked++;
    return granted = phoneSaysYes;
  }

  @override
  Future<String?> token() async => current;

  @override
  Stream<String> get tokenChanges => tokens.stream;

  @override
  Future<void> forget() async => forgotten++;

  @override
  Stream<PushTap> get opened => taps.stream;

  @override
  Future<PushTap?> openedAtStart() async => atStart;

  @override
  Stream<void> get arrived => messages.stream;
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  late FakePush phone;
  late List<String> calls; // "METHOD path body bearer"
  late Session session;
  late bool offline;

  /// The server as the app sees it: every call noted; offline, nothing reaches it.
  Api server(bool signedIn) {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (offline) throw http.ClientException('offline');
          calls.add('${req.method} ${req.url.path.replaceFirst('/api/v1', '')} ${req.body} '
              '${req.headers['Authorization']}');
          if (req.url.path.endsWith('/me/todo')) return _json(<String, int>{});
          if (req.method == 'GET') return _json({'items': [], 'unread': 0}); // the tabs and the list, empty
          return http.Response('', req.method == 'POST' ? 200 : 204);
        }))
      ..token = signedIn ? 'tok' : null;
    return api;
  }

  setUp(() async {
    offline = false;
    SharedPreferences.setMockInitialValues({});
    appLanguage.value = 'kk';
    phone = FakePush();
    calls = [];
    session = Session(server(true))..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': true}));
  });

  tearDown(Push.stop);

  List<String> pushCalls() => calls.where((c) => c.contains('/me/push') || c.contains('/auth/logout')).toList();

  /// A page with a button that offers the alerts, as a sent message or an open order does.
  Future<void> page(WidgetTester tester) async {
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            home: Builder(
                builder: (context) => Scaffold(
                    body:
                        Center(child: TextButton(onPressed: () => Push.offer(context), child: const Text('sent'))))))));
  }

  testWidgets('asked once at a useful moment; yes sends the phone token in the app language', (tester) async {
    await Push.use(phone, session);
    expect(pushCalls(), isEmpty, reason: 'the phone does not allow alerts yet: nothing to send');
    await page(tester);
    await tester.tap(find.text('sent'));
    await tester.pumpAndSettle();
    expect(find.text('Телефонға хабарландыру келсін бе?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('push-yes')));
    await tester.pumpAndSettle();
    expect(phone.asked, 1);
    expect(pushCalls(), ['PUT /me/push {"token":"token-1","lang":"kk"} Bearer tok']);

    await tester.tap(find.text('sent'));
    await tester.pumpAndSettle();
    expect(find.text('Телефонға хабарландыру келсін бе?'), findsNothing, reason: 'asked once');

    appLanguage.value = 'ru';
    await tester.pumpAndSettle();
    phone.tokens.add(phone.current = 'token-2');
    await tester.pumpAndSettle();
    expect(pushCalls().skip(1), [
      'PUT /me/push {"token":"token-1","lang":"ru"} Bearer tok',
      'PUT /me/push {"token":"token-2","lang":"ru"} Bearer tok',
    ]);
    appLanguage.value = 'kk';
  });

  testWidgets('"Кейін" asks nothing of the phone and waits before asking again', (tester) async {
    await Push.use(phone, session);
    await page(tester);
    await tester.tap(find.text('sent'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('push-later')));
    await tester.pumpAndSettle();
    expect(phone.asked, 0);
    await tester.tap(find.text('sent'));
    await tester.pumpAndSettle();
    expect(find.text('Телефонға хабарландыру келсін бе?'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('vitrina_push_later',
        DateTime.now().subtract(Push.askAgainAfter + const Duration(hours: 1)).millisecondsSinceEpoch);
    await tester.tap(find.text('sent'));
    await tester.pumpAndSettle();
    expect(find.text('Телефонға хабарландыру келсін бе?'), findsOneWidget, reason: 'asked again after a while');
  });

  testWidgets('a phone that already allows alerts is not asked, its token just goes', (tester) async {
    phone.granted = true;
    await Push.use(phone, session);
    await page(tester);
    await tester.tap(find.text('sent'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(pushCalls(), ['PUT /me/push {"token":"token-1","lang":"kk"} Bearer tok'], reason: 'sent once');
  });

  testWidgets('signing out is at once on the phone, then ends the sign-in and the alerts', (tester) async {
    phone.granted = true;
    await tester.runAsync(() async {
      await Push.use(phone, session);
      calls.clear();
      await session.signOut();
      expect(session.signedIn, isFalse);
      await Future<void>.delayed(Duration.zero);
    });
    expect(phone.forgotten, 1);
    expect(pushCalls(), ['POST /auth/logout  Bearer tok'], reason: 'the server drops the phone with the sign-in');
    await tester.runAsync(Push.register);
    expect(pushCalls().length, 1, reason: 'signed out: no token goes');
  });

  testWidgets('a tapped alert opens what it tells of from the home screen', (tester) async {
    phone.atStart = PushTap.fromData({'kind': 'payout', 'notification_id': '5'});
    await Push.use(phone, session);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: HomeShell())));
    // Not pumpAndSettle: the tabs underneath keep a loading circle turning.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Хабарландырулар'), findsOneWidget, reason: 'nothing of its own to open: the list');
    expect(Push.opened.value, isNull, reason: 'opened once');
    await tester.pumpWidget(const SizedBox()); // stops the polling timer
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('two useful moments at once ask once', (tester) async {
    await Push.use(phone, session);
    await page(tester);
    final context = tester.element(find.text('sent'));
    unawaited(Push.offer(context));
    unawaited(Push.offer(context));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('push-yes')), findsOneWidget);
  });

  testWidgets('the phone says no: told where to turn it on, with a button to the phone settings', (tester) async {
    phone.phoneSaysYes = false;
    final opened = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('vitrina/push'), (call) async {
      opened.add(call.method);
      return true;
    });
    addTearDown(() =>
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('vitrina/push'), null));
    await Push.use(phone, session);
    await page(tester);
    await tester.tap(find.text('sent'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('push-yes')));
    await tester.pumpAndSettle();
    expect(pushCalls(), isEmpty);
    expect(find.text('Баптауды ашу'), findsOneWidget);
    await tester.tap(find.text('Баптауды ашу'));
    await tester.pump();
    expect(opened, ['openSettings']);
  });

  testWidgets('the settings switch turns the phone alerts off and on, and follows the phone on return', (tester) async {
    phone.granted = true;
    await Push.use(phone, session);
    calls.clear();
    await tester
        .pumpWidget(SessionScope(session: session, child: const MaterialApp(home: NotificationSettingsScreen())));
    await tester.pumpAndSettle();
    final phoneSwitch = find.byKey(const Key('alert-phone'));
    expect(tester.widget<SwitchListTile>(phoneSwitch).value, isTrue);
    await tester.tap(phoneSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(phoneSwitch).value, isFalse);
    expect(pushCalls(), ['DELETE /me/push  Bearer tok']);
    await Push.register();
    expect(pushCalls().length, 1, reason: 'turned off here: no token goes');
    await tester.tap(phoneSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(phoneSwitch).value, isTrue);
    expect(pushCalls().last, 'PUT /me/push {"token":"token-1","lang":"kk"} Bearer tok');

    phone.granted = false; // turned off in the phone's settings meanwhile
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(phoneSwitch).value, isFalse);
  });

  testWidgets('a sign-out made offline reaches the server at the next start', (tester) async {
    await tester.runAsync(() async {
      offline = true;
      await session.signOut();
      expect(session.signedIn, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      offline = false;
      await Session(server(false)).restore();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(pushCalls(), ['POST /auth/logout  Bearer tok']);
      await Session(server(false)).restore();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(pushCalls().length, 1, reason: 'ended once');
  });
}
