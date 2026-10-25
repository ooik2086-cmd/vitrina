import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../net_image.dart';
import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/facts_fields.dart';
import '../widgets/listing_contents.dart';
import '../widgets/questions.dart';
import 'listing_editor_screen.dart';
import 'listing_screen.dart';
import 'help_screen.dart';
import '../i18n.dart';
import '../listing_quality.dart';
import '../quick_replies.dart';

const listingStatuses = {
  'draft': 'Жоба',
  'moderation': 'Тексерілуде',
  'published': 'Сатылымда',
  'paused': 'Тоқтатылған',
  'sold': 'Сатылды',
  'hidden': 'Модератор жасырды',
  'rejected': 'Қайтарылды',
};

/// Seller's own listing: change price, stock, name, photos and sizes, pause or put back on sale.
/// Once on sale the shoe itself (brand, model, category, photos buyers saw) is fixed, so buyers get what they chose.
class ManageListingScreen extends StatefulWidget {
  const ManageListingScreen({super.key, required this.listing, this.showPhotos = false});
  final Listing listing;

  /// Opens on the photos section, as a note about a photo to retake does, instead of the name fields.
  final bool showPhotos;

  @override
  State<ManageListingScreen> createState() => _ManageListingScreenState();
}

class _ManageListingScreenState extends State<ManageListingScreen> with WidgetsBindingObserver {
  final _form = GlobalKey<FormState>();
  late Listing _l = widget.listing;
  late final _price = TextEditingController(text: '${_l.priceTiyn ~/ 100}');
  late final _delivery = TextEditingController(text: '${_l.deliveryPriceTiyn ~/ 100}');
  late final _description = TextEditingController(text: _l.description ?? '');
  late final _defects = TextEditingController(text: _l.defects ?? '');
  late final _title = TextEditingController(text: _l.title);
  late final _brand = TextEditingController(text: _l.brand ?? '');
  late final _model = TextEditingController(text: _l.modelName ?? '');
  late final _color = TextEditingController(text: _l.color);
  late String _category = _l.category;
  late String? _audience = _l.audience;
  late String _condition = _l.condition;
  late Map<String, String> _facts = {..._l.facts};
  late final Map<int, int> _stock = {for (final s in _l.sizes) s.id: _count(s)};

  /// Whether the pending card found the photos ready, and for which photo set.
  bool _photosReady = false;
  String? _photosReadyFor;
  bool _busy = false;
  bool _changed = false;
  final _photos = GlobalKey();
  final _scroll = ScrollController();
  int _tries = 0;

  /// The note that a Save found no connection, while it is on screen.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _offlineBar;

  Timer? _keepTimer;
  bool _deleted = false; // the draft is gone: its edits are never kept again
  bool _restored = false; // changes from before were put back: say so, with a way to drop them
  int _skipped = 0; // kept changes not put back, as their value changed meanwhile
  String? _lastKept; // what was last written, so the same is not written again
  Session? _session; // held, as the page is still kept while it is being closed

  @override
  void initState() {
    super.initState();
    if (widget.showPhotos && !_locked(widget.listing)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bringPhotos());
    }
    WidgetsBinding.instance.addObserver(this);
    for (final (_, c, _) in _texts) {
      c.addListener(_onText);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session = SessionScope.maybeOf(context);
  }

  /// A change to stock or a choice is kept like typing is.
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _keepSoon();
  }

  /// Typing is kept; while the note about changes from before shows, the page also looks again whether any are left.
  void _onText() => _restored ? setState(() {}) : _keepSoon();

  void _keepSoon() {
    _keepTimer?.cancel();
    _keepTimer = Timer(const Duration(seconds: 1), _keep);
  }

  /// Android may close an app in the background at any moment: what is on the page is kept right away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) _keep();
  }

  /// The text fields, each with what the server holds for it.
  List<(String, TextEditingController, String)> get _texts => [
        ('price', _price, '${_l.priceTiyn ~/ 100}'),
        ('delivery', _delivery, '${_l.deliveryPriceTiyn ~/ 100}'),
        ('description', _description, _l.description ?? ''),
        ('defects', _defects, _l.defects ?? ''),
        ('title', _title, _l.title),
        ('brand', _brand, _l.brand ?? ''),
        ('model', _model, _l.modelName ?? ''),
        ('color', _color, _l.color),
      ];

  /// The choices, each with what the server holds for it.
  List<(String, String?, String?)> get _choices => [
        ('category', _category, _l.category),
        ('audience', _audience, _l.audience),
        ('condition', _condition, _l.condition),
        for (final k in factOptions.keys) ('fact:$k', _facts[k], _l.facts[k]),
      ];

  /// The facts as they would be saved: those the kind of footwear has (and any this app does not know).
  Map<String, String> get _shownFacts => factsFor(_category, _facts);

  /// Whether the page lets [value] be set for [key] now, as the name fields do: once on sale the shoe itself is
  /// fixed (brand, model, category), whom it is for and each fact stay once said, and its condition can only get
  /// worse.
  bool _canSet(String key, String? value) {
    final fresh = !_l.everOnSale;
    return switch (key) {
      'brand' || 'model' || 'category' => fresh,
      'audience' => fresh || _l.audience == null,
      final fact when fact.startsWith('fact:') => fresh || _l.facts[fact.substring(5)] == null,
      'condition' => fresh || conditions.keys.skipWhile((c) => c != _l.condition).contains(value),
      _ => true,
    };
  }

  /// Changes not saved are kept on the phone for a fortnight; after that they are likely stale, and dropped.
  static const _editsLast = Duration(days: 14);

  /// Every change not yet saved, each with the value it was changed from, so it is put back only on what the
  /// seller saw: a value changed meanwhile (a sale, another phone) is left as the server has it.
  Map<String, Object?> _edits() => {
        'owner': _session?.me?.id,
        'kept_at': clock.now().millisecondsSinceEpoch,
        'texts': {
          for (final (k, c, was) in _texts)
            if (c.text != was) k: [c.text, was]
        },
        'choices': {
          for (final (k, v, was) in _choices)
            if (v != was) k: [v, was]
        },
        'stock': {
          for (final e in _was.entries) '${e.key}': [_stock[e.key], e.value]
        },
      };

  Future<Map<String, dynamic>> _allEdits(SharedPreferences prefs) async {
    try {
      return jsonDecode(prefs.getString(Session.listingEditsKey) ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      return {}; // kept by an older version and no longer readable
    }
  }

  /// Keeps the page's changes on the phone, or lets them go once there are none (saved, undone, or a hidden
  /// listing that cannot be changed). Kept only for the person signed in, so no one else is ever shown them.
  Future<void> _keep({bool drop = false}) async {
    _keepTimer?.cancel();
    final edits = !drop && !_deleted && !_locked(_l) && _session?.me != null && _dirty ? _edits() : null;
    final mine = edits == null ? null : jsonEncode({...edits, 'kept_at': 0});
    if (mine != null && mine == _lastKept) return; // nothing new since it was last kept
    _lastKept = mine;
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = await _allEdits(prefs);
      final key = '${_l.id}';
      // Changes long gone stale, for any listing, go too: the map does not grow for ever.
      final now = clock.now().millisecondsSinceEpoch;
      final before = all.length;
      all.removeWhere((k, v) =>
          k != key && (v is! Map || v['kept_at'] is! int || now - (v['kept_at'] as int) > _editsLast.inMilliseconds));
      if (edits == null && !all.containsKey(key) && all.length == before) return;
      edits == null ? all.remove(key) : all[key] = edits;
      await prefs.setString(Session.listingEditsKey, jsonEncode(all));
    } catch (_) {
      // Nowhere to keep them (a full phone): the page still works, only an app closed now loses the changes.
    }
  }

  /// Puts back the changes kept from before, on the values they were made to.
  Future<void> _restore() async {
    if (!mounted) return;
    if (_locked(_l)) return _keep(drop: true); // hidden by a moderator: nothing on it can be changed
    Map<String, dynamic>? d;
    try {
      d = (await _allEdits(await SharedPreferences.getInstance()))['${_l.id}'] as Map<String, dynamic>?;
    } catch (_) {
      return;
    }
    if (d == null || !mounted || _dirty) return; // the seller already began changing it: that wins
    try {
      final me = _session?.me?.id;
      final keptAt = DateTime.fromMillisecondsSinceEpoch(d['kept_at'] as int);
      if (me == null || d['owner'] != me || clock.now().difference(keptAt) > _editsLast) {
        unawaited(_keep(drop: true)); // another person's changes on a shared phone, or long gone stale
        return;
      }
      final texts = d['texts'] as Map<String, dynamic>;
      final choices = d['choices'] as Map<String, dynamic>;
      final stock = d['stock'] as Map<String, dynamic>;
      // A change is put back only on the value it was made to, and only where the page still lets it be made.
      var skipped = 0;
      for (final (k, c, was) in _texts) {
        if (texts[k] case [final String v, final String from]) {
          if (from == was && _canSet(k, v)) {
            c.text = v;
          } else {
            skipped++;
          }
        }
      }
      setState(() {
        for (final (k, _, was) in _choices) {
          if (choices[k] case [final String? v, final String? from]) {
            // A fact taken off (null) comes back as taken off; every other choice is a value.
            if (from != was || v == null && !k.startsWith('fact:') || !_canSet(k, v)) {
              skipped++;
              continue;
            }
            switch (k) {
              case 'category':
                _category = v!;
              case 'audience':
                _audience = v;
              case 'condition':
                _condition = v!;
              case final fact when fact.startsWith('fact:'):
                if (v == null) {
                  _facts.remove(fact.substring(5));
                } else {
                  _facts[fact.substring(5)] = v;
                }
            }
          }
        }
        for (final MapEntry(:key, :value) in stock.entries) {
          final size = _l.sizes.where((s) => '${s.id}' == key).firstOrNull;
          if (value case [final int v, final int from] when size != null && from == _count(size)) {
            _stock[size.id] = v;
          } else {
            skipped++;
          }
        }
        _restored = _dirty;
        _skipped = skipped;
      });
      if (!_restored && skipped > 0) {
        // Nothing could come back: said, so the seller does not look for changes that are not there.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('Өткен жолғы сақталмаған өзгерістер қайтарылмады: тауар осы уақытта өзгерген.'))));
      }
    } catch (_) {
      unawaited(_keep(drop: true)); // not half of them
    }
  }

  /// The seller would rather start from what is saved: every change on the page goes, once they say so.
  Future<void> _dropRestored() async {
    final drop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Өзгерістерді алып тастау керек пе?')),
        content: Text(tr('Бет сақталған күйіне қайтады. Бұл беттегі барлық сақталмаған өзгерістер жоғалады.')),
        actions: [
          TextButton(
              key: const Key('drop-edits-sure'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Алып тастау'))),
          FilledButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Қалу'))),
        ],
      ),
    );
    if (drop != true || !mounted) return;
    _offlineBar?.close(); // its changes are not on the page any more
    for (final (_, c, was) in _texts) {
      c.text = was;
    }
    setState(() {
      _category = _l.category;
      _audience = _l.audience;
      _condition = _l.condition;
      _facts = {..._l.facts};
      _stock
        ..clear()
        ..addAll({for (final s in _l.sizes) s.id: _count(s)});
      _restored = false;
    });
    unawaited(_keep(drop: true));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Өзгерістер алып тасталды.'))));
  }

  void _bringPhotos() {
    if (!mounted) return;
    final at = _photos.currentContext;
    if (at != null) {
      Scrollable.ensureVisible(at);
    } else if (_scroll.hasClients && _tries++ < 20) {
      // The list builds only what is near the screen: go down until the photos are built.
      // A screen at a time, so no part is skipped over: more cards sit below the photos.
      final p = _scroll.position;
      _scroll.jumpTo(min(p.pixels + p.viewportDimension, p.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) => _bringPhotos());
    } else if (_scroll.hasClients) {
      _scroll.jumpTo(0); // not found: the page opens from the top as usual
    }
  }

  /// A hidden listing is only shown, not edited: it has no photos section.
  static bool _locked(Listing l) => l.status == 'hidden';

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_keepTimer?.isActive ?? false) unawaited(_keep()); // the last change, before the timer would have kept it
    _scroll.dispose();
    for (final c in [_price, _delivery, _description, _defects, _title, _brand, _model, _color]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _tiyn(String text) {
    final v = int.tryParse(text.replaceAll(RegExp(r'\s'), ''));
    return v == null ? null : v * 100;
  }

  /// Returns the error, or null once done. With [offline], a lost connection is told in those words, with a way to
  /// try again.
  Future<Object?> _run(Future<Listing> Function(Api api) action, String done, {String? offline}) async {
    setState(() => _busy = true);
    try {
      final l = await action(SessionScope.of(context).api);
      if (!mounted) return null;
      setState(() {
        _take(l);
        _changed = true;
      });
      // The newest attempt's answer replaces an old «no connection» at once.
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(done)));
      return null;
    } catch (e) {
      if (mounted && offline != null && e is ApiException && e.offline) {
        final messenger = ScaffoldMessenger.of(context)..clearSnackBars(); // so this one is first
        final bar = _offlineBar = messenger.showSnackBar(SnackBar(
            content: Text(offline),
            duration: const Duration(seconds: 8),
            // With a screen reader it waits to be reached; it is closed when the page is left.
            persist: MediaQuery.accessibleNavigationOf(context),
            action: SnackBarAction(
                label: tr('Қайта көру'),
                onPressed: () {
                  if (mounted && !_busy) _save();
                })));
        unawaited(bar.closed.then((_) {
          if (identical(_offlineBar, bar)) _offlineBar = null;
        }));
      } else if (mounted) {
        showError(context, e);
      }
      return e;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The new value of a name field, or null when it is unchanged, so Save never touches what the seller left alone.
  String? _edited(TextEditingController c, String? was) {
    final v = c.text.trim();
    return v == (was ?? '') ? null : v;
  }

  static int _count(ShoeSize s) => s.quantity ?? (s.available ? 1 : 0);

  /// Only the sizes the seller changed, each with the count it was changed from: a pair bought while the screen was
  /// open is not put back by a Save, and a count changed by a sale meanwhile is shown again before it is saved.
  Map<int, int> get _was => {
        for (final s in _l.sizes)
          if (_stock[s.id] != null && _stock[s.id] != _count(s)) s.id: _count(s)
      };

  /// The fields the contacts check reads, as on the page.
  List<TextEditingController> get _checkedWords => [_title, _description, _defects];

  /// Whether one tap can take out every piece the check found: each stands whole in one of the fields as typed.
  bool get _canRemoveContacts {
    final pieces = contactPieces(_l.moderation?.found);
    return pieces.isNotEmpty && pieces.every((p) => _checkedWords.any((c) => holdsPiece(c.text, p)));
  }

  /// The check found contacts, the seller has changed the words, and they hold none any more: Save (or «Қайта
  /// жіберу») is what is left. Unchanged words are the ones the server read, whatever the app's own copy of the rule
  /// makes of them.
  bool get _contactsGone {
    final stored = [_l.title, _l.description ?? '', _l.defects ?? ''];
    final words = _checkedWords;
    return contactPieces(_l.moderation?.found).isNotEmpty &&
        [for (var i = 0; i < words.length; i++) words[i].text.trim() != stored[i].trim()].contains(true) &&
        !words.any((c) => looksLikeContact(c.text));
  }

  /// Takes what the check found out of the name, the description and the defects. Nothing is saved: the seller
  /// sees the rest and presses Save (or «Қайта жіберу», which saves first), and the card says which.
  void _removeContacts() {
    if (!_canRemoveContacts) return;
    final pieces = contactPieces(_l.moderation?.found);
    setState(() {
      for (final c in _checkedWords) {
        final here = [
          for (final p in pieces)
            if (holdsPiece(c.text, p)) p
        ];
        if (here.isEmpty) continue;
        final text = withoutPieces(c.text, here);
        c.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
      }
    });
    if (_checkedWords.any((c) => looksLikeContact(c.text))) {
      final messenger = ScaffoldMessenger.of(context);
      if (_offlineBar == null) messenger.removeCurrentSnackBar(); // a bar about unsaved changes stays
      messenger.showSnackBar(SnackBar(content: Text(tr('Мәтінде тағы байланыс бар. Оны да алып тастаңыз.'))));
    } else {
      SemanticsService.sendAnnouncement(View.of(context), tr('Байланыс мәтіннен алынды.'), Directionality.of(context));
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final fresh = !_l.everOnSale;
    final was = _was;
    // A Save pauses a listing only when it brings pairs back to one that sold out, also out of sight while the page
    // was open: then the seller is asked at once whether it goes back on sale.
    final before = _l.status;
    final addsPairs = was.entries.any((e) => _stock[e.key]! > e.value);
    final saved = await _run(
      (api) => api.editListing(_l.id,
          priceTiyn: _tiyn(_price.text),
          deliveryPriceTiyn: _tiyn(_delivery.text) ?? 0,
          description: _description.text,
          defects: _defects.text,
          stock: was.isEmpty ? null : {for (final id in was.keys) id: _stock[id]!},
          stockWas: was,
          title: _edited(_title, _l.title),
          brand: fresh ? _edited(_brand, _l.brand) : null,
          modelName: fresh ? _edited(_model, _l.modelName) : null,
          color: _edited(_color, _l.color),
          category: fresh && _category != _l.category ? _category : null,
          audience: _audience != _l.audience ? _audience : null,
          condition: _condition != _l.condition ? _condition : null,
          facts: mapEquals(_shownFacts, _l.facts) ? null : _shownFacts),
      tr('Сақталды'),
      offline: tr('Байланыс жоқ. Өзгерістер жоғалған жоқ, осы бетте тұр.'),
    );
    final soldMeanwhile = saved is ApiException && saved.code == 'stock_changed';
    if (!mounted || saved != null && !soldMeanwhile) return;
    if (saved == null) {
      _showStored();
      _restored = false; // saved now: the note about changes from before has done its work
      if (before == 'moderation' && _l.status != 'moderation') {
        // Nothing held it any more: the check is over, without waiting for staff.
        ScaffoldMessenger.of(context)
          ..removeCurrentSnackBar()
          ..showSnackBar(SnackBar(
              content: Text(switch (_l.status) {
            'published' => tr('Сақталды. Тексеру аяқталды, тауар сатылымда.'),
            'sold' ||
            'paused' when _l.sizes.every((s) => s.quantity == 0) =>
              tr('Сақталды. Тексеру аяқталды. Сату үшін жұп қосыңыз.'),
            'paused' => tr('Сақталды. Тексеру аяқталды. Сатуға «Сатылымға шығару» басыңыз.'),
            _ => tr('Сақталды. Тексеру аяқталды.'),
          })));
      }
      if (before != 'paused' && addsPairs && _l.status == 'paused') _offerSale();
    }
    if (soldMeanwhile) {
      try {
        final l = await SessionScope.of(context).api.listing(_l.id);
        if (!mounted) return;
        _l = l;
        // An earlier Save whose answer was lost brought the pairs back: the same question, now.
        if (before != 'paused' && addsPairs && l.status == 'paused') _offerSale();
      } catch (_) {
        return; // the counts stay as the seller set them, and Save tries again
      }
    }
    // The counts as the server keeps them now, sales included.
    setState(() => _stock
      ..clear()
      ..addAll({for (final s in _l.sizes) s.id: _count(s)}));
  }

  /// Takes the server's copy of the listing. A size the seller has not touched follows the server's count, a sale
  /// meanwhile included, so it is neither shown as a change nor put back by Save; a count the seller set stays.
  void _take(Listing l) {
    final before = {for (final s in _l.sizes) s.id: _count(s)};
    for (final s in l.sizes) {
      if (_stock[s.id] == null || _stock[s.id] == before[s.id]) _stock[s.id] = _count(s);
    }
    _l = l;
  }

  /// Puts what the server stored back in the fields: it may tidy a colour or spaces, and a saved page reads as saved.
  void _showStored() {
    void put(TextEditingController c, String v) {
      if (c.text.trim() != v) c.text = v;
    }

    put(_title, _l.title);
    put(_brand, _l.brand ?? '');
    put(_model, _l.modelName ?? '');
    put(_color, _l.color);
    put(_description, _l.description ?? '');
    put(_defects, _l.defects ?? '');
  }

  /// Whether the page holds a change the server does not have yet: what Save would send.
  bool get _dirty =>
      !_locked(_l) &&
      (_tiyn(_price.text) != _l.priceTiyn ||
          (_tiyn(_delivery.text) ?? 0) != _l.deliveryPriceTiyn ||
          _description.text.trim() != (_l.description ?? '') ||
          _defects.text.trim() != (_l.defects ?? '') ||
          _edited(_title, _l.title) != null ||
          !_l.everOnSale && _edited(_brand, _l.brand) != null ||
          !_l.everOnSale && _edited(_model, _l.modelName) != null ||
          _edited(_color, _l.color) != null ||
          !_l.everOnSale && _category != _l.category ||
          _audience != _l.audience ||
          _condition != _l.condition ||
          !mapEquals(_shownFacts, _l.facts) ||
          _was.isNotEmpty);

  /// Back with changes not saved asks first: a seller who lost the connection, or forgot Save, keeps them.
  Future<void> _leave() async {
    final leave = !_dirty ||
        await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(tr('Сақтамай шығу керек пе?')),
                content: Text(tr('Енгізген өзгерістер сақталмайды.')),
                actions: [
                  // Staying keeps the work, so it is the button the eye goes to.
                  TextButton(
                      key: const Key('discard'),
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(tr('Шығып кету'))),
                  FilledButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Қалу'))),
                ],
              ),
            ) ==
            true;
    if (leave && mounted) {
      _offlineBar?.close(); // its changes are not on a page any more
      unawaited(_keep(drop: true)); // left without them on purpose: not offered again next time
      Navigator.pop(context, _changed);
    }
  }

  /// A draft made by mistake is deleted after asking; the list it came from loses it on the way back.
  Future<void> _deleteDraft() async {
    final sure = await confirmAction(context,
        title: tr('Жобаны өшіру керек пе? Оны қайтару мүмкін болмайды.'), action: tr('Өшіру'), destructive: true);
    if (!sure || !mounted) return;
    setState(() => _busy = true);
    try {
      try {
        await SessionScope.of(context).api.deleteDraft(_l.id);
      } on ApiException catch (e) {
        // Tapped again after an answer lost on the way: the first tap already deleted it.
        if (e.status != 404) rethrow;
      }
      if (!mounted) return;
      _deleted = true;
      _offlineBar?.close();
      unawaited(_keep(drop: true)); // nothing left to come back to
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Жоба өшірілді'))));
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted && !_deleted) setState(() => _busy = false);
    }
  }

  /// Asks whether a sold-out listing that got pairs again goes back on sale now; it stays paused otherwise. Only on
  /// this page while it is in front: a leave question or another page opened meanwhile is not covered by it, and the
  /// button to put it on sale stays on the page.
  void _offerSale() {
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    unawaited(_askSale());
  }

  Future<void> _askSale() async {
    final sell = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true, // with large text its words scroll rather than being cut off
        title: Text(tr('Қайта сатуға шығару керек пе?')),
        content: Text(tr(
            'Жұптар қосылды, бірақ тауар әзірге сатылымда емес. Кейін төмендегі «Сатылымға шығару» түймесімен де шығаруға болады.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Кейін'))),
          FilledButton(
              key: const Key('restock-publish'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Иә, шығару'))),
        ],
      ),
    );
    if (sell == true && mounted && !_busy) await _publish();
  }

  /// Its answer is told also when the page was left meanwhile. A lost answer is checked against the listing as the
  /// server has it, so a publish that went is not reported as failed, nor pressed again into a refusal.
  Future<void> _publish() async {
    if (_dirty) {
      // What the seller sees is what is sent: changes on the page, a contact taken out with one tap among them,
      // are saved first, and nothing is sent if they cannot be.
      await _save();
      if (!mounted || _dirty) return;
    }
    setState(() => _busy = true);
    final api = SessionScope.of(context).api;
    final messenger = ScaffoldMessenger.of(context);
    void say(String text) {
      // «Сақталды» just before is not left to stand in front of it; a bar about unsaved changes is.
      if (_offlineBar == null) messenger.removeCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(text)));
    }

    void went(Listing l) {
      if (mounted) {
        setState(() {
          _take(l);
          _changed = true;
        });
      }
      say(l.status == 'moderation' ? tr('Тексеруге жіберілді') : tr('Сатылымға шықты'));
    }

    try {
      went(await api.publishListing(_l.id));
    } catch (e) {
      if (e is ApiException && (e.passing || e.code == 'invalid_status')) {
        try {
          final l = await api.listing(_l.id);
          if (l.status == 'published' || l.status == 'moderation') return went(l);
        } catch (_) {} // still no answer: the first error is what is told
      }
      say(e is ApiException
          // «This size is out of stock» says nothing to a seller with no pair left on the listing.
          ? (e.code == 'out_of_stock' ? tr('Сату үшін алдымен жұп қосыңыз.') : e.message)
          : unexpectedText);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locked = _locked(_l);
    final publishable = const {'draft', 'paused', 'rejected'}.contains(_l.status);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(tr('Тауарды басқару'))),
        body: Form(
          key: _form,
          child: ListView(
              controller: _scroll,
              padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 8, 20, 120)),
              children: [
                Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: 72,
                      height: 72,
                      color: Brand.studio,
                      child: _l.coverUrl == null
                          ? const Icon(Icons.image_outlined)
                          : Image(
                              image: netImage(_l.coverUrl!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_l.title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      _StatusPill(status: _l.status),
                    ]),
                  ),
                ]),
                if (_restored && _dirty && !locked) ...[
                  const SizedBox(height: 16),
                  _EditsBackNote(skipped: _skipped > 0, onDrop: _dropRestored),
                ],
                if (locked) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(tr('Тауарды модератор жасырды. Өзгерту үшін қолдау қызметіне жазыңыз.')),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const SupportTile(), // the way there, not only the words
                ],
                if (_l.status == 'moderation' || _l.status == 'rejected') ...[
                  const SizedBox(height: 16),
                  // Follows the fields as the seller types, so the button goes once the words no longer hold what was found.
                  ListenableBuilder(
                    listenable: Listenable.merge(_checkedWords),
                    builder: (context, _) => ModerationCard(
                        listing: _l,
                        onRemoveContacts: _canRemoveContacts ? _removeContacts : null,
                        contactsGone: _contactsGone),
                  ),
                ],
                if (_l.photosPending && !(_photosReady && _photosReadyFor == _l.photosVersion) && !locked) ...[
                  const SizedBox(height: 16),
                  PhotosPendingCard(
                    listing: _l,
                    // Only the card goes: the listing on screen is kept, so stock the seller is changing is still
                    // compared with the counts they saw (a fresh copy would hide a pair sold meanwhile).
                    onReady: () {
                      setState(() {
                        _photosReady = true;
                        _photosReadyFor = _l.photosVersion;
                        _changed = true;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Фотолар дайын'))));
                    },
                  ),
                ],
                if (_l.stats != null) ...[
                  const SizedBox(height: 20),
                  _StatsRow(stats: _l.stats!),
                ],
                // What a seller comes back for most, price and stock, comes first; the rest waits below.
                const SizedBox(height: 24),
                Text(tr('Баға'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: TextFormField(
                      key: const Key('price'),
                      controller: _price,
                      enabled: !locked,
                      keyboardType: TextInputType.number,
                      inputFormatters: tengeInput,
                      decoration: InputDecoration(labelText: tr('Бағасы'), suffixText: '₸', errorMaxLines: 3),
                      validator: tengeCheck,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _delivery,
                      enabled: !locked,
                      keyboardType: TextInputType.number,
                      inputFormatters: tengeInput,
                      // Emptied, it asks again rather than turning into free delivery unseen.
                      decoration: InputDecoration(
                          labelText: tr('Жеткізу'),
                          suffixText: '₸',
                          helperText: tr('Тегін болса, 0'),
                          helperMaxLines: 3,
                          errorMaxLines: 3),
                      validator: (v) => tengeCheck(v, free: true),
                    ),
                  ),
                ]),
                const SizedBox(height: 24),
                Text(tr('Қалдық'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                for (final s in _l.sizes)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(s.label),
                    subtitle: Text(trf('{0} см', [s.insoleCm])),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton.outlined(
                        tooltip: tr('Азайту'),
                        icon: const Icon(Icons.remove),
                        onPressed: locked || (_stock[s.id] ?? 0) == 0
                            ? null
                            : () => setState(() => _stock[s.id] = _stock[s.id]! - 1),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text('${_stock[s.id]}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontVariations: [FontVariation('wght', 700)])),
                      ),
                      IconButton.outlined(
                        tooltip: tr('Көбейту'),
                        icon: const Icon(Icons.add),
                        onPressed: locked ? null : () => setState(() => _stock[s.id] = (_stock[s.id] ?? 0) + 1),
                      ),
                    ]),
                  ),
                // Buyers waiting for an answer are part of coming back too.
                if (_l.status == 'published' || _l.status == 'sold') ...[
                  const SizedBox(height: 8),
                  // How many wait for an answer, so a seller sees there is something to do without opening it.
                  _QuestionsRow(listingId: _l.id),
                ],
                const SizedBox(height: 16),
                TextFormField(
                  controller: _description,
                  enabled: !locked,
                  maxLines: 4,
                  decoration: InputDecoration(labelText: tr('Сипаттамасы')),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _defects,
                  enabled: !locked,
                  maxLines: 3,
                  decoration: InputDecoration(labelText: tr('Ақаулары')),
                ),
                if (!locked) ...[
                  const SizedBox(height: 24),
                  ListingNameFields(
                    listing: _l,
                    title: _title,
                    brand: _brand,
                    model: _model,
                    color: _color,
                    category: _category,
                    audience: _audience,
                    condition: _condition,
                    onCategory: (v) => setState(() => _category = v),
                    onAudience: (v) => setState(() => _audience = v),
                    onCondition: (v) => setState(() => _condition = v),
                  ),
                  FactsFields(
                    category: _category,
                    facts: _facts,
                    fixed: _l.everOnSale ? _l.facts.keys.toSet() : const {},
                    onChanged: (f) => setState(() => _facts = f),
                  ),
                  const SizedBox(height: 24),
                  ListingContentsCard(
                    key: _photos,
                    listing: _l,
                    showNoShoe: widget.showPhotos,
                    onChanged: (l) => setState(() {
                      _take(l);
                      _changed = true;
                    }),
                  ),
                ],
                if (!locked) ...[
                  const SizedBox(height: 32),
                  QualityCard(quality: listingQuality(_l)),
                ],
                if (!locked) ...[
                  const SizedBox(height: 16),
                  AuthenticityCard(listingId: _l.id, onChanged: () => _changed = true),
                ],
                if (!locked) ...[
                  const SizedBox(height: 16),
                  PromoCard(
                    listing: _l,
                    onChanged: (l) => setState(() {
                      _take(l);
                      _changed = true;
                    }),
                  ),
                ],
                // In words, not as two bare icons in the bar; at the end, as what the seller comes back for stays on top.
                const SizedBox(height: 16),
                Wrap(spacing: 4, runSpacing: 4, children: [
                  TextButton.icon(
                    key: const Key('preview'),
                    icon: const Icon(Icons.visibility_outlined, size: 20),
                    label: Text(tr('Сатып алушы көретіндей ашу')),
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListingScreen(listingId: _l.id))),
                  ),
                  TextButton.icon(
                    key: const Key('duplicate'),
                    icon: const Icon(Icons.content_copy_rounded, size: 20),
                    label: Text(tr('Ұқсас тауар қосу')),
                    onPressed: () async {
                      final created = await Navigator.of(context)
                          .push<bool>(MaterialPageRoute(builder: (_) => ListingEditorScreen(template: _l)));
                      if (created == true) _changed = true; // the seller's list reloads on the way back
                    },
                  ),
                ]),
                // Only a draft no buyer ever saw: anything once on sale keeps its history and is paused instead.
                if (_l.status == 'draft' && !_l.everOnSale) ...[
                  const SizedBox(height: 16),
                  Center(
                    child: TextButton.icon(
                      key: const Key('delete-draft'),
                      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                      onPressed: _busy ? null : _deleteDraft,
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: Text(tr('Жобаны өшіру')),
                    ),
                  ),
                ],
              ]),
        ),
        bottomNavigationBar: locked
            ? null
            : SafeArea(
                child: Padding(
                  padding: contentPadding(context, const EdgeInsets.fromLTRB(20, 8, 20, 12)),
                  child: Row(children: [
                    if (_l.status == 'published' || _l.status == 'moderation' && (_l.moderation?.goesOnSale ?? false))
                      Expanded(
                        child: OutlinedButton(
                          key: const Key('pause'),
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  (api) => api.pauseListing(_l.id),
                                  // Held for review: the pause is kept for when the review ends.
                                  _l.status == 'moderation'
                                      ? tr('Тоқтатылды. Тексеруден өткен соң, сатылымға өзіңіз шығарасыз.')
                                      : tr('Сатылым тоқтатылды')),
                          child: Text(tr('Тоқтату')),
                        ),
                      ),
                    // Not yet on sale: putting it on sale is the main step (it saves the edits first), so it is the
                    // filled button and «Save» the quiet one; on sale, saving is.
                    if (publishable)
                      Expanded(
                        child: FilledButton(
                          key: const Key('publish'),
                          onPressed: _busy ? null : _publish,
                          child: Text(_l.status == 'rejected' ? tr('Қайта жіберу') : tr('Сатылымға шығару')),
                        ),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: publishable
                          ? OutlinedButton(
                              key: const Key('save'), onPressed: _busy ? null : _save, child: Text(tr('Сақтау')))
                          : FilledButton(
                              key: const Key('save'), onPressed: _busy ? null : _save, child: Text(tr('Сақтау'))),
                    ),
                  ]),
                ),
              ),
      ),
    );
  }
}

/// Where the seller proves the pair is genuine: receipt, box label or tag photos that only staff see.
class AuthenticityCard extends StatefulWidget {
  const AuthenticityCard({super.key, required this.listingId, this.onChanged});
  final int listingId;
  final VoidCallback? onChanged;

  @override
  State<AuthenticityCard> createState() => _AuthenticityCardState();
}

class _AuthenticityCardState extends State<AuthenticityCard> with WidgetsBindingObserver {
  Proofs? _p;
  Object? _error;
  bool _retrying = false;
  DateTime? _loadedAt;
  bool _busy = false;

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
    if (_p == null) _load();
  }

  // Links to the receipts stop working an hour after they are given: back in the app after that, fetch new ones.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _loadedAt != null &&
        clock.now().difference(_loadedAt!) > const Duration(minutes: 50)) {
      _load();
    }
  }

  Future<void> _load() async {
    if (_error != null) setState(() => _retrying = true);
    try {
      final p = await SessionScope.of(context).api.proofs(widget.listingId);
      if (mounted) {
        setState(() {
          _p = p;
          _error = null;
          _loadedAt = clock.now();
        });
      }
    } catch (e) {
      // The rest of the page works without the card; a line says it did not load, so the seller can try again. A
      // refusal (not this seller's, not found) hides it.
      if (mounted && _p == null) setState(() => _error = e is ApiException && e.passing ? e : null);
    } finally {
      if (mounted && _retrying) setState(() => _retrying = false);
    }
  }

  Future<void> _run(Future<Proofs> Function(Api api) action) async {
    setState(() => _busy = true);
    try {
      final p = await action(SessionScope.of(context).api);
      if (!mounted) return;
      setState(() {
        _p = p;
        _loadedAt = clock.now();
      });
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final file = await pickPhoto(context, title: tr('Чек, қорап жапсырмасы не бирка'));
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    await _run((api) => api.addProof(widget.listingId, bytes, file.name));
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) {
      return _error == null
          ? const SizedBox.shrink()
          : Card(child: RetryLine(what: tr('Түпнұсқалығын дәлелдеу'), error: _error, busy: _retrying, onRetry: _load));
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = p.authenticity == 'documented' || p.authenticity == 'verified';
    final status = switch (p.authenticity) {
      'seller_evidence' => tr('Дәлел жіберілді, қызметкер тексереді.'),
      'documented' ||
      'verified' =>
        trf('Тексерілді: тауарда «{0}» белгісі тұр.', [label(authenticity, p.authenticity)]),
      _ => tr('Чек, қорап жапсырмасы не бирка фотосын қосыңыз. Тексерілген тауарға сенім көбірек.'),
    };
    return Card(
      key: const Key('authenticity-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(done ? Icons.verified_rounded : Icons.verified_outlined,
                color: done ? const Color(0xFF2E9E6A) : scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(child: Text(tr('Түпнұсқалығын дәлелдеу'), style: theme.textTheme.titleSmall)),
          ]),
          const SizedBox(height: 8),
          Text(status, style: theme.textTheme.bodyMedium),
          if (p.note != null) ...[
            const SizedBox(height: 8),
            Text(trf('Қызметкер: {0}', [p.note]), style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final item in p.items)
              Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image(
                      image: ResizeImage.resizeIfNeeded(216, null, netImage(item.url, keep: false)),
                      width: 72,
                      height: 72,
                      gaplessPlayback: true,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(width: 72, height: 72, color: Brand.studio)),
                ),
                if (!done)
                  // 48 by 48 to tap and named for screen readers; the mark itself stays small in the corner.
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton(
                      tooltip: tr('Фотоны өшіру'),
                      alignment: Alignment.topRight,
                      padding: const EdgeInsets.all(2),
                      onPressed: _busy ? null : () => _run((api) => api.deleteProof(widget.listingId, item.id)),
                      icon: const CircleAvatar(radius: 11, child: Icon(Icons.close, size: 14)),
                    ),
                  ),
              ]),
            if (!done && p.items.length < 4)
              SizedBox(
                width: 72,
                height: 72,
                child: OutlinedButton(
                  key: const Key('add-proof'),
                  style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  onPressed: _busy ? null : _add,
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add_a_photo_outlined),
                ),
              ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.lock_outline_rounded, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(tr('Бұл фотоларды сатып алушылар көрмейді, тек VITRINA қызметкері.'),
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Tells the seller why a listing is waiting for staff, or why staff sent it back and what to fix.
class ModerationCard extends StatelessWidget {
  const ModerationCard({super.key, required this.listing, this.onRemoveContacts, this.contactsGone = false});
  final Listing listing;

  /// Takes what the check found out of the fields on the page, when they hold it; nothing is saved.
  final VoidCallback? onRemoveContacts;

  /// The fields on the page no longer hold a contact: what was found is not asked for again, only the next step.
  final bool contactsGone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rejected = listing.status == 'rejected';
    final m = listing.moderation;
    final reasons = m?.reasons(appLanguage.value) ?? const <String>[];
    final found = (m?.found ?? '').isNotEmpty && !contactsGone;
    // Only a hold for contacts alone ends on the seller's Save (the server's SELF_FIXABLE); others wait for staff.
    final ownFix = !rejected && (m?.flags ?? const []).every((f) => f == 'contacts');
    return Card(
      key: const Key('moderation-card'),
      color: rejected ? theme.colorScheme.errorContainer : theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(rejected ? Icons.reply_rounded : Icons.hourglass_top_rounded, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(rejected ? tr('Тауар қайтарылды') : tr('Тауар тексерілуде'),
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700, fontVariations: const [FontVariation('wght', 700)])),
            ),
          ]),
          const SizedBox(height: 8),
          if (rejected && (m?.note ?? '').isNotEmpty) ...[
            Text(trf('Қызметкердің жазбасы: {0}', [m!.note!])),
            const SizedBox(height: 8),
          ],
          for (final r in reasons)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('•  '),
                Expanded(child: Text(r)),
              ]),
            ),
          if (found)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(takeOutLine(m!.found!),
                  key: const Key('moderation-found'),
                  style: TextStyle(fontWeight: FontWeight.w700, fontVariations: const [FontVariation('wght', 700)])),
            ),
          if (onRemoveContacts != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: FilledButton.tonalIcon(
                key: const Key('moderation-remove-contacts'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.backspace_outlined),
                label: Text(tr('Мәтіннен алып тастау')),
                onPressed: onRemoveContacts,
              ),
            ),
          const SizedBox(height: 4),
          Text(
            contactsGone
                ? tr(rejected
                    ? 'Байланыс алынды. Енді «Қайта жіберу» басыңыз.'
                    : 'Байланыс алынды. Енді «Сақтау» басыңыз.')
                : rejected
                    ? tr('Сипаттаманы түзетіп, «Қайта жіберу» басыңыз.')
                    : found && ownFix
                        // A listing held for contacts alone leaves the queue on Save (release_if_fixed).
                        ? tr('Мәтіннен алып тастап, «Сақтау» басыңыз. Сонда тексеру бірден аяқталады.')
                        : tr('Қызметкер қарап шыққанша сатып алушылар көрмейді. Нәтижесі хабарландыруда келеді.'),
            key: const Key('moderation-next'),
            style: theme.textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

/// Makes and hands out the 8-second promo video: the seller's 360° photos, the price and music,
/// sized for Instagram, TikTok and WhatsApp statuses.
/// Says the photos just given are still being prepared, and looks again now and then so it goes away by itself
/// once they are ready.
class PhotosPendingCard extends StatefulWidget {
  const PhotosPendingCard(
      {super.key, required this.listing, required this.onReady, this.pollEvery = const Duration(seconds: 20)});
  final Listing listing;
  final VoidCallback onReady;
  final Duration pollEvery;

  @override
  State<PhotosPendingCard> createState() => _PhotosPendingCardState();
}

class _PhotosPendingCardState extends State<PhotosPendingCard> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _schedule() {
    _poll?.cancel();
    _poll = Timer(widget.pollEvery, () async {
      try {
        final l = await SessionScope.of(context).api.listing(widget.listing.id);
        if (!mounted) return;
        if (l.photosPending) {
          _schedule();
        } else {
          widget.onReady();
        }
      } catch (_) {
        if (mounted) _schedule();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('photos-pending'),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_fix_high_rounded, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(tr('Фотолар өңделуде'),
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700, fontVariations: const [FontVariation('wght', 700)])),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
              tr('Фотолардың фоны алынып жатыр, бұл біраз уақыт алуы мүмкін. Оған дейін сатып алушылар фотоларды түсірілген күйінде көреді.'),
              style: theme.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class PromoCard extends StatefulWidget {
  const PromoCard(
      {super.key, required this.listing, required this.onChanged, this.pollEvery = const Duration(seconds: 2)});
  final Listing listing;
  final ValueChanged<Listing> onChanged;
  final Duration pollEvery;

  @override
  State<PromoCard> createState() => _PromoCardState();
}

class _PromoCardState extends State<PromoCard> {
  Timer? _poll;
  bool _starting = false;
  int _asked = 0; // checks since the video began; each waits a little longer, and after 40 the card stops asking
  bool get _gaveUp => _asked >= 40;

  String? get _state => widget.listing.promo?.state;

  @override
  void initState() {
    super.initState();
    if (_state == 'rendering') _schedule();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  // On a weak line the asking slows down (up to 8 waits apart) and stops, leaving «Қайта көру», not a bar for ever.
  void _schedule() {
    _poll?.cancel();
    if (_gaveUp) {
      if (mounted) setState(() {});
      return;
    }
    _poll = Timer(widget.pollEvery * min(1 + _asked ~/ 5, 8), () async {
      _asked++;
      try {
        final l = await SessionScope.of(context).api.listing(widget.listing.id);
        if (!mounted) return;
        widget.onChanged(l);
        if (l.promo?.state == 'rendering') _schedule();
      } catch (_) {
        if (mounted) _schedule();
      }
    });
  }

  void _askAgain() {
    setState(() => _asked = 0);
    _schedule();
  }

  Future<void> _make() async {
    setState(() {
      _starting = true;
      _asked = 0; // a new video is checked from the start
    });
    try {
      final l = await SessionScope.of(context).api.makePromo(widget.listing.id, appLanguage.value);
      if (!mounted) return;
      widget.onChanged(l);
      _schedule();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = widget.listing.promo?.url;
    final rendering = _state == 'rendering' || _starting;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Brand.ink,
        borderRadius: BorderRadius.circular(Brand.radius),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.movie_creation_outlined, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Text(tr('Жарнама видео'),
                style: weight(theme.textTheme.titleMedium!, 700).copyWith(color: Colors.white)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(
          switch (_state) {
            'ready' => tr('Дайын. Видеоны ашып, телефонға сақтаңыз немесе сілтемесін жіберіңіз.'),
            'failed' => tr('Видео жасалмады. Қайта көріңіз.'),
            _ when rendering => tr('Видео жасалуда, бұл бірнеше секунд алады…'),
            _ => tr('8 секундтық тік видео: фотолар, баға және музыка. Instagram, TikTok және WhatsApp үшін.'),
          },
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
        ),
        const SizedBox(height: 12),
        if (rendering && _gaveUp && !_starting)
          OutlinedButton(
            key: const Key('promo-ask-again'),
            style:
                OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54)),
            onPressed: _askAgain,
            child: Text(tr('Қайта көру')),
          )
        else if (rendering)
          const LinearProgressIndicator(color: Brand.accent, backgroundColor: Colors.white24)
        else if (_state == 'ready' && url != null)
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              key: const Key('open-promo'),
              style: FilledButton.styleFrom(backgroundColor: Brand.accentStrong, foregroundColor: Colors.white),
              onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(tr('Ашу')),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Сілтеме көшірілді'))));
                }
              },
              icon: const Icon(Icons.link_rounded),
              label: Text(tr('Сілтемені көшіру')),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              onPressed: _make,
              child: Text(tr('Қайта жасау')),
            ),
          ])
        else
          FilledButton.icon(
            key: const Key('make-promo'),
            style: FilledButton.styleFrom(backgroundColor: Brand.accentStrong, foregroundColor: Colors.white),
            onPressed: _make,
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(tr('Видео жасау')),
          ),
      ]),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.stats});
  final ListingStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(IconData icon, int value, String label) => Expanded(
          child: Column(children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 4),
            Text('$value', style: weight(theme.textTheme.titleMedium!, 700)),
            Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(Brand.radius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(children: [
        cell(Icons.visibility_outlined, stats.views, tr('қаралым')),
        cell(Icons.favorite_border_rounded, stats.favorites, tr('таңдаулы')),
        cell(Icons.chat_bubble_outline_rounded, stats.chats, tr('чат')),
        cell(Icons.shopping_bag_outlined, stats.orders, tr('тапсырыс')),
      ]),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final live = status == 'published';
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: live ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(tr(listingStatuses[status] ?? status),
            style: TextStyle(
                color: live ? scheme.onPrimary : scheme.onSurface,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontVariations: const [FontVariation('wght', 600)])),
      ),
    );
  }
}

/// One-line stock summary for list rows, e.g. "3 дана".
String stockSummary(Listing l) {
  final total = l.sizes.fold<int>(0, (n, s) => n + (s.quantity ?? 0));
  final views = l.stats == null ? '' : trf(' · {0} қаралым', [l.stats!.views]);
  return trf('{0} дана · {1}{2}', [total, formatTenge(l.priceTiyn), views]);
}

/// The page's completeness score and the few things that would raise it most.
class QualityCard extends StatelessWidget {
  const QualityCard({super.key, required this.quality});
  final ListingQuality quality;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final q = quality;
    final light = theme.brightness == Brightness.light;
    final color = q.score >= 85
        ? const Color(0xFF2E9E6A)
        : q.score >= 60
            ? Brand.accent
            : scheme.error;
    // The verdict is small text, so it takes a deeper shade of the bar's colour where the card is white.
    final verdictColor = q.score >= 85
        ? (light ? const Color(0xFF1F7A50) : color)
        : q.score >= 60
            ? accentText(context)
            : color;
    return Card(
      key: const Key('listing-quality'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(tr('Тауар бетінің толықтығы'), style: theme.textTheme.titleSmall)),
            Text('${q.score}/100', key: const Key('quality-score'), style: weight(theme.textTheme.titleMedium!, 750)),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: q.score / 100,
              minHeight: 8,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 8),
          Text(q.verdict,
              style: theme.textTheme.labelMedium?.copyWith(
                  color: verdictColor,
                  fontWeight: FontWeight.w700,
                  fontVariations: const [FontVariation('wght', 700)])),
          for (final t in q.tips.take(3)) ...[
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.add_circle_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(t.text, style: theme.textTheme.bodyMedium)),
              const SizedBox(width: 8),
              Text('+${t.points}', style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// Changes not saved last time were put back on the page. One calm line, and a way to start from what is saved.
class _EditsBackNote extends StatelessWidget {
  const _EditsBackNote({required this.skipped, required this.onDrop});

  /// Some kept changes were not put back, as their value changed meanwhile.
  final bool skipped;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('edits-back'),
      color: theme.colorScheme.secondaryContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 8, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.history_rounded, size: 20),
            const SizedBox(width: 10),
            Expanded(
                child: Semantics(
                    liveRegion: true, // put back a moment after the page opens: said, not just shown
                    child: Text([
                      tr('Өткен жолы сақталмаған өзгерістеріңізді бетке қайта қойдық. Оларды сақтау үшін «Сақтау» басыңыз.'),
                      if (skipped) tr('Кейбірі қайтарылмады: олар осы уақытта өзгерген.'),
                    ].join(' ')))),
          ]),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
                key: const Key('drop-edits'), onPressed: onDrop, child: Text(tr('Өзгерістерді алып тастау'))),
          ),
        ]),
      ),
    );
  }
}

/// The Q&A row of a listing on sale or sold, with how many buyers' questions wait for the seller's answer. It asks
/// when it comes on the page (also when the listing goes back on sale), on coming back from the Q&A page and when
/// the app comes back from the background while this page is in front.
class _QuestionsRow extends StatefulWidget {
  const _QuestionsRow({required this.listingId});
  final int listingId;

  @override
  State<_QuestionsRow> createState() => _QuestionsRowState();
}

class _QuestionsRowState extends State<_QuestionsRow> with WidgetsBindingObserver {
  int? _waiting; // the last number had; kept when a later ask fails, so a known count never vanishes
  Object? _error; // the last ask failed
  bool _asking = false;
  int _ask = 0; // the latest ask: an older answer coming in late is dropped
  bool _away = false; // the app went to the background (not just a dialog or the notification shade over it)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _count());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) _away = true;
    if (state == AppLifecycleState.resumed && _away) {
      _away = false;
      // A buyer may have asked meanwhile. Under the Q&A page it asks on coming back from it instead.
      if (ModalRoute.of(context)?.isCurrent ?? true) unawaited(_count());
    }
  }

  Future<void> _count() async {
    if (!mounted) return;
    final api = SessionScope.of(context).api;
    final ask = ++_ask;
    setState(() => _asking = true);
    try {
      final n = await api.unansweredQuestions(widget.listingId);
      if (mounted && ask == _ask) {
        setState(() {
          _waiting = n;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && ask == _ask) setState(() => _error = e);
    } finally {
      if (mounted && ask == _ask) setState(() => _asking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _waiting;
    final theme = Theme.of(context);
    // Not had even once: the row still opens the Q&A page, says why the number is missing and asks again on a tap,
    // as every part of the app does. A retry line in its place took the way to the questions away while offline,
    // and with large text on a small phone its button left no room for its words.
    final failed = waiting == null && _error != null;
    final tile = ListTile(
      key: const Key('listing-questions'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.forum_outlined),
      title: Text(tr('Сұрақ-жауап')),
      // Bold when buyers wait: a number on the icon would run into the title with large text.
      subtitle: failed
          ? Text(errorText(_error), key: const Key('questions-unknown'))
          : waiting != null && waiting > 0
              ? Text(trf('Жауапсыз: {0}', [waiting]),
                  key: const Key('questions-waiting'),
                  style: weight(theme.textTheme.bodyMedium!, 700).copyWith(color: theme.colorScheme.onSurface))
              : Text(tr('Сатып алушылардың сұрақтарына жауап беру')),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => QuestionsScreen(listingId: widget.listingId, seller: true)));
        unawaited(_count()); // the seller may have answered some there
      },
    );
    if (!failed) return tile;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      tile,
      Padding(
        key: const Key('listing-questions-retry'),
        padding: const EdgeInsetsDirectional.only(start: 28), // its icon under the row's words
        child: TextButton.icon(
          key: const Key('retry'),
          onPressed: _asking ? null : _count,
          icon: _asking
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh_rounded),
          label: Text(tr('Қайта көру')),
        ),
      ),
    ]);
  }
}
