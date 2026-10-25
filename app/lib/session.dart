import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'chat_drafts.dart';
import 'push.dart';

/// Signed-in state shared across screens. The token is kept on the device; the phone number never leaves the profile.
class Session extends ChangeNotifier {
  Session(this.api);
  final Api api;
  Me? me;

  static const _tokenKey = 'vitrina_token';

  /// A new listing not yet saved, kept on the phone so a closed app loses nothing. It carries its owner, so a
  /// lapsed sign-in does not lose it and another person signing in on the phone never sees it.
  static const editorDraftKey = 'vitrina_editor_draft';

  /// Changes to the seller's own listings not yet saved, by listing, kept the same way: a closed app loses nothing.
  static const listingEditsKey = 'vitrina_listing_edits';

  /// A sign-out the server has not heard of yet (offline): ended at the next start, so the sign-in and its phone
  /// alerts do not live on there.
  static const _logoutKey = 'vitrina_logout_pending';

  bool get signedIn => api.token != null;

  Future<void> restore() async {
    unawaited(ChatDrafts.sweep()); // chat words past their time go, even if their chat is never opened again
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getString(_logoutKey);
    if (pending != null) unawaited(_logout(pending));
    api.token = prefs.getString(_tokenKey);
    if (api.token == null) return;
    await reloadMe();
  }

  /// Why the profile did not load (offline, the server away), while signed in without it; null otherwise.
  Object? meError;
  Future<void>? _reloading;

  /// Why the sign-in ended without the person signing out (the account blocked), to be said once; null otherwise.
  final notice = ValueNotifier<ApiException?>(null);

  /// The profile, when signed in without it: at the start, and again when the line is back (the tabs' minute check,
  /// the app coming back, "Қайта көру" with [shown]), so an app opened offline does not stay without it until
  /// restarted. Every page that reads the session is rebuilt only when what it shows changes, not at each failed try.
  Future<void> reloadMe({bool shown = false}) => _reloading ??= _reloadMe(shown).whenComplete(() => _reloading = null);

  Future<void> _reloadMe(bool shown) async {
    final bearer = api.token;
    if (bearer == null || me != null) return;
    if (shown && meError != null) {
      meError = null; // the circle while it tries, the error again only if it fails
      notifyListeners();
    }
    Object? failed;
    try {
      final loaded = await api.me();
      if (api.token != bearer) return; // signed out (or in again) meanwhile
      me = loaded;
      meError = null;
      unawaited(Push.register());
      notifyListeners();
      return;
    } on ApiException catch (e) {
      if (api.token != bearer) return; // an answer for a sign-in already gone
      // Ended, or the account blocked: signed out here too; a block is said in words (HomeShell).
      if (e.status == 401 || e.code == 'account_blocked') {
        if (e.code == 'account_blocked') notice.value = e;
        await signOut(server: false);
        return;
      }
      failed = e;
    } catch (e) {
      if (api.token != bearer) return;
      failed = e; // offline: the sign-in is kept, and tried again later
    }
    final first = meError == null;
    meError = failed;
    if (first) notifyListeners();
  }

  Future<void> signIn(String phone, String code) async {
    me = await api.verifyOtp(phone, code);
    meError = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, api.token!);
    notifyListeners();
    unawaited(Push.register());
  }

  void update(Me value) {
    me = value;
    notifyListeners();
  }

  /// Everything [owner] left on this phone (a new listing, unsaved edits, words in chats) goes with their account.
  Future<void> forgetLocal(int owner) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final draft = prefs.getString(editorDraftKey);
      if (draft != null && (jsonDecode(draft) as Map)['owner'] == owner) await prefs.remove(editorDraftKey);
      final edits = jsonDecode(prefs.getString(listingEditsKey) ?? '{}') as Map<String, dynamic>;
      final before = edits.length;
      edits.removeWhere((_, v) => v is Map && v['owner'] == owner);
      if (edits.length != before) await prefs.setString(listingEditsKey, jsonEncode(edits));
    } catch (_) {
      // Kept in a shape no longer readable: nothing of theirs to find there.
    }
    await ChatDrafts.forget(owner);
  }

  /// Signs out on the phone at once, then on the server ([server]; not when the server already ended the sign-in),
  /// which also stops this phone's alerts. Offline, Firebase still forgets the phone, so no alert of this account
  /// reaches it, and the token kept here is gone either way.
  Future<void> signOut({bool server = true}) async {
    final bearer = api.token;
    api.token = null;
    me = null;
    meError = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    notifyListeners();
    if (bearer == null) return;
    unawaited(Push.forget());
    if (!server) return;
    await prefs.setString(_logoutKey, bearer);
    unawaited(_logout(bearer));
  }

  /// Done once the server answers, even with "already ended" (401); offline or the server away, it waits for the next
  /// start.
  Future<void> _logout(String bearer) async {
    try {
      await api.logout(bearer);
    } on ApiException catch (e) {
      if (e.passing) return;
    } catch (_) {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_logoutKey) == bearer) await prefs.remove(_logoutKey);
    } catch (_) {}
  }
}

class SessionScope extends InheritedNotifier<Session> {
  const SessionScope({super.key, required Session session, required super.child}) : super(notifier: session);

  static Session of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SessionScope>()!.notifier!;

  /// The session, when there is one above: a page shown on its own (in a test) has none.
  static Session? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<SessionScope>()?.notifier;
}
