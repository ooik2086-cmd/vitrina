import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitrina/net_image_io.dart';
import 'package:vitrina/screens/onboarding_screen.dart';

/// Widget tests run on fake time, where real file reads never finish, so photos are not kept on disk in them;
/// test/net_image_test.dart gives the cache a folder of its own.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  KeptImage.folder = () async => null;
  setUp(forgetOnboardingPage); // each test meets the intro from its first page, as a fresh launch does
  await testMain();
}
