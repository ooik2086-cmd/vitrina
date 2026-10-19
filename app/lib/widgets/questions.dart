import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../labels.dart';
import '../screens/login_screen.dart';
import '../session.dart';
import '../theme.dart';
import 'common.dart';

/// Questions block on a listing: the latest answered ones and a way to ask.
class QuestionsSection extends StatefulWidget {
  const QuestionsSection({super.key, required this.listingId, required this.sellerId});
  final int listingId;
  final int sellerId;

  @override
  State<QuestionsSection> createState() => _QuestionsSectionState();
}

class _QuestionsSectionState extends State<QuestionsSection> {
  Future<({List<Question> items, int? unanswered})>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= shown(SessionScope.of(context).api.questions(widget.listingId));
  }

  void _reload() => setState(() {
        _data = shown(SessionScope.of(context).api.questions(widget.listingId));
      });

  Future<void> _ask() async {
    final session = SessionScope.of(context);
    if (!session.signedIn) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
      if (!session.signedIn || !mounted) return;
    }
    final sent = await askQuestion(context, widget.listingId);
    if (sent && mounted) _reload();
  }

  Future<void> _all() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            QuestionsScreen(listingId: widget.listingId, seller: SessionScope.of(context).me?.id == widget.sellerId)));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seller = SessionScope.of(context).me?.id == widget.sellerId;
    return FutureBuilder<({List<Question> items, int? unanswered})>(
      future: _data,
      builder: (context, snap) {
        final items = snap.data?.items ?? const <Question>[];
        final unanswered = snap.data?.unanswered ?? 0;
        final visible = items.where((q) => q.answer != null || q.mine).take(2).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: Text(tr('Сұрақ-жауап'), style: theme.textTheme.titleMedium)),
            if (items.isNotEmpty)
              TextButton(
                key: const Key('questions-all'),
                onPressed: _all,
                child: Text(seller && unanswered > 0
                    ? trf('Жауапсыз: {0}', [unanswered])
                    : trf('Барлығы ({0})', [items.length])),
              ),
          ]),
          // Not loaded: said, so «no questions yet» is not believed.
          if (snap.hasError)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 12),
              child: Card(
                child: RetryLine(
                    what: tr('Сұрақтар жүктелмеді'),
                    error: snap.error,
                    busy: snap.connectionState == ConnectionState.waiting,
                    onRetry: _reload),
              ),
            )
          else if (visible.isEmpty && !seller)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(tr('Өлшемі, қорабы не жағдайы туралы сұраңыз: жауапты бәрі көреді.'),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          for (final q in visible) QuestionTile(question: q),
          if (!seller)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('ask-question'),
                onPressed: _ask,
                icon: const Icon(Icons.help_outline_rounded),
                label: Text(tr('Сұрақ қою')),
              ),
            ),
        ]);
      },
    );
  }
}

/// Opens the ask sheet; true when a question was sent.
Future<bool> askQuestion(BuildContext context, int listingId) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TextSheet(
      title: tr('Сатушыға сұрақ'),
      hint: tr('Мысалы: өлшемі кішілеу ме? Қорабы бар ма?'),
      note: tr('Сатушы жауап бергенде сұрақ пен жауапты барлық сатып алушы көреді. Телефон мен сілтеме жазбаңыз.'),
      action: tr('Жіберу'),
      minLength: 5,
      maxLength: 500,
      send: (text) => SessionScope.of(context).api.askQuestion(listingId, text),
    ),
  );
  return sent == true;
}

class QuestionTile extends StatelessWidget {
  const QuestionTile({super.key, required this.question, this.trailing});
  final Question question;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = question;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(q.text, style: weight(theme.textTheme.bodyLarge!, 650)),
            const SizedBox(height: 4),
            if (q.answer != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // The plain ink: on this grey even the deeper accent reads under 4.5:1 at this size.
                  Text(tr('Сатушы'), style: weight(theme.textTheme.labelSmall!, 750)),
                  const SizedBox(height: 2),
                  Text(q.answer!, style: theme.textTheme.bodyMedium),
                ]),
              )
            else
              Text(trf('{0} · жауап күтуде', [formatDay(q.askedAt)]),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// Every question on one listing. The seller answers here; a buyer can take back an unanswered question.
class QuestionsScreen extends StatefulWidget {
  const QuestionsScreen({super.key, required this.listingId, this.seller = false});
  final int listingId;
  final bool seller;

  @override
  State<QuestionsScreen> createState() => _QuestionsScreenState();
}

class _QuestionsScreenState extends State<QuestionsScreen> {
  late Future<({List<Question> items, int? unanswered})> _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data = shown(SessionScope.of(context).api.questions(widget.listingId));
  }

  void _reload() => setState(() {
        _data = shown(SessionScope.of(context).api.questions(widget.listingId));
      });

  Future<void> _answer(Question q) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TextSheet(
        title: q.text,
        hint: tr('Жауабыңыз'),
        initial: q.answer,
        note: tr('Жауапты барлық сатып алушы көреді. Телефон мен сілтеме жазбаңыз.'),
        action: q.answer == null ? tr('Жауап беру') : tr('Сақтау'),
        minLength: 2,
        maxLength: 1000,
        send: (text) => SessionScope.of(context).api.answerQuestion(q.id, text),
      ),
    );
    if (done == true && mounted) _reload();
  }

  Future<void> _hide(Question q) async {
    try {
      await SessionScope.of(context).api.hideQuestion(q.id);
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Сұрақ-жауап'))),
      floatingActionButton: widget.seller
          ? null
          : FloatingActionButton.extended(
              onPressed: () async {
                if (await askQuestion(context, widget.listingId) && mounted) _reload();
              },
              icon: const Icon(Icons.help_outline_rounded),
              label: Text(tr('Сұрақ қою')),
            ),
      body: FutureBuilder<({List<Question> items, int? unanswered})>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError && snap.connectionState == ConnectionState.done) {
            return ErrorRetry(error: snap.error, onRetry: _reload);
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!.items;
          if (items.isEmpty) return Center(child: Text(tr('Әзірге сұрақ жоқ.')));
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, i) {
              final q = items[i];
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                QuestionTile(
                  question: q,
                  trailing: widget.seller || (q.mine && q.answer == null)
                      ? IconButton(
                          tooltip: widget.seller ? tr('Сұрақты жасыру') : tr('Сұрақты қайтарып алу'),
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _hide(q),
                        )
                      : null,
                ),
                if (widget.seller)
                  q.answer == null
                      ? FilledButton.tonal(
                          key: Key('answer-${q.id}'), onPressed: () => _answer(q), child: Text(tr('Жауап беру')))
                      : TextButton(onPressed: () => _answer(q), child: Text(tr('Жауапты өзгерту'))),
              ]);
            },
          );
        },
      ),
    );
  }
}

class _TextSheet extends StatefulWidget {
  const _TextSheet({
    required this.title,
    required this.hint,
    required this.note,
    required this.action,
    required this.minLength,
    required this.maxLength,
    required this.send,
    this.initial,
  });
  final String title, hint, note, action;
  final String? initial;
  final int minLength, maxLength;
  final Future<Object?> Function(String text) send;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final _text = TextEditingController(text: widget.initial);
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await widget.send(_text.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.title, style: weight(theme.textTheme.titleLarge!, 800)),
        const SizedBox(height: 12),
        TextField(
          key: const Key('question-text'),
          controller: _text,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          maxLength: widget.maxLength,
          decoration: InputDecoration(hintText: widget.hint),
          onChanged: (_) => setState(() {}),
        ),
        Text(widget.note, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('question-send'),
            onPressed: _busy || _text.text.trim().length < widget.minLength ? null : _send,
            child: Text(widget.action),
          ),
        ),
      ]),
    );
  }
}
