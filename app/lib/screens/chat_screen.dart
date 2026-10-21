import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net_image.dart';
import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../i18n.dart';
import '../quick_replies.dart';

String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Inbox: every thread the user is part of, as buyer or as seller.
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  Future<List<Conversation>>? _items;
  bool? _loadedFor;

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
          final items = snap.data!;
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
                        subtitle: Text(
                          c.lastMessage == null
                              ? c.listingTitle
                              : (c.lastMessage!.body.isEmpty ? tr('📷 Фото') : c.lastMessage!.body),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (c.lastMessage != null)
                                Text(_time(c.lastMessage!.createdAt), style: theme.textTheme.labelSmall),
                              const SizedBox(height: 4),
                              if (c.unread > 0) Badge(label: Text('${c.unread}')),
                            ]),
                        onTap: () async {
                          await Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: c.id)));
                          _reload();
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

  /// A photo that may not have gone, kept with its caption and key: sent again it arrives once, picked again it would
  /// be a new one.
  _Photo? _unsentPhoto;

  Api get _api => SessionScope.of(context).api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.draft case final draft?) _input.text = draft;
    _input.addListener(_onText);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
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
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// A changed or cleared text is a new message: it gets its own key, and the line about the old one goes.
  void _onText() {
    if (_sendKeyFor == null || _input.text.trim() == _sendKeyFor) return;
    _sendKey = _sendKeyFor = null;
    if (_notSent) setState(() => _notSent = false);
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
      if (_notSent && came((m) => m.photoUrl == null && m.body == _sendKeyFor)) _input.clear();
      final photo = _unsentPhoto;
      final photoCame = photo != null && came((m) => m.photoUrl != null && m.body == photo.caption);
      if (photoCame && _input.text.trim() == photo.caption) _input.clear();
      setState(() {
        if (photoCame) _unsentPhoto = null;
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
    setState(() => _sending = true);
    try {
      final m = await _api.sendMessage(widget.conversationId, text, idempotencyKey: _sendKey);
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
      setState(() => _notSent = offline && _input.text.trim() == text);
      if (!offline) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendPhoto() async {
    if (_sending) return;
    final file = await pickPhoto(context);
    if (file == null || !mounted) return;
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
    setState(() => _sending = true);
    try {
      final m = await _api.sendChatPhoto(widget.conversationId, photo.bytes, photo.name,
          caption: photo.caption, idempotencyKey: photo.key);
      if (_input.text.trim() == photo.caption) _input.clear(); // the caption went with the photo
      setState(() {
        _unsentPhoto = null;
        if (!_messages.any((x) => x.id == m.id)) _messages.add(m);
      });
      _toBottom();
    } catch (e) {
      if (!mounted) return;
      // On a lost connection the photo is kept with its words in a line above the field, to go again with a tap,
      // once. The words leave the field, so they are not sent again as a message of their own.
      final offline = e is ApiException && e.offline;
      final went = offline && _cameWhileSending(before, (m) => m.photoUrl != null && m.body == photo.caption);
      if (offline && _input.text.trim() == photo.caption) _input.clear();
      setState(() => _unsentPhoto = offline && !went ? photo : null);
      if (!offline) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Puts the kept photo aside; its words come back to the field, as they are the sender's to keep or send.
  void _dropPhoto(_Photo photo) {
    setState(() => _unsentPhoto = null);
    if (_input.text.trim().isEmpty && photo.caption.isNotEmpty) {
      _input.value =
          TextEditingValue(text: photo.caption, selection: TextSelection.collapsed(offset: photo.caption.length));
    }
  }

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
        if (conv?.role == 'seller') _QuickReplies(onPick: _useReply, payments: _payments),
        if (_unsentPhoto case final photo?)
          _NotSentLine(
            key: const Key('chat-photo-not-sent'),
            text: tr('Байланыс жоқ. Фото жетпеген болуы мүмкін.'),
            photo: photo.bytes,
            caption: photo.caption,
            onRetry: _sending ? null : () => _postPhoto(photo),
            onDrop: _sending ? null : () => _dropPhoto(photo),
          ),
        if (_notSent)
          _NotSentLine(
            key: const Key('chat-not-sent'),
            text: tr('Байланыс жоқ. Хабарлама жетпеген болуы мүмкін, мәтіні осы жерде тұр.'),
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
                  onPressed: _sending || _unsentPhoto != null ? null : _sendPhoto,
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

/// A picked photo with what goes with it, as it was sent.
typedef _Photo = ({Uint8List bytes, String name, String caption, String key});

/// Says, above the field and not over it, that a message may not have gone, with a way to send it again. A photo is
/// shown small, so it is clear which one, and can be put aside.
class _NotSentLine extends StatelessWidget {
  const _NotSentLine(
      {super.key, required this.text, required this.onRetry, this.photo, this.caption = '', this.onDrop});
  final String text;
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
      Icon(Icons.cloud_off_outlined, size: 20, color: scheme.error),
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
        key: Key(photo == null ? 'chat-resend' : 'chat-photo-resend'),
        onPressed: onRetry,
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        child: Text(tr('Қайта көру')),
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
  const _QuickReplies({required this.onPick, required this.payments});
  final ValueChanged<String> onPick;
  final bool payments;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>?>(
      valueListenable: quickReplies,
      builder: (context, _, __) {
        final items = currentQuickReplies(payments: payments);
        return SizedBox(
          height: 48,
          child: ListView(
            key: const Key('quick-replies'),
            scrollDirection: Axis.horizontal,
            padding: contentPadding(context, const EdgeInsets.fromLTRB(12, 6, 12, 6)),
            children: [
              // First, so it is never scrolled out of reach.
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
