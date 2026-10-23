import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Stands in for the phone's video player: each video made is remembered with what was asked of it, and opens at
/// once as a 9-second 720×1280 clip (or fails, with [fail]).
class FakeVideoPlatform extends VideoPlayerPlatform {
  final made = <String>[];
  final calls = <String>[];
  final _events = <int, StreamController<VideoEvent>>{};
  var _next = 0;
  bool fail = false;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _next++;
    made.add(options.dataSource.uri ?? '');
    final events = _events[id] = StreamController<VideoEvent>();
    scheduleMicrotask(() {
      if (fail) {
        events.addError(PlatformException(code: 'VideoError', message: 'no video'));
      } else {
        events.add(VideoEvent(
            eventType: VideoEventType.initialized, duration: const Duration(seconds: 9), size: const Size(720, 1280)));
      }
    });
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async => calls.add('seek ${position.inSeconds}');

  @override
  Future<Duration> getPosition(int playerId) async => const Duration(seconds: 3);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const ColoredBox(key: Key('fake-video'), color: Colors.grey);
}
