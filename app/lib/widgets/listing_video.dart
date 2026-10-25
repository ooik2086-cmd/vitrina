import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../i18n.dart';
import '../net_image.dart';
import '../session.dart';
import 'common.dart';
import 'video_pane.dart';

/// The seller's own video of the pair on the manage page: filmed or picked (a minute at most), sent with its progress
/// shown, then made smaller by the server while the page checks back; once ready it can be watched or taken off.
class ListingVideoSection extends StatefulWidget {
  const ListingVideoSection({super.key, required this.listing, required this.onChanged, this.picker});
  final Listing listing;
  final ValueChanged<Listing> onChanged;
  final ImagePicker? picker;

  @override
  State<ListingVideoSection> createState() => _ListingVideoSectionState();
}

class _ListingVideoSectionState extends State<ListingVideoSection> {
  static const maxLength = Duration(seconds: 60);

  /// How often the page asks whether the video is made yet, and for how long before leaving it to the next visit.
  static const checkEvery = Duration(seconds: 8);
  static const checkFor = Duration(minutes: 20);

  late final _picker = widget.picker ?? ImagePicker();
  double? _sent; // 0..1 while sending
  bool _busy = false;
  Timer? _check;
  DateTime? _checkSince;
  bool _gaveUp = false; // checked for checkFor without an answer
  bool _asking = false; // one question at a time: on a weak line an answer can take longer than checkEvery
  int _changes = 0; // the seller's own changes here; an answer asked before one of them is out of date
  // The listing the page held when asking: an answer that comes after the page took another (an edit elsewhere on it,
  // a change here) would put back what was there before; the next tick asks again.

  Listing get _l => widget.listing;
  ListingVideo? get _video => _l.video;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(ListingVideoSection old) {
    super.didUpdateWidget(old);
    _follow();
  }

  @override
  void dispose() {
    _check?.cancel();
    super.dispose();
  }

  /// While the server makes the video, asks for the listing again now and then, so the page shows it when ready.
  void _follow() {
    if (_video?.state != 'processing') {
      _check?.cancel();
      _check = null;
      _checkSince = null;
      _gaveUp = false; // the next video is followed afresh
      return;
    }
    _checkSince ??= DateTime.now();
    _check ??= Timer.periodic(checkEvery, (_) async {
      if (DateTime.now().difference(_checkSince!) > checkFor) {
        _check?.cancel();
        if (mounted) setState(() => _gaveUp = true); // the spinner gives way to «Қайта көру»
        return;
      }
      if (_asking || _busy || !mounted) return;
      _asking = true;
      final asked = _changes, held = _l;
      try {
        final l = await SessionScope.of(context).api.listing(_l.id);
        if (mounted && asked == _changes && identical(held, _l) && !_busy && l.video?.state != 'processing') {
          widget.onChanged(l);
        }
      } catch (_) {
        // offline for now: the next tick asks again
      } finally {
        _asking = false;
      }
    });
  }

  Future<void> _add() async {
    final source = await showSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const Key('video-camera'),
            leading: const Icon(Icons.videocam_outlined),
            title: Text(tr('Видео түсіру')),
            subtitle: Text(tr('1 минутқа дейін. Аяқкиімді жан-жағынан баяу көрсетіңіз.')),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            key: const Key('video-gallery'),
            leading: const Icon(Icons.video_library_outlined),
            title: Text(tr('Галереядан таңдау')),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null || !mounted) return;
    // A refused permission or a file that did not open is said as such, not as a lost connection.
    final file = await takePhoto(context, () => _picker.pickVideo(source: source, maxDuration: maxLength),
        camera: source == ImageSource.camera, video: true);
    if (file == null || !mounted) return;
    final api = SessionScope.of(context).api;
    setState(() {
      _busy = true;
      _sent = 0;
      _changes++;
    });
    try {
      final l = await api.addListingVideo(_l.id, file.openRead(), await file.length(), file.name, onProgress: (p) {
        if (mounted) setState(() => _sent = p);
      });
      if (!mounted) return;
      widget.onChanged(l);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('Видео жіберілді. Дайын болғанда көрінеді.'))));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _sent = null;
        });
      }
    }
  }

  Future<void> _remove() async {
    final sure =
        await confirmAction(context, title: tr('Видеоны өшіру керек пе?'), action: tr('Өшіру'), destructive: true);
    if (!sure || !mounted) return;
    setState(() {
      _busy = true;
      _changes++;
    });
    try {
      final l = await SessionScope.of(context).api.removeListingVideo(_l.id);
      if (!mounted) return;
      widget.onChanged(l);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Видео өшірілді'))));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _watch(ListingVideo video) => showDialog<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: SafeArea(
            child: Stack(children: [
              Positioned.fill(child: VideoPane(url: video.url!, posterUrl: video.posterUrl, seconds: video.seconds)),
              Positioned(
                top: 4,
                left: 4,
                child: IconButton(
                  color: Colors.white,
                  tooltip: tr('Жабу'),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final video = _video;
    final small = theme.textTheme.bodySmall;
    return Column(key: const Key('video-section'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('Видео (міндетті емес)'), style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      if (_sent != null) ...[
        Text(trf('Видео жіберіліп жатыр: {0}%', [(_sent! * 100).round()]), key: const Key('video-sending')),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: _sent),
      ] else if (video?.state == 'processing')
        Row(key: const Key('video-processing'), children: [
          if (!_gaveUp) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          if (!_gaveUp) const SizedBox(width: 12),
          Expanded(child: Text(tr('Видео дайындалып жатыр. Бірнеше минут кетуі мүмкін.'), style: small)),
          if (_gaveUp)
            TextButton(
              key: const Key('video-ask-again'),
              onPressed: () {
                setState(() => _gaveUp = false);
                _check?.cancel();
                _check = null;
                _checkSince = null;
                _follow();
              },
              child: Text(tr('Қайта көру')),
            ),
        ])
      else if (video != null && video.ready)
        Row(key: const Key('video-ready'), children: [
          InkWell(
            onTap: () => _watch(video),
            borderRadius: BorderRadius.circular(14),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 80,
                height: 80,
                child: Stack(fit: StackFit.expand, children: [
                  ColoredBox(
                    color: Colors.black,
                    child: video.posterUrl == null
                        ? null
                        : Image(
                            image: ResizeImage.resizeIfNeeded(240, null, netImage(video.posterUrl!)),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                  ),
                  Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 36, semanticLabel: tr('Көру')),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
                video.seconds == null
                    ? tr('Видео дайын')
                    : trf('Видео дайын: {0}', [clockText(Duration(seconds: video.seconds!))]),
                style: theme.textTheme.bodyMedium),
          ),
          TextButton.icon(
            key: const Key('remove-video'),
            onPressed: _busy ? null : _remove,
            icon: const Icon(Icons.delete_outline),
            label: Text(tr('Өшіру')),
          ),
        ])
      else ...[
        Text(
            video?.state == 'failed'
                ? tr('Видео дайындалмады. Қайта жіберіп көріңіз.')
                : tr('1 минутқа дейін өз видеоңызды қосыңыз: сатып алушы аяқкиімді шын күйінде көреді.'),
            key: const Key('video-note'),
            style: video?.state == 'failed' ? small?.copyWith(color: theme.colorScheme.error) : small),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('add-video'),
          onPressed: _busy ? null : _add,
          icon: const Icon(Icons.videocam_outlined),
          label: Text(tr('Видео қосу')),
        ),
      ],
    ]);
  }
}
