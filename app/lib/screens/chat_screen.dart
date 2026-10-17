import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../i18n.dart';

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
      _items = session.signedIn ? session.api.conversations() : null;
    }
  }

  Future<void> _reload() async {
    final f = SessionScope.of(context).api.conversations();
    setState(() => _items = f);
    await f;
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
          if (snap.hasError) return Center(child: Text('${snap.error}'));
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
                                : Image.network(c.listingCover!,
                                    fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
                          ),
                        ),
                        title: Text(c.otherName, style: weight(theme.textTheme.titleSmall!, c.unread > 0 ? 750 : 600)),
                        subtitle: Text(
                          c.lastMessage?.body ?? c.listingTitle,
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
                              if (c.unread > 0) Badge(label: Text('${c.unread}'), backgroundColor: Brand.accent),
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
  const ChatScreen({super.key, required this.conversationId, this.pollEvery = const Duration(seconds: 4)});
  final int conversationId;
  final Duration pollEvery;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<ChatMessage> _messages = [];
  Conversation? _conversation;
  Timer? _poll;
  bool _sending = false;
  bool _loading = false;

  Api get _api => SessionScope.of(context).api;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_poll == null) {
      _fetch();
      _poll = Timer.periodic(widget.pollEvery, (_) => _fetch());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    if (_loading) return;
    _loading = true;
    try {
      final (conv, fresh) =
          await _api.messages(widget.conversationId, afterId: _messages.isEmpty ? 0 : _messages.last.id);
      if (!mounted) return;
      final known = {for (final m in _messages) m.id};
      setState(() {
        _conversation = conv;
        _messages.addAll(fresh.where((m) => !known.contains(m.id)));
      });
      if (fresh.isNotEmpty) _toBottom();
    } catch (_) {
      // Keep the thread on screen; the next poll retries.
    } finally {
      _loading = false;
    }
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final m = await _api.sendMessage(widget.conversationId, text);
      _input.clear();
      setState(() {
        if (!_messages.any((x) => x.id == m.id)) _messages.add(m);
      });
      _toBottom();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
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
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(conv?.otherName ?? '', style: theme.textTheme.titleMedium),
          if (conv != null)
            Text('${conv.listingTitle} · ${formatTenge(conv.priceTiyn)}',
                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      conv?.role == 'buyer' ? tr('Өлшемі, жағдайы немесе жеткізу туралы сұраңыз.') : tr('Хабарлама әлі жоқ.'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) {
                    final m = _messages[i];
                    return _Bubble(message: m, mine: m.senderId == me);
                  },
                ),
        ),
        Material(
          color: scheme.surface,
          child: SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant))),
              padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
              child: Row(children: [
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});
  final ChatMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;
    return Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
      Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
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
          Text(message.body, style: theme.textTheme.bodyLarge?.copyWith(color: fg)),
          const SizedBox(height: 2),
          Text(_time(message.createdAt), style: theme.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.6))),
        ]),
      ),
      // Shown to the reader of a message with a phone number or link: deals outside the app lose the protection.
      if (message.contactWarning && !mine)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.shield_outlined, size: 14, color: scheme.error),
            const SizedBox(width: 4),
            Flexible(
              child: Text(tr('Төлемді тек VITRINA арқылы жасаңыз, әйтпесе ақшаңыз қорғалмайды.'),
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.error)),
            ),
          ]),
        ),
    ]);
  }
}
