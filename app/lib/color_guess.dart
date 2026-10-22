import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;

import 'colors.dart';

/// A first guess at the shoe's colour from the seller's photo, so most sellers answer one question ("Көк пе?")
/// instead of looking through all the colours. Only a guess: the seller confirms it or picks another.
///
/// The photo is shrunk to 96 px. The background is the commonest colour along the edges; what differs from it is
/// the shoe. When most of the shoe is one hue, that hue is matched to the nearest listed colour; otherwise the shoe
/// is black, grey, white, or black-and-white by how light it is. Too little shoe, or a photo that cannot be
/// read, gives no guess.
Future<String?> guessShoeColor(Uint8List bytes) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    // The phone's decoder shrinks the photo as it reads it (the buffer is let go by the codec).
    codec = await ui.instantiateImageCodecWithSize(await ui.ImmutableBuffer.fromUint8List(bytes),
        getTargetSize: (w, h) =>
            w >= h ? ui.TargetImageSize(width: math.min(_side, w)) : ui.TargetImageSize(height: math.min(_side, h)));
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    // Some ten thousand pixels: worked through away from the screen, which is busy showing the new photo.
    return await compute(_guess, (data.buffer.asUint8List(), image.width, image.height));
  } catch (_) {
    return null; // not a photo the phone can read: the seller picks the colour as before
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

String? _guess((Uint8List, int, int) p) => guessFromPixels(p.$1, p.$2, p.$3);

const _side = 96;

/// The colours told apart by lightness alone, and those never guessed (two or many colours).
const _plain = {'қара', 'ақ', 'сұр', 'күміс', 'қара-ақ', 'түрлі түсті'};

typedef _Lab = (double l, double a, double b);

/// Where each coloured name sits as lightness, hue (degrees) and colourfulness: the picker's dots, and a few
/// colours real photos give that the dots do not (a lighter blue that is still "көк", a dusty pale pink, a
/// greyish navy).
final List<(String, double, double, double)> _anchors = [
  for (final MapEntry(:key, :value) in shoeColors.entries)
    if (!_plain.contains(key))
      if (_lab((value.r * 255).round(), (value.g * 255).round(), (value.b * 255).round())
          case (final l, final a, final b))
        (key, l, _hue(a, b), _chroma(a, b)),
  ('көк', 50, 250, 35),
  ('қызғылт', 70, 20, 14),
  ('қою көк', 25, 270, 20),
];

/// The guess for an image given as rows of RGBA bytes, [w] by [h]; null when the shoe is too little of it.
String? guessFromPixels(Uint8List rgba, int w, int h) {
  if (w < 4 || h < 4 || rgba.length < w * h * 4) return null;
  int at(int x, int y) => (y * w + x) * 4;

  // The background: the commonest coarse colour along the edges, when the edges are not see-through.
  final edge = <int>[
    for (var x = 0; x < w; x++) ...[at(x, 0), at(x, 1), at(x, h - 2), at(x, h - 1)],
    for (var y = 0; y < h; y++) ...[at(0, y), at(1, y), at(w - 2, y), at(w - 1, y)],
  ];
  final opaque = edge.where((i) => rgba[i + 3] > 128).toList();
  _Lab? background;
  if (opaque.length > edge.length * 0.5) {
    int coarse(int i) => (rgba[i] >> 4) << 8 | (rgba[i + 1] >> 4) << 4 | rgba[i + 2] >> 4;
    final counts = <int, int>{};
    for (final i in opaque) {
      counts.update(coarse(i), (n) => n + 1, ifAbsent: () => 1);
    }
    final top = counts.entries.reduce((m, e) => e.value > m.value ? e : m).key;
    final same = opaque.where((i) => coarse(i) == top).toList();
    double mean(int c) => same.fold(0, (s, i) => s + rgba[i + c]) / same.length;
    background = _lab(mean(0), mean(1), mean(2));
  }

  final shoe = <_Lab>[];
  for (var i = 0; i < w * h * 4; i += 4) {
    if (rgba[i + 3] < 128) continue;
    final q = _lab(rgba[i], rgba[i + 1], rgba[i + 2]);
    if (background != null && _distance(q, background) < 12) continue;
    shoe.add(q);
  }
  final n = shoe.length;
  if (n < w * h * 0.03) return null;

  // Mostly one hue: the hue (in 30° steps, with its neighbours) that most of the shoe has. Colourful, but of no one
  // hue (a many-coloured pair): no guess, rather than name it by the few plain parts.
  final colourful = [
    for (final q in shoe)
      if (_chroma(q.$2, q.$3) >= 7) q
  ];
  if (colourful.length >= 0.4 * n) {
    int bin(_Lab q) => _hue(q.$2, q.$3) ~/ 30;
    final bins = List.filled(12, 0);
    for (final q in colourful) {
      bins[bin(q)]++;
    }
    final top = bins.indexOf(bins.reduce(math.max));
    final near = [
      for (final q in colourful)
        if (math.min((bin(q) - top).abs(), 12 - (bin(q) - top).abs()) <= 1) q
    ];
    if (near.length >= 0.35 * n) {
      final l = _median([for (final q in near) q.$1]);
      final a = near.fold(0.0, (s, q) => s + q.$2) / near.length;
      final b = near.fold(0.0, (s, q) => s + q.$3) / near.length;
      return _nearest(l, _hue(a, b), _chroma(a, b));
    }
    return null;
  }

  // Black, white and the greys between, by lightness. Silver is a shine, not a lightness: it is never guessed.
  final lights = [
    for (final q in shoe)
      if (_chroma(q.$2, q.$3) < 7) q.$1
  ];
  final dark = lights.where((l) => l < 35).length / lights.length;
  final light = lights.where((l) => l > 75).length / lights.length;
  // Two-tone only when both halves are large: a black upper on a white sole is still a black shoe.
  if (dark >= 0.4 && light >= 0.4) return 'қара-ақ';
  final l = _median(lights);
  return l < 32 ? 'қара' : (l < 72 ? 'сұр' : 'ақ');
}

String _nearest(double l, double hue, double chroma) {
  var best = _anchors.first.$1;
  var bestDistance = double.infinity;
  for (final (name, l2, h2, c2) in _anchors) {
    final dh = (hue - h2).abs();
    final turn = math.min(dh, 360 - dh);
    final c = math.log(math.max(chroma, 1) / c2);
    final d = math.pow(turn / 18, 2) + math.pow((l - l2) / 14, 2) + c * c * 0.25;
    if (d < bestDistance) (bestDistance, best) = (d.toDouble(), name);
  }
  return best;
}

double _median(List<double> values) => (values..sort())[values.length ~/ 2];

double _hue(double a, double b) => (math.atan2(b, a) * 180 / math.pi) % 360;

double _chroma(double a, double b) => math.sqrt(a * a + b * b);

double _distance(_Lab p, _Lab q) =>
    math.sqrt(math.pow(p.$1 - q.$1, 2) + math.pow(p.$2 - q.$2, 2) + math.pow(p.$3 - q.$3, 2));

/// sRGB (0–255) to CIE Lab under D65.
_Lab _lab(num r, num g, num b) {
  double linear(num c) {
    final v = c / 255;
    return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  final (lr, lg, lb) = (linear(r), linear(g), linear(b));
  final x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047;
  final y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb;
  final z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883;
  double f(double t) => t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
  final (fx, fy, fz) = (f(x), f(y), f(z));
  return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
}
