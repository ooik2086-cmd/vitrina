import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../net_image.dart';

/// The picture itself, tiny, blurred and stretched over the whole frame. A photo or video shown whole in a frame of
/// another shape (a tall video on a wide stage, or the other way round) then stands on its own colours: nothing is
/// cut off and there are no black bars at its sides.
class BlurFill extends StatelessWidget {
  const BlurFill({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => ClipRect(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24, tileMode: TileMode.mirror),
          child: Image(
            image: ResizeImage(netImage(url), width: 48), // a blur needs no detail: decoded at 48 px wide
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
            excludeFromSemantics: true,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      );
}
