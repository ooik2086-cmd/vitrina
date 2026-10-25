import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo.dart';
import 'i18n.dart';
import 'session.dart';
import 'widgets/common.dart';

/// What a tapped alert opens: the same as the notification it tells of (notifications_screen.dart openNotice).
class PushTap {
  PushTap.fromData(Map<String, dynamic> data)
      : kind = '${data['kind'] ?? ''}',
        orderId = int.tryParse('${data['order_id']}'),
        conversationId = int.tryParse('${data['conversation_id']}'),
        listingId = int.tryParse('${data['listing_id']}');
  final String kind;
  final int? orderId, conversationId, listingId;
}

/// The phone's side of the alerts: Firebase on a real phone, a stand-in in tests.
abstract class PushPlatform {
  /// Whether the phone lets the app show alerts.
  Future<bool> allowed();

  /// Asks the phone (Android 13 and later show their own question); whether it is allowed now.
  Future<bool> ask();
  Future<String?> token();
  Stream<String> get tokenChanges;

  /// This phone's token is dropped: alerts sent to it no longer arrive, and the next sign-in gets a new one.
  Future<void> forget();

  /// Alerts tapped while the app was in the background, and the one that started it, if any.
  Stream<PushTap> get opened;
  Future<PushTap?> openedAtStart();

  /// Alerts that came while the app was open (the phone shows none then).
  Stream<void> get arrived;
}

// The registration-token calls, not FCM's newer installation-ID ones (register/onRegistered): the server sends to
// a token through the HTTP v1 API, as Firebase documents it (backend vitrina_api/push.py).
// ignore_for_file: deprecated_member_use
class _FirebasePush implements PushPlatform {
  final _m = FirebaseMessaging.instance;

  @override
  Future<bool> allowed() async => _granted((await _m.getNotificationSettings()).authorizationStatus);

  @override
  Future<bool> ask() async => _granted((await _m.requestPermission()).authorizationStatus);

  static bool _granted(AuthorizationStatus s) =>
      s == AuthorizationStatus.authorized || s == AuthorizationStatus.provisional;

  @override
  Future<String?> token() => _m.getToken();

  @override
  Stream<String> get tokenChanges => _m.onTokenRefresh;

  @override
  Future<void> forget() => _m.deleteToken();

  @override
  Stream<PushTap> get opened => FirebaseMessaging.onMessageOpenedApp.map((m) => PushTap.fromData(m.data));

  @override
  Future<PushTap?> openedAtStart() async {
    final m = await _m.getInitialMessage();
    return m == null ? null : PushTap.fromData(m.data);
  }

  @override
  Stream<void> get arrived => FirebaseMessaging.onMessage;
}

/// Alerts on the phone while the app is closed (the server's vitrina_api/push.py sends them). The app works the same
/// without them: a build without the Firebase values (the demo APK, a computer) simply has no push.
///
/// The phone is asked once, at a moment the alerts plainly help (a message sent, an order open, a listing put on
/// sale, a size or search to be told about), with the app's own calm question first; "Кейін" asks again after a
/// while. The phone's token goes to the server at every start, after sign-in and whenever it or the app's language
/// changes; signing out takes it back.
class Push {
  Push._();

  static PushPlatform? _platform;
  static Session? _session;
  static String? _sent; // token, language and sign-in last sent, so nothing is sent twice
  static final _subs = <StreamSubscription<Object?>>[];
  static Future<void> _registering = Future.value();
  static Future<void>? _forgetting;
  static bool _offering = false;
  static const _settings = MethodChannel('vitrina/push');

  /// A tapped alert, waiting for the home screen to open it.
  static final opened = ValueNotifier<PushTap?>(null);

  /// Counts alerts that came while the app was open, so the badges catch up at once.
  static final arrived = ValueNotifier<int>(0);

  static const _laterKey = 'vitrina_push_later';
  static const _askedKey = 'vitrina_push_asked';
  static const _offKey = 'vitrina_push_off';
  static const askAgainAfter = Duration(days: 14);

  static bool get available => _platform != null;

  /// Firebase starts only in a build that carries its values; anything else leaves push off, quietly.
  static Future<void> start(Session session) async {
    if (demoMode || kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await Firebase.initializeApp();
    } catch (_) {
      return; // built without --dart-define=FCM_* (android/app/build.gradle.kts)
    }
    await use(_FirebasePush(), session);
  }

  /// Push through [platform]: Firebase in the app, a stand-in in tests.
  @visibleForTesting
  static Future<void> use(PushPlatform platform, Session session) async {
    stop();
    _platform = platform;
    _session = session;
    _subs
      ..add(platform.tokenChanges.listen((_) => unawaited(register())))
      ..add(platform.opened.listen((tap) => opened.value = tap))
      ..add(platform.arrived.listen((_) => arrived.value++));
    appLanguage.addListener(_languageChanged);
    try {
      final first = await platform.openedAtStart();
      if (first != null) opened.value = first;
    } catch (_) {}
    await register();
  }

  @visibleForTesting
  static void stop() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    appLanguage.removeListener(_languageChanged);
    _platform = _session = _sent = _forgetting = null;
    _registering = Future.value();
    _offering = false;
    opened.value = null;
  }

  static void _languageChanged() => unawaited(register());

  /// Sends this phone's token, when the person is signed in, the phone allows alerts and they did not turn them off.
  /// One at a time: a start, a sign-in and a new token at once send it once. Also when the app comes back to the
  /// screen, as the person may have allowed alerts in the phone's settings meanwhile.
  static Future<void> register() => _registering = _registering.then((_) => _register());

  static Future<void> _register() async {
    final platform = _platform, session = _session;
    final bearer = session?.api.token;
    if (platform == null || session == null || bearer == null) return;
    try {
      await _forgetting; // a token being dropped is not sent again
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_offKey) ?? false) return;
      if (!await platform.allowed()) return;
      final token = await platform.token();
      if (token == null) return;
      // Signed out (or in as someone else) meanwhile: this sign-in's token is not sent.
      if (session.api.token != bearer) return;
      final what = '$token ${appLanguage.value} $bearer';
      if (what == _sent) return;
      await session.api.putPush(token, appLanguage.value);
      _sent = what;
    } catch (_) {
      // Offline, or Firebase away for a moment: tried again at the next start, sign-in, new token or return.
    }
  }

  /// After signing out (the server drops the phone with the sign-in): Firebase forgets this phone's token as well,
  /// in case the server was not reached. The next sign-in waits for this and sends the new token.
  static Future<void> forget() {
    final platform = _platform;
    if (platform == null) return Future.value();
    _sent = null;
    return _forgetting = platform.forget().catchError((Object _) {});
  }

  /// Whether alerts reach this phone now: allowed by the phone and not turned off here.
  static Future<bool> on() async {
    final platform = _platform;
    if (platform == null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_offKey) ?? false) return false;
      return await platform.allowed();
    } catch (_) {
      return false;
    }
  }

  /// The settings switch, and "Иә, қосу". Asks the phone if need be; false when the phone said no.
  static Future<bool> turnOn() async {
    final platform = _platform;
    if (platform == null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_askedKey, true);
      if (!(await platform.allowed() || await platform.ask())) return false;
      await prefs.remove(_offKey);
    } catch (_) {
      return false;
    }
    unawaited(register()); // the answer is the phone's; the token goes on its own time
    return true;
  }

  /// The settings switch turned off: the server forgets this phone (offline, Firebase does, which ends it too).
  static Future<void> turnOff() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_offKey, true);
    final session = _session;
    _sent = null;
    if (session != null && session.signedIn) {
      try {
        await session.api.deletePush();
        return;
      } catch (_) {}
    }
    await forget();
  }

  /// The phone said no: where to turn alerts on, with a button that opens the phone's own page for them.
  static void refused(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: Text(tr('Телефон хабарландыруға рұқсат бермеді. Оны телефонның баптауларында қосуға болады.')),
      action: SnackBarAction(
        label: tr('Баптауды ашу'),
        onPressed: () => unawaited(_settings.invokeMethod<bool>('openSettings').catchError((Object _) => false)),
      ),
    ));
  }

  /// At a moment alerts plainly help: the app's own question, then the phone's. Asked once; "Кейін" waits a while.
  /// Never fails the step it follows: whatever goes wrong here, the message, order or listing is done.
  static Future<void> offer(BuildContext context) async {
    final platform = _platform;
    if (platform == null || !(_session?.signedIn ?? false) || _offering) return;
    _offering = true; // two moments at once (a send and a reload) ask once
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getBool(_askedKey) ?? false) || (prefs.getBool(_offKey) ?? false)) return;
      final later = prefs.getInt(_laterKey);
      if (later != null && DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(later)) < askAgainAfter) {
        return;
      }
      if (await platform.allowed()) {
        unawaited(register()); // allowed already (Android 12 and older): nothing to ask
        return;
      }
      if (!context.mounted) return;
      final yes = await showSheet<bool>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true, // as tall as its words need, scrolled on a small screen or with large text
        builder: (context) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.notifications_active_outlined, size: 40),
            const SizedBox(height: 12),
            Text(tr('Телефонға хабарландыру келсін бе?'),
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
                tr('Жаңа хат, тапсырыс не сұрақ келгенде, күткен өлшеміңіз шыққанда телефоныңыз бірден айтады, қосымша жабық тұрса да.'),
                textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('push-yes'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Иә, қосу')),
            ),
            TextButton(
              key: const Key('push-later'),
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Кейін')),
            ),
          ]),
        ),
      );
      if (yes == true) {
        if (!await turnOn() && context.mounted) refused(context);
      } else {
        // Closed with "Кейін", or swiped away: asked again after a while.
        await prefs.setInt(_laterKey, DateTime.now().millisecondsSinceEpoch);
      }
    } catch (_) {
      // The question is a help, never in the way.
    } finally {
      _offering = false;
    }
  }
}
