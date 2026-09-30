// Generates the ZRemote launcher icon set:
//   assets/icon/icon.png      – full-bleed 1024 icon (iOS + legacy Android)
//   assets/icon/icon_fg.png   – transparent foreground for Android adaptive icons
//
// Design ("orbit"): the official ZCode glyph — assets/icon/z_glyph.png,
// extracted from the installed app by tool/extract_z.dart — centered inside a
// thin slate ring. A sky-blue arc trails into a satellite dot in the
// upper-right quadrant: the "remote" cue. Vector parts are rasterized at 4x
// and box-downscaled; the glyph mask is area-downscaled from its 703px source
// and composited at final size, so both stay crisp.
//
// Run: dart run tool/icon_gen.dart   (then: dart run flutter_launcher_icons)
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart';

const _ss = 4; // supersample factor for the vector parts
const _out = 1024;

final _bg = ColorRgba8(0x16, 0x16, 0x16, 0xFF); // official dark background
final _ring = ColorRgba8(0x3A, 0x41, 0x50, 0xFF);
final _sky = ColorRgba8(0x0E, 0xA5, 0xE9, 0xFF); // official sky-500

void main() async {
  Directory('assets/icon').create(recursive: true);
  final glyph = (await decodePngFile('assets/icon/z_glyph.png'))!;

  encodePngFile(
      'assets/icon/icon.png',
      _render(glyph,
          opaque: true,
          ringR: 0.385,
          ringTh: 0.048,
          dotR: 0.062,
          glyphH: 0.33));
  // Adaptive foreground: the whole composition must fit the center 66% safe
  // circle (radius 0.33W), so the ring shrinks and the dot hugs it closer.
  encodePngFile(
      'assets/icon/icon_fg.png',
      _render(glyph,
          opaque: false,
          ringR: 0.278,
          ringTh: 0.038,
          dotR: 0.042,
          glyphH: 0.24));
  stdout.writeln('icons written to assets/icon/');
}

Image _render(Image glyph,
    {required bool opaque,
    required double ringR,
    required double ringTh,
    required double dotR,
    required double glyphH}) {
  final w = _out * _ss;
  final img = Image(width: w, height: w, numChannels: 4);
  if (opaque) fill(img, color: _bg);

  final c = w / 2;
  final rr = ringR * w, rth = ringTh * w;
  _paintRadial(img, c, c, arcs: [_Arc(rr, rth, 0, 360, _ring)]);
  // Sky arc trailing behind the satellite dot.
  _paintRadial(img, c, c, arcs: [_Arc(rr, rth, -72, 62, _sky)]);
  final dotA = -32 * math.pi / 180;
  _paintRadial(img, c + rr * math.cos(dotA), c + rr * math.sin(dotA),
      dotR: dotR * w, dotColor: _sky, arcs: const []);

  final base = opaque
      ? copyResize(img,
          width: _out, height: _out, interpolation: Interpolation.average)
      : _downscalePremultiplied(img, _ss);
  _compositeGlyph(base, glyph, _out / 2, _out / 2, glyphH * _out);
  return base;
}

class _Arc {
  final double r, th, centerDeg, spanDeg;
  final ColorRgba8 color;
  const _Arc(this.r, this.th, this.centerDeg, this.spanDeg, this.color);
}

/// Dot plus arc bands with round caps; [spanDeg] 360 draws a full ring.
void _paintRadial(Image img, double cx, double cy,
    {double dotR = 0, ColorRgba8? dotColor, required List<_Arc> arcs}) {
  var ext = dotR;
  for (final a in arcs) {
    ext = math.max(ext, a.r + a.th / 2);
  }
  ext += 2;
  final x0 = math.max(0, (cx - ext).floor());
  final x1 = math.min(img.width - 1, (cx + ext).ceil());
  final y0 = math.max(0, (cy - ext).floor());
  final y1 = math.min(img.height - 1, (cy + ext).ceil());

  // Round-cap endpoints, paired with their arc's half-thickness.
  final caps = <math.Point<double>, double>{};
  for (final a in arcs) {
    if (a.spanDeg >= 360) continue;
    final center = a.centerDeg * math.pi / 180;
    final span = a.spanDeg * math.pi / 180;
    for (final sgn in [-1.0, 1.0]) {
      final ang = center + sgn * span / 2;
      caps[math.Point(a.r * math.cos(ang), a.r * math.sin(ang))] =
          a.th / 2;
    }
  }

  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final dx = x + 0.5 - cx, dy = y + 0.5 - cy;
      final rr = math.sqrt(dx * dx + dy * dy);
      ColorRgba8? hit;
      if (dotColor != null && rr <= dotR) hit = dotColor;
      if (hit == null) {
        for (final a in arcs) {
          if ((rr - a.r).abs() > a.th / 2) continue;
          if (a.spanDeg >= 360) {
            hit = a.color;
            break;
          }
          var d = math.atan2(dy, dx) - a.centerDeg * math.pi / 180;
          while (d > math.pi) {
            d -= 2 * math.pi;
          }
          while (d < -math.pi) {
            d += 2 * math.pi;
          }
          if (d.abs() <= a.spanDeg * math.pi / 360) {
            hit = a.color;
            break;
          }
        }
      }
      if (hit == null) {
        for (final e in caps.entries) {
          final ex = dx - e.key.x, ey = dy - e.key.y;
          if (ex * ex + ey * ey <= e.value * e.value) {
            // Caps inherit their arc's color; all capped arcs here are sky.
            hit = _sky;
            break;
          }
        }
      }
      if (hit != null) img.setPixelRgba(x, y, hit.r, hit.g, hit.b, 255);
    }
  }
}

/// Scales the official glyph mask to height [gh] centered at (cx, cy) and
/// composites it in white with proper "over" blending.
void _compositeGlyph(
    Image img, Image glyph, double cx, double cy, double gh) {
  final scaled = copyResize(glyph,
      height: gh.round(), interpolation: Interpolation.average);
  final ox = (cx - scaled.width / 2).round();
  final oy = (cy - scaled.height / 2).round();
  for (var y = 0; y < scaled.height; y++) {
    final dy = oy + y;
    if (dy < 0 || dy >= img.height) continue;
    for (var x = 0; x < scaled.width; x++) {
      final dx = ox + x;
      if (dx < 0 || dx >= img.width) continue;
      final sa = scaled.getPixel(x, y).a.toInt() / 255.0;
      if (sa == 0) continue;
      final d = img.getPixel(dx, dy);
      final da = d.a.toInt() / 255.0;
      final outA = sa + da * (1 - sa);
      if (outA <= 0) continue;
      int ch(num dc) =>
          ((255 * sa + dc * da * (1 - sa)) / outA).round().clamp(0, 255);
      img.setPixelRgba(
          dx, dy, ch(d.r), ch(d.g), ch(d.b), (outA * 255).round());
    }
  }
}

/// Box downscale on premultiplied alpha so transparent edges keep their color.
Image _downscalePremultiplied(Image src, int f) {
  final out =
      Image(width: src.width ~/ f, height: src.height ~/ f, numChannels: 4);
  for (var y = 0; y < out.height; y++) {
    for (var x = 0; x < out.width; x++) {
      var r = 0, g = 0, b = 0, a = 0;
      for (var dy = 0; dy < f; dy++) {
        for (var dx = 0; dx < f; dx++) {
          final p = src.getPixel(x * f + dx, y * f + dy);
          final pa = p.a.toInt();
          a += pa;
          r += p.r.toInt() * pa;
          g += p.g.toInt() * pa;
          b += p.b.toInt() * pa;
        }
      }
      if (a == 0) {
        out.setPixelRgba(x, y, 0, 0, 0, 0);
      } else {
        out.setPixelRgba(x, y, r ~/ a, g ~/ a, b ~/ a, a ~/ (f * f));
      }
    }
  }
  return out;
}
