import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../net_image.dart';
import '../api.dart';
import '../colors.dart';
import '../i18n.dart';
import '../labels.dart';
import '../screens/listing_editor_screen.dart';
import '../session.dart';
import '../theme.dart';
import 'common.dart';
import 'listing_video.dart';

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
    required this.audience,
    required this.condition,
    required this.onCategory,
    required this.onAudience,
    required this.onCondition,
  });
  final Listing listing;
  final TextEditingController title;
  final TextEditingController brand;
  final TextEditingController model;
  final TextEditingController color;
  final String category;
  final String? audience;
  final String condition;
  final ValueChanged<String> onCategory;
  final ValueChanged<String> onAudience;
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
      // One under the other: side by side, «(міндетті емес)» was cut off on a usual phone.
      TextFormField(
          key: const Key('edit-brand'),
          controller: brand,
          enabled: fresh,
          decoration: InputDecoration(labelText: tr('Бренді (міндетті емес)'))),
      const SizedBox(height: 12),
      TextFormField(
          key: const Key('edit-model'),
          controller: model,
          enabled: fresh,
          decoration: InputDecoration(labelText: tr('Моделі'))),
      const SizedBox(height: 12),
      ColorField(controller: color),
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
      // Whom it is for stays once said and on sale; a pair listed before it was asked can still be told.
      if (fresh || listing.audience == null) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const Key('edit-audience'),
          initialValue: audience,
          isExpanded: true,
          decoration: InputDecoration(labelText: tr('Кімге арналған')),
          items: [for (final e in audiences.entries) DropdownMenuItem(value: e.key, child: Text(tr(e.value)))],
          onChanged: (v) => v == null ? null : onAudience(v),
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
  const ListingContentsCard({super.key, required this.listing, required this.onChanged, this.showNoShoe = false});
  final Listing listing;
  final ValueChanged<Listing> onChanged;

  /// Opened from the note about a photo with no shoe found: the strip starts at that photo and its line is in view.
  final bool showNoShoe;

  @override
  State<ListingContentsCard> createState() => _ListingContentsCardState();
}

class _ListingContentsCardState extends State<ListingContentsCard> {
  final _picker = ImagePicker();
  bool _busy = false;

  final _strip = ScrollController();
  final _note = GlobalKey();

  Listing get _l => widget.listing;

  /// Where the strip starts so the first marked photo shows, with the photo before it for context.
  double _firstMarked() {
    final photos = _l.media.where((m) => m.angle != 'frame').toList();
    final i = photos.indexWhere((m) => m.noShoe);
    return i <= 0 ? 0 : (i - 1) * _tile;
  }

  static const _tile = 96.0 + 12;

  @override
  void initState() {
    super.initState();
    if (widget.showNoShoe) {
      // Runs after the page has brought the card's top up: with large text the line below may still be out of view.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_strip.hasClients) _strip.jumpTo(math.min(_firstMarked(), _strip.position.maxScrollExtent));
        final at = _note.currentContext;
        if (at != null) {
          Scrollable.ensureVisible(at, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
        }
      });
    }
  }

  @override
  void dispose() {
    _strip.dispose();
    super.dispose();
  }

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

  /// Uploads three at a time: a 360° set is dozens of frames, one by one it takes minutes on mobile data, and all at
  /// once chokes it. Each address is put in [into] by the file's place as it comes, so a failure keeps the others.
  Future<List<Map<String, String>>> _upload(Api api, List<XFile> files, String angle, {Map<int, String>? into}) async {
    final urls = into ?? <int, String>{};
    Object? failed;
    final left = [
      for (var i = 0; i < files.length; i++)
        if (!urls.containsKey(i)) i
    ];
    for (var k = 0; k < left.length; k += 3) {
      await Future.wait([
        for (final i in left.skip(k).take(3))
          files[i]
              .readAsBytes()
              .then((b) => api.uploadPhotoPatiently(b, files[i].name, detail: detailAngles.contains(angle)))
              .then<void>((url) => urls[i] = url, onError: (Object e) => failed ??= e),
      ]);
    }
    if (failed != null) throw failed!;
    return [
      for (var i = 0; i < files.length; i++) {'url': urls[i]!, 'angle': angle}
    ];
  }

  Future<void> _addPhoto() async {
    final filled = {for (final m in _l.media) m.angle};
    final angle = await showSheet<String>(
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
    final source = await showSheet<ImageSource>(
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
    if (source == null || !mounted) return;
    final side = detailAngles.contains(angle) ? 3000.0 : 2000.0;
    final file = await takePhoto(
        context, () => _picker.pickImage(source: source, maxWidth: side, maxHeight: side, imageQuality: 90),
        camera: source == ImageSource.camera);
    if (file == null || !mounted) return;
    await _run((api) async => api.editListing(_l.id, addPhotos: await _upload(api, [file], angle)), tr('Фото қосылды'));
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
    // The server's rule for a listing that was on sale: the main sides and defect close-ups stay, and so does the
    // count publishing asks for. Orders keep their own copy of what they were placed on.
    bool removable(int i) {
      if (!_l.everOnSale) return photos.length > 1;
      final angle = _l.media[i].angle;
      if (angle == 'defect' || photos.length <= _minPhotosOnSale) return false;
      return !_requiredAngles.contains(angle) || photos.where((j) => _l.media[j].angle == angle).length > 1;
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(header: true, child: Text(tr('Фото және өлшемдер'), style: theme.textTheme.titleMedium)),
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
        child: ListView(controller: _strip, scrollDirection: Axis.horizontal, children: [
          for (final i in photos)
            Padding(
              padding: const EdgeInsets.only(right: _tile - 96),
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
                        child: Image(
                            image: ResizeImage.resizeIfNeeded(
                                240, null, netImage(_l.media[i].processedUrl ?? _l.media[i].originalUrl)),
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                            semanticLabel: _l.media[i].noShoe
                                ? trf('{0}: аяқкиім табылмады, фоны алынбайды',
                                    [tr(photoAngles[_l.media[i].angle] ?? 'Фото')])
                                : tr(photoAngles[_l.media[i].angle] ?? ''),
                            errorBuilder: (_, __, ___) => const SizedBox(
                                width: 80, height: 80, child: Icon(Icons.image_outlined, color: Colors.black54))),
                      ),
                    ),
                  ),
                  // The model found no shoe in it, so it stays as taken: the one to take again.
                  if (_l.media[i].noShoe)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: Tooltip(
                        message: trf(
                            '{0}: аяқкиім табылмады, фоны алынбайды', [tr(photoAngles[_l.media[i].angle] ?? 'Фото')]),
                        excludeFromSemantics: true, // the photo's own label says it
                        child: CircleAvatar(
                          key: Key('no-shoe-$i'),
                          radius: 11,
                          backgroundColor: theme.colorScheme.errorContainer,
                          child: Icon(Icons.hide_image_outlined, size: 14, color: theme.colorScheme.onErrorContainer),
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
      // The badge alone says nothing to a sighted seller; the completeness card may not list it among its top tips.
      if (photos.any((i) => _l.media[i].noShoe))
        Padding(
          key: const Key('photos-no-shoe'),
          padding: const EdgeInsets.only(top: 8),
          child: Row(key: _note, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.hide_image_outlined, size: 18, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  tr('Белгіленген фотода аяқкиім табылмады, сондықтан фоны алынбайды. Сол жағынан жаңа фото қосып, ескісін өшіріңіз.'),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
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
        OutlinedButton.icon(
          key: const Key('add-size'),
          onPressed: _busy ? null : _addSize,
          icon: const Icon(Icons.straighten_rounded),
          label: Text(tr('Өлшем қосу')),
        ),
      ]),
      if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
      const SizedBox(height: 20),
      ListingVideoSection(listing: _l, onChanged: widget.onChanged, picker: _picker),
    ]);
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
