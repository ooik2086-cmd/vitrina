import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../i18n.dart';
import '../net_image.dart';
import 'blur_fill.dart';

/// "1:05" for a video's length or place in it.
String clockText(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// The seller's own video of the pair: its poster first, nothing downloaded until a tap on play; then the video with
/// a play/pause button, a bar to move through it and the time. [active] false (another tab shown) pauses it, keeping
/// its place.
class VideoPane extends StatefulWidget {
  const VideoPane(
      {super.key, required this.url, this.posterUrl, this.seconds, this.active = true, this.background = Colors.black});
  final String url;
  final String? posterUrl;
  final int? seconds;
  final bool active;
  final Color background;

  @override
  State<VideoPane> createState() => _VideoPaneState();
}

class _VideoPaneState extends State<VideoPane> {
  VideoPlayerController? _video;
  bool _failed = false;

  @override
  void didUpdateWidget(VideoPane old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _video?.dispose();
      _video = null;
      _failed = false;
    } else if (!widget.active && old.active) {
      _video?.pause();
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final video = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    setState(() {
      _video = video;
      _failed = false;
    });
    try {
      await video.initialize();
      if (!mounted || _video != video) return;
      // Switched to the 360° or the photos while it loaded: it waits, silent, for the Видео tab.
      if (widget.active) await video.play();
    } catch (_) {
      if (!mounted || _video != video) return;
      video.dispose();
      setState(() {
        _video = null;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    return ColoredBox(
      color: widget.background,
      child: Stack(fit: StackFit.expand, children: [
        // A video of any shape shows whole, on its own colours (see BlurFill) rather than on bars.
        if (widget.posterUrl != null) BlurFill(url: widget.posterUrl!),
        video == null
            ? _poster(context)
            : ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: video,
                builder: (context, v, _) => v.isInitialized
                    ? _playing(context, video, v)
                    : Stack(fit: StackFit.expand, children: [
                        _posterImage(),
                        const Center(child: CircularProgressIndicator(color: Colors.white)),
                      ]),
              ),
      ]),
    );
  }

  Widget _posterImage() => widget.posterUrl == null
      ? const SizedBox.shrink()
      : Image(
          image: netImage(widget.posterUrl!),
          fit: BoxFit.contain,
          excludeFromSemantics: true,
          errorBuilder: (_, __, ___) => const SizedBox.shrink());

  Widget _poster(BuildContext context) {
    final length = widget.seconds == null ? null : clockText(Duration(seconds: widget.seconds!));
    return Stack(fit: StackFit.expand, children: [
      _posterImage(),
      Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Material(
            color: Colors.black.withValues(alpha: 0.55),
            shape: const CircleBorder(),
            child: IconButton(
              key: const Key('video-play'),
              iconSize: 44,
              padding: const EdgeInsets.all(14),
              color: Colors.white,
              tooltip: length == null ? tr('Видеоны ойнату') : trf('Видеоны ойнату, {0}', [length]),
              onPressed: _start,
              icon: const Icon(Icons.play_arrow_rounded),
            ),
          ),
          if (_failed)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: DecoratedBox(
                decoration:
                    BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(tr('Видео ашылмады. Қайта басып көріңіз.'),
                      key: const Key('video-failed'), style: const TextStyle(color: Colors.white)),
                ),
              ),
            ),
        ]),
      ),
    ]);
  }

  Widget _playing(BuildContext context, VideoPlayerController video, VideoPlayerValue v) {
    final ended = v.position >= v.duration && !v.isPlaying;
    return Stack(fit: StackFit.expand, children: [
      Center(child: AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(video))),
      Positioned(
        left: 8,
        right: 8,
        bottom: 8,
        child: DecoratedBox(
          decoration:
              BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(24)),
          child: Row(children: [
            IconButton(
              key: const Key('video-toggle'),
              color: Colors.white,
              tooltip: v.isPlaying ? tr('Тоқтата тұру') : tr('Ойнату'),
              onPressed: () {
                if (v.isPlaying) {
                  video.pause();
                } else {
                  if (ended) video.seekTo(Duration.zero);
                  video.play();
                }
              },
              icon: Icon(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            Expanded(
              // A screen reader moves it 5 seconds at a time, as a slider.
              child: Semantics(
                slider: true,
                label: tr('Видео'),
                value: clockText(v.position),
                increasedValue: clockText(v.position + const Duration(seconds: 5)),
                decreasedValue: clockText(
                    v.position < const Duration(seconds: 5) ? Duration.zero : v.position - const Duration(seconds: 5)),
                onIncrease: () => video.seekTo(v.position + const Duration(seconds: 5)),
                onDecrease: () => video.seekTo(v.position - const Duration(seconds: 5)),
                child: VideoProgressIndicator(
                  video,
                  allowScrubbing: true,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  colors: const VideoProgressColors(
                      playedColor: Colors.white, bufferedColor: Colors.white38, backgroundColor: Colors.white24),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ExcludeSemantics(
                child: Text('${clockText(v.position)} / ${clockText(v.duration)}',
                    key: const Key('video-time'), maxLines: 1, style: const TextStyle(color: Colors.white)),
              ),
            ),
          ]),
        ),
      ),
    ]);
  }
}
