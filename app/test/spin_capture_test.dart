// The camera page never keeps spinning: whatever fails is said, and it tries again when the person comes back.
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/screens/spin_capture_screen.dart';

class _Cameras extends CameraPlatform {
  _Cameras(this.answer);
  Future<List<CameraDescription>> Function() answer;
  int asked = 0;

  @override
  Future<List<CameraDescription>> availableCameras() {
    asked++;
    return answer();
  }
}

void main() {
  testWidgets('a platform failure that is not the camera\'s own is said, not spun on', (tester) async {
    final old = CameraPlatform.instance;
    addTearDown(() => CameraPlatform.instance = old);
    CameraPlatform.instance = _Cameras(() async => throw PlatformException(code: 'boom'));
    await tester.pumpWidget(const MaterialApp(home: SpinCaptureScreen()));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Камераны ашу мүмкін болмады.'), findsOneWidget);
  });

  testWidgets('back from the settings with camera access given, it opens again', (tester) async {
    final old = CameraPlatform.instance;
    addTearDown(() => CameraPlatform.instance = old);
    final cameras = _Cameras(() async => throw CameraException('CameraAccessDenied', 'no'));
    CameraPlatform.instance = cameras;
    await tester.pumpWidget(const MaterialApp(home: SpinCaptureScreen()));
    await tester.pump();
    expect(find.textContaining('Камераға рұқсат берілмеді'), findsOneWidget);
    cameras.answer = () async => const [];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(cameras.asked, 2);
    expect(find.textContaining('Камераға рұқсат берілмеді'), findsNothing);
    expect(find.text('Камераны ашу мүмкін болмады.'), findsOneWidget);
  });
}
