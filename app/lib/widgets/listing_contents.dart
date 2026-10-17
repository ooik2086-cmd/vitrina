import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../i18n.dart';
import '../labels.dart';
import '../screens/listing_editor_screen.dart';
import '../screens/spin_capture_screen.dart';
import '../session.dart';
import 'common.dart';

/// What the listing shows: its name, photos, 360° view and sizes, edited in place on the manage page.
/// Before the listing was ever on sale everything can change; afterwards the server keeps the category, condition
/// and the photos buyers already saw, and the seller can still add photos, a 360° view and sizes.
class ListingContentsCard extends StatefulWidget {
  const ListingContentsCard({super.key, required this.listing, required this.onChanged});
  final Listing listing;
  final ValueChanged<Listing> onChanged;

  @override
  State<ListingContentsCard> createState() => _ListingContentsCardState();
}

const _photoAngles = {...requiredAngles, ...optionalAngles, 'defect': 'Ақау, жақыннан'};

class _ListingContentsCardState extends State<ListingContentsCard> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.listing.title);
  late final _brand = TextEditingController(text: widget.listing.brand ?? '');
  late final _model = TextEditingController(text: widget.listing.modelName ?? '');
  late String _category = widget.listing.category;
  late String _condition = widget.listing.condition;
  final _picker = ImagePicker();
  bool _busy = false;

  Listing get _l => widget.listing;
  bool get _fresh => _l.status == 'draft' || _l.status == 'rejected';
  bool get _hasSpin => _l.media.any((m) => m.angle == 'frame');

  @override
  void dispose() {
    for (final c in [_title, _brand, _model]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<Listing> Function(Api api) action, String done) async {
    setState(() => _busy = true);
    try {
      final l = await action(SessionScope.of(context).api);
      if (!mounted) return;
      widget.onChanged(l);
      final queued = l.status == 'moderation' && _l.status != 'moderation';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(queued ? tr('Өзгеріс тексеруге жіберілді') : done)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _saveName() {
    if (!_form.currentState!.validate()) return;
    _run(
      (api) => api.editListing(_l.id,
          title: _title.text.trim(),
          brand: _brand.text.trim(),
          modelName: _model.text.trim(),
          category: _fresh && _category != _l.category ? _category : null,
          condition: _fresh && _condition != _l.condition ? _condition : null),
      tr('Сақталды'),
    );
  }

  Future<List<Map<String, String>>> _upload(Api api, List<XFile> files, String angle) async => [
        for (final f in files) {'url': await api.uploadPhoto(await f.readAsBytes(), f.name), 'angle': angle}
      ];

  Future<void> _addPhoto() async {
    final angle = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(tr('Қай жағынан?'), style: Theme.of(context).textTheme.titleMedium)),
          for (final e in _photoAngles.entries)
            ListTile(key: Key('angle-${e.key}'), title: Text(tr(e.value)), onTap: () => Navigator.pop(context, e.key)),
        ]),
      ),
    );
    if (angle == null) return;
    final file =
        await _picker.pickImage(source: ImageSource.gallery, maxWidth: 2000, maxHeight: 2000, imageQuality: 90);
    if (file == null) return;
    await _run((api) async => api.editListing(_l.id, addPhotos: await _upload(api, [file], angle)), tr('Фото қосылды'));
  }

  Future<void> _addSpin() async {
    final frames = await Navigator.of(context)
        .push<List<XFile>>(MaterialPageRoute(builder: (_) => const SpinCaptureScreen(), fullscreenDialog: true));
    if (frames == null || frames.isEmpty) return;
    await _run((api) async => api.editListing(_l.id, addPhotos: await _upload(api, frames, 'frame')),
        tr('360° көрініс қосылды'));
  }

  void _removePhoto(int index) {
    final keep = [
      for (var i = 0; i < _l.media.length; i++)
        if (i != index) {'url': _l.media[i].originalUrl, 'angle': _l.media[i].angle}
    ];
    _run((api) => api.editListing(_l.id, photos: keep), tr('Фото өшірілді'));
  }

  Future<void> _addSize() async {
    final size = await showDialog<Map<String, Object>>(context: context, builder: (_) => const _NewSizeDialog());
    if (size != null) await _run((api) => api.editListing(_l.id, addSizes: [size]), tr('Өлшем қосылды'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photos = [
      for (var i = 0; i < _l.media.length; i++)
        if (_l.media[i].angle != 'frame') i
    ];
    final frames = _l.media.where((m) => m.angle == 'frame').length;
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Атауы мен фотолары'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          _fresh
              ? tr('Тауар әлі сатылымға шықпаған, сондықтан бәрін өзгертуге болады.')
              : tr('Сатып алушылар көрген фото, санат және күй өзгермейді. Жаңа фото, 360° және өлшем қосуға болады.'),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('edit-title'),
          controller: _title,
          decoration: InputDecoration(labelText: tr('Атауы')),
          validator: (v) => (v ?? '').trim().length < 3 ? tr('Атауы кемінде 3 әріп болсын') : null,
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: TextFormField(
                  controller: _brand, decoration: InputDecoration(labelText: tr('Бренді (міндетті емес)')))),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(controller: _model, decoration: InputDecoration(labelText: tr('Моделі')))),
        ]),
        if (_fresh) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _category,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('Санаты')),
            items: [for (final e in categories.entries) DropdownMenuItem(value: e.key, child: Text(tr(e.value)))],
            onChanged: (v) => setState(() => _category = v ?? _category),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _condition,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('Жағдайы')),
            items: [for (final e in conditions.entries) DropdownMenuItem(value: e.key, child: Text(tr(e.value)))],
            onChanged: (v) => setState(() => _condition = v ?? _condition),
          ),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
              key: const Key('save-name'), onPressed: _busy ? null : _saveName, child: Text(tr('Атауын сақтау'))),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 88,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final i in photos)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.network(_l.media[i].processedUrl ?? _l.media[i].originalUrl,
                        width: 80,
                        height: 80,
                        cacheWidth: 240,
                        fit: BoxFit.cover,
                        semanticLabel: tr(_photoAngles[_l.media[i].angle] ?? ''),
                        errorBuilder: (_, __, ___) =>
                            const SizedBox(width: 80, height: 80, child: Icon(Icons.image_outlined))),
                  ),
                  if (_fresh && photos.length > 1)
                    Positioned(
                      top: -8,
                      right: -8,
                      child: IconButton(
                        key: Key('remove-photo-$i'),
                        tooltip: tr('Өшіру'),
                        icon: const CircleAvatar(radius: 12, child: Icon(Icons.close, size: 14)),
                        onPressed: _busy ? null : () => _removePhoto(i),
                      ),
                    ),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            key: const Key('add-photo'),
            onPressed: _busy ? null : _addPhoto,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(tr('Фото қосу')),
          ),
          if (!_hasSpin)
            OutlinedButton.icon(
              key: const Key('add-spin'),
              onPressed: _busy ? null : _addSpin,
              icon: const Icon(Icons.threesixty),
              label: Text(tr('360° қосу')),
            ),
          OutlinedButton.icon(
            key: const Key('add-size'),
            onPressed: _busy ? null : _addSize,
            icon: const Icon(Icons.straighten_rounded),
            label: Text(tr('Өлшем қосу')),
          ),
        ]),
        if (_hasSpin) ...[
          const SizedBox(height: 8),
          Text(trf('360° көрініс: {0} кадр', [frames]), style: theme.textTheme.bodySmall),
        ],
        if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
      ]),
    );
  }
}

class _NewSizeDialog extends StatefulWidget {
  const _NewSizeDialog();

  @override
  State<_NewSizeDialog> createState() => _NewSizeDialogState();
}

class _NewSizeDialogState extends State<_NewSizeDialog> {
  final _form = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _cm = TextEditingController();
  final _qty = TextEditingController(text: '1');

  @override
  void dispose() {
    for (final c in [_label, _cm, _qty]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Өлшем қосу')),
      content: Form(
        key: _form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            key: const Key('size-label'),
            controller: _label,
            decoration: InputDecoration(labelText: tr('Өлшем'), hintText: 'EU 42'),
            validator: (v) => (v ?? '').trim().isEmpty ? tr('Өлшемді жазыңыз') : null,
          ),
          TextFormField(
            key: const Key('size-cm'),
            controller: _cm,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: tr('Ұлтарақ, см')),
            validator: insoleCheck,
          ),
          TextFormField(
            key: const Key('size-qty'),
            controller: _qty,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('Саны')),
            validator: (v) => (int.tryParse(v ?? '') ?? -1) < 0 ? tr('Санын жазыңыз') : null,
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Болдырмау'))),
        FilledButton(
          key: const Key('size-add'),
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, <String, Object>{
              'label': _label.text.trim(),
              'insole_cm': _cm.text.trim(),
              'quantity': int.parse(_qty.text.trim()),
            });
          },
          child: Text(tr('Қосу')),
        ),
      ],
    );
  }
}
