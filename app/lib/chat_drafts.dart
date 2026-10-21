import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What each person was writing in each chat, kept on the phone so leaving a chat or a closed app loses nothing: the
/// words in the field, a message that may not have gone (with its key, so sent again it arrives once) and a pair
/// marked sold whose answer was lost (with its key). Kept by person and chat: two people on one phone never see or
/// replace each other's words.
class ChatDrafts {
  static const key = 'vitrina_chat_drafts';

  /// Long enough for a few days away; after that the chat has moved on.
  static const keptFor = Duration(days: 7);

  static String _id(int owner, int chat) => '$owner:$chat';

  static Map<String, dynamic> _all(SharedPreferences prefs) {
    try {
      return jsonDecode(prefs.getString(key) ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      return {}; // kept by an older version and no longer readable
    }
  }

  /// Applies [change] to everything kept, after letting stale entries go, and writes only when something changed.
  /// The reading and the writing happen with nothing in between (the phone's copy changes at once, the file after),
  /// so two chats closing together both keep their words. False when the phone could not keep it (a full phone).
  static Future<bool> _update(void Function(Map<String, dynamic> all, int now) change) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = _all(prefs);
      final before = jsonEncode(all);
      final now = clock.now().millisecondsSinceEpoch;
      all.removeWhere(
          (_, v) => v is! Map || v['kept_at'] is! int || now - (v['kept_at'] as int) > keptFor.inMilliseconds);
      change(all, now);
      final after = jsonEncode(all);
      if (after != before) await (all.isEmpty ? prefs.remove(key) : prefs.setString(key, after));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// What [owner] kept in [chat], unless it has gone stale.
  static Future<Map<String, dynamic>?> read(int owner, int chat) async {
    try {
      final e = _all(await SharedPreferences.getInstance())[_id(owner, chat)];
      if (e is! Map || e['kept_at'] is! int) return null;
      final age = clock.now().millisecondsSinceEpoch - (e['kept_at'] as int);
      return age > keptFor.inMilliseconds ? null : Map<String, dynamic>.from(e);
    } catch (_) {
      return null;
    }
  }

  /// Keeps [entry] as what [owner] has in [chat]; null lets it go.
  static Future<bool> put(int owner, int chat, Map<String, dynamic>? entry) => _update((all, now) {
        entry == null ? all.remove(_id(owner, chat)) : all[_id(owner, chat)] = {...entry, 'kept_at': now};
      });

  /// The message or sale mark sent with [sendKey] got its answer, also after the chat was closed: what was kept for
  /// it goes, anything else written in the chat stays.
  static Future<void> settled(int owner, int chat, String sendKey) => _update((all, now) {
        final e = all[_id(owner, chat)];
        if (e is! Map) return;
        final m = Map<String, dynamic>.from(e);
        if (m['key'] == sendKey) {
          for (final k in ['text', 'not_sent', 'key', 'after']) {
            m.remove(k);
          }
        }
        if (m['sale'] is Map && (m['sale'] as Map)['key'] == sendKey) m.remove('sale');
        final empty = ((m['text'] as String?) ?? '').trim().isEmpty && m['sale'] == null;
        empty ? all.remove(_id(owner, chat)) : all[_id(owner, chat)] = m;
      });

  /// Lets stale entries go, e.g. at start: words are not kept past their time just because no chat was opened.
  static Future<void> sweep() => _update((_, __) {});

  /// Everything [owner] kept in any chat, e.g. when their account is deleted.
  static Future<void> forget(int owner) => _update((all, _) => all.removeWhere((k, _) => k.startsWith('$owner:')));
}
