import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../i18n.dart';

/// Frame count that gives a smooth turn (one frame every 15°). The server accepts 8 or more.
const spinTargetFrames = 24;
const spinMinFrames = 8;

/// Guided capture of a 360° sequence: the seller turns the shoe (or walks around it) a little
/// between shots. The previous shot is shown faintly over the camera so each frame lines up.
/// Returns the frames in order, or null when cancelled.
class SpinCaptureScreen extends StatefulWidget {
  const SpinCaptureScreen({super.key});

  @override
  State<SpinCaptureScreen> createState() => _SpinCaptureScreenState();
}

class _SpinCaptureScreenState extends State<SpinCaptureScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  String? _error;
  bool _busy = false;
  final List<XFile> _frames = [];
  Uint8List? _lastBytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      c.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _open();
    }
  }

  Future<void> _open() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('none', 'no camera');
      final back = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      final c = CameraController(back, ResolutionPreset.high, enableAudio: false);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } on CameraException catch (e) {
      setState(() => _error = e.code == 'CameraAccessDenied'
          ? tr('Камераға рұқсат берілмеді. Телефон баптауларынан рұқсат беріңіз.')
          : tr('Камераны ашу мүмкін болмады.'));
    }
  }

  Future<void> _capture() async {
    final c = _controller;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      // Locking exposure and focus at the first frame keeps brightness from jumping between frames.
      if (_frames.isEmpty) {
        await c.setExposureMode(ExposureMode.locked).catchError((_) {});
        await c.setFocusMode(FocusMode.locked).catchError((_) {});
      }
      final shot = await c.takePicture();
      final bytes = await shot.readAsBytes();
      setState(() {
        _frames.add(shot);
        _lastBytes = bytes;
      });
    } on CameraException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Кадр түспеді, қайталаңыз.'))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _undo() async {
    if (_frames.isEmpty) return;
    _frames.removeLast();
    final bytes = _frames.isEmpty ? null : await _frames.last.readAsBytes();
    setState(() => _lastBytes = bytes);
  }

  /// Back with frames taken asks before throwing them away.
  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Кадрларды тастап шығу керек пе?')),
        content: Text(trf('Түсірілген {0} кадр сақталмайды.', [_frames.length])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Қалу'))),
          FilledButton(
              key: const Key('discard'), onPressed: () => Navigator.pop(context, true), child: Text(tr('Шығып кету'))),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final n = _frames.length;
    return PopScope(
      canPop: n == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(tr('360° түсіру')),
          actions: [
            TextButton(
              onPressed: n >= spinMinFrames ? () => Navigator.pop(context, List<XFile>.of(_frames)) : null,
              child: Text(trf('Дайын ({0})', [n]),
                  style: TextStyle(color: n >= spinMinFrames ? Colors.white : Colors.white38)),
            ),
          ],
        ),
        body: _error != null
            ? Center(
                child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, style: const TextStyle(color: Colors.white))))
            : c == null
                ? const Center(child: CircularProgressIndicator())
                : Column(children: [
                    Expanded(
                      child: Stack(fit: StackFit.expand, children: [
                        Center(child: CameraPreview(c)),
                        if (_lastBytes != null)
                          IgnorePointer(
                              child: Opacity(opacity: 0.35, child: Image.memory(_lastBytes!, fit: BoxFit.contain))),
                        Positioned(
                          left: 16,
                          right: 16,
                          top: 12,
                          child: Text(
                            n == 0
                                ? tr('Аяқкиімді жазық жерге қойып, бүйірінен түсіріңіз.')
                                : tr('Аяқкиімді сәл бұрып (шамамен 15°), алдыңғы кадрмен сәйкестендіріп түсіріңіз.'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
                          ),
                        ),
                      ]),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                          IconButton(
                            tooltip: tr('Соңғы кадрды өшіру'),
                            onPressed: n > 0 && !_busy ? _undo : null,
                            icon: const Icon(Icons.undo, color: Colors.white),
                          ),
                          Semantics(
                            button: true,
                            label: tr('Кадр түсіру'),
                            child: GestureDetector(
                              onTap: _capture,
                              child: SizedBox(
                                width: 84,
                                height: 84,
                                child: CustomPaint(
                                  painter: SpinProgressPainter(captured: n, target: spinTargetFrames),
                                  child: Center(
                                    child: Container(
                                      width: 60,
                                      height: 60,
                                      decoration: BoxDecoration(
                                          shape: BoxShape.circle, color: _busy ? Colors.white54 : Colors.white),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 48,
                            child: Text('$n/$spinTargetFrames',
                                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                          ),
                        ]),
                      ),
                    ),
                  ]),
      ),
    );
  }
}

/// Ring of [target] segments; captured ones are filled, so the seller sees how far round they are.
class SpinProgressPainter extends CustomPainter {
  SpinProgressPainter({required this.captured, required this.target});
  final int captured;
  final int target;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 3;
    final sweep = 2 * math.pi / target;
    for (var i = 0; i < target; i++) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.butt
        ..color = i < captured ? const Color(0xFF4CD964) : Colors.white24;
      canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius), -math.pi / 2 + i * sweep + 0.03, sweep - 0.06, false, paint);
    }
  }

  @override
  bool shouldRepaint(SpinProgressPainter old) => old.captured != captured || old.target != target;
}
