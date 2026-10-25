import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../api.dart';
import '../i18n.dart';
import '../labels.dart';
import '../quick_replies.dart';
import '../screens/login_screen.dart';
import '../session.dart';
import '../theme.dart';
import 'common.dart';
import 'listing_lines.dart';

/// Questions block on a listing: the latest answered ones and a way to ask.
class QuestionsSection extends StatefulWidget {
  const QuestionsSection(
      {super.key, required this.listingId, required this.sellerId, this.inSheet = false, this.onLoaded});
  final int listingId;
  final int sellerId;

  /// Told each time the questions load, so the line that opened this sheet counts them without asking again.
  final ValueChanged<({List<Question> items, int? unanswered})>? onLoaded;

  /// Shown in the listing page's questions sheet, which has its own title.
  final bool inSheet;

  @override
  State<QuestionsSection> createState() => _QuestionsSectionState();
}

class _QuestionsSectionState extends State<QuestionsSection> {
  Future<({List<Question> items, int? unanswered})>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= _fetch();
  }

  Future<({List<Question> items, int? unanswered})> _fetch() {
    final data = shown(SessionScope.of(context).api.questions(widget.listingId));
    data.then((d) => widget.onLoaded?.call(d), onError: (_) {});
    return data;
  }

  void _reload() => setState(() {
        _data = _fetch();
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
        // On the page two; in the sheet the line opens, all of them.
        final visible = items.where((q) => q.answer != null || q.mine).take(widget.inSheet ? items.length : 2).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!widget.inSheet) const SizedBox(height: 24),
          Row(children: [
            Expanded(
                child: widget.inSheet
                    ? const SizedBox.shrink()
                    : Text(tr('Сұрақ-жауап'), style: theme.textTheme.titleMedium)),
            // In the sheet, as on the approved demo, the buyer sees the answers themselves; the seller the way to answer.
            if (items.isNotEmpty && (!widget.inSheet || seller))
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
          else if ((visible.isEmpty || widget.inSheet) && !seller)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(tr('Өлшемі, қорабы не жағдайы туралы сұраңыз: жауапты бәрі көреді.'),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            )
          else if (items.isEmpty && seller && snap.hasData)
            Text(tr('Әзірге сұрақ жоқ.'),
                key: const Key('no-questions'),
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          for (final q in visible)
            QuestionTile(
                question: q,
                card: widget.inSheet,
                // The buyer's own question, while unanswered, can be taken back where it is read.
                trailing: widget.inSheet && q.mine && q.answer == null
                    ? TextButton(
                        key: Key('take-back-${q.id}'),
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () => takeBackQuestion(context, q, seller: false, done: _reload),
                        child: Text(tr('Қайтарып алу')),
                      )
                    : null),
          if (!seller && widget.inSheet)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: OutlinedButton(
                key: const Key('ask-question'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: theme.colorScheme.surface,
                  foregroundColor: theme.colorScheme.onSurface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  side: BorderSide(color: theme.colorScheme.outlineVariant),
                  textStyle: weight(theme.textTheme.bodyLarge!, 700),
                ),
                onPressed: _ask,
                child: Text(tr('Сұрақ қою')),
              ),
            )
          else if (!seller)
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

/// The listing page's questions as one line, "Сұрақтар · 2 ›", opening a sheet with the answers and a way to ask.
class QuestionsLine extends StatefulWidget {
  const QuestionsLine({super.key, required this.listingId, required this.sellerId});
  final int listingId;
  final int sellerId;

  @override
  State<QuestionsLine> createState() => _QuestionsLineState();
}

class _QuestionsLineState extends State<QuestionsLine> {
  Future<({List<Question> items, int? unanswered})>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= _load();
  }

  @override
  void didUpdateWidget(QuestionsLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listingId != widget.listingId) _data = _load(); // another colour, its own questions
  }

  // Not shown as an error here: the line just carries no count, and the sheet says what did not load.
  Future<({List<Question> items, int? unanswered})> _load() => SessionScope.of(context).api.questions(widget.listingId);

  Future<void> _open() => showPageSheet<void>(context,
      title: tr('Сұрақтар'),
      builder: (_) => QuestionsSection(
          listingId: widget.listingId,
          sellerId: widget.sellerId,
          inSheet: true,
          // A question asked in the sheet counts on the line too, from what the sheet loaded.
          onLoaded: (d) {
            if (mounted) {
              setState(() {
                _data = Future.value(d);
              });
            }
          }));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({List<Question> items, int? unanswered})>(
      future: _data,
      builder: (context, snap) {
        final n = snap.data?.items.length;
        // The seller cannot ask on their own pair: for them nothing asked yet is a plain 0.
        final seller = SessionScope.of(context).me?.id == widget.sellerId;
        return LineButton(
          key: const Key('questions-line'),
          title: tr('Сұрақтар'),
          detail: n == null ? null : (n == 0 && !seller ? tr('сұрақ қою') : '$n'),
          onTap: _open,
        );
      },
    );
  }
}

/// Opens the ask sheet; true when a question was sent.
Future<bool> askQuestion(BuildContext context, int listingId) async {
  final sent = await showSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TextSheet(
      title: tr('Сатушыға сұрақ'),
      hint: tr('Мысалы: өлшемі кішілеу ме? Қорабы бар ма?'),
      note: tr(
          'Сатушы жауап бергенде сұрақ пен жауапты барлық сатып алушы көреді. Телефон, сілтеме, почта, @атау не мессенджер жазбаңыз.'),
      action: tr('Жіберу'),
      minLength: 5,
      maxLength: 500,
      send: (text) => SessionScope.of(context).api.askQuestion(listingId, text),
    ),
  );
  return sent == true;
}

/// The seller hides a question, or a buyer takes back her own: asked first, sent once.
Future<void> takeBackQuestion(BuildContext context, Question q,
    {required bool seller, required VoidCallback done}) async {
  final ok = await confirmAction(context,
      title: seller ? tr('Сұрақты жасыру керек пе?') : tr('Сұрағыңызды қайтарып алу керек пе?'),
      action: seller ? tr('Жасыру') : tr('Қайтарып алу'),
      destructive: true);
  if (!ok || !context.mounted) return;
  await once((#takeBackQuestion, q.id), () async {
    try {
      await SessionScope.of(context).api.hideQuestion(q.id);
      if (context.mounted) done();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  });
}

class QuestionTile extends StatelessWidget {
  const QuestionTile({super.key, required this.question, this.trailing, this.card = false});
  final Question question;
  final Widget? trailing;

  /// As on the approved demo's sheet: a white card, the question, then "Сатушы: …" under it.
  final bool card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = question;
    if (card) {
      final muted = theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.45);
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            // White on the paper, as on the demo; at night a step lighter than the sheet, so the card still shows.
            color: theme.brightness == Brightness.dark
                ? theme.colorScheme.surfaceContainerHigh
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(q.text, style: weight(theme.textTheme.bodyLarge!, 700)),
          const SizedBox(height: 6),
          Text(q.answer != null ? '${tr('Сатушы')}: ${q.answer}' : trf('{0} · жауап күтуде', [formatDay(q.askedAt)]),
              style: muted),
          if (trailing != null) Align(alignment: Alignment.centerLeft, child: trailing!),
        ]),
      );
    }
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
    final done = await showSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TextSheet(
        title: q.text,
        hint: tr('Жауабыңыз'),
        initial: q.answer,
        note: tr('Жауапты барлық сатып алушы көреді. Телефон, сілтеме, почта, @атау не мессенджер жазбаңыз.'),
        action: q.answer == null ? tr('Жауап беру') : tr('Сақтау'),
        minLength: 2,
        maxLength: 1000,
        send: (text) => SessionScope.of(context).api.answerQuestion(q.id, text),
        // The seller's ready answers from the chat, so most questions take a tap instead of typing.
        ready: true,
      ),
    );
    if (done == true && mounted) _reload();
  }

  Future<void> _hide(Question q) => takeBackQuestion(context, q, seller: widget.seller, done: _reload);

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
    this.ready = false,
  });
  final String title, hint, note, action;
  final String? initial;
  final int minLength, maxLength;
  final Future<Object?> Function(String text) send;

  /// The seller's ready answers are offered above the field (those a public answer can take, publicQuickReplies),
  /// and the keyboard waits for a tap on the field, so the sheet opens on them.
  final bool ready;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final _text = TextEditingController(text: widget.initial);
  bool _busy = false;
  Object? _error; // the last send's refusal, shown under the field: a snack bar would sit behind this sheet
  String? _picked; // the ready answer last put in the field

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// A ready answer goes into the field, not straight out: the seller can still change it before it is public.
  /// It takes the place of an empty field, the old answer or the ready answer picked before; words the seller wrote
  /// are kept, with it added after them.
  void _pick(String text) {
    final now = _text.text.trim();
    final replace = now.isEmpty || now == (widget.initial ?? '').trim() || now == _picked;
    final joined = replace ? text : '$now $text';
    final fits = joined.characters.take(widget.maxLength).toString();
    setState(() {
      _picked = fits;
      _error = null;
      _text.value = TextEditingValue(text: fits, selection: TextSelection.collapsed(offset: fits.length));
    });
    SemanticsService.sendAnnouncement(View.of(context), tr('Жауап өріске қойылды.'), Directionality.of(context));
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.send(_text.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const side = EdgeInsets.symmetric(horizontal: 20);
    // The words scroll when the keyboard and large text leave too little room; the button stays in view above them.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 8),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: side, child: Text(widget.title, style: weight(theme.textTheme.titleLarge!, 800))),
              const SizedBox(height: 12),
              if (widget.ready) ...[
                _ReadyAnswers(onPick: _pick, padding: side),
                const SizedBox(height: 8),
              ],
              Padding(
                padding: side,
                child: TextField(
                  key: const Key('question-text'),
                  controller: _text,
                  autofocus: !widget.ready,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: widget.maxLength,
                  buildCounter: nearLimitCounter,
                  decoration: InputDecoration(
                      // errorMaxLines: a refusal reads in full, at any text size; the sheet scrolls.
                      hintText: widget.hint,
                      // Begun but too short: says why «send» waits, rather than leaving it grey without a word.
                      helperText: _text.text.trim().isNotEmpty && _text.text.trim().length < widget.minLength
                          ? trf('Кемінде {0} әріп жазыңыз', [widget.minLength])
                          : null,
                      errorText: _error == null ? null : refusalText(_error, _text.text),
                      errorMaxLines: 30),
                  onChanged: (_) => setState(() => _error = null),
                ),
              ),
              Padding(
                padding: side,
                child: RemoveContactsButton(
                    error: _error,
                    controller: _text,
                    onRemoved: (clean) => setState(() => _error = clean ? null : moreContacts())),
              ),
              Padding(
                padding: side,
                child: Text(widget.note,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
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

/// One row of the seller's ready answers, the ones the chat offers (changed there, under «Үлгілер») that a public
/// answer can take.
class _ReadyAnswers extends StatelessWidget {
  const _ReadyAnswers({required this.onPick, required this.padding});
  final ValueChanged<String> onPick;
  final EdgeInsets padding; // inside the row, so it scrolls to the sheet's edges

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>?>(
      valueListenable: quickReplies,
      builder: (context, _, __) {
        final items = publicQuickReplies();
        if (items.isEmpty) return const SizedBox.shrink();
        final scale = MediaQuery.textScalerOf(context);
        // Wider with large text, so a chip still shows enough words to tell it from the next.
        final widest = min(scale.scale(220), MediaQuery.sizeOf(context).width * 0.8);
        return SizedBox(
          // Grows with large text, so the chips are never cut at the top.
          height: 48 + (scale.scale(14) - 14) * 1.7,
          // A few short chips (ten at most), all built at once.
          child: SingleChildScrollView(
            key: const Key('ready-answers'),
            scrollDirection: Axis.horizontal,
            padding: padding,
            child: Row(children: [
              for (final t in items)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: ActionChip(
                    label: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: widest),
                      child: Text(t, overflow: TextOverflow.ellipsis),
                    ),
                    onPressed: () => onPick(t),
                  ),
                ),
            ]),
          ),
        );
      },
    );
  }
}
