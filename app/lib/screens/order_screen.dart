import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../net_image.dart';
import '../api.dart';
import '../labels.dart';
import '../push.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/listing_contents.dart' show photoAngles;
import '../colors.dart';
import '../i18n.dart';
import 'chat_screen.dart';
import 'help_screen.dart';
import 'listing_screen.dart';

/// An action the current user may offer on an order. The server still checks every move.
class _Action {
  const _Action(this.label, this.endpoint,
      {this.needs, this.destructive = false, this.ask, this.explain, this.done, this.hint});
  final String label;
  final String endpoint;
  final String? needs; // 'reason' or 'tracking'
  final bool destructive;

  /// The question of a confirmation dialog; null when the move needs none (or asks for a reason instead).
  final String? ask;

  /// What happens to the order and the money, shown in the dialog before the move.
  final String? explain;

  /// Said in a snackbar once the server has made the move.
  final String? done;

  /// Placeholder of the reason field.
  final String? hint;
}

List<_Action> _actionsFor(OrderInfo o, {required bool isBuyer}) {
  final cancel = _Action(tr('Тапсырыстан бас тарту'), 'cancel',
      destructive: true,
      ask: tr('Тапсырыстан бас тарту керек пе?'),
      explain: tr('Тапсырыс жойылады, өлшем басқаларға ашылады. Төлем өтіп кетсе, ақша сізге толық қайтарылады.'),
      done: tr('Тапсырыс жойылды.'));
  final dispute = _Action(tr('Дау ашу'), 'dispute',
      needs: 'reason',
      destructive: true,
      explain: tr('Тапсырысты қолдау қызметі қарайды. Шешім шыққанша ақша ешкімге өтпейді.'),
      done: tr('Дау ашылды. «Дәлелдер» бөлімінде фото не видео қосыңыз: қолдау қызметі соны қарап шешеді.'));
  if (isBuyer) {
    return switch (o.status) {
      'CREATED' => [_Action(tr('Төлеу'), 'pay'), cancel],
      'PAYMENT_PENDING' => [cancel],
      'PAID' => [
          _Action(tr('Бас тарту, ақшаны қайтару'), 'cancel',
              destructive: true,
              ask: tr('Тапсырыстан бас тарту керек пе?'),
              explain: tr('Ақша сізге толық қайтарылады, тапсырыс жабылады.'),
              done: tr('Тапсырыс жойылды. Ақша сізге қайтарылады.'))
        ],
      'SHIPPED' || 'IN_TRANSIT' => [
          _Action(tr('Тауарды алдым'), 'received',
              ask: tr('Сәлемдеме қолыңызға тиді ме?'),
              explain: trf(
                  'Тексеруге {0} күн басталады. Осы уақытта растауға, қайтаруға не дау ашуға болады. Ештеңе таңдамасаңыз, тапсырыс аяқталып, ақша сатушыға өтеді.',
                  [buyerChecksWithinDays]),
              done: tr('Белгіленді. Аяқкиімді тексеріп көріңіз.')),
          dispute,
        ],
      'DELIVERED_PENDING_CONFIRMATION' => [
          _Action(tr('Алдым, бәрі дұрыс'), 'confirm',
              ask: tr('Бәрі дұрыс па?'),
              explain: tr(
                  'Растасаңыз, ақша комиссия шегеріліп сатушыға өтеді. Осыдан кейін қайтару не дау ашу мүмкін болмайды.'),
              done: tr('Рақмет! Тапсырыс аяқталды.')),
          _Action(tr('Қайтару'), 'return',
              needs: 'reason',
              explain: tr('Сатушы қайтаруды мақұлдаса, ақша сізге қайтарылады. Келіспесе, қолдау қызметі шешеді.'),
              done: tr('Қайтару сұрауы сатушыға жіберілді. «Дәлелдер» бөлімінде ақаудың фотосын қосыңыз.')),
          dispute,
        ],
      'RETURN_REQUESTED' => [dispute],
      _ => const [],
    };
  }
  final decline = _Action(tr('Бас тарту'), 'decline',
      needs: 'reason',
      destructive: true,
      explain: tr('Ақша сатып алушыға толық қайтарылады, өлшем қайта сатылымға шығады.'),
      done: tr('Тапсырыстан бас тарттыңыз. Ақша сатып алушыға қайтарылады.'));
  return switch (o.status) {
    'PAID' => [_Action(tr('Қабылдау'), 'accept', done: tr('Қабылданды. Енді аяқкиімді жіберіңіз.')), decline],
    'SELLER_ACCEPTED' || 'PREPARING' => [
        _Action(tr('Жібердім'), 'ship', needs: 'tracking', done: tr('Жіберілді деп белгіленді.')),
        decline,
      ],
    'RETURN_REQUESTED' => [
        _Action(tr('Қайтаруды мақұлдау'), 'approve-return',
            ask: tr('Қайтаруды мақұлдау керек пе?'),
            explain: tr('Ақша сатып алушыға қайтарылады.'),
            done: tr('Қайтару мақұлданды.')),
        _Action(tr('Қайтаруға келіспеу'), 'dispute',
            needs: 'reason',
            destructive: true,
            hint: tr('Неге келіспейсіз? Қолдау қызметі осыны оқиды.'),
            explain: tr('Қайтаруды қолдау қызметі шешеді. Шешім шыққанша ақша ешкімге өтпейді.'),
            done: tr('Қолдау қызметіне жіберілді. «Дәлелдер» бөлімінде өз дәлеліңізді қосыңыз.')),
      ],
    _ => const [],
  };
}

class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.orderId});
  final int orderId;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

/// From payment until the box has left: when a printed slip is useful.
const _slipStatuses = {'PAID', 'SELLER_ACCEPTED', 'PREPARING', 'SHIPPED'};

/// Links to evidence photos and videos stop working an hour after the server gives them; the order is fetched again
/// before that, so an old screen never opens a dead link.
const linkFreshFor = Duration(minutes: 50);

class _OrderScreenState extends State<OrderScreen> with WidgetsBindingObserver {
  /// A6 page with the recipient, address, pair and size, to print and put on the box.
  Future<void> _slip() async {
    try {
      final bytes = await _api.packingSlip(widget.orderId);
      final name = 'vitrina-${widget.orderId}.pdf';
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(Uint8List.fromList(bytes), mimeType: 'application/pdf', name: name)],
        fileNameOverrides: [name],
        downloadFallbackEnabled: true,
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  OrderInfo? _order;
  DateTime? _loadedAt;
  Object? _error;
  bool _busy = false;
  bool _paymentStarted = false;
  bool _reviewed = false;

  Api get _api => SessionScope.of(context).api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_order == null && _error == null) _refresh();
  }

  bool get _stale => _loadedAt == null || clock.now().difference(_loadedAt!) > linkFreshFor;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _order != null && _stale) _refresh();
  }

  /// The address to open an evidence item at: the one on screen, or a new one if that may have expired.
  Future<String> _evidenceUrl(Evidence e) async {
    if (_stale) await _refresh();
    return _order?.evidence.where((x) => x.id == e.id).firstOrNull?.url ?? e.url;
  }

  /// Loads the order. With nothing on screen yet a failure shows in place of it with a retry; once the order is
  /// shown, a failed reload keeps it and says so in a snackbar.
  Future<void> _refresh() async {
    try {
      final o = await _api.order(widget.orderId);
      if (mounted) {
        setState(() {
          _order = o;
          _loadedAt = clock.now();
          _error = null;
        });
        // Paid and on its way: when it is sent or arrives, the phone can say so.
        if (const {'PAID', 'SELLER_ACCEPTED', 'SHIPPED'}.contains(o.status)) unawaited(Push.offer(context));
      }
    } catch (e) {
      if (!mounted) return;
      if (_order == null) {
        setState(() => _error = e);
      } else {
        showError(context, e);
      }
    }
  }

  void _retry() {
    setState(() => _error = null);
    _refresh();
  }

  /// One line of text before a move; «Жіберу» waits for it, so an empty press never looks like it did nothing.
  Future<String?> _ask(String title, String hint, {String? explain, int maxLength = 2000}) async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (explain != null) ...[Text(explain), const SizedBox(height: 12)],
          TextField(
              key: const Key('action-reason'),
              controller: ctrl,
              autofocus: true,
              maxLines: maxLength > 100 ? 3 : 1,
              maxLength: maxLength,
              // A track number is one line of capitals; the keyboard's own key sends it.
              textCapitalization: maxLength > 100 ? TextCapitalization.sentences : TextCapitalization.characters,
              textInputAction: maxLength > 100 ? TextInputAction.newline : TextInputAction.done,
              onSubmitted: (t) {
                if (t.trim().isNotEmpty) Navigator.pop(context, t.trim());
              },
              decoration: InputDecoration(hintText: hint, counterText: '')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Жабу'))),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: ctrl,
            builder: (context, v, _) => FilledButton(
                key: const Key('action-send'),
                onPressed: v.text.trim().isEmpty ? null : () => Navigator.pop(context, ctrl.text.trim()),
                child: Text(tr('Жіберу'))),
          ),
        ],
      ),
    );
    return text;
  }

  /// Yes or no before a move that touches the money; the dialog says what happens to it.
  Future<bool> _confirm(_Action a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(a.ask!),
        content: a.explain == null ? null : Text(a.explain!),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Жабу'))),
          FilledButton(
              key: const Key('confirm-action'), onPressed: () => Navigator.pop(context, true), child: Text(a.label)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _do(_Action a) async {
    String? reason, tracking;
    if (a.needs == 'reason') {
      reason = await _ask(a.label, a.hint ?? tr('Себебін жазыңыз'), explain: a.explain);
      if (reason == null || reason.isEmpty) return;
    } else if (a.needs == 'tracking') {
      tracking = await _ask(tr('Трек-нөмір'), tr('Мысалы, KZ123456789'),
          explain: tr('Пошта не курьер берген нөмір. Сатып алушы сәлемдеменің қайда екенін осы нөмір арқылы көреді.'),
          maxLength: 60);
      if (tracking == null || tracking.isEmpty) return;
    } else if (a.ask != null) {
      if (!await _confirm(a)) return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      if (a.endpoint == 'pay') {
        await _api.startPayment(widget.orderId);
        _paymentStarted = true;
      } else if (a.endpoint == 'received') {
        await _api.markReceived(widget.orderId);
      } else {
        await _api.action(widget.orderId, a.endpoint, reason: reason, trackingNumber: tracking);
      }
      if (mounted && a.done != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(a.done!)));
      }
      await _refresh(); // the action reply has no history or photo; reload the full view
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chat() => once((this, #chat), () async {
        try {
          final c = await _api.orderConversation(widget.orderId);
          if (!mounted) return;
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: c.id)));
        } catch (e) {
          if (mounted) showError(context, e);
        }
      });

  @override
  Widget build(BuildContext context) {
    final me = SessionScope.of(context).me;
    final o = _order;
    return Scaffold(
      appBar: AppBar(title: Text(trf('Тапсырыс №{0}', [widget.orderId])), actions: [
        if (o != null && me != null && (me.id == o.buyerId || me.id == o.sellerId))
          IconButton(
            key: const Key('order-chat'),
            tooltip: me.id == o.buyerId ? tr('Сатушыға жазу') : tr('Сатып алушыға жазу'),
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            onPressed: _chat,
          ),
        if (o != null)
          IconButton(
            key: const Key('share-order'),
            tooltip: tr('Тапсырыс мәліметін бөлісу'),
            icon: const Icon(Icons.ios_share),
            onPressed: () => SharePlus.instance.share(ShareParams(text: orderSummaryText(o))),
          ),
      ]),
      body: o == null
          ? (_error == null
              ? const Center(child: CircularProgressIndicator())
              : ErrorRetry(error: _error, onRetry: _retry))
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 8, 20, 24)), children: [
                if (me?.id == o.buyerId && o.status == 'CREATED') ...[
                  _PayNow(order: o, busy: _busy, onPay: () => _do(_actionsFor(o, isBuyer: true).first)),
                  const SizedBox(height: 16),
                ],
                _OrderHeader(order: o),
                const SizedBox(height: 16),
                if (orderDeadlineText(o, me?.id) case final text?) ...[
                  _DeadlineNote(text: text),
                  const SizedBox(height: 16),
                ],
                if (o.delivery != null) ...[
                  _DeliveryCard(delivery: o.delivery!),
                  const SizedBox(height: 16)
                ] else if (me?.id == o.sellerId && const {'CREATED', 'PAYMENT_PENDING'}.contains(o.status)) ...[
                  Text(tr('Мекенжай төлем түскенде көрінеді.'), style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 16),
                ],
                _PriceCard(order: o),
                const SizedBox(height: 16),
                if (o.orderedPhotos.isNotEmpty) ...[
                  _OrderedPhotos(photos: o.orderedPhotos),
                  const SizedBox(height: 16),
                ],
                if (o.listingDetails != null) ...[
                  _OrderedDetails(details: o.listingDetails!),
                  const SizedBox(height: 16),
                ],
                _Timeline(order: o),
                const SizedBox(height: 16),
                const _ProtectionNote(),
                if (_paymentStarted && o.status == 'PAYMENT_PENDING')
                  Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(tr('Төлем провайдері әлі қосылмаған: сынақ режимінде төлем расталмайды.')),
                  ),
                const SizedBox(height: 16),
                if (me?.id == o.buyerId && o.status == 'COMPLETED' && !o.reviewed && !_reviewed)
                  _ReviewForm(orderId: o.id, onDone: () => setState(() => _reviewed = true)),
                if (_reviewed) Padding(padding: EdgeInsets.only(bottom: 12), child: Text(tr('Пікіріңіз үшін рақмет!'))),
                if (me?.id == o.buyerId && const {'COMPLETED', 'REFUNDED', 'CANCELLED'}.contains(o.status))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      key: const Key('buy-again'),
                      onPressed: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => ListingScreen(listingId: o.listingId))),
                      icon: const Icon(Icons.replay),
                      label: Text(tr('Тауар бетін ашу')),
                    ),
                  ),
                if (me?.id == o.sellerId && o.delivery != null && _slipStatuses.contains(o.status))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      key: const Key('slip'),
                      onPressed: _slip,
                      icon: const Icon(Icons.print_outlined),
                      label: Text(tr('Жіберу парағын жүктеу')),
                    ),
                  ),
                // Next to the buttons that open a return or dispute, so it is where the next step is.
                if (o.evidence.isNotEmpty || _canAddEvidence(o, me?.id)) ...[
                  _EvidenceCard(
                    order: o,
                    canAdd: _canAddEvidence(o, me?.id),
                    meId: me?.id,
                    onAdded: _refresh,
                    urlOf: _evidenceUrl,
                  ),
                  const SizedBox(height: 16),
                ],
                for (final a in _actionsFor(o, isBuyer: me?.id == o.buyerId))
                  if (a.endpoint != 'pay') // the banner on top carries it
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: a.destructive
                          ? OutlinedButton(onPressed: _busy ? null : () => _do(a), child: Text(a.label))
                          : FilledButton(onPressed: _busy ? null : () => _do(a), child: Text(a.label)),
                    ),
              ]),
            ),
    );
  }
}

/// While a return or dispute is open, both sides may add photos or a video; support decides on them.
const _evidenceOpen = {'RETURN_REQUESTED', 'DISPUTED'};

/// The buyer may also photograph the pair during the inspection days, before deciding on a return.
bool _canAddEvidence(OrderInfo o, int? me) =>
    me != null &&
    (me == o.sellerId && _evidenceOpen.contains(o.status) ||
        me == o.buyerId && (_evidenceOpen.contains(o.status) || o.status == 'DELIVERED_PENDING_CONFIRMATION'));
const _maxEvidence = 10;
const _maxUploadBytes = 12 * 1024 * 1024;
const _videoSeconds = 15; // about what a phone records at 1080p within 12 MB

/// What the listing said when the order was placed: the condition and defects the buyer agreed to.
class _OrderedDetails extends StatelessWidget {
  const _OrderedDetails({required this.details});
  final Map<String, dynamic> details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = details['color'];
    final name = [details['brand'], details['model_name'], if (color is String) colorName(color)]
        .whereType<String>()
        .where((v) => v.isNotEmpty)
        .join(' · ');
    final defects = (details['defects'] as String?)?.trim() ?? '';
    final description = (details['description'] as String?)?.trim() ?? '';
    return Card(
      key: const Key('ordered-details'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Тапсырыс берген кездегі сипаттама'), style: theme.textTheme.titleSmall),
          if (details['backfilled'] == true) ...[
            const SizedBox(height: 2),
            Text(
                tr('Бұл тапсырыс сипаттама сақтала бастағанға дейін берілген. Мұнда тауар бетінің кейінгі нұсқасы тұр.'),
                style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          if (name.isNotEmpty) Text(name),
          Text(trf('Жағдайы: {0}', [label(conditions, details['condition'] as String?)])),
          // What the seller said it is made of and where, as picked then (a newer server's facts this app can't name
          // are left out).
          for (final (key, option) in _facts(details))
            if (factText(key, option) case final text?) Text('${tr(factNames[key]!)}: $text'),
          if (defects.isNotEmpty) Text(trf('Ақаулар: {0}', [defects])),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(description, style: theme.textTheme.bodySmall),
          ],
        ]),
      ),
    );
  }
}

/// The facts kept with an order, in the order a buyer reads them.
Iterable<(String, String)> _facts(Map<String, dynamic> details) sync* {
  final facts = details['facts'];
  if (facts is! Map) return;
  for (final key in factKeys(details['category'] as String?)) {
    if (facts[key] case final String option) yield (key, option);
  }
}

/// Photos and videos each side added to the return or dispute. Nothing here can be edited or removed.
class _EvidenceCard extends StatefulWidget {
  const _EvidenceCard(
      {required this.order, required this.canAdd, required this.meId, required this.onAdded, required this.urlOf});
  final OrderInfo order;
  final bool canAdd;
  final int? meId;
  final Future<void> Function() onAdded;
  final Future<String> Function(Evidence e) urlOf;

  @override
  State<_EvidenceCard> createState() => _EvidenceCardState();
}

class _EvidenceCardState extends State<_EvidenceCard> {
  bool _uploading = false;

  int get _mine => widget.order.evidence.where((e) => _side(e.from) == widget.meId).length;

  int? _side(String from) => from == 'buyer' ? widget.order.buyerId : widget.order.sellerId;

  Future<XFile?> _pick() async {
    final isBuyer = widget.meId == widget.order.buyerId;
    final choice = await showSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              title: Text(tr('Дәлел қосу')),
              subtitle: Text(isBuyer
                  ? tr('Келген аяқкиімді, қорапты және жапсырманы анық түсіріңіз. Жіберген соң өшіруге болмайды.')
                  : tr('Жіберген аяқкиімнің, қораптың не трек-чектің фотосын қосыңыз. Жіберген соң өшіруге болмайды.')),
            ),
            ListTile(
              key: const Key('evidence-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(tr('Фото түсіру')),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              key: const Key('evidence-gallery'),
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(tr('Галереядан фото')),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              key: const Key('evidence-record'),
              leading: const Icon(Icons.videocam_outlined),
              title: Text(tr('Видео түсіру')),
              subtitle: Text(trf('{0} секундқа дейін', [_videoSeconds])),
              onTap: () => Navigator.pop(context, 'record'),
            ),
            ListTile(
              key: const Key('evidence-video'),
              leading: const Icon(Icons.video_library_outlined),
              title: Text(tr('Галереядан видео')),
              subtitle: Text(tr('MP4 не MOV, 12 МБ-қа дейін (шамамен 10 секунд)')),
              onTap: () => Navigator.pop(context, 'video'),
            ),
          ]),
        ),
      ),
    );
    final picker = ImagePicker();
    if (choice == null || !mounted) return null;
    // A refused camera or gallery says so instead of doing nothing.
    return takePhoto(
        context,
        () => switch (choice) {
              'camera' => picker.pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 90),
              'gallery' => picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 90),
              // maxDuration only stops a recording; a gallery clip is checked by size below.
              'record' =>
                picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(seconds: _videoSeconds)),
              'video' => picker.pickVideo(source: ImageSource.gallery),
              _ => Future.value(null),
            },
        camera: choice == 'camera' || choice == 'record');
  }

  /// Shows what is about to go out and that it is final. Null when cancelled, '' when sent without a note. The
  /// controller is left to the collector: disposing it here would break the dialog's closing animation.
  Future<String?> _confirm(Uint8List bytes, bool video) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Дәлелді жіберу керек пе?')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              key: const Key('evidence-preview'),
              borderRadius: BorderRadius.circular(12),
              child: ColoredBox(
                color: Brand.studio,
                child: SizedBox(
                  height: 120,
                  width: double.infinity,
                  child: video
                      ? const Icon(Icons.videocam_outlined, size: 40, color: Colors.black87)
                      : Image.memory(bytes,
                          fit: BoxFit.contain,
                          cacheHeight: 360,
                          errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined, color: Colors.black54)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('evidence-note'),
              controller: ctrl,
              maxLength: 500,
              maxLines: 3,
              decoration: InputDecoration(
                  labelText: tr('Түсініктеме (міндетті емес)'),
                  hintText: widget.meId == widget.order.buyerId
                      ? tr('Мысалы: оң аяқтың табаны жарылған')
                      : tr('Мысалы: жіберер алдындағы түрі')),
            ),
            Text(tr('Жіберген соң өзгертуге не өшіруге болмайды. Екі тарап та, қолдау қызметі де көреді.'),
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Болдырмау'))),
          FilledButton(
              key: const Key('evidence-send'),
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: Text(tr('Жіберу'))),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final XFile? file;
    final Uint8List bytes;
    try {
      file = await _pick();
      if (file == null || !mounted) return;
      // Measured before reading: a long gallery clip can be hundreds of MB, and is refused without loading it.
      if (await file.length() > _maxUploadBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(tr('Файл тым үлкен: 12 МБ-қа дейін. Қысқарақ видео түсіріңіз не фото жіберіңіз.'))));
        }
        return;
      }
      bytes = await file.readAsBytes();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr('Файлды ашу мүмкін болмады. Басқасын таңдаңыз.'))));
      }
      return;
    }
    if (!mounted) return;
    final video = file.name.toLowerCase().endsWith('.mp4') ||
        file.name.toLowerCase().endsWith('.mov') ||
        (file.mimeType ?? '').startsWith('video/');
    final note = await _confirm(bytes, video);
    if (note == null || !mounted) return; // cancelled
    final key = List.generate(16, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
    await _send(bytes, file.name, note, key);
  }

  /// One try; after a dropped connection the same [key] is offered again, so a copy that did arrive is not doubled.
  Future<void> _send(Uint8List bytes, String name, String note, String key) async {
    setState(() => _uploading = true);
    try {
      await SessionScope.of(context).api.addEvidence(widget.order.id, bytes, name, note: note, key: key);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Дәлел қосылды'))));
      }
      await widget.onAdded();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Дәлел жіберілмеді: байланыс үзілді.')),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(label: tr('Қайталау'), onPressed: () => _send(bytes, name, note, key)),
        ));
      } else {
        showError(context, e);
        if (e.status == 409) await widget.onAdded(); // the case closed or the limit filled: show it as it is now
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Widget _tile(Evidence e) {
    final video = e.kind == 'video';
    final who = _side(e.from) == widget.meId ? tr('Сіз') : (e.from == 'buyer' ? tr('Сатып алушы') : tr('Сатушы'));
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(
          button: true,
          label: video ? tr('Видеоны ашу') : tr('Фотоны ашу'),
          child: InkWell(
            key: Key('evidence-${e.id}'),
            borderRadius: BorderRadius.circular(12),
            onTap: video
                ? () async {
                    final url = await widget.urlOf(e);
                    final opened =
                        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).catchError((_) => false);
                    if (!opened && mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(tr('Видеоны ашатын бағдарлама табылмады.'))));
                    }
                  }
                : () async {
                    final url = await widget.urlOf(e);
                    if (mounted) _OrderedPhotos.open(context, url);
                  },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ColoredBox(
                color: Brand.studio,
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: video
                      ? const Icon(Icons.play_circle_outline, size: 36, color: Colors.black87)
                      : Image(
                          image: ResizeImage.resizeIfNeeded(216, null, netImage(e.url, keep: false)),
                          gaplessPlayback: true, // a reload with a new link keeps the old picture until it is in
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined, color: Colors.black54)),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                '$who · ${formatDay(e.at)} ${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}',
                style: Theme.of(context).textTheme.labelMedium),
            if (e.note != null) Text(e.note!),
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = _maxEvidence - _mine;
    return Card(
      key: const Key('evidence'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Дәлелдер'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(tr('Екі тарап та, қолдау қызметі де көреді. Жіберілген дәлелді өзгертуге не өшіруге болмайды.'),
              style: theme.textTheme.bodySmall),
          if (widget.order.evidenceUntil case final until?) ...[
            const SizedBox(height: 4),
            Text(
                trf('Дәлел қосу мерзімі: {0} дейін. Содан кейін қолдау қызметі шешеді.', [
                  '${formatDay(until)} ${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')}'
                ]),
                key: const Key('evidence-until'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.w600, fontVariations: const [FontVariation('wght', 600)])),
          ],
          if (widget.order.status == 'DELIVERED_PENDING_CONFIRMATION') ...[
            const SizedBox(height: 4),
            Text(tr('Ақау байқасаңыз, қазір түсіріп қойыңыз: қайтару сұрағанда сатушы бірден көреді.'),
                style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 10),
          if (widget.order.evidence.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(tr('Әзірге дәлел жоқ.'), style: theme.textTheme.bodyMedium),
            ),
          for (final e in widget.order.evidence) _tile(e),
          if (widget.canAdd)
            left > 0
                ? OutlinedButton.icon(
                    key: const Key('add-evidence'),
                    onPressed: _uploading ? null : _add,
                    icon: _uploading
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.add_a_photo_outlined),
                    label: Text(trf('Дәлел қосу ({0} қалды)', [left])),
                  )
                : Text(tr('Дәлелдер саны шегіне жетті.'), style: theme.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

/// Plain text of the order for a messenger or a note. Not a fiscal receipt: that comes from the payment partner.
String orderSummaryText(OrderInfo o) {
  final lines = [
    trf('VITRINA · тапсырыс №{0}', [o.id]),
    if (o.createdAt != null)
      '${formatDay(o.createdAt!)}.${o.createdAt!.year} ${o.createdAt!.hour.toString().padLeft(2, '0')}:${o.createdAt!.minute.toString().padLeft(2, '0')}',
    if (o.listingTitle != null) o.listingTitle!,
    if (o.sizeLabel != null) trf('Өлшем {0} · {1} см', [o.sizeLabel, o.sizeCm]),
    if (o.sellerName != null) trf('Сатушы: {0}', [o.sellerName]),
    trf('Тауар: {0}', [formatTenge(o.itemPriceTiyn + o.promoDiscountTiyn)]),
    if (o.promoCode != null) trf('Промокод {0}: −{1}', [o.promoCode, formatTenge(o.promoDiscountTiyn)]),
    trf('Жеткізу: {0}', [o.deliveryPriceTiyn == 0 ? tr('тегін') : formatTenge(o.deliveryPriceTiyn)]),
    trf('Жиыны: {0}', [formatTenge(o.totalTiyn)]),
    trf('Күйі: {0}', [label(orderStatuses, o.status)]),
    if (o.trackingNumber != null) trf('Трек-нөмір: {0}', [o.trackingNumber]),
    tr('Бұл фискалдық чек емес.'),
  ];
  return lines.join('\n');
}

/// The photos the buyer ordered from, kept with the order: the listing page itself may have changed since.
class _OrderedPhotos extends StatelessWidget {
  const _OrderedPhotos({required this.photos});
  final List<({String url, String angle})> photos;

  static void open(BuildContext context, String url) => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Brand.studio,
          insetPadding: const EdgeInsets.all(16),
          child: Stack(children: [
            InteractiveViewer(
              child: Image(
                  image: netImage(url),
                  fit: BoxFit.contain,
                  semanticLabel: tr('Тапсырыс берген кездегі фото'),
                  loadingBuilder: (_, child, progress) => progress == null
                      ? child
                      : const SizedBox(height: 240, child: Center(child: CircularProgressIndicator())),
                  errorBuilder: (_, __, ___) => SizedBox(
                      height: 240,
                      child: Center(
                          child: Text(tr('Фото ашылмады. Байланысты тексеріп, қайта көріңіз.'),
                              textAlign: TextAlign.center, style: const TextStyle(color: Colors.black87))))),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                  tooltip: tr('Жабу'),
                  icon: const Icon(Icons.close, color: Colors.black87),
                  onPressed: () => Navigator.pop(context)),
            ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stills = photos.where((p) => p.angle != 'frame').toList();
    return Card(
      key: const Key('ordered-photos'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Тапсырыс берген кездегі фото'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(tr('Сатушы тауар бетін кейін өзгертсе де, бұл фотолар өзгермейді.'), style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          SizedBox(
            height: 72,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final p in stills)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => open(context, p.url),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: ColoredBox(
                        color: Brand.studio,
                        child: Image(
                            image: ResizeImage.resizeIfNeeded(216, null, netImage(p.url)),
                            width: 72,
                            height: 72,
                            fit: BoxFit.cover,
                            semanticLabel: tr(photoAngles[p.angle] ?? 'Фото'),
                            errorBuilder: (_, __, ___) => const SizedBox(
                                width: 72, height: 72, child: Icon(Icons.image_outlined, color: Colors.black54))),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _PriceCard extends StatelessWidget {
  const _PriceCard({required this.order});
  final OrderInfo order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = order;
    Widget row(String label, String value, {TextStyle? style, Key? key}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(label, style: style ?? theme.textTheme.bodyMedium)),
            Text(value, key: key, style: style ?? theme.textTheme.bodyMedium),
          ]),
        );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(children: [
          row(tr('Тауар'), formatTenge(o.itemPriceTiyn + o.promoDiscountTiyn)),
          if (o.promoCode != null)
            row(trf('Промокод {0}', [o.promoCode]), '−${formatTenge(o.promoDiscountTiyn)}',
                style: theme.textTheme.bodyMedium?.copyWith(color: accentText(context))),
          row(tr('Жеткізу'), o.deliveryPriceTiyn == 0 ? tr('Тегін') : formatTenge(o.deliveryPriceTiyn)),
          const Divider(),
          row(tr('Жиыны'), formatTenge(o.totalTiyn),
              style: weight(theme.textTheme.titleMedium!, 750), key: const Key('order-total')),
        ]),
      ),
    );
  }
}

class _OrderHeader extends StatelessWidget {
  const _OrderHeader({required this.order});
  final OrderInfo order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = order;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 76,
              height: 76,
              color: Brand.studio,
              child: o.listingCover == null
                  ? const Icon(Icons.image_outlined)
                  : Image(
                      image: netImage(o.listingCover!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(o.listingTitle ?? '',
                  style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (o.sizeLabel != null)
                Text(trf('Өлшем {0} · {1} см', [o.sizeLabel, o.sizeCm]), style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(formatTenge(o.totalTiyn), style: weight(theme.textTheme.titleMedium!, 750)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _DeliveryCard extends StatelessWidget {
  const _DeliveryCard({required this.delivery});
  final Delivery delivery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = delivery;
    return Card(
      key: const Key('delivery-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.place_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Жеткізу мекенжайы'), style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              SelectableText('${d.city}, ${d.address}', style: theme.textTheme.bodyMedium),
              SelectableText('${d.recipientName} · ${d.recipientPhone}', style: theme.textTheme.bodyMedium),
              if (d.note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(d.note!,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The happy path as five steps; disputes, returns and cancellations show as a banner instead.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.order});
  final OrderInfo order;

  // Built on each call, not cached: a cached list would keep the language the app started in.
  static List<(String, String, IconData)> get _steps => [
        ('PAID', tr('Төленді'), Icons.lock_outline_rounded),
        ('SELLER_ACCEPTED', tr('Сатушы қабылдады'), Icons.storefront_outlined),
        ('SHIPPED', tr('Жіберілді'), Icons.local_shipping_outlined),
        ('DELIVERED_PENDING_CONFIRMATION', tr('Жеткізілді'), Icons.inventory_2_outlined),
        ('COMPLETED', tr('Аяқталды'), Icons.check_circle_outline_rounded),
      ];
  static const _off = {'DISPUTED', 'RETURN_REQUESTED', 'REFUND_PENDING', 'REFUNDED', 'CANCELLED'};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final o = order;
    final reached = {for (final h in o.history) h.status: h.at};
    final steps = _steps;
    String when(DateTime t) =>
        '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}, ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_off.contains(o.status))
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(14)),
              child: Text(label(orderStatuses, o.status),
                  style: weight(theme.textTheme.bodyMedium!, 650).copyWith(color: scheme.onErrorContainer)),
            )
          else if (!reached.containsKey('PAID'))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(label(orderStatuses, o.status), style: theme.textTheme.titleSmall),
            ),
          for (final (i, (code, title, icon)) in steps.indexed)
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Column(children: [
                  CircleAvatar(
                    radius: 15,
                    backgroundColor: reached.containsKey(code) ? scheme.primary : scheme.surfaceContainerHighest,
                    child: Icon(icon,
                        size: 16, color: reached.containsKey(code) ? scheme.onPrimary : scheme.onSurfaceVariant),
                  ),
                  if (i < steps.length - 1)
                    Expanded(
                      child: Container(
                        width: 2,
                        margin: const EdgeInsets.symmetric(vertical: 2),
                        color: reached.containsKey(steps[i + 1].$1) ? scheme.primary : scheme.outlineVariant,
                      ),
                    ),
                ]),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 5, bottom: 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title,
                          style: weight(theme.textTheme.bodyMedium!, reached.containsKey(code) ? 650 : 450)
                              .copyWith(color: reached.containsKey(code) ? scheme.onSurface : scheme.onSurfaceVariant)),
                      if (reached[code] != null) Text(when(reached[code]!), style: theme.textTheme.labelSmall),
                      if (code == 'SHIPPED' && o.trackingNumber != null)
                        SelectableText(trf('Трек-нөмір: {0}', [o.trackingNumber]), style: theme.textTheme.labelMedium),
                    ]),
                  ),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _ProtectionNote extends StatelessWidget {
  const _ProtectionNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Brand.radius)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.shield_outlined),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            tr(protectionText),
            style: theme.textTheme.bodySmall,
          ),
        ),
        TextButton(
          key: const Key('protection-more'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HelpScreen())),
          child: Text(tr('Толығырақ')),
        ),
      ]),
    );
  }
}

class _ReviewForm extends StatefulWidget {
  const _ReviewForm({required this.orderId, required this.onDone});
  final int orderId;
  final VoidCallback onDone;

  @override
  State<_ReviewForm> createState() => _ReviewFormState();
}

class _ReviewFormState extends State<_ReviewForm> {
  int _rating = 0;
  final _text = TextEditingController();
  final List<String> _photos = [];
  String? _fit;
  bool _busy = false;
  bool _uploading = false;

  Future<void> _addPhoto() async {
    final file = await pickPhoto(context, title: tr('Келген аяқкиімнің фотосы'));
    if (file == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final url = await SessionScope.of(context).api.uploadReviewPhoto(widget.orderId, bytes, file.name);
      if (mounted) setState(() => _photos.add(url));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await SessionScope.of(context).api.review(widget.orderId, _rating, _text.text.trim(), photos: _photos, fit: _fit);
      widget.onDone();
    } catch (e) {
      if (mounted) showError(context, e);
      // Sent twice and the first one was kept: show the review that is there.
      if (e is ApiException && e.code == 'already_reviewed') widget.onDone();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Сатушыны бағалаңыз'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(children: [
            for (var i = 1; i <= 5; i++)
              IconButton(
                tooltip: trf('{0} жұлдыз', [i]),
                onPressed: () => setState(() => _rating = i),
                icon: Icon(i <= _rating ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: 32, color: const Color(0xFFFFB020)),
              ),
          ]),
          Text(tr('Өлшемі қалай?'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final e in fits.entries)
              ChoiceChip(
                key: Key('fit-${e.key}'),
                label: Text(tr(e.value)),
                selected: _fit == e.key,
                onSelected: (on) => setState(() => _fit = on ? e.key : null),
              ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            maxLines: 3,
            maxLength: 1000,
            decoration: InputDecoration(hintText: tr('Тауар сипаттамаға сәйкес пе? Жеткізу қалай болды?')),
          ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final url in _photos)
              Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image(
                      image: ResizeImage.resizeIfNeeded(216, null, netImage(url)),
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(width: 72, height: 72)),
                ),
                // 48 by 48 to tap, though the round mark itself stays small in the photo's corner.
                Positioned(
                  right: 0,
                  top: 0,
                  child: IconButton(
                    tooltip: tr('Фотоны алып тастау'),
                    alignment: Alignment.topRight,
                    padding: const EdgeInsets.all(2),
                    onPressed: () => setState(() => _photos.remove(url)),
                    icon: const CircleAvatar(radius: 11, child: Icon(Icons.close, size: 14)),
                  ),
                ),
              ]),
            if (_photos.length < 3)
              SizedBox(
                width: 72,
                height: 72,
                child: OutlinedButton(
                  key: const Key('review-photo'),
                  style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  onPressed: _uploading ? null : _addPhoto,
                  child: _uploading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      // Only an icon shows, so a screen reader is told what it does.
                      : Icon(Icons.add_a_photo_outlined, semanticLabel: tr('Фото қосу')),
                ),
              ),
          ]),
          const SizedBox(height: 4),
          Text(tr('Келген жұпты суретке түсіріңіз: басқа сатып алушыларға көп көмектеседі.'),
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _rating == 0 || _busy || _uploading ? null : _submit,
              child: Text(tr('Пікір қалдыру')),
            ),
          ),
        ]),
      ),
    );
  }
}

String _clock(DateTime t) => '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}, '
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// What happens at the order's deadline, told to whoever can still act on it; null when no clock is running.
String? orderDeadlineText(OrderInfo o, int? meId) {
  final at = o.deadline;
  if (at == null) return null;
  final buyer = meId == o.buyerId;
  return switch (o.status) {
    'CREATED' ||
    'PAYMENT_PENDING' when buyer =>
      trf('{0} дейін төлемесеңіз, тапсырыс жойылады және өлшем басқаларға ашылады.', [_clock(at)]),
    'PAID' when buyer => trf('Сатушы {0} дейін жауап бермесе, ақша сізге өзі қайтарылады.', [_clock(at)]),
    'PAID' => trf('{0} дейін қабылдаңыз немесе бас тартыңыз. Әйтпесе ақша сатып алушыға қайтарылады.', [_clock(at)]),
    'SELLER_ACCEPTED' ||
    'PREPARING' when buyer =>
      trf('Сатушы {0} дейін жібермесе, тапсырыс жойылып, ақша сізге толық қайтарылады.', [_clock(at)]),
    'SELLER_ACCEPTED' || 'PREPARING' => trf(
        '{0} дейін жіберіп, трек-нөмірді енгізіңіз. Әйтпесе тапсырыс жойылып, ақша сатып алушыға толық қайтарылады.',
        [_clock(at)]),
    'SHIPPED' || 'IN_TRANSIT' when buyer => trf(
        'Сәлемдемені алғанда «Тауарды алдым» басыңыз. {0} дейін жетпесе, тапсырысты қолдау қызметі дау ретінде қарайды.',
        [_clock(at)]),
    'SHIPPED' || 'IN_TRANSIT' => trf(
        '{0} дейін жеткізілмесе, тапсырысты қолдау қызметі дау ретінде қарайды. Ақша оған дейін ұсталып тұрады.',
        [_clock(at)]),
    'RETURN_REQUESTED' when buyer =>
      trf('Сатушы {0} дейін жауап бермесе, қайтаруды қолдау қызметі шешеді.', [_clock(at)]),
    'RETURN_REQUESTED' => trf(
        '{0} дейін қайтаруды мақұлдаңыз не келіспеу себебін жазыңыз. Әйтпесе қайтаруды қолдау қызметі шешеді.',
        [_clock(at)]),
    'DELIVERED_PENDING_CONFIRMATION' when buyer => trf(
        '{0} дейін тексеріңіз. Растамасаңыз, қайтару не дау ашпасаңыз, тапсырыс өзі аяқталып, ақша сатушыға өтеді.',
        [_clock(at)]),
    'DELIVERED_PENDING_CONFIRMATION' => trf(
        'Сатып алушы {0} дейін қайтару не дау ашпаса, тапсырыс аяқталып, ақша комиссия шегеріліп сізге өтеді.',
        [_clock(at)]),
    _ => null,
  };
}

/// On top of an order the buyer has not paid yet: the size is held for them, and paying is the next step.
class _PayNow extends StatelessWidget {
  const _PayNow({required this.order, required this.busy, required this.onPay});
  final OrderInfo order;
  final bool busy;
  final VoidCallback onPay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const Key('pay-now'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(Brand.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Енді төлеңіз'), style: weight(theme.textTheme.titleMedium!, 750).copyWith(color: scheme.onPrimary)),
        const SizedBox(height: 4),
        Text(tr('Тапсырыс жасалды, өлшем сізге сақталып тұр. Төлем түскенде сатушы тапсырысты көреді.'),
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onPrimary.withValues(alpha: 0.8))),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('pay'),
            style: FilledButton.styleFrom(backgroundColor: Brand.accentStrong, foregroundColor: Colors.white),
            onPressed: busy ? null : onPay,
            child: Text(trf('{0} төлеу', [formatTenge(order.totalTiyn)])),
          ),
        ),
      ]),
    );
  }
}

class _DeadlineNote extends StatelessWidget {
  const _DeadlineNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('order-deadline'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.schedule_rounded, size: 20, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ]),
    );
  }
}
