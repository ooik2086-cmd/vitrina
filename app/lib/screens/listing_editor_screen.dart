import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../labels.dart';
import '../session.dart';
import '../widgets/common.dart';
import 'spin_capture_screen.dart';

/// Required angles first; the server refuses to publish with fewer than four photos.
const requiredAngles = {'front': 'Алдынан', 'outer': 'Сырт бүйірі', 'inner': 'Ішкі бүйірі', 'back': 'Өкшесі'};
const optionalAngles = {'sole': 'Табаны', 'top': 'Үстінен', 'label': 'Жапсырма, өлшем'};
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
  const ListingEditorScreen({super.key});

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
  String _category = 'sneakers';
  String _condition = 'new_with_box';
  String _style = 'clean';
  final _sizes = [_SizeRow()];
  final Map<String, _Upload> _photos = {};
  final List<_Upload> _defectPhotos = [];
  List<_Upload> _frames = [];
  bool _saving = false;
  final _picker = ImagePicker();

  Api get _api => SessionScope.of(context).api;

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

  _Upload _startUpload(XFile file) {
    late final _Upload u;
    u = _Upload(file.readAsBytes().then((b) => _api.uploadPhoto(b, file.name)).then((url) {
      if (mounted) setState(() => u.url = url);
      return url;
    }, onError: (Object e) {
      if (mounted) setState(() => u.error = e);
      throw e;
    }));
    u.future.ignore(); // errors are shown on the tile and checked again at save time
    return u;
  }

  Future<XFile?> _pick() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(children: [
          ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Камерамен түсіру'),
              onTap: () => Navigator.pop(context, ImageSource.camera)),
          ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Галереядан таңдау'),
              onTap: () => Navigator.pop(context, ImageSource.gallery)),
        ]),
      ),
    );
    if (source == null) return null;
    return _picker.pickImage(source: source, maxWidth: 2000, maxHeight: 2000, imageQuality: 90);
  }

  Future<void> _pickAngle(String angle) async {
    final file = await _pick();
    if (file != null) setState(() => _photos[angle] = _startUpload(file));
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
      if (mounted) showError(context, ApiException(422, 'too_few_frames', '360° үшін кемінде $spinMinFrames кадр керек.'));
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
    final missing = requiredAngles.keys.where((a) => _photos[a] == null).map((a) => requiredAngles[a]).toList();
    if (missing.isNotEmpty) {
      showError(context, ApiException(422, 'missing_required_photos', 'Фото жетіспейді: ${missing.join(', ')}.'));
      return;
    }
    if (_condition == 'defective' && _defectPhotos.isEmpty) {
      showError(context, ApiException(422, 'defects_required', 'Әр ақаудың жақын фотосын қосыңыз.'));
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
        'category': _category,
        if (_brand.text.trim().isNotEmpty) 'brand': _brand.text.trim(),
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
      if (publish) await _api.publishListing(listing.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _required(String? v) => (v ?? '').trim().isEmpty ? 'Толтырыңыз' : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uploading = [..._photos.values, ..._defectPhotos, ..._frames].where((u) => u.url == null && u.error == null).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Жаңа тауар')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('Фото', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Жарық жерде, біркелкі фонда түсіріңіз. Фото өзгертілмейді, тек метадеректер өшіріледі.',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in {...requiredAngles, ...optionalAngles}.entries)
              _PhotoSlot(
                label: e.value,
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
                  Expanded(child: Text('360° көрініс', style: theme.textTheme.titleSmall)),
                  if (_frames.isNotEmpty)
                    Text('${_frames.where((f) => f.url != null).length}/${_frames.length}',
                        style: theme.textTheme.bodySmall),
                ]),
                const SizedBox(height: 4),
                Text(
                  'Міндетті емес, бірақ сатып алушы тауарды жан-жағынан көреді. '
                  'Аяқкиімді аздап бұрып, $spinTargetFrames шақты кадр түсіріңіз.',
                  style: theme.textTheme.bodySmall,
                ),
                if (_frames.any((f) => f.error != null))
                  Text('Кейбір кадрлар жүктелмеді. Қайта түсіріңіз.', style: TextStyle(color: theme.colorScheme.error)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  FilledButton.tonalIcon(
                      onPressed: _captureSpin, icon: const Icon(Icons.photo_camera_outlined), label: const Text('Түсіру')),
                  OutlinedButton.icon(
                      onPressed: _pickSpinFromGallery,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Галереядан')),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
              controller: _title, decoration: const InputDecoration(labelText: 'Атауы'), validator: _required, maxLength: 120),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Санаты'),
            items: [for (final e in categories.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => _category = v!),
          ),
          TextFormField(controller: _brand, decoration: const InputDecoration(labelText: 'Бренді (міндетті емес)')),
          TextFormField(controller: _color, decoration: const InputDecoration(labelText: 'Түсі'), validator: _required),
          DropdownButtonFormField<String>(
            initialValue: _condition,
            decoration: const InputDecoration(labelText: 'Жағдайы'),
            items: [for (final e in conditions.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => _condition = v!),
          ),
          if (_defectRequired.contains(_condition)) ...[
            TextFormField(
              controller: _defects,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Ақаулары', hintText: 'Не, қай жерде, қандай көлемде'),
              validator: _required,
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final d in _defectPhotos) _PhotoSlot(label: 'Ақау', upload: d, onTap: null),
              ActionChip(
                  avatar: const Icon(Icons.add_a_photo_outlined, size: 18),
                  label: const Text('Ақау фотосы'),
                  onPressed: _addDefect),
            ]),
          ],
          TextFormField(
              controller: _description,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Сипаттамасы (міндетті емес)')),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _price,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Бағасы', suffixText: '₸'),
                validator: (v) => (_tiyn(v ?? '') ?? 0) <= 0 ? 'Бағаны енгізіңіз' : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _delivery,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Жеткізу', suffixText: '₸'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Text('Өлшемдер', style: theme.textTheme.titleMedium),
          for (final (i, s) in _sizes.indexed)
            Row(children: [
              Expanded(
                  child: TextFormField(
                      controller: s.label, decoration: const InputDecoration(labelText: 'Өлшем'), validator: _required)),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  controller: s.cm,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Ұлтарақ, см'),
                  validator: _required,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 56,
                child: TextFormField(
                    controller: s.qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Саны')),
              ),
              IconButton(
                tooltip: 'Өшіру',
                onPressed: _sizes.length > 1 ? () => setState(() => _sizes.removeAt(i).dispose()) : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
            ]),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () => setState(() => _sizes.add(_SizeRow())),
                icon: const Icon(Icons.add),
                label: const Text('Өлшем қосу')),
          ),
          const SizedBox(height: 8),
          Text('Витрина фоны', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'clean', label: Text('Таза')),
              ButtonSegment(value: 'premium', label: Text('Премиум')),
              ButtonSegment(value: 'dynamic', label: Text('Динамик')),
            ],
            selected: {_style},
            onSelectionChanged: (v) => setState(() => _style = v.first),
          ),
          const SizedBox(height: 24),
          if (uploading > 0) Text('Жүктелуде: $uploading фото', style: theme.textTheme.bodySmall),
          FilledButton(
            onPressed: _saving ? null : () => _save(publish: true),
            child: Text(_saving ? 'Сақталуда…' : 'Жариялау'),
          ),
          TextButton(
            onPressed: _saving ? null : () => _save(publish: false),
            child: const Text('Жоба ретінде сақтау'),
          ),
        ]),
      ),
    );
  }
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
      inner = Image.network(u.url!, fit: BoxFit.cover, width: 96, height: 96);
    }
    return Semantics(
      button: onTap != null,
      label: '$label фотосы',
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
