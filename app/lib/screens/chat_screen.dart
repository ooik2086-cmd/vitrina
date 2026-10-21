import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat_drafts.dart';
import '../chat_photos.dart';
import '../net_image.dart';
import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../i18n.dart';
import '../quick_replies.dart';

String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Bumped when a chat closes, so every chat list shown (the Chat tab stays alive behind the others) reads the
/// answers and unread counts again, not only the list the chat was opened from.
final chatsChanged = ValueNotifier<int>(0);

/// Inbox: every thread the user is part of, as buyer or as seller.
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key, this.waitingFirst = false});

  /// Opened from the to-do card: the chats where a buyer waits for an answer come first.
  final bool waitingFirst;

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  Future<List<Conversation>>? _items;
  bool? _loadedFor;

  @override
  void initState() {
    super.initState();
    chatsChanged.addListener(_changed);
  }

  @override
  void dispose() {
    chatsChanged.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted && _items != null) _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (_loadedFor != session.signedIn) {
      _loadedFor = session.signedIn;
      _items = session.signedIn ? shown(session.api.conversations()) : null;
    }
  }

  Future<void> _reload() async {
    final f = SessionScope.of(context).api.conversations();
    setState(() {
      _items = shown(f);
    });
    await settled(f);
  }

  @override
  Widget build(BuildContext context) {
    if (_items == null) return SignInPrompt(text: tr('Сатушымен хат алмасу үшін кіріңіз.'));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Хабарламалар'))),
      body: FutureBuilder<List<Conversation>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError && snap.connectionState == ConnectionState.done) {
            return ErrorRetry(error: snap.error, onRetry: _reload);
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final roomy = MediaQuery.textScalerOf(context).scale(14) <= 18;
          final items = [
            if (widget.waitingFirst) ...snap.data!.where((c) => c.awaitsAnswer),
            ...snap.data!.where((c) => !widget.waitingFirst || !c.awaitsAnswer),
          ];
          return RefreshIndicator(
            onRefresh: _reload,
            child: items.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 120),
                    Icon(Icons.chat_bubble_outline_rounded, size: 40, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 12),
                    Center(child: Text(tr('Әзірге хат жоқ. Тауар бетінен сатушыға жазыңыз.'))),
                  ])
                : ListView.separated(
                    padding: contentPadding(context, EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom)),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(indent: 88),
                    itemBuilder: (context, i) {
                      final c = items[i];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            width: 52,
                            height: 52,
                            color: Brand.studio,
                            child: c.listingCover == null
                                ? const Icon(Icons.image_outlined)
                                : Image(
                                    image: netImage(c.listingCover!),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
                          ),
                        ),
                        title: Text(personName(c.otherName),
                            style: weight(theme.textTheme.titleSmall!, c.unread > 0 ? 750 : 600)),
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          // Stays after the chat is opened, until the seller answers: the to-do card counts these.
                          // A line of its own, so the buyer's words stay readable beside it at any text size.
                          if (c.awaitsAnswer)
                            Text(tr('Жауап күтеді'),
                                key: Key('chat-awaits-${c.id}'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: accentText(context),
                                    fontWeight: FontWeight.w700,
                                    fontVariations: const [FontVariation('wght', 700)])),
                          Text(
                            c.lastMessage == null
                                ? c.listingTitle
                                : (c.lastMessage!.body.isEmpty ? tr('📷 Фото') : c.lastMessage!.body),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ]),
                        // The time over the unread number; side by side with large text, as a list tile keeps
                        // its trailing part within 56 pixels of height.
                        trailing: Flex(
                            direction: roomy ? Axis.vertical : Axis.horizontal,
                            mainAxisSize: roomy ? MainAxisSize.max : MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: roomy ? CrossAxisAlignment.end : CrossAxisAlignment.center,
                            children: [
                              if (c.lastMessage != null)
                                Text(_time(c.lastMessage!.createdAt), style: theme.textTheme.labelSmall),
                              const SizedBox(height: 4, width: 6),
                              if (c.unread > 0) Badge(label: Text('${c.unread}')),
                            ]),
                        onTap: () async {
                          // The list reads itself again when the chat closes (chatsChanged).
                          await Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: c.id)));
                        },
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}

/// One thread. New messages are fetched every few seconds while the screen is open.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversationId, this.pollEvery = const Duration(seconds: 4), this.draft});
  final int conversationId;
  final Duration pollEvery;

  /// Put in the message box, for the person to change or send: e.g. the size picked on the listing.
  final String? draft;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<ChatMessage> _messages = [];
  Conversation? _conversation;
  Timer? _poll;
  bool _sending = false;
  bool _loading = false;
  bool _started = false;
  bool _payments = true;
  Object? _loadError; // the first load failed, so there is nothing to show but the error and a retry

  /// The key of the message in the field, kept while the same text is sent again: a send whose answer was lost on
  /// weak mobile data, tried again, reaches the other side once. A changed text is a new message.
  String? _sendKey;
  String? _sendKeyFor;

  /// The message in the field may not have gone: the line above the field says so while its text is unchanged.
  bool _notSent = false;

  /// The last message on screen when that message was sent: only a message of mine after it can be the one that went
  /// after all, not the same words sent days before.
  int _notSentAfter = 0;

  /// Brought back from the phone: says it may not have gone without claiming the connection is down now. Shown only
  /// once the chat has loaded and it is clear the message did not arrive meanwhile ([_checking]).
  bool _notSentKept = false;
  bool _checking = false;

  /// What is kept on the phone for this chat, so leaving it or a closed app loses nothing; see [_keep].
  Timer? _keepTimer;
  String? _lastKept;
  bool _keptOnce = false;
  int? _owner; // read while the chat is on screen: when it closes, the session above can no longer be asked
  int? _restoredFor;

  /// A photo that may not have gone, kept with its caption and key: sent again it arrives once, picked again it would
  /// be a new one. It is kept on the phone too ([_photoFile]) from the moment it is sent until its answer comes.
  _Photo? _unsentPhoto;
  _Photo? _photoSending;
  ({String key, String file})? _photoFile; // the copy on the phone, of the photo with that key
  String? _photoWriting; // the key of the photo being written to the phone now, so it is written once
  /// The last message on screen when the photo with [_photoAfterFor] was first sent: only a later one can be it.
  /// -1 when the chat had not loaded yet: then nothing on screen can tell, and the line stays until it is sent again.
  int _photoAfter = -1;
  String? _photoAfterFor;
  bool _photoKept =
      false; // brought back from the phone, or the server's trouble: the line does not say "no connection"
  bool _photoChecking = false;
  bool _photoRestoring = true; // a photo kept on the phone may still be on its way back to the screen
  final _photosDone = <String>{}; // keys of photos that went or were put aside: a file written late for one goes
  bool _fetchedOnce = false; // a load of the chat has ended, with the thread or without it

  /// A pair marked sold from this chat whose answer did not come back. Sent again as it was, it is taken once.
  _Sale? _pendingSale;
  bool _saleKept = false; // brought back from the phone, see [_notSentKept]

  /// The last pair marked here, which a tap can take back for a while (see [undoFor]); with [_undoUnsure] its undo
  /// was sent and the answer lost, so the line offers to send it again with the same key.
  _Sale? _undoable;
  String _undoSaid = '';
  bool _undoUnsure = false;
  bool _undoing = false;
  Timer? _undoTimer;
  final _markedAt = <String, DateTime>{}; // keys of marks made in this chat: a mark brought back later is too old

  /// Under the server's ten minutes, so a tap near the end still arrives in time.
  static const undoFor = Duration(minutes: 9);
  _Sale? _saleSending; // on its way: kept in case the chat or the app closes before the answer
  bool _marking = false;

  Api get _api => SessionScope.of(context).api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.draft case final draft?) _input.text = draft;
    _input.addListener(_onText);
  }

  /// Keeps what this chat would lose if left now: the words in the field, whether they may already have gone (with
  /// their key, also while their send waits for an answer), a photo that may not have gone and a sale mark not yet
  /// answered. Nothing left to keep
  /// lets the chat's entry go. Nothing is kept or let go while it is not known who is signed in.
  Future<void> _keep() async {
    _keepTimer?.cancel();
    final me = _owner;
    if (me == null) return;
    final text = _input.text;
    final sending = _sending && _sendKeyFor != null && text.trim() == _sendKeyFor;
    final sale = _pendingSale ?? _saleSending;
    final photo = _unsentPhoto ?? _photoSending;
    final file = photo != null && _photoFile?.key == photo.key ? _photoFile!.file : null;
    // The words going with the photo are kept with it, not again as words in the field.
    final words = photo != null && file != null && photo.caption.isNotEmpty && text.trim() == photo.caption ? '' : text;
    final entry = words.trim().isEmpty && sale == null && file == null
        ? null
        : {
            'text': words,
            if (_notSent || sending) ...{'not_sent': true, 'key': _sendKey, 'after': _notSentAfter},
            if (sale != null)
              'sale': {'listing_id': sale.listingId, 'size_id': sale.sizeId, 'label': sale.label, 'key': sale.key},
            if (photo != null && file != null) // a kept photo the chat does not hold stays, see ChatDrafts.put
              'photo': {
                'file': file,
                'name': photo.name,
                'caption': photo.caption,
                'key': photo.key,
                'after': _photoAfter,
              },
          };
    final mine = entry == null ? null : jsonEncode(entry);
    if (_keptOnce && mine == _lastKept) return; // nothing new since it was last kept
    if (await ChatDrafts.put(me, widget.conversationId, entry)) {
      _keptOnce = true;
      _lastKept = mine;
    }
  }

  /// Typing is kept a moment after it stops, not on every letter.
  void _keepSoon() {
    _keepTimer?.cancel();
    _keepTimer = Timer(const Duration(milliseconds: 400), _keep);
  }

  /// Puts back what this person kept in this chat: their words (over the note the listing page puts in), the line
  /// saying a message may not have gone (with its key) and the sale mark to send again. Waits until it is known who
  /// is signed in: on a weak connection the profile can come later than the chat.
  Future<void> _restore() async {
    final me = _owner;
    if (me == null || _restoredFor != null) return;
    _restoredFor = me;
    final d = await ChatDrafts.read(me, widget.conversationId);
    if (d == null || !mounted) return _photoRestored();
    try {
      final text = d['text'] as String? ?? '';
      final notSent = d['not_sent'] == true && d['key'] is String;
      final sale = d['sale'] as Map<String, dynamic>?;
      // The person's own words win over the note from the listing, unless they already began writing here.
      final takeText = _input.text == (widget.draft ?? '') && text.trim().isNotEmpty;
      setState(() {
        if (takeText) {
          _input.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
          if (notSent) {
            _sendKey = d['key'] as String;
            _sendKeyFor = text.trim();
            _notSentAfter = d['after'] as int? ?? 0;
            _notSent = _notSentKept = true;
            _checking = !_fetchedOnce; // the first load says whether it arrived meanwhile
          }
        }
        if (sale != null && _pendingSale == null) {
          _pendingSale = (
            listingId: sale['listing_id'] as int,
            sizeId: sale['size_id'] as int,
            label: sale['label'] as String,
            key: sale['key'] as String,
          );
          _saleKept = true;
        }
      });
      // Already on screen: it went after all.
      if (_notSent && _cameWhileSending(_notSentAfter, (m) => m.photoUrl == null && m.body == _sendKeyFor)) {
        _input.clear();
      }
    } catch (_) {
      unawaited(ChatDrafts.put(me, widget.conversationId, null)); // kept by an older version in another shape
    }
    // The photo after the words: reading it from the phone takes longer, and the words should not wait for it.
    try {
      final photo = d['photo'] as Map<String, dynamic>?;
      if (photo == null) return;
      final key = photo['key'] as String, file = photo['file'] as String;
      final read = await ChatPhotos.read(file);
      if (!mounted) return;
      // Its file is gone: nothing to show or send. Could not be read this time: kept for the next visit.
      if (read.missing) unawaited(ChatDrafts.settled(me, widget.conversationId, key));
      final bytes = read.bytes;
      if (bytes == null || _unsentPhoto != null || _photoSending != null) return;
      setState(() {
        _unsentPhoto = (bytes: bytes, name: photo['name'] as String, caption: photo['caption'] as String, key: key);
        _photoFile = (key: key, file: file);
        _photoAfter = photo['after'] as int? ?? -1;
        _photoAfterFor = key;
        _photoKept = true;
        _photoChecking = !_fetchedOnce; // the first load says whether it arrived meanwhile
      });
      if (_unsentPhoto case final p? when _photoIn(_messages, p)) _photoWent(p);
    } catch (_) {
      // Kept by an older version in another shape: let it be, it goes with its entry in seven days.
    } finally {
      _photoRestored();
    }
  }

  void _photoRestored() {
    if (mounted && _photoRestoring) setState(() => _photoRestoring = false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _owner = SessionScope.of(context).me?.id;
    if (_started) {
      _restore(); // the profile came after the chat: now it is known whose words to bring back
    } else {
      _started = true;
      // Both at once: the chat does not wait on the phone's storage. Whichever ends last tells a kept message that
      // went after all ([_checking] and the check at the end of [_restore]).
      _restore();
      _fetch();
      _startPolling();
      SessionScope.of(context).api.paymentsOn().then((on) {
        if (mounted && on != _payments) setState(() => _payments = on);
      });
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(widget.pollEvery, (_) => _fetch());
  }

  /// No polling while the app is in the background: it would only use the battery and the data plan.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fetch();
      _startPolling();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _poll?.cancel();
      _poll = null;
      _keep(); // the phone may close the app from here
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _undoTimer?.cancel();
    // Reads the field now; the writing finishes after. A send still waiting is kept with its key.
    if ((_keepTimer?.isActive ?? false) || _sending || _marking) _keep();
    _keepTimer?.cancel();
    _input.removeListener(_onText);
    _input.dispose();
    _scroll.dispose();
    // After the tree is settled: the lists rebuild, and nothing may be rebuilt while this chat is being taken down.
    scheduleMicrotask(() => chatsChanged.value++);
    super.dispose();
  }

  /// A changed or cleared text is a new message: it gets its own key, and the line about the old one goes.
  void _onText() {
    _keepSoon();
    if (_sendKeyFor == null || _input.text.trim() == _sendKeyFor) return;
    _sendKey = _sendKeyFor = null;
    if (_notSent) setState(() => _notSent = _notSentKept = false);
  }

  Future<void> _fetch() async {
    if (_loading) return;
    _loading = true;
    try {
      final (conv, fresh) =
          await _api.messages(widget.conversationId, afterId: _messages.isEmpty ? 0 : _messages.last.id);
      if (!mounted) return;
      final known = {for (final m in _messages) m.id};
      final me = SessionScope.of(context).me?.id;
      // A send whose answer was lost may have gone after all: once it shows up here, it is not in the field.
      bool came(bool Function(ChatMessage m) same) =>
          !_sending && fresh.any((m) => !known.contains(m.id) && m.senderId == me && same(m));
      if (_notSent && came((m) => m.id > _notSentAfter && m.photoUrl == null && m.body == _sendKeyFor)) _input.clear();
      // A kept photo is looked for whenever it is not going again itself (a text going meanwhile does not matter).
      final photo = _photoSending == null ? _unsentPhoto : null;
      final photoCame = photo != null && _photoIn(fresh.where((m) => !known.contains(m.id)), photo);
      if (photoCame) _photoWent(photo);
      setState(() {
        _conversation = conv;
        _loadError = null;
        _messages.addAll(fresh.where((m) => !known.contains(m.id)));
      });
      if (fresh.isNotEmpty) _toBottom();
    } catch (e) {
      // With the thread on screen, keep it there; the next poll retries. Before it ever loaded, say why.
      if (mounted && _conversation == null) setState(() => _loadError = e);
    } finally {
      // Every request ends within the API timeout, so a hung one cannot stop the polling for good.
      _loading = false;
      // A message or photo brought back from the phone that did not arrive: now the line may say so.
      _fetchedOnce = true;
      if (mounted && (_checking || _photoChecking)) setState(() => _checking = _photoChecking = false);
    }
  }

  void _retry() {
    setState(() => _loadError = null);
    _fetch();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  Future<void> _block(Conversation conv) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trf('{0}: бұғаттау керек пе?', [personName(conv.otherName)])),
        content: Text(tr(
            'Екеуіңіз бір-біріңізге жаза алмайсыз, баға ұсынысы, сұрақ пен тапсырыс та жабылады. Профильдегі «Бұғатталғандар» бөлімінен қайтаруға болады.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Жабу'))),
          FilledButton(
              key: const Key('confirm-block'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Бұғаттау'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.blockInChat(conv.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(trf('{0}: бұғатталды.', [personName(conv.otherName)]))));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// A ready answer goes into the field, not straight to the buyer, so the seller can add the details.
  void _useReply(String text) {
    _input.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    if (_sendKeyFor != text) {
      _sendKey = newIdempotencyKey();
      _sendKeyFor = text;
    }
    final before = _lastId;
    final owner = _owner, key = _sendKey!;
    if (!_notSent) _notSentAfter = before; // sent again, it is still the first time that counts
    setState(() => _sending = true);
    _keep(); // with its key while it waits: the chat or the app may close before the answer comes
    try {
      final m = await _api.sendMessage(widget.conversationId, text, idempotencyKey: key);
      if (owner != null) unawaited(ChatDrafts.settled(owner, widget.conversationId, key)); // also once closed
      if (!mounted) return;
      _input.clear(); // drops the key and the note with the text
      setState(() {
        if (!_messages.any((x) => x.id == m.id)) _messages.add(m);
      });
      _toBottom();
    } catch (e) {
      if (!mounted) return;
      // On a lost connection the text stays in the field with a line above it; the same message goes again with a
      // tap, and arrives once. A refusal from the server is told in its own words.
      final offline = e is ApiException && e.offline;
      if (offline && _cameWhileSending(before, (m) => m.photoUrl == null && m.body == text)) {
        if (_input.text.trim() == text) _input.clear(); // it went after all: the thread already shows it
        return;
      }
      setState(() {
        _notSent = offline && _input.text.trim() == text;
        _notSentKept = _checking = false; // the connection is down now: the line says so
      });
      if (!offline) showError(context, e);
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _keep();
      }
    }
  }

  Future<void> _sendPhoto() async {
    if (_sending) return;
    final file = await pickPhoto(context);
    // A photo brought back from the phone meanwhile goes first: its line is on screen now.
    if (file == null || !mounted || _unsentPhoto != null || _sending) return;
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (mounted) {
      await _postPhoto((bytes: bytes, name: file.name, caption: _input.text.trim(), key: newIdempotencyKey()));
    }
  }

  /// The id of the last message on screen.
  int get _lastId => _messages.isEmpty ? 0 : _messages.last.id;

  /// Whether a message of mine like [same] reached the thread on screen after [before], while its send was waiting:
  /// the poll read it then, so it never comes again as new.
  bool _cameWhileSending(int before, bool Function(ChatMessage m) same) {
    final me = SessionScope.of(context).me?.id;
    return _messages.any((m) => m.id > before && m.senderId == me && same(m));
  }

  Future<void> _postPhoto(_Photo photo) async {
    if (_sending) return;
    final before = _lastId;
    final owner = _owner;
    if (_photoAfterFor != photo.key) {
      // Sent again, it is still the first time that counts.
      _photoAfter = _conversation == null ? -1 : before;
      _photoAfterFor = photo.key;
    }
    setState(() {
      _sending = true;
      _photoSending = photo;
    });
    // Onto the phone while it goes, not before: the chat or the app may close before the answer comes.
    if (owner != null && _photoFile?.key != photo.key && _photoWriting != photo.key) _keepPhotoFile(owner, photo);
    try {
      final m = await _api.sendChatPhoto(widget.conversationId, photo.bytes, photo.name,
          caption: photo.caption, idempotencyKey: photo.key);
      _photoDone(owner, photo); // also once closed
      if (!mounted) return;
      if (_input.text.trim() == photo.caption) _input.clear(); // the caption went with the photo
      setState(() {
        _unsentPhoto = _photoSending = null;
        _photoFile = null;
        _photoKept = false;
        if (!_messages.any((x) => x.id == m.id)) _messages.add(m);
      });
      _toBottom();
    } catch (e) {
      // On a lost connection, or the server's own trouble, the photo is kept with its words in a line above the
      // field, to go again with a tap, once, and on the phone. The words leave the field, so they are not sent again
      // as a message of their own. A refusal from the server is told in its own words, the photo is not kept, and its
      // words stay in the field (or come back to it, for a photo brought back from the phone).
      final offline = e is ApiException && e.offline;
      final unsure = e is ApiException && e.passing;
      final went = mounted && unsure && _photoIn(_messages, photo);
      if (!unsure || went) _photoDone(owner, photo);
      if (!mounted) return;
      if (unsure && _input.text.trim() == photo.caption) _input.clear();
      if (!unsure && !went && _input.text.trim().isEmpty && photo.caption.isNotEmpty) _putBack(photo.caption);
      setState(() {
        _unsentPhoto = unsure && !went ? photo : null;
        if (_unsentPhoto == null) _photoFile = null;
        _photoKept = !offline; // with the connection down now the line says so; not for the server's trouble
        _photoChecking = false;
      });
      if (!unsure) showError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _photoSending = null;
        });
        _keep();
      }
    }
  }

  /// Writes [photo] to the phone and then names it in this chat's entry, unless it went or was put aside meanwhile:
  /// then the file goes again. Also when the chat closed meanwhile, as the send it waits for may still be on its way.
  void _keepPhotoFile(int owner, _Photo photo) {
    _photoWriting = photo.key;
    ChatPhotos.keep(owner, widget.conversationId, photo.key, photo.bytes).then((file) {
      if (_photoWriting == photo.key) _photoWriting = null;
      if (file == null) return;
      if (_photosDone.contains(photo.key) || (_photoSending ?? _unsentPhoto)?.key != photo.key) {
        unawaited(ChatPhotos.drop(names: [file]));
        return;
      }
      _photoFile = (key: photo.key, file: file);
      _keep();
    });
  }

  /// [photo] went, or the server refused it, or it was put aside: what was kept of it on the phone goes.
  void _photoDone(int? owner, _Photo photo) {
    _photosDone.add(photo.key);
    if (owner != null) unawaited(ChatDrafts.settled(owner, widget.conversationId, photo.key));
  }

  /// Whether [photo] is among [messages]: mine, after it was first sent ([_photoAfter], not known when -1).
  bool _photoIn(Iterable<ChatMessage> messages, _Photo photo) {
    final me = SessionScope.of(context).me?.id;
    return _photoAfter >= 0 && messages.any((m) => m.id > _photoAfter && m.senderId == me && _isPhoto(m, photo));
  }

  /// Whether [m] is my message carrying [photo]: a photo with its words. A photo without words cannot be told from
  /// another one of mine (sent from another phone, say): its line stays, and sent again it is the message the first
  /// try made, as the server knows its key.
  bool _isPhoto(ChatMessage m, _Photo photo) =>
      m.photoUrl != null && photo.caption.isNotEmpty && m.body == photo.caption;

  /// The kept [photo] is in the thread after all: its line, its words in the field and its copy on the phone go.
  void _photoWent(_Photo photo) {
    _photoDone(_owner, photo);
    if (_input.text.trim() == photo.caption) _input.clear();
    setState(() {
      if (_unsentPhoto?.key == photo.key) _unsentPhoto = null;
      _photoFile = null;
      _photoKept = false;
    });
  }

  /// The seller sold a pair in this chat, paid in hand or by transfer: one pair of the chosen size leaves the stock,
  /// so the page does not offer what is gone.
  Future<void> _markSold() async {
    final conv = _conversation;
    if (!mounted || conv == null || _marking || _pendingSale != null) return;
    setState(() => _marking = true);
    try {
      final listing = await _api.listing(conv.listingId);
      if (!mounted) return;
      if (!listing.everOnSale || listing.status == 'hidden' || listing.status == 'archived') {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(tr('Бұл тауардың қалдығын қазір өзгерту мүмкін емес.'))));
        return;
      }
      final left = [
        for (final x in listing.sizes)
          if ((x.quantity ?? 0) > 0) x
      ];
      if (left.isEmpty) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(tr('Бұл тауардың қалдығы жоқ.'))));
        return;
      }
      final size = await showModalBottomSheet<ShoeSize>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _SoldSizeSheet(sizes: left),
      );
      if (size == null || !mounted) return;
      final had = size.quantity!;
      // The page shows it sold only when it was on sale; a paused one stays paused.
      final last = left.length == 1 && had == 1 && listing.status == 'published';
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('Бір жұп сатылды ма?')),
          content: Text([
            trf('{0} өлшемі: {1} жұп еді, {2} жұп қалады.', [size.label, had, had - 1]),
            if (last) tr('Бұл соңғы жұп. Тауар «Сатылды» деп белгіленеді, оны енді ешкім сатып ала алмайды.'),
          ].join('\n\n')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Болдырмау'))),
            FilledButton(
                key: const Key('sold-sure'),
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr('Иә, сатылды'))),
          ],
        ),
      );
      if (sure != true || !mounted) return;
      final key = newIdempotencyKey();
      _markedAt[key] = DateTime.now();
      await _saveSale((listingId: listing.id, sizeId: size.id, label: size.label, key: key));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  /// Takes the pair from the count as it is on the server; sent again with its key after a lost answer, it takes
  /// nothing more. A mark that may have gone stays in a line above the field until it is sent again.
  Future<void> _saveSale(_Sale sale) async {
    final owner = _owner;
    setState(() => _saleSending = sale);
    _keep(); // with its key while it waits: the chat or the app may close before the answer comes
    try {
      final l = await _api.markPairSold(sale.listingId, sale.sizeId, idempotencyKey: sale.key);
      if (owner != null) unawaited(ChatDrafts.settled(owner, widget.conversationId, sale.key)); // also once closed
      if (!mounted) return;
      setState(() {
        _pendingSale = _saleSending = null;
        _saleKept = false;
      });
      _keep();
      _saleDone(sale, l.sizes);
    } catch (e) {
      // A lost connection or a failing server may still have taken the pair: kept with its key to send again. A
      // clear refusal leaves nothing to send again.
      final unsure = e is ApiException && e.passing;
      if (!unsure && owner != null) unawaited(ChatDrafts.settled(owner, widget.conversationId, sale.key));
      if (!mounted) return;
      setState(() {
        _pendingSale = unsure ? sale : null;
        _saleSending = null;
        _saleKept = false;
      });
      _keep();
      if (!unsure) showError(context, e);
    }
  }

  Future<void> _resendSale() async {
    final sale = _pendingSale;
    if (!mounted || sale == null || _marking) return;
    setState(() => _marking = true);
    try {
      await _saveSale(sale);
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  /// Says what is left. For a mark made here it is said in a line above the field, with the way to take it back
  /// while the server still allows it: one place, nothing on top of the field or of the button.
  void _saleDone(_Sale sale, List<ShoeSize> sizes) {
    final left = sizes.where((x) => x.id == sale.sizeId).firstOrNull?.quantity ?? 0;
    final gone = sizes.every((x) => (x.quantity ?? 0) == 0);
    final said = gone
        ? tr('Белгіленді: тауар түгел сатылды.')
        : trf('Белгіленді: {0} өлшемінен {1} жұп қалды.', [sale.label, left]);
    final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
    final at = _markedAt[sale.key];
    final remaining = at == null ? Duration.zero : at.add(undoFor).difference(DateTime.now());
    if (remaining <= Duration.zero) {
      messenger.showSnackBar(SnackBar(content: Text(said))); // brought back from the phone, long after the tap
      return;
    }
    _undoTimer?.cancel();
    _undoTimer = Timer(remaining, () {
      if (mounted && !_undoing && !_undoUnsure) setState(() => _undoable = null);
    });
    setState(() {
      _undoable = sale;
      _undoSaid = said;
      _undoUnsure = false;
    });
  }

  /// Puts the pair back with the mark's own key, so only that mark and only once. Its answer is told also when the
  /// chat was left meanwhile; a lost one keeps the line, to send the same undo again.
  Future<void> _undoSale(_Sale sale) async {
    if (!mounted || _undoing) return;
    setState(() => _undoing = true);
    final messenger = ScaffoldMessenger.of(context);
    final reader = MediaQuery.accessibleNavigationOf(context);
    void done() {
      if (!mounted) return;
      _undoTimer?.cancel();
      setState(() {
        if (_undoable?.key == sale.key) _undoable = null;
        _undoUnsure = false;
      });
    }

    try {
      final l = await _api.undoPairSold(sale.listingId, sale.sizeId, idempotencyKey: sale.key);
      _markedAt.remove(sale.key);
      done();
      final left = l.sizes.where((x) => x.id == sale.sizeId).firstOrNull?.quantity ?? 0;
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(trf('Белгі алынды: {0} өлшемінен {1} жұп бар.', [sale.label, left]))));
    } catch (e) {
      if (e is ApiException && e.passing) {
        if (mounted) {
          setState(() => _undoUnsure = true); // the line stays, now with the same undo to send again
        } else {
          messenger
            ..clearSnackBars()
            ..showSnackBar(SnackBar(
                content: Text(trf('Байланыс жоқ. {0} өлшемінің белгісі алынбаған болуы мүмкін.', [sale.label])),
                duration: const Duration(seconds: 12),
                persist: reader));
        }
      } else {
        done();
        // Too late, or the listing was taken down meanwhile: said long enough to read what to do instead.
        messenger
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
              content: Text(e is ApiException ? e.message : tr('Байланыс жоқ. Қайта көріңіз.')),
              duration: const Duration(seconds: 12),
              persist: reader));
      }
    } finally {
      if (mounted) setState(() => _undoing = false);
    }
  }

  /// Puts the kept photo aside; its words come back to the field, as they are the sender's to keep or send.
  void _dropPhoto(_Photo photo) {
    _photoDone(_owner, photo); // and from the phone
    setState(() {
      _unsentPhoto = null;
      _photoFile = null;
      _photoKept = false;
    });
    if (_input.text.trim().isEmpty && photo.caption.isNotEmpty) _putBack(photo.caption);
  }

  void _putBack(String words) =>
      _input.value = TextEditingValue(text: words, selection: TextSelection.collapsed(offset: words.length));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final me = SessionScope.of(context).me?.id;
    final conv = _conversation;
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (conv != null)
            PopupMenuButton<String>(
              key: const Key('chat-menu'),
              onSelected: (_) => _block(conv),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'block', key: const Key('block-user'), child: Text(tr('Бұғаттау'))),
              ],
            ),
        ],
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(personName(conv?.otherName ?? ''), style: theme.textTheme.titleMedium),
          if (conv != null)
            Text('${conv.listingTitle} · ${formatTenge(conv.priceTiyn)}',
                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
        ]),
      ),
      body: Column(children: [
        if (conv?.role == 'buyer' && conv?.sellerAwayUntil != null)
          Container(
            key: const Key('chat-away'),
            width: double.infinity,
            color: Brand.studio,
            padding: contentPadding(context, const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
            child: Row(children: [
              const Icon(Icons.beach_access_outlined, size: 18, color: Brand.ink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    trf('Сатушы {0} дейін демалыста, жауабы кешігуі мүмкін.', [formatDay(conv!.sellerAwayUntil!)]),
                    style: theme.textTheme.bodyMedium?.copyWith(color: Brand.ink)),
              ),
            ]),
          ),
        Expanded(
          child: conv == null && _loadError != null
              ? ErrorRetry(error: _loadError, onRetry: _retry)
              : _messages.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          conv?.role == 'buyer'
                              ? tr('Өлшемі, жағдайы немесе жеткізу туралы сұраңыз.')
                              : tr('Хабарлама әлі жоқ.'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: contentPadding(context, const EdgeInsets.fromLTRB(16, 12, 16, 12)),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) {
                        final m = _messages[i];
                        return _Bubble(message: m, mine: m.senderId == me, payments: _payments);
                      },
                    ),
        ),
        if (conv?.role == 'seller')
          _QuickReplies(
              onPick: _useReply,
              payments: _payments,
              onSold: _marking || _undoing || _undoUnsure || _pendingSale != null ? null : _markSold),
        if (_pendingSale case final sale?)
          _NotSentLine(
            key: const Key('sale-not-sent'),
            text: _saleKept
                ? trf('{0} өлшемінің белгісі сақталмаған болуы мүмкін.', [sale.label])
                : trf('Байланыс жоқ. {0} өлшемінің белгісі сақталмаған болуы мүмкін.', [sale.label]),
            retryKey: 'sale-resend',
            onRetry: _marking ? null : _resendSale,
          ),
        if (_undoable case final sale?)
          _NotSentLine(
            key: const Key('sale-undo-line'),
            text: _undoUnsure
                ? trf('Байланыс жоқ. {0} өлшемінің белгісі алынбаған болуы мүмкін.', [sale.label])
                : _undoSaid,
            icon: _undoUnsure ? null : Icons.check_circle_outline,
            retryLabel: _undoUnsure ? null : tr('Қате басылды'),
            retryKey: _undoUnsure ? 'sale-undo-again' : 'sale-undo',
            onRetry: _undoing ? null : () => _undoSale(sale),
          ),
        if (_unsentPhoto case final photo? when !_photoChecking)
          _NotSentLine(
            key: const Key('chat-photo-not-sent'),
            // Brought back from the phone, it does not claim the connection is down now.
            text: _photoKept ? tr('Фото жетпеген болуы мүмкін.') : tr('Байланыс жоқ. Фото жетпеген болуы мүмкін.'),
            photo: photo.bytes,
            caption: photo.caption,
            onRetry: _sending ? null : () => _postPhoto(photo),
            onDrop: _sending ? null : () => _dropPhoto(photo),
          ),
        if (_notSent && !_checking)
          _NotSentLine(
            key: const Key('chat-not-sent'),
            // Brought back from the phone, it does not claim the connection is down now.
            text: _notSentKept
                ? tr('Хабарлама жетпеген болуы мүмкін, мәтіні осы жерде тұр.')
                : tr('Байланыс жоқ. Хабарлама жетпеген болуы мүмкін, мәтіні осы жерде тұр.'),
            onRetry: _sending ? null : _send,
          ),
        Material(
          color: scheme.surface,
          child: SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant))),
              padding: contentPadding(context, const EdgeInsets.fromLTRB(6, 10, 10, 10)),
              child: Row(children: [
                IconButton(
                  key: const Key('chat-photo'),
                  tooltip: tr('Фото жіберу'),
                  // One kept photo at a time: it goes again or is put aside before the next.
                  // And none while a kept one may still come back from the phone.
                  onPressed:
                      _sending || _unsentPhoto != null || (_photoRestoring && _owner != null) ? null : _sendPhoto,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: tr('Хабарлама'),
                      counterText: '',
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide(color: scheme.outlineVariant)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: tr('Жіберу'),
                  onPressed: _sending ? null : _send,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// One pair of a size marked sold, with the key that makes it count once.
typedef _Sale = ({int listingId, int sizeId, String label, String key});

/// Which size was sold: only sizes still in stock, each with what is left.
class _SoldSizeSheet extends StatelessWidget {
  const _SoldSizeSheet({required this.sizes});
  final List<ShoeSize> sizes;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(tr('Қай өлшемі сатылды?'), style: Theme.of(context).textTheme.titleMedium),
            subtitle: Text(tr('Қалдықтан бір жұп алынады.')),
          ),
          for (final x in sizes)
            ListTile(
              key: Key('sold-size-${x.id}'),
              minTileHeight: 56,
              title: Text(x.label),
              subtitle: Text(trf('Қалды: {0}', [x.quantity])),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(context, x),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// A picked photo with what goes with it, as it was sent.
typedef _Photo = ({Uint8List bytes, String name, String caption, String key});

/// Says, above the field and not over it, that a message may not have gone, with a way to send it again. A photo is
/// shown small, so it is clear which one, and can be put aside.
class _NotSentLine extends StatelessWidget {
  const _NotSentLine(
      {super.key,
      required this.text,
      required this.onRetry,
      this.photo,
      this.caption = '',
      this.onDrop,
      this.retryKey,
      this.icon,
      this.retryLabel});
  final String text;

  /// A line that offers a way back rather than a retry says so with its own icon and button.
  final IconData? icon;
  final String? retryLabel;

  /// The retry button's key, where it is not the text's or the photo's.
  final String? retryKey;
  final VoidCallback? onRetry;
  final Uint8List? photo;

  /// The words that go with the photo, shown as they will go.
  final String caption;
  final VoidCallback? onDrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface);
    final words = Row(children: [
      Icon(icon ?? Icons.cloud_off_outlined, size: 20, color: icon == null ? scheme.error : scheme.primary),
      const SizedBox(width: 8),
      if (photo case final bytes?) ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.memory(bytes,
              width: 40,
              height: 40,
              cacheWidth: (40 * MediaQuery.devicePixelRatioOf(context)).round(), // a small preview, decoded small
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 40)),
        ),
        const SizedBox(width: 8),
      ],
      Expanded(
        child: Semantics(
          liveRegion: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: style),
            if (caption.isNotEmpty)
              Text('«$caption»',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    ]);
    final buttons = [
      TextButton(
        key: Key(retryKey ?? (photo == null ? 'chat-resend' : 'chat-photo-resend')),
        onPressed: onRetry,
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        child: Text(retryLabel ?? tr('Қайта көру')),
      ),
      if (photo != null)
        IconButton(
          key: const Key('chat-photo-drop'),
          tooltip: tr('Алып тастау'),
          onPressed: onDrop,
          icon: const Icon(Icons.close),
        ),
    ];
    // With large text the words get the whole width and the buttons go under them.
    final roomy = MediaQuery.textScalerOf(context).scale(14) <= 18;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHigh, // calm: it is said once, in words, with the way out beside it
      padding: contentPadding(context, const EdgeInsets.fromLTRB(16, 6, 8, 6)),
      child: roomy
          ? Row(children: [Expanded(child: words), ...buttons])
          : Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              words,
              Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, children: buttons),
            ]),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine, this.payments = true});
  final ChatMessage message;
  final bool mine;
  final bool payments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;
    return Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
      Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        // Relative to the capped message column, not the whole window.
        constraints: BoxConstraints(maxWidth: min(MediaQuery.sizeOf(context).width, maxContentWidth) * 0.78),
        decoration: BoxDecoration(
          color: mine ? scheme.primary : scheme.surface,
          border: mine ? null : Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 4),
            bottomRight: Radius.circular(mine ? 4 : 18),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (message.photoUrl != null)
            Padding(
              padding: EdgeInsets.only(bottom: message.body.isEmpty ? 4 : 8),
              child: GestureDetector(
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => _PhotoViewer(url: message.photoUrl!), fullscreenDialog: true)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image(
                    image: netImage(message.photoUrl!, keep: false),
                    width: 220,
                    height: 220,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const SizedBox(width: 220, height: 220, child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              ),
            ),
          if (message.body.isNotEmpty) Text(message.body, style: theme.textTheme.bodyLarge?.copyWith(color: fg)),
          const SizedBox(height: 2),
          Text(_time(message.createdAt), style: theme.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.6))),
        ]),
      ),
      // Shown to the reader of a message with a phone number or link: deals outside the app lose the protection.
      // While online payment is off every deal is outside the app, so the warning is about paying ahead instead.
      if (message.contactWarning && !mine)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.shield_outlined, size: 14, color: scheme.error),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                  tr(payments
                      ? 'Төлемді тек VITRINA арқылы жасаңыз, әйтпесе ақшаңыз қорғалмайды.'
                      : 'Тауарды көрмей тұрып толық аударым жасамаңыз.'),
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.error)),
            ),
          ]),
        ),
    ]);
  }
}

/// Full-screen photo from the chat, pinch to zoom.
class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          systemOverlayStyle: SystemUiOverlayStyle.light), // white icons on the black viewer
      body: InteractiveViewer(maxScale: 5, child: Center(child: Image(image: netImage(url, keep: false)))),
    );
  }
}

class _QuickReplies extends StatelessWidget {
  const _QuickReplies({required this.onPick, required this.payments, this.onSold});
  final ValueChanged<String> onPick;
  final bool payments;

  /// Marks one pair sold; off while a mark is on its way.
  final VoidCallback? onSold;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>?>(
      valueListenable: quickReplies,
      builder: (context, _, __) {
        final items = currentQuickReplies(payments: payments);
        return SizedBox(
          // Grows with large text, so the chips are never cut at the top.
          height: 48 + (MediaQuery.textScalerOf(context).scale(14) - 14) * 1.7,
          child: ListView(
            key: const Key('quick-replies'),
            scrollDirection: Axis.horizontal,
            padding: contentPadding(context, const EdgeInsets.fromLTRB(12, 6, 12, 6)),
            children: [
              // First, so they are never scrolled out of reach.
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  key: const Key('mark-sold'),
                  avatar: const Icon(Icons.check_circle_outline, size: 16),
                  label: Text(tr('Сатылды')),
                  onPressed: onSold,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  key: const Key('edit-quick-replies'),
                  avatar: const Icon(Icons.edit_outlined, size: 16),
                  label: Text(tr('Үлгілер')),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    builder: (_) => QuickRepliesSheet(payments: payments),
                  ),
                ),
              ),
              for (final t in items)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(t, overflow: TextOverflow.ellipsis),
                    ),
                    onPressed: () => onPick(t),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Add, change or remove ready answers.
class QuickRepliesSheet extends StatefulWidget {
  const QuickRepliesSheet({super.key, this.payments = true});
  final bool payments;

  @override
  State<QuickRepliesSheet> createState() => _QuickRepliesSheetState();
}

class _QuickRepliesSheetState extends State<QuickRepliesSheet> {
  late final List<TextEditingController> _rows = [
    for (final t in currentQuickReplies(payments: widget.payments)) TextEditingController(text: t)
  ];

  @override
  void dispose() {
    for (final c in _rows) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Жылдам жауаптар'), style: weight(theme.textTheme.titleLarge!, 800)),
          const SizedBox(height: 4),
          Text(tr('Басқанда мәтін өріске қойылады, жібермес бұрын толықтыра аласыз. Тек осы телефонда сақталады.'),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          for (final (i, c) in _rows.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    key: Key('quick-reply-$i'),
                    controller: c,
                    minLines: 1,
                    maxLines: 3,
                    maxLength: maxQuickReplyLength,
                    decoration: const InputDecoration(counterText: ''),
                  ),
                ),
                IconButton(
                  tooltip: tr('Өшіру'),
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() => _rows.removeAt(i).dispose()),
                ),
              ]),
            ),
          if (_rows.length < maxQuickReplies)
            TextButton.icon(
              key: const Key('add-quick-reply'),
              onPressed: () => setState(() => _rows.add(TextEditingController())),
              icon: const Icon(Icons.add),
              label: Text(tr('Жауап қосу')),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('save-quick-replies'),
              onPressed: () async {
                await saveQuickReplies([for (final c in _rows) c.text]);
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(tr('Сақтау')),
            ),
          ),
        ]),
      ),
    );
  }
}
