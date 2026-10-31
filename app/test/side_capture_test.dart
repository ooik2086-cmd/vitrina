// The guided camera for listing photos: each side in turn with its outline and words, a check after each shot,
// and a way out when the camera does not open.
import 'dart:async';
import 'dart:convert';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;
import 'package:vitrina/screens/listing_editor_screen.dart' show optionalAngles, requiredAngles;
import 'package:vitrina/screens/side_capture_screen.dart';

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

/// A phone camera that opens at once and gives a tiny photo for each shot.
class FakeCamera extends CameraPlatform {
  FakeCamera({this.fails});
  final Object? fails;
  int shots = 0, asked = 0;
  final _initialized = StreamController<CameraInitializedEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async {
    asked++;
    if (fails != null) throw fails!;
    return const [CameraDescription(name: 'back', lensDirection: CameraLensDirection.back, sensorOrientation: 90)];
  }

  @override
  Future<int> createCameraWithSettings(CameraDescription d, MediaSettings? s) async => 1;

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int id) => _initialized.stream;

  @override
  Stream<CameraErrorEvent> onCameraError(int id) => StreamController<CameraErrorEvent>().stream; // never fails

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() => const Stream.empty();

  @override
  Future<void> initializeCamera(int id, {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {
    scheduleMicrotask(() =>
        _initialized.add(const CameraInitializedEvent(1, 1280, 720, ExposureMode.auto, false, FocusMode.auto, false)));
  }

  @override
  Future<void> lockCaptureOrientation(int id, DeviceOrientation orientation) async {}

  @override
  Widget buildPreview(int id) => const ColoredBox(color: Colors.grey);

  @override
  Future<XFile> takePicture(int id) async {
    shots++;
    return XFile.fromData(base64Decode(_png), name: 'shot$shots.png', path: '/shot$shots.png');
  }

  @override
  Future<void> dispose(int id) async {}
}

void main() {
  late CameraPlatform old;
  setUp(() => old = CameraPlatform.instance);
  tearDown(() => CameraPlatform.instance = old);

  /// Opens the camera page from a screen underneath; [taken] records each side as it is confirmed.
  Future<SideCaptureResult? Function()> open(WidgetTester tester, List<String> angles,
      [Map<String, XFile>? taken]) async {
    SideCaptureResult? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async => result = await Navigator.of(context).push<SideCaptureResult>(MaterialPageRoute(
                    builder: (_) => SideCaptureScreen(
                        angles: angles,
                        labels: {...requiredAngles, ...optionalAngles},
                        onTaken: (a, p) => taken?[a] = p))),
                child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result;
  }

  Future<void> shoot(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('capture-shutter')));
    await tester.pumpAndSettle();
  }

  String side(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('capture-side'))).data!;

  testWidgets('each side in turn: its words, a check after the shot, each kept at once, «Дайын» at the end',
      (tester) async {
    CameraPlatform.instance = FakeCamera();
    final taken = <String, XFile>{};
    final result = await open(tester, ['front', 'outer'], taken);
    expect(side(tester), 'Алдынан');
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text(sideHints['front']!), findsOneWidget);
    await shoot(tester);
    expect(find.byKey(const Key('capture-shot')), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture-retake')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('capture-shot')), findsNothing, reason: 'retaken: the camera again, same side');
    expect(side(tester), 'Алдынан');
    await shoot(tester);
    expect(find.text('Дұрыс, келесі'), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture-keep')));
    await tester.pumpAndSettle();
    expect(taken.keys, ['front'], reason: 'sent on at once, not at the end');
    expect(taken['front']!.name, 'shot2.png', reason: 'the retake, not the first shot');
    expect(side(tester), 'Сырт бүйірі');
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text(sideHints['outer']!), findsOneWidget);
    await shoot(tester);
    expect(find.text('Дайын'), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture-keep')));
    await tester.pumpAndSettle();
    expect(taken.keys, ['front', 'outer']);
    expect(result()!.fallback, isNull);
  });

  testWidgets('back on a shot being checked takes it again; back otherwise leaves, kept sides staying', (tester) async {
    CameraPlatform.instance = FakeCamera();
    final taken = <String, XFile>{};
    final result = await open(tester, ['front', 'outer'], taken);
    await shoot(tester);
    await tester.tap(find.byKey(const Key('capture-keep')));
    await tester.pumpAndSettle();
    await shoot(tester);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('capture-shot')), findsNothing);
    expect(side(tester), 'Сырт бүйірі', reason: 'still on the page');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(SideCaptureScreen), findsNothing);
    expect(taken.keys, ['front']);
    expect(result(), isNull);
  });

  testWidgets('camera access refused: said, the gallery as the way on, and no asking again on return', (tester) async {
    final camera = FakeCamera(fails: CameraException('CameraAccessDenied', 'no'));
    CameraPlatform.instance = camera;
    final result = await open(tester, ['front']);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Камераға рұқсат берілмеді'), findsOneWidget);
    // The refusal's own dialog pauses and resumes the app: that must not open the camera (and ask) again.
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
    expect(camera.asked, 1);
    expect(find.text('Галереядан таңдау'), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture-fallback')));
    await tester.pumpAndSettle();
    expect(result()!.fallback, ImageSource.gallery);
  });

  testWidgets('a failure that is not about access: the phone\'s own camera, or try again', (tester) async {
    final camera = FakeCamera(fails: PlatformException(code: 'boom'));
    CameraPlatform.instance = camera;
    final result = await open(tester, ['outer']);
    expect(find.text('Камераны ашу мүмкін болмады.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture-again')));
    await tester.pumpAndSettle();
    expect(camera.asked, 2);
    await tester.tap(find.byKey(const Key('capture-fallback')));
    await tester.pumpAndSettle();
    expect(result()!.fallback, ImageSource.camera);
  });

  testWidgets('back from a call opens the camera again', (tester) async {
    final camera = FakeCamera();
    CameraPlatform.instance = camera;
    await open(tester, ['outer']);
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pumpAndSettle();
    expect(camera.asked, 2);
    expect(find.byKey(const Key('capture-shutter')), findsOneWidget);
  });

  testWidgets('a close-up asks only whether the photo is sharp', (tester) async {
    CameraPlatform.instance = FakeCamera();
    await open(tester, ['label']);
    await shoot(tester);
    expect(find.text('Фото анық па?'), findsOneWidget);
  });

  test('every side has an outline and plain words; the inner side is the outer one turned round', () {
    for (final a in ['front', 'outer', 'inner', 'back', 'sole', 'top', 'detail', 'label']) {
      expect(sideHints[a], isNotNull, reason: a);
      expect(ShoeOutlinePainter.outline(a, const Size(300, 400)).getBounds().isEmpty, isFalse, reason: a);
    }
    final outer = ShoeOutlinePainter.outline('outer', const Size(300, 400)).getBounds();
    final inner = ShoeOutlinePainter.outline('inner', const Size(300, 400)).getBounds();
    expect(inner.left, closeTo(300 - outer.right, 0.5));
  });
}
