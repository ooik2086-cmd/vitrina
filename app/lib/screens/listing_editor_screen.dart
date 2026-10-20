import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../net_image.dart';
import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/listing_contents.dart' show ShowcaseStopsHint;
import 'spin_capture_screen.dart';
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

/// Uploads run as soon as a photo is picked, so the final save only sends URLs.
class _Upload {
  _Upload(this.future);
  final Future<String> future;
  String? url;
  Object? error;
}

class ListingEditorScreen extends StatefulWidget {
  const ListingEditorScreen({super.key, this.template});

  /// A listing to start from: same model in another colour, say. Its photos are never copied.
  final Listing? template;

  @override
  State<ListingEditorScreen> createState() => _ListingEditorScreenState();
}

class _ListingEditorScreenState extends State<ListingEditorScreen> {
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
  String _style = 'clean';
  final _sizes = [_SizeRow()];
  final Map<String, _Upload> _photos = {};
  final List<_Upload> _defectPhotos = [];
  List<_Upload> _frames = [];
  bool _saving = false;
  int _step = 0; // photos, then the pair, then price and sizes
  final _picker = ImagePicker();
  Suggestion? _suggestion;
  bool _suggestAsked = false;
  String? _modelName;
  late final String _initial; // what the form held on opening

  Api get _api => SessionScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _prefill();
    _initial = _snapshot();
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
        _condition,
        _style,
        for (final r in _sizes) '${r.label.text.trim()}|${r.cm.text.trim()}|${r.qty.text.trim()}',
        ..._photos.keys,
        '${_defectPhotos.length}/${_frames.length}',
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Қалу'))),
          FilledButton(
              key: const Key('discard'), onPressed: () => Navigator.pop(context, true), child: Text(tr('Шығып кету'))),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.pop(context);
  }

  _Upload _startUpload(XFile file, {bool detail = false}) {
    late final _Upload u;
    u = _Upload(file.readAsBytes().then((b) => _api.uploadPhoto(b, file.name, detail: detail)).then((url) {
      if (mounted) setState(() => u.url = url);
      return url;
    }, onError: (Object e) {
      if (mounted) setState(() => u.error = e);
      throw e;
    }));
    u.future.ignore(); // errors are shown on the tile and checked again at save time
    return u;
  }

  Future<XFile?> _pick({double side = 2000}) async {
    final source = await showModalBottomSheet<ImageSource>(
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
    setState(() => _photos[angle] = upload);
    if (!_suggestAsked && (angle == 'outer' || angle == 'front')) {
      _suggestAsked = true;
      _suggestFrom(upload);
    }
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

  Future<void> _captureSpin() async {
    final frames = await Navigator.of(context)
        .push<List<XFile>>(MaterialPageRoute(builder: (_) => const SpinCaptureScreen(), fullscreenDialog: true));
    if (frames != null) setState(() => _frames = [for (final f in frames) _startUpload(f)]);
  }

  Future<void> _pickSpinFromGallery() async {
    final files = await _picker.pickMultiImage(maxWidth: 2000, maxHeight: 2000, imageQuality: 90);
    if (files.isEmpty) return;
    if (files.length < spinMinFrames) {
      if (mounted) {
        showError(
            context, ApiException(422, 'too_few_frames', trf('360° үшін кемінде {0} кадр керек.', [spinMinFrames])));
      }
      return;
    }
    setState(() => _frames = [for (final f in files) _startUpload(f)]);
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
        for (final f in _frames) {'url': await f.future, 'angle': 'frame'},
      ];
      final listing = await _api.createListing({
        'title': _title.text.trim(),
        'category': _category!,
        if (_audience != null) 'audience': _audience,
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
      });
      final shown = publish ? await _api.publishListing(listing.id) : listing;
      if (!mounted) return;
      // Shown on the screen underneath, so the seller knows where the listing went.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(!publish
              ? tr('Жоба ретінде сақталды')
              : shown.status == 'moderation'
                  ? tr('Тексеруге жіберілді')
                  : tr('Сатылымға шықты'))));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      // An upload that failed after Next: back to the step that shows it, so it can be taken again.
      final failedStep = [..._photos.values, ..._frames].any((u) => u.error != null)
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
    // A failed upload is found now, while the seller can still retake it, not at the last step.
    if (_photos.values.any((u) => u.error != null)) {
      showError(context,
          ApiException(422, 'photo_failed', tr('Кейбір фото жүктелмеді. Белгісі бар фотоны қайта түсіріңіз.')));
      return false;
    }
    if (_frames.any((f) => f.error != null)) {
      showError(context, ApiException(422, 'photo_failed', tr('Кейбір кадрлар жүктелмеді. Қайта түсіріңіз.')));
      return false;
    }
    return true;
  }

  /// Next from the details: every field on the page is filled in, and a defective pair shows its defects.
  bool _detailsDone() {
    if (!_form.currentState!.validate()) return false;
    if (_defectPhotos.any((d) => d.error != null)) {
      // A defect tile cannot be retaken in place, so a failed one goes and is added again.
      setState(() => _defectPhotos.removeWhere((d) => d.error != null));
      showError(context, ApiException(422, 'photo_failed', tr('Ақау фотосы жүктелмеді. Қайта қосыңыз.')));
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
      setState(() => _step++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uploading =
        [..._photos.values, ..._defectPhotos, ..._frames].where((u) => u.url == null && u.error == null).length;
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
                  child: Text(trf('«{0}» мәліметтері көшірілді. Фото мен 360° кадрларды осы жұптан жаңадан түсіріңіз.',
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
              onTap: () => _pickAngle(e.key),
            ),
        ]),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.threesixty),
                const SizedBox(width: 8),
                Expanded(child: Text(tr('360° көрініс'), style: theme.textTheme.titleSmall)),
                if (_frames.isNotEmpty)
                  Text('${_frames.where((f) => f.url != null).length}/${_frames.length}',
                      style: theme.textTheme.bodySmall),
              ]),
              const SizedBox(height: 4),
              Text(
                trf('Міндетті емес, бірақ сатып алушы тауарды жан-жағынан көреді. Аяқкиімді аздап бұрып, {0} шақты кадр түсіріңіз.',
                    [spinTargetFrames]),
                style: theme.textTheme.bodySmall,
              ),
              if (_frames.isNotEmpty)
                ShowcaseStopsHint(have: {
                  for (final e in _photos.entries)
                    if (e.value.error == null) e.key
                }, onPick: _pickAngle),
              if (_frames.any((f) => f.error != null))
                Text(tr('Кейбір кадрлар жүктелмеді. Қайта түсіріңіз.'),
                    style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                FilledButton.tonalIcon(
                    onPressed: _captureSpin, icon: const Icon(Icons.photo_camera_outlined), label: Text(tr('Түсіру'))),
                OutlinedButton.icon(
                    onPressed: _pickSpinFromGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text(tr('Галереядан'))),
              ]),
            ]),
          ),
        ),
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
          onChanged: (v) => setState(() => _category = v!),
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
        ColorField(controller: _color),
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
            for (final d in _defectPhotos) _PhotoSlot(label: tr('Ақау'), upload: d, onTap: null),
            ActionChip(
                avatar: const Icon(Icons.add_a_photo_outlined, size: 18),
                label: Text(tr('Ақау фотосы')),
                onPressed: _addDefect),
          ]),
        ],
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
        const SizedBox(height: 8),
        Text(tr('Витрина фоны'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'clean', label: Text(tr('Таза'))),
            ButtonSegment(value: 'premium', label: Text(tr('Премиум'))),
            ButtonSegment(value: 'dynamic', label: Text(tr('Динамик'))),
          ],
          selected: {_style},
          onSelectionChanged: (v) => setState(() => _style = v.first),
        ),
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
      inner = Icon(Icons.error_outline, color: scheme.error);
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
      label: trf('{0} фотосы', [label]),
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
