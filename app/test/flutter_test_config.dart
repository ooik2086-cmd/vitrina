import 'dart:async';

import 'package:vitrina/net_image_io.dart';

/// Widget tests run on fake time, where real file reads never finish, so photos are not kept on disk in them;
/// test/net_image_test.dart gives the cache a folder of its own.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  KeptImage.folder = () async => null;
  await testMain();
}
