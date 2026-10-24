import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net_image.dart';
import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/facts_fields.dart';
import '../color_guess.dart';
import '../colors.dart';
import '../i18n.dart';

/// Required angles first; the server refuses to publish with fewer than four photos.
const requiredAngles = {'front': 'Алдынан', 'outer': 'Сырт бүйірі', 'inner': 'Ішкі бүйірі', 'back': 'Өкшесі'};
const optionalAngles = {
  'sole': 'Табаны',
  'top': 'Үстінен',
  'detail': 'Жақыннан (тігіс, логотип)',
  'label': 'Жапсырма, өлшем',
};

/// Close-ups the showcase zooms into; they are uploaded larger so stitching and print stay sharp.
const detailAngles = {'top', 'sole', 'detail', 'label'};
const _defectRequired = {'used_good', 'defective'};
const _resendPhotoText = 'Кейбір фото жүктелмеді. Белгісі бар фотоны басып, қайта жіберіңіз.';
const _retakePhotoText = 'Фото қабылданбады. Белгісі бар фотоны басып, басқасын түсіріңіз.';

class _SizeRow {
  final label = TextEditingController();
  final cm = TextEditingController();
  final qty = TextEditingController(text: '1');

  void dispose() {
    label.dispose();
    cm.dispose();
    qty.dispose();
  }
}

/// Uploads run as soon as a photo is picked, so the final save only sends URLs. The photo is kept, so one that
/// did not go is sent again with a tap, never taken again.
class _Upload {
  _Upload(this.send, {this.path});
  final Future<String> Function() send;

  /// Where the photo lies on the phone, so work kept after the app closed can send it again.
  final String? path;
  late Future<String> future;
  String? url;
  Object? error;

  /// Replaced by another photo, or the page was left: if still waiting its turn, it is not sent at all.
  bool cancelled = false;

  /// A failure that may pass (no connection, the server's trouble) is sent again; a refusal (too large, not a
  /// photo) needs another photo.
  bool get canResend => error is ApiException && (error! as ApiException).passing;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Sends a few photos at a time: many at once choke weak mobile data, so the rest wait their turn.
class _Pool {
  _Pool(this.size);
  final int size;
  var _running = 0;
  final _waiting = <Completer<void>>[];

  /// [first] puts the job ahead of those waiting: the photo just taken goes before older ones still queued.
  Future<T> run<T>(Future<T> Function() job, {bool first = false}) async {
    if (_running < size) {
      _running++;
    } else {
      final turn = Completer<void>();
      first ? _waiting.insert(0, turn) : _waiting.add(turn);
      await turn.future;
    }
    try {
      return await job();
    } finally {
      // The place goes straight to the next in line, so no newcomer slips in between.
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _running--;
      }
    }
  }
}

class ListingEditorScreen extends StatefulWidget {
  const ListingEditorScreen({super.key, this.template});

  /// A listing to start from: same model in another colour, say. Its photos are never copied.
  final Listing? template;

  @override
  State<ListingEditorScreen> createState() => _ListingEditorScreenState();
}

class _ListingEditorScreenState extends State<ListingEditorScreen> with WidgetsBindingObserver {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _brand = TextEditingController();
  final _color = TextEditingController();
  final _defects = TextEditingController();
  final _description = TextEditingController();
  final _price = TextEditingController();
  final _delivery = TextEditingController(text: '0');
  String? _category; // chosen, or filled in from a photo: a default would file boots as sneakers
  String _condition = 'new_with_box';
  String? _audience; // asked, never assumed: a men's default would hide a women's pair from women
  Map<String, String> _facts = {}; // picked, each optional
  String _style = 'clean';
  final _sizes = [_SizeRow()];
  final Map<String, _Upload> _photos = {};
  final List<_Upload> _defectPhotos = [];
  bool _saving = false;
  int _step = 0; // photos, then the pair, then price and sizes
  final _picker = ImagePicker();
  final _pool = _Pool(3);
  Suggestion? _suggestion;
  bool _suggestAsked = false;

  /// The colour the outer side photo (or, until there is one, the front) suggests, asked as one question in the
  /// next step; [_guessAngle] is the photo it came from, [_guessRun] keeps a slow, older guess from landing last.
  String? _colorGuess;
  String? _guessAngle;
  int _guessRun = 0;

  /// The guess the seller already answered, yes or no: not asked again, on coming back to the step either.
  String? _colorAnswered;
  String? _modelName;
  late final String _initial; // what the form held on opening
  Timer? _keepTimer;
  bool _restored = false; // work from before was put back: say so, with a way to start over
  bool _finished = false; // saved or thrown away: nothing more to keep
  Session? _session; // held, as the page is still kept while it is being closed

  /// One per pair, kept with the work: every try at saving it, after a restart too, makes one listing at most.
  String _saveKey = newIdempotencyKey();

  Api get _api => SessionScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _prefill();
    _initial = _snapshot();
    WidgetsBinding.instance.addObserver(this);
    if (widget.template == null) _restore();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session = SessionScope.maybeOf(context);
  }

  /// Every change is kept on the phone a moment later, so a closed app or a dead battery loses nothing.
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (_finished || !_keeps) return;
    _keepTimer?.cancel();
    _keepTimer = Timer(const Duration(seconds: 1), _keep);
  }

  /// Only a new pair is kept: a copy of another listing loses nothing that the listing itself does not hold, and
  /// must never replace or wipe a new pair kept from before.
  bool get _keeps => widget.template == null;

  /// Android may close an app in the background at any moment: what is on the page is kept right away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _keep();
  }

  Future<void> _keep() async {
    _keepTimer?.cancel();
    if (_finished || !_keeps) return;
    final draft = _dirty ? jsonEncode(_draft()) : null; // back to a blank page: nothing to offer next time
    try {
      final prefs = await SharedPreferences.getInstance();
      await (draft == null ? prefs.remove(Session.editorDraftKey) : prefs.setString(Session.editorDraftKey, draft));
    } catch (_) {
      // Nowhere to keep it (a test, a full phone): the page still works, only an app closed now loses the work.
    }
  }

  Future<void> _forget() async {
    _finished = true;
    _keepTimer?.cancel();
    if (!_keeps) return;
    try {
      await (await SharedPreferences.getInstance()).remove(Session.editorDraftKey);
    } catch (_) {}
  }

  Map<String, Object?> _draft() => {
        'owner': _session?.me?.id,
        'save_key': _saveKey,
        'kept_at': DateTime.now().millisecondsSinceEpoch,
        'step': _step,
        for (final (k, c) in _fields) k: c.text,
        'category': _category,
        'condition': _condition,
        'audience': _audience,
        'facts': _facts,
        'style': _style,
        'model': _modelName,
        'sizes': [
          for (final r in _sizes) [r.label.text, r.cm.text, r.qty.text]
        ],
        'photos': {for (final e in _photos.entries) e.key: _kept(e.value)},
        'defect_photos': [for (final d in _defectPhotos) _kept(d)],
      };

  List<(String, TextEditingController)> get _fields => [
        ('title', _title),
        ('brand', _brand),
        ('color', _color),
        ('defects', _defects),
        ('description', _description),
        ('price', _price),
        ('delivery', _delivery),
      ];

  /// A photo is kept by its address once it went, and by its file on the phone, to be sent again if needed.
  Map<String, String> _kept(_Upload u) => {
        if (u.url != null) 'url': u.url!,
        if (u.path != null) 'path': u.path!,
      };

  /// The server clears photos no listing uses after a week (backend orphans.py); a day sooner, a kept address is
  /// no longer trusted and the photo is sent again from the phone.
  static const _keptUrlsLast = Duration(days: 6);

  Future<void> _restore() async {
    String? raw;
    try {
      raw = (await SharedPreferences.getInstance()).getString(Session.editorDraftKey);
    } catch (_) {
      return;
    }
    if (raw == null || !mounted || _dirty) return; // the seller already began something new: that wins
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      final me = _session?.me?.id;
      if (d['owner'] != null && me != null && d['owner'] != me) {
        unawaited(_forget()); // another person's work, on a shared phone
        _finished = false;
        return;
      }
      setState(() {
        _apply(d);
        _restored = true;
      });
    } catch (_) {
      unawaited(_forget()); // kept by an older version and no longer readable
      _finished = false;
      setState(() => _apply({})); // not half of it: a clean page
    }
  }

  /// Puts kept work on the page; an empty map gives a blank page, for starting over.
  void _apply(Map<String, dynamic> d) {
    _cancel([..._photos.values, ..._defectPhotos]);
    for (final (k, c) in _fields) {
      c.text = d[k] as String? ?? (k == 'delivery' ? '0' : '');
    }
    _category = d['category'] as String?;
    _condition = d['condition'] as String? ?? 'new_with_box';
    _audience = d['audience'] as String?;
    _facts = {
      for (final MapEntry(:key, :value) in ((d['facts'] as Map?) ?? const {}).entries)
        if (key is String && value is String) key: value
    };
    _style = d['style'] as String? ?? 'clean';
    _modelName = d['model'] as String?;
    _suggestAsked = _brand.text.isNotEmpty;
    _suggestion = null;
    _colorGuess = _guessAngle = _colorAnswered = null;
    _guessRun++;
    final keptAt = DateTime.fromMillisecondsSinceEpoch(d['kept_at'] as int? ?? 0);
    final fresh = DateTime.now().difference(keptAt) < _keptUrlsLast;
    final sizes = [
      for (final r in (d['sizes'] as List? ??
              [
                const ['', '', '1']
              ])
          .cast<List>())
        (r[0] as String, r[1] as String, r[2] as String),
    ];
    final old = [..._sizes]; // still held by the fields on screen until the next frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final r in old) {
        r.dispose();
      }
    });
    _sizes
      ..clear()
      ..addAll([
        for (final (label, cm, qty) in sizes)
          _SizeRow()
            ..label.text = label
            ..cm.text = cm
            ..qty.text = qty,
      ]);
    _photos
      ..clear()
      ..addAll({
        for (final e in (d['photos'] as Map? ?? {}).entries)
          if (_revive(e.value, fresh, detail: detailAngles.contains(e.key)) case final u?) e.key as String: u,
      });
    _defectPhotos
      ..clear()
      ..addAll([for (final j in d['defect_photos'] as List? ?? []) _revive(j, fresh)].nonNulls);
    // A draft from before the photo-frame 360° was taken out may still hold 'frames': they are left behind unsent.
    // Kept photos: the colour is guessed again while none is set.
    if (_color.text.trim().isEmpty) {
      if (_photos['outer']?.path case final path?) {
        _guessColor(XFile(path), 'outer');
      } else if (_photos['front']?.path case final path?) {
        _guessColor(XFile(path), 'front');
      }
    }
    _step = (d['step'] as int? ?? 0).clamp(0, 2);
    _saveKey = d['save_key'] as String? ?? newIdempotencyKey(); // starting over is another pair
  }

  /// A kept photo: done if it went lately, otherwise sent again from the phone. A file the phone has since
  /// cleared fails to read, and its tile asks for another photo.
  _Upload? _revive(Object? kept, bool fresh, {bool detail = false}) {
    if (kept is! Map) return null;
    final path = kept['path'] as String?;
    if (kept['url'] case final String url when fresh) {
      return _Upload(() async => url, path: path)
        ..url = url
        ..future = Future.value(url);
    }
    if (path != null) return _startUpload(XFile(path), detail: detail);
    return null;
  }

  /// Asks first, as leaving does: one tap must not throw away a whole pair's photos.
  Future<void> _startOver() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Барлығын өшіріп, жаңадан бастау керек пе?')),
        content: Text(tr('Толтырған мәліметтер мен фотолар өшіріледі.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Қалу'))),
          FilledButton(
              key: const Key('start-over-sure'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Өшіру'))),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    unawaited(_forget());
    setState(() {
      _apply({});
      _restored = false;
    });
    _finished = false;
  }

  void _prefill() {
    final t = widget.template;
    if (t == null) return;
    _title.text = t.title;
    _brand.text = t.brand ?? '';
    _modelName = t.modelName;
    _color.text = t.color;
    _description.text = t.description ?? '';
    _price.text = '${t.priceTiyn ~/ 100}';
    _delivery.text = '${t.deliveryPriceTiyn ~/ 100}';
    _category = t.category;
    _audience = t.audience;
    _facts = {...t.facts}; // the same shoe in another colour is made of the same
    _style = t.showcaseStyle;
    if (t.condition != 'defective') _condition = t.condition; // a defect belongs to one pair, with its own photos
    _suggestAsked = true; // brand and model are known already
    if (t.sizes.isNotEmpty) {
      _sizes.first.dispose();
      _sizes
        ..clear()
        ..addAll([
          for (final s in t.sizes)
            _SizeRow()
              ..label.text = s.label
              ..cm.text = s.insoleCm
              ..qty.text = '${(s.quantity ?? 0) > 0 ? s.quantity : 1}',
        ]);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keep(); // the last change, before the timer would have kept it
    _cancel([..._photos.values, ..._defectPhotos]); // nothing more is sent for a page that was left
    for (final c in [_title, _brand, _color, _defects, _description, _price, _delivery]) {
      c.dispose();
    }
    for (final s in _sizes) {
      s.dispose();
    }
    super.dispose();
  }

  /// Everything the seller can change, as one string, to tell whether leaving would lose work.
  String _snapshot() => [
        for (final c in [_title, _brand, _color, _defects, _description, _price, _delivery]) c.text.trim(),
        _category,
        _audience,
        for (final e in _facts.entries) '${e.key}=${e.value}',
        _condition,
        _style,
        for (final r in _sizes) '${r.label.text.trim()}|${r.cm.text.trim()}|${r.qty.text.trim()}',
        ..._photos.keys,
        '${_defectPhotos.length}',
      ].join('\u0000');

  bool get _dirty => _snapshot() != _initial;

  /// Back with unsaved work asks first; uploads already made are simply left unused.
  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Сақтамай шығу керек пе?')),
        content: Text(tr('Толтырған мәліметтер мен фотолар жоғалады. Кейін жалғастыру үшін жоба ретінде сақтаңыз.')),
        actions: [
          // Staying keeps the work, so it is the button the eye goes to.
          TextButton(
              key: const Key('discard'), onPressed: () => Navigator.pop(context, true), child: Text(tr('Шығып кету'))),
          FilledButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Қалу'))),
        ],
      ),
    );
    if (leave == true && mounted) {
      unawaited(_forget()); // thrown away on purpose: not offered again next time
      Navigator.pop(context);
    }
  }

  _Upload _startUpload(XFile file, {bool detail = false}) {
    final api = _api;
    late final _Upload u;
    u = _Upload(
        () => _pool.run(() async {
              if (u.cancelled) throw const _Cancelled();
              return api.uploadPhotoPatiently(await file.readAsBytes(), file.name, detail: detail);
            }, first: true),
        path: file.path.isEmpty ? null : file.path);
    return _send(u);
  }

  /// Sends [u], again if it failed before: the tile turns back to waiting, then shows the photo or the failure.
  _Upload _send(_Upload u) {
    u
      ..error = null
      ..future = u.send().then((url) {
        if (mounted) setState(() => u.url = url);
        return url;
      }, onError: (Object e) {
        if (mounted) setState(() => u.error = e);
        throw e;
      });
    u.future.ignore(); // errors are shown on the tile and checked again at save time
    return u;
  }

  void _resend(Iterable<_Upload> uploads) =>
      setState(() => uploads.where((u) => u.error != null).toList().forEach(_send));

  /// A failed side photo: sent again when the failure may pass, otherwise another is taken.
  void _retryAngle(String angle) {
    final u = _photos[angle]!;
    if (!u.canResend) {
      _pickAngle(angle);
      return;
    }
    _resend([u]);
    if (!_suggestAsked && (angle == 'outer' || angle == 'front')) {
      _suggestAsked = true;
      _suggestFrom(u);
    }
  }

  /// A failed defect photo: sent again when the failure may pass, otherwise it goes and another is taken.
  void _retryDefect(_Upload d) {
    if (d.canResend) {
      _resend([d]);
    } else {
      setState(() => _defectPhotos.remove(d));
      _addDefect();
    }
  }

  /// What to say about failed uploads: the server's reason for a refused photo, or to send the rest again.
  void _sayFailed(Iterable<_Upload> uploads, String resendText) {
    final failed = uploads.where((u) => u.error != null).toList();
    final refused = failed.where((u) => !u.canResend).firstOrNull;
    showError(
        context,
        refused?.error is ApiException
            ? refused!.error!
            : ApiException(422, 'photo_failed', tr(refused == null ? resendText : _retakePhotoText)));
  }

  void _cancel(Iterable<_Upload> uploads) {
    for (final u in uploads) {
      u.cancelled = true;
    }
  }

  Future<XFile?> _pick({double side = 2000}) async {
    final source = await showSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(children: [
          ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(tr('Камерамен түсіру')),
              onTap: () => Navigator.pop(context, ImageSource.camera)),
          ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(tr('Галереядан таңдау')),
              onTap: () => Navigator.pop(context, ImageSource.gallery)),
        ]),
      ),
    );
    if (source == null) return null;
    return _picker.pickImage(source: source, maxWidth: side, maxHeight: side, imageQuality: 90);
  }

  Future<void> _pickAngle(String angle) async {
    final detail = detailAngles.contains(angle);
    final file = await _pick(side: detail ? 3000 : 2000);
    if (file == null) return;
    final upload = _startUpload(file, detail: detail);
    _photos[angle]?.cancelled = true;
    setState(() => _photos[angle] = upload);
    _guessColor(file, angle);
    if (!_suggestAsked && (angle == 'outer' || angle == 'front')) {
      _suggestAsked = true;
      _suggestFrom(upload);
    }
  }

  Future<void> _guessColor(XFile file, String angle) async {
    if (angle != 'outer' && (angle != 'front' || _guessAngle == 'outer')) return;
    if (_color.text.trim().isNotEmpty && _color.text != widget.template?.color) return; // the seller chose already
    _guessAngle = angle;
    final run = ++_guessRun;
    String? guess;
    try {
      guess = await guessShoeColor(await file.readAsBytes());
    } catch (_) {} // a photo the phone no longer has: the seller picks the colour from the list
    if (mounted && run == _guessRun) setState(() => _colorGuess = guess);
  }

  /// Offers brand, model and category from look-alikes once the first side photo is uploaded.
  /// Quietly does nothing when photo search is off or nothing on VITRINA looks alike.
  Future<void> _suggestFrom(_Upload upload) async {
    try {
      final s = await _api.suggestDetails(await upload.future);
      if (mounted && !s.isEmpty) setState(() => _suggestion = s);
    } catch (_) {
      _suggestAsked = false; // try again with the next side photo
    }
  }

  void _applySuggestion() {
    final s = _suggestion!;
    setState(() {
      if (s.category != null && categories.containsKey(s.category)) _category = s.category!;
      if (s.brand != null && _brand.text.trim().isEmpty) _brand.text = s.brand!;
      _modelName = s.modelName;
      if (_title.text.trim().isEmpty) {
        _title.text = [s.brand, s.modelName].whereType<String>().join(' ');
      }
      _suggestion = null;
    });
  }

  Future<void> _addDefect() async {
    final file = await _pick();
    if (file != null) setState(() => _defectPhotos.add(_startUpload(file)));
  }

  int? _tiyn(String text) {
    final v = int.tryParse(text.replaceAll(RegExp(r'\s'), ''));
    return v == null ? null : v * 100;
  }

  Future<void> _save({required bool publish}) async {
    if (!_form.currentState!.validate()) return;
    final missing = requiredAngles.keys.where((a) => _photos[a] == null).map((a) => tr(requiredAngles[a]!)).toList();
    if (missing.isNotEmpty) {
      showError(
          context, ApiException(422, 'missing_required_photos', trf('Фото жетіспейді: {0}.', [missing.join(', ')])));
      return;
    }
    if (_condition == 'defective' && _defectPhotos.isEmpty) {
      showError(context, ApiException(422, 'defects_required', tr('Әр ақаудың жақын фотосын қосыңыз.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final photos = <Map<String, String>>[
        for (final e in _photos.entries) {'url': await e.value.future, 'angle': e.key},
        for (final d in _defectPhotos) {'url': await d.future, 'angle': 'defect'},
      ];
      final body = {
        'title': _title.text.trim(),
        'category': _category!,
        if (_audience != null) 'audience': _audience,
        if (factsFor(_category, _facts) case final facts when facts.isNotEmpty) 'facts': facts,
        if (_brand.text.trim().isNotEmpty) 'brand': _brand.text.trim(),
        if (_modelName != null) 'model_name': _modelName,
        'color': _color.text.trim(),
        'condition': _condition,
        if (_defects.text.trim().isNotEmpty) 'defects': _defects.text.trim(),
        if (_description.text.trim().isNotEmpty) 'description': _description.text.trim(),
        'price_tiyn': _tiyn(_price.text),
        'delivery_price_tiyn': _tiyn(_delivery.text) ?? 0,
        'showcase_style': _style,
        'sizes': [
          for (final s in _sizes)
            {'label': s.label.text.trim(), 'insole_cm': s.cm.text.trim(), 'quantity': int.tryParse(s.qty.text) ?? 0},
        ],
        'photos': photos,
      };
      final listing = await _api.createListing(body, idempotencyKey: _saveKey);
      // A try whose answer was lost made this listing already, as it was then: changed since, or already sent on,
      // it is not published from here; the seller finds it in their listings, never a second one.
      final earlier = !_madeAsSent(listing, body);
      final shown = publish && !earlier && listing.status == 'draft' ? await _api.publishListing(listing.id) : listing;
      unawaited(_forget()); // it is on VITRINA now, kept there
      if (!mounted) return;
      // Shown on the screen underneath, and said by what the listing is now, so the seller knows where it went.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(earlier
              ? tr('Бұл тауар бұрын сақталған. Өзгерістерді «Менің тауарларым» бетінде енгізіңіз.')
              : switch (shown.status) {
                  'draft' => tr('Жоба ретінде сақталды'),
                  'moderation' => tr('Тексеруге жіберілді'),
                  'published' => tr('Сатылымға шықты'),
                  _ => tr('Бұл тауар бұрын сақталған. Өзгерістерді «Менің тауарларым» бетінде енгізіңіз.'),
                })));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      // An upload that failed after Next: back to the step that shows it, so it can be taken again.
      final failedStep = _photos.values.any((u) => u.error != null)
          ? 0
          : _defectPhotos.any((d) => d.error != null)
              ? 1
              : null;
      if (failedStep != null) setState(() => _step = failedStep);
      showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Whether the listing the server answered with is what was just sent: not one an earlier try made before the
  /// seller changed something. Photos are compared by side, as their addresses change when sent again.
  bool _madeAsSent(Listing l, Map<String, Object?> body) {
    final sizes = [for (final s in body['sizes']! as List<Map<String, Object>>) '${s['label']}|${s['quantity']}'];
    final angles = [for (final p in body['photos']! as List<Map<String, String>>) p['angle']!]..sort();
    return l.title == body['title'] &&
        l.priceTiyn == body['price_tiyn'] &&
        l.deliveryPriceTiyn == body['delivery_price_tiyn'] &&
        l.condition == body['condition'] &&
        listEquals([for (final s in l.sizes) '${s.label}|${s.quantity}'], sizes) &&
        listEquals([for (final m in l.media) m.angle]..sort(), angles);
  }

  String? _required(String? v) => (v ?? '').trim().isEmpty ? tr('Толтырыңыз') : null;

  String? _titleCheck(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return tr('Толтырыңыз');
    return t.length < 3 ? tr('Атауы кемінде 3 таңбадан тұрсын') : null;
  }

  /// Next from the photos: the four sides are there. Uploads may still be running; save waits for them.
  bool _photosDone() {
    final missing = requiredAngles.keys.where((a) => _photos[a] == null).map((a) => tr(requiredAngles[a]!)).toList();
    if (missing.isNotEmpty) {
      showError(
          context, ApiException(422, 'missing_required_photos', trf('Фото жетіспейді: {0}.', [missing.join(', ')])));
      return false;
    }
    // A failed upload is found now, while its tile is on screen to send again, not at the last step.
    if (_photos.values.any((u) => u.error != null)) {
      _sayFailed(_photos.values, _resendPhotoText);
      return false;
    }
    return true;
  }

  /// Next from the details: every field on the page is filled in, and a defective pair shows its defects.
  bool _detailsDone() {
    if (!_form.currentState!.validate()) return false;
    if (_defectPhotos.any((d) => d.error != null)) {
      _sayFailed(_defectPhotos, _resendPhotoText);
      return false;
    }
    if (_condition == 'defective' && _defectPhotos.isEmpty) {
      showError(context, ApiException(422, 'defects_required', tr('Әр ақаудың жақын фотосын қосыңыз.')));
      return false;
    }
    return true;
  }

  void _next() {
    if (_step == 0 ? _photosDone() : _detailsDone()) {
      FocusScope.of(context).unfocus();
      setState(() {
        _step++;
        _restored = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uploading = [..._photos.values, ..._defectPhotos].where((u) => u.url == null && u.error == null).length;
    return PopScope(
      canPop: _step == 0 && !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_step > 0) {
          setState(() => _step--); // back walks the steps; nothing typed is lost
        } else {
          _confirmLeave();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.template == null ? tr('Жаңа тауар') : tr('Ұқсас тауар'))),
        body: Form(
          key: _form,
          // Typing changes what back does, so the screen rebuilds with each edit.
          onChanged: () => setState(() {}),
          child: ListView(
            key: ValueKey('step-$_step'), // each step opens at its top
            padding: contentPadding(context, const EdgeInsets.all(16)),
            children: [
              if (_restored) _RestoredNote(onStartOver: _startOver),
              _StepHeader(step: _step),
              const SizedBox(height: 20),
              ...switch (_step) {
                0 => _photoStep(theme),
                1 => _detailStep(),
                _ => _priceStep(theme),
              },
              const SizedBox(height: 24),
              if (uploading > 0) Text(trf('Жүктелуде: {0} фото', [uploading]), style: theme.textTheme.bodySmall),
              if (_step < 2)
                FilledButton(key: const Key('next'), onPressed: _next, child: Text(tr('Келесі')))
              else ...[
                FilledButton(
                  onPressed: _saving ? null : () => _save(publish: true),
                  child: Text(_saving ? tr('Сақталуда…') : tr('Жариялау')),
                ),
                TextButton(
                  onPressed: _saving ? null : () => _save(publish: false),
                  child: Text(tr('Жоба ретінде сақтау')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _photoStep(ThemeData theme) => [
        if (widget.template != null)
          Card(
            key: const Key('template-note'),
            color: theme.colorScheme.secondaryContainer,
            margin: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                const Icon(Icons.content_copy_rounded, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(trf('«{0}» мәліметтері көшірілді. Фотоларды осы жұптан жаңадан түсіріңіз.',
                      [widget.template!.title])),
                ),
              ]),
            ),
          ),
        Text(tr('Жарық жерде, біркелкі фонда түсіріңіз. Фото өзгертілмейді, тек метадеректер өшіріледі.'),
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in {...requiredAngles, ...optionalAngles}.entries)
            _PhotoSlot(
              label: tr(e.value),
              required: requiredAngles.containsKey(e.key),
              upload: _photos[e.key],
              onTap: _photos[e.key]?.error != null ? () => _retryAngle(e.key) : () => _pickAngle(e.key),
            ),
        ]),
      ];

  List<Widget> _detailStep() => [
        if (_suggestion != null)
          _SuggestionCard(
              suggestion: _suggestion!, onApply: _applySuggestion, onDismiss: () => setState(() => _suggestion = null)),
        TextFormField(
            controller: _title,
            decoration: InputDecoration(labelText: tr('Атауы')),
            validator: _titleCheck,
            maxLength: 120),
        DropdownButtonFormField<String>(
          key: ValueKey('category-$_category'), // a suggestion can change it from outside
          initialValue: _category,
          isExpanded: true, // long names in large text are cut short instead of running off the screen
          decoration: InputDecoration(labelText: tr('Санаты')),
          items: [for (final e in categories.entries) DropdownMenuItem(value: e.key, child: Text(tr(e.value)))],
          validator: (v) => v == null ? tr('Түрін таңдаңыз') : null,
          onChanged: (v) => setState(() {
            _category = v!;
            _facts = factsFor(v, _facts); // a boot's height does not go with a sneaker
          }),
        ),
        DropdownButtonFormField<String>(
          key: const Key('audience'),
          initialValue: _audience,
          isExpanded: true,
          decoration: InputDecoration(labelText: tr('Кімге арналған')),
          items: [for (final e in audiences.entries) DropdownMenuItem(value: e.key, child: Text(tr(e.value)))],
          validator: (v) => v == null ? tr('Кімге арналғанын таңдаңыз') : null,
          onChanged: (v) => setState(() => _audience = v),
        ),
        TextFormField(controller: _brand, decoration: InputDecoration(labelText: tr('Бренді (міндетті емес)'))),
        ColorField(
          controller: _color,
          // Asked while no colour is set, or while it is still the one copied from the similar pair: another
          // colour of the same shoe is the usual reason to copy one.
          guess: _colorGuess != _colorAnswered && (_color.text.trim().isEmpty || _color.text == widget.template?.color)
              ? _colorGuess
              : null,
          onAnswered: () => _colorAnswered = _colorGuess,
        ),
        DropdownButtonFormField<String>(
          initialValue: _condition,
          isExpanded: true,
          decoration: InputDecoration(labelText: tr('Жағдайы')),
          items: [for (final e in conditions.entries) DropdownMenuItem(value: e.key, child: Text(tr(e.value)))],
          onChanged: (v) => setState(() => _condition = v!),
        ),
        if (_defectRequired.contains(_condition)) ...[
          TextFormField(
            controller: _defects,
            maxLines: 3,
            decoration: InputDecoration(labelText: tr('Ақаулары'), hintText: tr('Не, қай жерде, қандай көлемде')),
            validator: _required,
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final d in _defectPhotos)
              _PhotoSlot(label: tr('Ақау'), upload: d, onTap: d.error != null ? () => _retryDefect(d) : null),
            ActionChip(
                avatar: const Icon(Icons.add_a_photo_outlined, size: 18),
                label: Text(tr('Ақау фотосы')),
                onPressed: _addDefect),
          ]),
        ],
        FactsFields(category: _category, facts: _facts, onChanged: (f) => setState(() => _facts = f)),
        TextFormField(
            controller: _description,
            maxLines: 3,
            decoration: InputDecoration(labelText: tr('Сипаттамасы (міндетті емес)'))),
      ];

  List<Widget> _priceStep(ThemeData theme) => [
        Row(children: [
          Expanded(
            child: TextFormField(
              controller: _price,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('Бағасы'), suffixText: '₸'),
              validator: (v) => (_tiyn(v ?? '') ?? 0) <= 0 ? tr('Бағаны енгізіңіз') : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: _delivery,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('Жеткізу'), suffixText: '₸'),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        Text(tr('Өлшемдер'), style: theme.textTheme.titleMedium),
        // Each size on two lines: in one row of four, «Ұлтарақ, см» and «Саны» were cut off on a usual phone.
        for (final (i, s) in _sizes.indexed) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: TextFormField(
                    controller: s.label, decoration: InputDecoration(labelText: tr('Өлшем')), validator: _required)),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                controller: s.cm,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: tr('Ұлтарақ, см')),
                validator: insoleCheck,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            SizedBox(
              width: 120,
              child: TextFormField(
                  controller: s.qty,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: tr('Саны'))),
            ),
            const Spacer(),
            if (_sizes.length > 1)
              TextButton.icon(
                key: ValueKey('remove-size-$i'),
                onPressed: () => setState(() => _sizes.removeAt(i).dispose()),
                icon: const Icon(Icons.remove_circle_outline),
                label: Text(tr('Өшіру')),
              ),
          ]),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
              onPressed: () => setState(() => _sizes.add(_SizeRow())),
              icon: const Icon(Icons.add),
              label: Text(tr('Өлшем қосу'))),
        ),
        // No "showcase background" to pick any more: the 3D stage and the photos have the app's own light or dark
        // scene, which the buyer switches. The stored style is still sent, for the server and older apps.
      ];
}

/// Where the seller is: one short page at a time, so nothing on it is missed.
class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.step});
  final int step;

  static const titles = ['Фото', 'Тауар туралы', 'Бағасы мен өлшемі'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(trf('{0}-қадам, барлығы {1}', [step + 1, titles.length]), style: theme.textTheme.bodySmall),
        const SizedBox(height: 2),
        // Read out as each step opens, so a screen reader user knows the page changed.
        Semantics(
          header: true,
          liveRegion: true,
          child: Text(tr(titles[step]), key: const Key('step-title'), style: theme.textTheme.titleMedium),
        ),
        const SizedBox(height: 10),
        Row(children: [
          for (var i = 0; i < titles.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  color: i <= step ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ]),
      ]),
    );
  }
}

/// Insole length as sellers type it, 27,5 or 27.5: a number of centimetres a shoe can have.
String? insoleCheck(String? v) {
  final t = (v ?? '').trim();
  if (t.isEmpty) return tr('Толтырыңыз');
  final cm = double.tryParse(t.replaceAll(',', '.'));
  if (cm == null) return tr('Санмен жазыңыз, мысалы 27,5');
  return cm < 8 || cm > 35 ? tr('8–35 см аралығында болуы керек') : null;
}

class _PhotoSlot extends StatelessWidget {
  const _PhotoSlot({required this.label, required this.upload, required this.onTap, this.required = false});
  final String label;
  final _Upload? upload;
  final VoidCallback? onTap;
  final bool required;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final u = upload;
    Widget inner;
    if (u == null) {
      inner = Icon(Icons.add_a_photo_outlined, color: scheme.outline);
    } else if (u.error != null) {
      // Refresh: a tap sends it again; a refused photo is taken anew.
      inner = Icon(u.canResend ? Icons.refresh : Icons.error_outline, color: scheme.error);
    } else if (u.url == null) {
      inner = const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2));
    } else {
      inner = Image(
        image: ResizeImage.resizeIfNeeded(288, null, netImage(u.url!)),
        fit: BoxFit.cover,
        width: 96,
        height: 96,
      );
    }
    return Semantics(
      container: true,
      button: onTap != null,
      label: u?.error != null ? trf('{0} фотосы жүктелмеді', [label]) : trf('{0} фотосы', [label]),
      hint: u?.error == null
          ? null
          : u!.canResend
              ? tr('Қайта жіберу үшін басыңыз')
              : tr('Басқасын түсіру үшін басыңыз'),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(children: [
          Container(
            width: 96,
            height: 96,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: scheme.surfaceContainerHighest,
              border: Border.all(color: required && u == null ? scheme.primary : Colors.transparent),
            ),
            child: Center(child: inner),
          ),
          const SizedBox(height: 4),
          SizedBox(
              width: 96,
              child: Text(label + (required ? ' *' : ''),
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall)),
        ]),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.suggestion, required this.onApply, required this.onDismiss});
  final Suggestion suggestion;
  final VoidCallback onApply;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = suggestion;
    final parts = [
      s.brand,
      s.modelName,
      if (s.category != null) tr(categories[s.category] ?? s.category!),
    ].whereType<String>();
    return Card(
      key: const Key('suggestion'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_awesome_outlined, size: 20, color: Brand.accent),
            const SizedBox(width: 8),
            Expanded(child: Text(tr('Ұқсас тауарларға қарағанда'), style: theme.textTheme.labelLarge)),
          ]),
          const SizedBox(height: 6),
          Text(parts.join(' · '), style: weight(theme.textTheme.titleMedium!, 700)),
          Text(tr('Тексеріп, дұрыс болса ғана қолданыңыз.'),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: onDismiss, child: Text(tr('Жоқ'))),
            FilledButton(key: const Key('apply-suggestion'), onPressed: onApply, child: Text(tr('Қолдану'))),
          ]),
        ]),
      ),
    );
  }
}

/// Work from before was put back on the page. One calm line, and a way to begin a new pair instead.
class _RestoredNote extends StatelessWidget {
  const _RestoredNote({required this.onStartOver});
  final VoidCallback onStartOver;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('restored-note'),
      color: theme.colorScheme.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 8, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.history_rounded, size: 20),
            const SizedBox(width: 10),
            Expanded(
                child: Semantics(
                    liveRegion: true, // put back a moment after the page opens: said, not just shown
                    child: Text(tr('Алдыңғы жұмысыңыз сақталған, тоқтаған жерден жалғастырыңыз.')))),
          ]),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(key: const Key('start-over'), onPressed: onStartOver, child: Text(tr('Жаңадан бастау'))),
          ),
        ]),
      ),
    );
  }
}
