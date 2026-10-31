import 'dart:io' show File, Platform;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;

import 'listing_editor_screen.dart' show detailAngles;

import '../i18n.dart';

/// Whether tapping «Камерамен түсіру» opens the guided camera below (phones) or the phone's own camera (web, tests).
bool guidedCamera = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// What to do for each side, in big plain words: where the shoe points, so every listing's photos look alike.
const sideHints = {
  'front': 'Аяқкиімді тұмсығымен өзіңізге қаратып қойыңыз.',
  // The left shoe of the pair: only its outer side faces the camera with the toe to the left (the outline's way).
  'outer': 'Сол аяқтың аяқкиімін алыңыз: сырт бүйірі көрінсін, тұмсығы солға қарасын.',
  'inner': 'Сол аяқтың аяқкиімін алыңыз: ішкі бүйірі көрінсін, тұмсығы оңға қарасын.',
  'back': 'Аяқкиімді өкшесімен өзіңізге қаратып қойыңыз.',
  'sole': 'Аяқкиімді аударып, табанын түсіріңіз.',
  'top': 'Аяқкиімді үстінен, тіке төмен қарап түсіріңіз.',
  'detail': 'Тігісін не логотипін жақыннан түсіріңіз.',
  'label': 'Ішіндегі жапсырманы, өлшемі көрінетіндей түсіріңіз.',
};

/// How the camera page ended: [fallback] names where the first side not taken comes from instead (the phone's own
/// camera, or the gallery when camera access was refused), when this camera could not open; null otherwise.
class SideCaptureResult {
  const SideCaptureResult({this.fallback});
  final ImageSource? fallback;
}

/// The camera for listing photos: each side in turn, with the shoe's outline on the screen and one line saying how
/// to put it. After each shot the photo is shown with «Қайта түсіру» and «Дұрыс», so a blurred one is never sent.
class SideCaptureScreen extends StatefulWidget {
  const SideCaptureScreen({super.key, required this.angles, required this.labels, required this.onTaken});

  /// The sides to take, in order.
  final List<String> angles;
  final Map<String, String> labels;

  /// Each side as soon as it is confirmed: its upload starts and the listing's draft keeps it at once.
  final void Function(String angle, XFile photo) onTaken;

  @override
  State<SideCaptureScreen> createState() => _SideCaptureScreenState();
}

class _SideCaptureScreenState extends State<SideCaptureScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  String? _error;
  bool _denied = false; // camera access refused: the gallery is the way on
  bool _opening = false, _busy = false, _paused = false;
  int _at = 0; // the side being taken
  XFile? _shot; // taken, waiting for «Дұрыс»
  Uint8List? _shotBytes;

  String get _angle => widget.angles[_at];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Upright only: turned sideways the preview would stretch and the outline would no longer sit on the photo.
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(const []);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      final c = _controller;
      if (c == null) return;
      _paused = true;
      setState(() => _controller = null);
      c.dispose();
    } else if (state == AppLifecycleState.resumed && _paused && !_opening) {
      // Back from a call or another app: opened again. Only a camera this page closed itself: a refusal's own
      // dialog also pauses and resumes the app, and opening again then would ask again and again.
      _paused = false;
      _open();
    }
  }

  Future<void> _open() async {
    _opening = true;
    if (_error != null) setState(() => _error = null);
    CameraController? c;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('none', 'no camera');
      final back = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      // The main sides at 1920 on the long side, near the phone's own camera's 2000 and light on weak internet;
      // close-ups (sole, top, a seam, the size label) at the camera's best, as they were at 3000 before.
      final best = widget.angles.any(detailAngles.contains);
      c = CameraController(back, best ? ResolutionPreset.max : ResolutionPreset.veryHigh,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      await c.lockCaptureOrientation(DeviceOrientation.portraitUp).catchError((_) {});
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (e) {
      try {
        await c?.dispose();
      } catch (_) {}
      if (!mounted) return;
      // Any failure is said, never a spinner left turning. iOS names a refusal from before differently.
      _denied = e is CameraException && e.code.startsWith('CameraAccess');
      setState(() => _error = _denied
          ? tr('Камераға рұқсат берілмеді. Телефон баптауларынан рұқсат беріңіз.')
          : tr('Камераны ашу мүмкін болмады.'));
    } finally {
      _opening = false;
    }
  }

  Future<void> _take() async {
    final c = _controller;
    if (c == null || _busy || _shot != null) return;
    setState(() => _busy = true);
    try {
      final shot = await c.takePicture();
      final bytes = await shot.readAsBytes();
      if (!mounted) return;
      setState(() {
        _shot = shot;
        _shotBytes = bytes;
      });
    } catch (_) {
      // The camera closed mid-shot or the file did not read: said, and the shutter works again.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Фото түспеді, қайта басыңыз.'))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _keep() {
    final shot = _shot;
    if (shot == null) return;
    widget.onTaken(_angle, shot);
    if (_at == widget.angles.length - 1) {
      Navigator.pop(context, const SideCaptureResult());
      return;
    }
    setState(() {
      _at++;
      _shot = null;
      _shotBytes = null;
    });
  }

  void _retake() {
    final shot = _shot;
    setState(() {
      _shot = null;
      _shotBytes = null;
    });
    // A shot not kept leaves the phone: full-size photos would pile up in the app's files.
    if (shot != null && !kIsWeb) File(shot.path).delete().catchError((_) => File(shot.path));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _controller;
    final many = widget.angles.length > 1;
    final closeUp = detailAngles.contains(_angle);
    return PopScope(
      canPop: _shot == null,
      // Back on a shot being checked is «Қайта түсіру»; otherwise it leaves, the sides already kept staying in
      // the listing and the rest to be taken later.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _retake();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          systemOverlayStyle: SystemUiOverlayStyle.light,
          titleTextStyle: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
          // The side alone, so it is never cut; the count beside it.
          title: Text(tr(widget.labels[_angle] ?? ''), key: const Key('capture-side')),
          actions: [
            if (many)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                    child: Text('${_at + 1} / ${widget.angles.length}',
                        key: const Key('capture-count'),
                        style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70))),
              ),
          ],
        ),
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              // Said aloud by TalkBack each time it changes: the next side, or the check after a shot.
              child: Semantics(
                liveRegion: true,
                child: Text(
                    _shot == null
                        ? tr(sideHints[_angle] ?? '')
                        : closeUp
                            ? tr('Фото анық па?')
                            : tr('Фото анық па? Аяқкиім толық көрініп тұр ма?'),
                    key: const Key('capture-hint'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(color: Colors.white)),
              ),
            ),
            Expanded(
              child: _error != null
                  ? _failed(theme)
                  : _shotBytes != null
                      ? Image.memory(_shotBytes!,
                          fit: BoxFit.contain, cacheWidth: 1080, gaplessPlayback: true, key: const Key('capture-shot'))
                      : c == null
                          ? const Center(child: CircularProgressIndicator(color: Colors.white))
                          : Center(
                              child: AspectRatio(
                                // The preview's own shape, upright: the outline sits where the photo will be.
                                aspectRatio: 1 / c.value.aspectRatio,
                                child: Stack(fit: StackFit.expand, children: [
                                  CameraPreview(c),
                                  CustomPaint(painter: ShoeOutlinePainter(_angle)),
                                ]),
                              ),
                            ),
            ),
            Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 20), child: _actions(c)),
          ]),
        ),
      ),
    );
  }

  Widget _actions(CameraController? c) {
    if (_error != null) return const SizedBox.shrink();
    if (_shot != null) {
      final last = _at == widget.angles.length - 1;
      return Row(children: [
        Expanded(
          child: OutlinedButton(
              key: const Key('capture-retake'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                  minimumSize: const Size.fromHeight(56)),
              onPressed: _retake,
              child: Text(tr('Қайта түсіру'))),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
              key: const Key('capture-keep'),
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.white, foregroundColor: Colors.black, minimumSize: const Size.fromHeight(56)),
              onPressed: _keep,
              child: Text(last ? tr('Дайын') : tr('Дұрыс, келесі'))),
        ),
      ]);
    }
    return Center(
      child: Semantics(
        button: true,
        label: tr('Түсіру'),
        child: InkResponse(
          key: const Key('capture-shutter'),
          onTap: c == null || _busy ? null : _take,
          radius: 48,
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 5)),
            padding: const EdgeInsets.all(6),
            child: DecoratedBox(
                decoration: BoxDecoration(shape: BoxShape.circle, color: _busy ? Colors.white54 : Colors.white)),
          ),
        ),
      ),
    );
  }

  Widget _failed(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!,
                key: const Key('capture-error'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white)),
            const SizedBox(height: 16),
            // Not a dead end. Refused: the phone's own camera would be refused too, so the gallery. Otherwise the
            // phone's own camera still takes the photo, only without the outline.
            FilledButton(
                key: const Key('capture-fallback'),
                style: FilledButton.styleFrom(
                    backgroundColor: Colors.white, foregroundColor: Colors.black, minimumSize: const Size(48, 56)),
                onPressed: () => Navigator.pop(
                    context, SideCaptureResult(fallback: _denied ? ImageSource.gallery : ImageSource.camera)),
                child: Text(_denied ? tr('Галереядан таңдау') : tr('Телефон камерасымен түсіру'))),
            const SizedBox(height: 8),
            TextButton(
                key: const Key('capture-again'),
                style: TextButton.styleFrom(foregroundColor: Colors.white, minimumSize: const Size(48, 48)),
                onPressed: _opening ? null : _open,
                child: Text(tr('Қайта көру'))),
          ]),
        ),
      );
}

/// The shoe's outline for a side, dashed, in the middle of the frame: from the side a low shoe with its toe to the
/// left (outer) or right (inner); from the front or back a narrow upright shape; the sole and top a long oval.
/// Close-ups get only the frame's corners.
class ShoeOutlinePainter extends CustomPainter {
  ShoeOutlinePainter(this.angle);
  final String angle;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final path = outline(angle, size);
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 18) {
        canvas.drawPath(metric.extractPath(d, d + 10), paint);
      }
    }
  }

  static Path outline(String angle, Size size) {
    final w = size.width, h = size.height;
    switch (angle) {
      case 'outer':
      case 'inner':
        final p = _side(Rect.fromCenter(center: Offset(w / 2, h / 2), width: w * 0.86, height: w * 0.42));
        if (angle == 'outer') return p;
        return p.transform((Matrix4.identity()
              ..translateByDouble(w, 0, 0, 1)
              ..scaleByDouble(-1, 1, 1, 1))
            .storage);
      case 'front':
      case 'back':
        // A shoe from its toe or heel is about as tall as it is wide.
        final r = Rect.fromCenter(center: Offset(w / 2, h / 2), width: w * 0.56, height: w * 0.66);
        return Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.4)));
      case 'sole':
      case 'top':
        return Path()..addOval(Rect.fromCenter(center: Offset(w / 2, h / 2), width: w * 0.42, height: h * 0.78));
      default:
        final r = Rect.fromCenter(center: Offset(w / 2, h / 2), width: w * 0.7, height: w * 0.7);
        const k = 28.0;
        return Path()
          ..moveTo(r.left, r.top + k)
          ..lineTo(r.left, r.top)
          ..lineTo(r.left + k, r.top)
          ..moveTo(r.right - k, r.top)
          ..lineTo(r.right, r.top)
          ..lineTo(r.right, r.top + k)
          ..moveTo(r.right, r.bottom - k)
          ..lineTo(r.right, r.bottom)
          ..lineTo(r.right - k, r.bottom)
          ..moveTo(r.left + k, r.bottom)
          ..lineTo(r.left, r.bottom)
          ..lineTo(r.left, r.bottom - k);
    }
  }

  /// A low shoe seen from the side, toe to the left, filling [r].
  static Path _side(Rect r) {
    Offset at(double x, double y) => Offset(r.left + r.width * x, r.top + r.height * y);
    final p = Path()..moveTo(at(0.02, 0.86).dx, at(0.02, 0.86).dy);
    void curve(double x1, double y1, double x2, double y2, double x, double y) {
      final a = at(x1, y1), b = at(x2, y2), c = at(x, y);
      p.cubicTo(a.dx, a.dy, b.dx, b.dy, c.dx, c.dy);
    }

    curve(0.0, 0.62, 0.08, 0.5, 0.26, 0.42); // toe up to the laces
    curve(0.42, 0.34, 0.56, 0.08, 0.7, 0.04); // laces up to the collar
    curve(0.8, 0.0, 0.86, 0.08, 0.9, 0.04); // collar
    curve(0.97, 0.0, 1.0, 0.3, 0.99, 0.62); // heel
    curve(0.99, 0.86, 0.97, 1.0, 0.9, 1.0); // heel down to the sole
    p.lineTo(at(0.1, 1.0).dx, at(0.1, 1.0).dy); // sole
    curve(0.05, 1.0, 0.02, 0.94, 0.02, 0.86);
    return p..close();
  }

  @override
  bool shouldRepaint(ShoeOutlinePainter old) => old.angle != angle;
}
