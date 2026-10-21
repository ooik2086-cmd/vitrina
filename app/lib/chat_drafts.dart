import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_photos.dart';

/// What each person was writing in each chat, kept on the phone so leaving a chat or a closed app loses nothing: the
/// words in the field, a message or a photo that may not have gone (with its key, so sent again it arrives once; the
/// photo itself is a file, see [ChatPhotos]) and a pair marked sold whose answer was lost (with its key). Kept by
/// person and chat: two people on one phone never see or replace each other's words.
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
  /// A photo whose entry goes (sent, put aside, past its time or replaced) goes from the phone with it.
  static Future<bool> _update(void Function(Map<String, dynamic> all, int now) change) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = _all(prefs);
      final before = jsonEncode(all);
      final photosBefore = photoFiles(all);
      final now = clock.now().millisecondsSinceEpoch;
      all.removeWhere(
          (_, v) => v is! Map || v['kept_at'] is! int || now - (v['kept_at'] as int) > keptFor.inMilliseconds);
      change(all, now);
      final after = jsonEncode(all);
      if (after != before) await (all.isEmpty ? prefs.remove(key) : prefs.setString(key, after));
      final gone = photosBefore.difference(photoFiles(all));
      if (gone.isNotEmpty) unawaited(ChatPhotos.drop(names: gone)); // nothing waits on the disk for it
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The files of the photos kept in [all].
  static Set<String> photoFiles(Map<String, dynamic> all) => {
        for (final v in all.values)
          if (v is Map && v['photo'] is Map && (v['photo'] as Map)['file'] is String)
            (v['photo'] as Map)['file'] as String,
      };

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

  /// Keeps [entry] as what [owner] has in [chat]; null lets it go. A photo kept there stays unless [entry] names
  /// another one: it goes only with [settled], once it went, was refused or was put aside. The chat writes what it
  /// holds, and it may not hold the kept photo yet (still being read from the phone, or not shown this visit).
  static Future<bool> put(int owner, int chat, Map<String, dynamic>? entry) => _update((all, now) {
        final old = all[_id(owner, chat)];
        final photo = old is Map && old['photo'] is Map ? old['photo'] : null;
        final next = entry == null || entry['photo'] != null || photo == null ? entry : {...entry, 'photo': photo};
        next == null && photo != null
            ? all[_id(owner, chat)] = {'text': '', 'photo': photo, 'kept_at': now}
            : next == null
                ? all.remove(_id(owner, chat))
                : all[_id(owner, chat)] = {...next, 'kept_at': now};
      });

  /// The message, photo or sale mark sent with [sendKey] got its answer (or the photo was put aside), also after the chat was closed: what was kept for
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
        if (m['photo'] is Map && (m['photo'] as Map)['key'] == sendKey) m.remove('photo');
        final empty = ((m['text'] as String?) ?? '').trim().isEmpty && m['sale'] == null && m['photo'] == null;
        empty ? all.remove(_id(owner, chat)) : all[_id(owner, chat)] = m;
      });

  /// Lets stale entries go, e.g. at start: words are not kept past their time just because no chat was opened. A
  /// photo file no entry names (its chat closed between writing it and naming it) goes too, once it is a while old.
  static Future<void> sweep() async {
    await _update((_, __) {});
    try {
      final kept = photoFiles(_all(await SharedPreferences.getInstance()));
      await ChatPhotos.drop(except: kept, olderThan: const Duration(minutes: 10));
    } catch (_) {}
  }

  /// Everything [owner] kept in any chat, e.g. when their account is deleted: their photos too, named in an entry or
  /// not yet. The words go before this returns; the photo files go after, as signing out does not wait on the disk.
  static Future<void> forget(int owner) async {
    await _update((all, _) => all.removeWhere((k, _) => k.startsWith('$owner:')));
    unawaited(ChatPhotos.drop(prefix: ChatPhotos.prefixOf(owner)));
  }
}
