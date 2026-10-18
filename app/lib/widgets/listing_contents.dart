import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../i18n.dart';
import '../labels.dart';
import '../screens/listing_editor_screen.dart';
import '../screens/spin_capture_screen.dart';
import '../session.dart';
import '../theme.dart';
import 'common.dart';

/// The server's own minimum (Settings.min_listing_photos) for a listing that is or was on sale.
const _minPhotosOnSale = 4;
const _requiredAngles = {'front', 'outer', 'inner', 'back'};

const photoAngles = {...requiredAngles, ...optionalAngles, 'defect': 'Ақау, жақыннан'};

/// The listing's name fields, owned by the manage page so its one Save button sends them with everything else.
/// Before the listing was ever on sale everything can change; afterwards the server keeps the brand, model and
/// category buyers chose, and the condition can only be marked worse.
class ListingNameFields extends StatelessWidget {
  const ListingNameFields({
    super.key,
    required this.listing,
    required this.title,
    required this.brand,
    required this.model,
    required this.color,
    required this.category,
    required this.condition,
    required this.onCategory,
    required this.onCondition,
  });
  final Listing listing;
  final TextEditingController title;
  final TextEditingController brand;
  final TextEditingController model;
  final TextEditingController color;
  final String category;
  final String condition;
  final ValueChanged<String> onCategory;
  final ValueChanged<String> onCondition;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fresh = !listing.everOnSale;
    final order = conditions.keys.toList();
    // After sale a seller may admit wear that appeared, never claim the shoe got better.
    final allowed = fresh ? order : order.sublist(order.indexOf(listing.condition).clamp(0, order.length - 1));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('Атауы мен сипаты'), style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        fresh
            ? tr('Тауар әлі сатылымға шықпаған, сондықтан бәрін өзгертуге болады.')
            : tr(
                'Сатып алушылар таңдаған бренд, модель және санат өзгермейді. Күйін тек нашарлатып белгілеуге болады.'),
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      TextFormField(
        key: const Key('edit-title'),
        controller: title,
        decoration: InputDecoration(labelText: tr('Атауы')),
        validator: (v) => (v ?? '').trim().length < 3 ? tr('Атауы кемінде 3 әріп болсын') : null,
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
            child: TextFormField(
                key: const Key('edit-brand'),
                controller: brand,
                enabled: fresh,
                decoration: InputDecoration(labelText: tr('Бренді (міндетті емес)')))),
        const SizedBox(width: 12),
        Expanded(
            child: TextFormField(
                key: const Key('edit-model'),
                controller: model,
                enabled: fresh,
                decoration: InputDecoration(labelText: tr('Моделі')))),
      ]),
      const SizedBox(height: 12),
      TextFormField(
        key: const Key('edit-color'),
        controller: color,
        decoration: InputDecoration(labelText: tr('Түсі')),
        validator: (v) => (v ?? '').trim().length < 2 ? tr('Түсін жазыңыз') : null,
      ),
      if (fresh) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: category,
          isExpanded: true,
          decoration: InputDecoration(labelText: tr('Санаты')),
          items: [for (final e in categories.entries) DropdownMenuItem(value: e.key, child: Text(tr(e.value)))],
          onChanged: (v) => onCategory(v ?? category),
        ),
      ],
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: const Key('edit-condition'),
        initialValue: condition,
        isExpanded: true,
        decoration: InputDecoration(labelText: tr('Жағдайы')),
        items: [
          for (final k in allowed) DropdownMenuItem(value: k, child: Text(tr(conditions[k]!))),
        ],
        onChanged: (v) => onCondition(v ?? condition),
      ),
    ]);
  }
}

/// What the listing shows besides its name: photos, 360° view and sizes, each saved the moment it is added.
class ListingContentsCard extends StatefulWidget {
  const ListingContentsCard({super.key, required this.listing, required this.onChanged});
  final Listing listing;
  final ValueChanged<Listing> onChanged;

  @override
  State<ListingContentsCard> createState() => _ListingContentsCardState();
}

class _ListingContentsCardState extends State<ListingContentsCard> {
  final _picker = ImagePicker();
  bool _busy = false;

  Listing get _l => widget.listing;
  bool get _hasSpin => _l.media.any((m) => m.angle == 'frame');

  Future<void> _run(Future<Listing> Function(Api api) action, String done) async {
    setState(() => _busy = true);
    try {
      final l = await action(SessionScope.of(context).api);
      if (!mounted) return;
      final queued = l.status == 'moderation' && _l.status != 'moderation';
      widget.onChanged(l);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(queued ? tr('Өзгеріс тексеруге жіберілді') : done)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Uploads a few at a time: a 360° set is dozens of frames, one by one it takes minutes on mobile data.
  Future<List<Map<String, String>>> _upload(Api api, List<XFile> files, String angle) async {
    final urls = <String>[];
    for (var i = 0; i < files.length; i += 4) {
      urls.addAll(await Future.wait([
        for (final f in files.skip(i).take(4))
          f.readAsBytes().then((b) => api.uploadPhoto(b, f.name, detail: detailAngles.contains(angle))),
      ]));
    }
    return [
      for (final u in urls) {'url': u, 'angle': angle}
    ];
  }

  Future<void> _addPhoto() async {
    final filled = {for (final m in _l.media) m.angle};
    final angle = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(tr('Қай жағынан?'), style: Theme.of(context).textTheme.titleMedium)),
          for (final e in photoAngles.entries)
            ListTile(
              key: Key('angle-${e.key}'),
              title: Text(tr(e.value)),
              trailing: filled.contains(e.key)
                  ? Icon(Icons.check_circle,
                      semanticLabel: tr('Фото бар'), color: Theme.of(context).colorScheme.primary)
                  : null,
              onTap: () => Navigator.pop(context, e.key),
            ),
        ]),
      ),
    );
    if (angle == null || !mounted) return;
    await _addPhotoAt(angle);
  }

  Future<void> _addPhotoAt(String angle) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const Key('source-camera'),
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(tr('Камерамен түсіру')),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            key: const Key('source-gallery'),
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(tr('Галереядан таңдау')),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null) return;
    final side = detailAngles.contains(angle) ? 3000.0 : 2000.0;
    final file = await _picker.pickImage(source: source, maxWidth: side, maxHeight: side, imageQuality: 90);
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

  Future<void> _removePhoto(int index) async {
    final name = tr(photoAngles[_l.media[index].angle] ?? 'Фото');
    final sure = await confirmAction(context,
        title: trf('«{0}» фотосын өшіру керек пе?', [name]), action: tr('Өшіру'), destructive: true);
    if (!sure || !mounted) return;
    final keep = [
      for (var i = 0; i < _l.media.length; i++)
        if (i != index) {'url': _l.media[i].originalUrl, 'angle': _l.media[i].angle}
    ];
    await _run((api) => api.editListing(_l.id, photos: keep), tr('Фото өшірілді'));
  }

  Future<void> _removeSpin() async {
    final sure = await confirmAction(context,
        title: tr('360° көріністі өшіру керек пе?'), action: tr('Өшіру'), destructive: true);
    if (!sure || !mounted) return;
    final keep = [
      for (final m in _l.media)
        if (m.angle != 'frame') {'url': m.originalUrl, 'angle': m.angle}
    ];
    await _run((api) => api.editListing(_l.id, photos: keep), tr('360° көрініс өшірілді'));
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
    // The server's rule for a listing that was on sale: the main sides and defect close-ups stay, and so does the
    // count publishing asks for. Orders keep their own copy of what they were placed on.
    bool removable(int i) {
      if (!_l.everOnSale) return photos.length > 1;
      final angle = _l.media[i].angle;
      if (angle == 'defect' || photos.length <= _minPhotosOnSale) return false;
      return !_requiredAngles.contains(angle) || photos.where((j) => _l.media[j].angle == angle).length > 1;
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('Фото, 360° және өлшемдер'), style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        _l.everOnSale
            ? tr(
                'Жаңа фото қосып, қосымша фотоны өшіруге болады. Негізгі төрт жақ пен ақау фотолары қалады. Тапсырыс бергендер өздері көрген фотоны тапсырыс ішінен көреді.')
            : tr('Қосқан әр фото мен өлшем бірден сақталады.'),
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 96,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final i in photos)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: SizedBox(
                width: 96,
                height: 96,
                child: Stack(children: [
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      // Cut-outs are transparent: the studio backdrop keeps them readable in dark mode too.
                      child: ColoredBox(
                        color: Brand.studio,
                        child: Image.network(_l.media[i].processedUrl ?? _l.media[i].originalUrl,
                            width: 80,
                            height: 80,
                            cacheWidth: 240,
                            fit: BoxFit.cover,
                            semanticLabel: tr(photoAngles[_l.media[i].angle] ?? ''),
                            errorBuilder: (_, __, ___) => const SizedBox(
                                width: 80, height: 80, child: Icon(Icons.image_outlined, color: Colors.black54))),
                      ),
                    ),
                  ),
                  if (removable(i))
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        key: Key('remove-photo-$i'),
                        tooltip: trf('Өшіру: {0}', [tr(photoAngles[_l.media[i].angle] ?? 'Фото')]),
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        icon: CircleAvatar(
                          radius: 12,
                          backgroundColor: theme.colorScheme.inverseSurface,
                          child: Icon(Icons.close, size: 14, color: theme.colorScheme.onInverseSurface),
                        ),
                        onPressed: _busy ? null : () => _removePhoto(i),
                      ),
                    ),
                ]),
              ),
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
        Row(children: [
          Expanded(child: Text(trf('360° көрініс: {0} кадр', [frames]), style: theme.textTheme.bodySmall)),
          TextButton.icon(
            key: const Key('remove-spin'),
            onPressed: _busy ? null : _removeSpin,
            icon: const Icon(Icons.delete_outline),
            label: Text(tr('360° өшіру')),
          ),
        ]),
        ShowcaseStopsHint(have: {for (final m in _l.media) m.angle}, onPick: _addPhotoAt, enabled: !_busy),
      ],
      if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
    ]);
  }
}

/// After the 360° turn the showcase scrolls on to the top, the sole and a close-up. This asks the seller for the
/// ones still missing, one tap each; a stop without its photo is simply skipped on the listing page.
class ShowcaseStopsHint extends StatelessWidget {
  const ShowcaseStopsHint({super.key, required this.have, required this.onPick, this.enabled = true});

  /// Angles the listing already has a photo for.
  final Set<String> have;
  final ValueChanged<String> onPick;
  final bool enabled;

  static const stops = {'top': 'Үстінен', 'sole': 'Табаны', 'label': 'Жақыннан (тігіс, логотип, жапсырма)'};

  @override
  Widget build(BuildContext context) {
    final missing = [
      for (final a in stops.keys)
        if (!have.contains(a)) a
    ];
    if (missing.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('360° айналымнан кейін сатып алушы үстін, табанын және жақын көріністі көреді. Бір-бір фото қосыңыз:'),
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final a in missing)
            ActionChip(
              key: Key('stop-$a'),
              avatar: const Icon(Icons.add_a_photo_outlined, size: 18),
              label: Text(tr(stops[a]!)),
              onPressed: enabled ? () => onPick(a) : null,
            ),
        ]),
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
      scrollable: true, // the keyboard takes half a small screen; the fields scroll instead of overflowing
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
