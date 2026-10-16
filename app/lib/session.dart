import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Signed-in state shared across screens. The token is kept on the device; the phone number never leaves the profile.
class Session extends ChangeNotifier {
  Session(this.api);
  final Api api;
  Me? me;

  static const _tokenKey = 'vitrina_token';

  bool get signedIn => api.token != null;

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    api.token = prefs.getString(_tokenKey);
    if (api.token == null) return;
    try {
      me = await api.me();
    } on ApiException catch (e) {
      if (e.status == 401) await signOut();
    } catch (_) {
      // Offline: keep the token and try again later.
    }
    notifyListeners();
  }

  Future<void> signIn(String phone, String code) async {
    me = await api.verifyOtp(phone, code);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, api.token!);
    notifyListeners();
  }

  void update(Me value) {
    me = value;
    notifyListeners();
  }

  Future<void> signOut() async {
    api.token = null;
    me = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    notifyListeners();
  }
}

class SessionScope extends InheritedNotifier<Session> {
  const SessionScope({super.key, required Session session, required super.child}) : super(notifier: session);

  static Session of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SessionScope>()!.notifier!;
}
