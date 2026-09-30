// Renders alternative ZRemote logo concepts side by side for comparison:
//   tool/preview/logo_variants.png
//
// A – refined flat mark (current): white Z + sky broadcast on flat dark
// B – premium depth: radial slate gradient, gradient glyph, sky→cyan signal
// C – emission: the Z's diagonal pierces the top-right corner as a blue beam
// D – orbit: thin ring around the Z with a sky arc + satellite dot
//
// Run: dart run tool/icon_preview.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart';

const _ss = 4;
const _out = 1024;

final _bg = ColorRgba8(0x16, 0x16, 0x16, 0xFF);
final _white = ColorRgba8(0xFF, 0xFF, 0xFF, 0xFF);
final _sky = ColorRgba8(0x0E, 0xA5, 0xE9, 0xFF);
final _skyMid = ColorRgba8(0x38, 0xBD, 0xF8, 0xFF);
final _skyLight = ColorRgba8(0x7D, 0xD3, 0xFC, 0xFF);
final _ring = ColorRgba8(0x3A, 0x41, 0x50, 0xFF);

void main() async {
  final glyph = (await decodePngFile('assets/icon/z_glyph.png'))!;
  final variants = <Image>[
    _variantA(),
    _variantB(),
    _variantC(),
    _variantD(glyph),
    _variantE(glyph),
  ];
  Directory('tool/preview').create(recursive: true);
  encodePngFile('tool/preview/logo_variants.png', _contactSheet(variants));
  encodePngFile('tool/preview/logo_D.png', _variantD(glyph));
  encodePngFile('tool/preview/logo_E.png', _variantE(glyph));
  stdout.writeln('preview written to tool/preview/');
}

// ---------------------------------------------------------------- variant A
// Refined flat mark (the current design).
Image _variantA() {
  final w = _out * _ss;
  final img = Image(width: w, height: w, numChannels: 4);
  fill(img, color: _bg);

  final s = w * 0.42, t = s * 0.215, zw = s * 0.86;
  final gap = t * 0.28, dotR = t * 0.50;
  final r1 = t * 1.02, r2 = t * 1.72, th = t * 0.42;

  final groupW = zw + gap + dotR + r2 + th / 2;
  final left = (w - groupW) / 2;
  final top = (w - s) / 2;

  _drawZ(img, left, top, left + zw, top + s, t, _white);
  _paintRadial(img, left + zw + gap + dotR, top + s - t / 2,
      dotR: dotR,
      dotColor: _sky,
      arcs: [_Arc(r1, th, -45, 84, _sky), _Arc(r2, th, -45, 84, _sky)]);
  return _shrink(img);
}

// ---------------------------------------------------------------- variant B
// Same composition as A, with depth: radial slate background, softly graded
// glyph, and a cyan→sky signal.
Image _variantB() {
  final w = _out * _ss;
  final img = Image(width: w, height: w, numChannels: 4);
  _fillRadialBg(img, _Pt(w * 0.42, w * 0.36), w * 0.78,
      ColorRgba8(0x24, 0x2C, 0x38, 0xFF), ColorRgba8(0x0D, 0x10, 0x15, 0xFF));

  final s = w * 0.42, t = s * 0.215, zw = s * 0.86;
  final gap = t * 0.28, dotR = t * 0.50;
  final r1 = t * 1.02, r2 = t * 1.72, th = t * 0.42;

  final groupW = zw + gap + dotR + r2 + th / 2;
  final left = (w - groupW) / 2;
  final top = (w - s) / 2;

  // Glyph via a mask so it can carry a subtle top-light gradient.
  final mask = Image(width: w, height: w, numChannels: 4);
  _drawZ(mask, left, top, left + zw, top + s, t, _white);
  final hi = _Pt(0xFF / 255, 0xFF / 255, 0xFF / 255);
  final lo = _Pt(0xD8 / 255, 0xE0 / 255, 0xEA / 255);
  for (var y = top.round(); y <= (top + s).round(); y++) {
    final f = ((y - top) / s).clamp(0.0, 1.0);
    final cr = ((hi.x + (lo.x - hi.x) * f) * 255).round();
    final cg = ((hi.y + (lo.y - hi.y) * f) * 255).round();
    final cb = ((hi.z + (lo.z - hi.z) * f) * 255).round();
    for (var x = 0; x < w; x++) {
      if (mask.getPixel(x, y).a > 0) img.setPixelRgba(x, y, cr, cg, cb, 255);
    }
  }

  _paintRadial(img, left + zw + gap + dotR, top + s - t / 2,
      dotR: dotR,
      dotColor: _skyLight,
      arcs: [
        _Arc(r1, th, -45, 84, _skyMid),
        _Arc(r2, th, -45, 84, _sky),
      ]);
  return _shrink(img);
}

// ---------------------------------------------------------------- variant C
// Emission: the diagonal continues past the Z's top-right corner as a blue
// beam with a signal burst — the glyph itself is transmitting.
Image _variantC() {
  final w = _out * _ss;
  final img = Image(width: w, height: w, numChannels: 4);
  fill(img, color: _bg);

  final s = w * 0.40, t = s * 0.215, zw = s * 0.86;
  final len = math.sqrt(zw * zw + s * s);
  final ux = zw / len, uy = -s / len; // beam direction: continuing the diagonal
  final beamAng = math.atan2(uy, ux);
  final beamLen = t * 1.15;
  final r1 = t * 1.00, r2 = t * 1.62, th = t * 0.44;

  // Compose in origin space first, then center the group's bounding box.
  final tip = _Pt(zw + ux * beamLen, uy * beamLen);
  final ext = r2 + th / 2;
  final maxX = tip.x + ext * math.cos(beamAng + 43 * math.pi / 180);
  final minY = tip.y - ext; // beam angle ≈ −49°, span reaches straight up
  final ox = (w - maxX) / 2;
  final oy = (w - (s - minY)) / 2 - minY;

  _drawZ(img, ox, oy, ox + zw, oy + s, t, _white);

  // Tapered beam: full stroke width at the corner, narrower round tip.
  final nx = s / len, ny = zw / len; // perpendicular of the beam
  final c0 = _Pt(ox + zw, oy);
  final tp = _Pt(c0.x + ux * beamLen, c0.y + uy * beamLen);
  _fillPoly(img, [
    _Pt(c0.x + nx * t / 2, c0.y + ny * t / 2),
    _Pt(tp.x + nx * t * 0.28, tp.y + ny * t * 0.28),
    _Pt(tp.x - nx * t * 0.28, tp.y - ny * t * 0.28),
    _Pt(c0.x - nx * t / 2, c0.y - ny * t / 2),
  ], _sky);
  _paintRadial(img, tp.x, tp.y,
      dotR: t * 0.28,
      dotColor: _sky,
      arcs: [
        _Arc(r1, th, beamAng * 180 / math.pi, 86, _sky),
        _Arc(r2, th, beamAng * 180 / math.pi, 86, _sky),
      ]);
  return _shrink(img);
}

// ---------------------------------------------------------------- variant D
// Orbit: the official ZCode glyph inside a thin slate ring; a sky arc trails
// behind a satellite dot in the upper-right quadrant.
Image _variantD(Image glyph) {
  final w = _out * _ss;
  final img = Image(width: w, height: w, numChannels: 4);
  fill(img, color: _bg);
  _paintOrbit(img, w);
  _compositeGlyph(img, glyph, w / 2, w / 2, w * 0.33, _white);
  return _shrink(img);
}

// ---------------------------------------------------------------- variant E
// Variant D on a premium radial slate gradient with a lighter ring.
Image _variantE(Image glyph) {
  final w = _out * _ss;
  final img = Image(width: w, height: w, numChannels: 4);
  _fillRadialBg(img, _Pt(w * 0.42, w * 0.36), w * 0.78,
      ColorRgba8(0x24, 0x2C, 0x38, 0xFF), ColorRgba8(0x0D, 0x10, 0x15, 0xFF));
  _paintOrbit(img, w, ring: ColorRgba8(0x4A, 0x53, 0x66, 0xFF));
  _compositeGlyph(img, glyph, w / 2, w / 2, w * 0.33, _white);
  return _shrink(img);
}

void _paintOrbit(Image img, int w, {ColorRgba8? ring}) {
  final cx = w / 2, cy = w / 2;
  final ringR = w * 0.385, ringTh = w * 0.048;
  _paintRadial(img, cx, cy,
      arcs: [_Arc(ringR, ringTh, 0, 360, ring ?? _ring)]);
  // Sky arc trailing behind the satellite dot.
  _paintRadial(img, cx, cy, arcs: [_Arc(ringR, ringTh, -72, 62, _sky)]);
  final dotA = -32 * math.pi / 180;
  _paintRadial(img, cx + ringR * math.cos(dotA), cy + ringR * math.sin(dotA),
      dotR: w * 0.062, dotColor: _sky, arcs: const []);
}

/// Alpha-composites the official Z mask, scaled to height [gh] and centered
/// at (cx, cy), tinted with [color].
void _compositeGlyph(
    Image img, Image glyph, double cx, double cy, double gh, ColorRgba8 color) {
  final scaled = copyResize(glyph,
      height: gh.round(),
      interpolation:
          gh > glyph.height ? Interpolation.cubic : Interpolation.average);
  final ox = (cx - scaled.width / 2).round();
  final oy = (cy - scaled.height / 2).round();
  for (var y = 0; y < scaled.height; y++) {
    final dy = oy + y;
    if (dy < 0 || dy >= img.height) continue;
    for (var x = 0; x < scaled.width; x++) {
      final dx = ox + x;
      if (dx < 0 || dx >= img.width) continue;
      final p = scaled.getPixel(x, y);
      final a = p.a.toInt();
      if (a == 0) continue;
      if (a >= 255) {
        img.setPixelRgba(dx, dy, color.r, color.g, color.b, 255);
        continue;
      }
      final d = img.getPixel(dx, dy);
      final ia = 255 - a;
      img.setPixelRgba(
          dx,
          dy,
          (color.r * a + d.r * ia) ~/ 255,
          (color.g * a + d.g * ia) ~/ 255,
          (color.b * a + d.b * ia) ~/ 255,
          255);
    }
  }
}

// --------------------------------------------------------------- primitives

class _Pt {
  final double x, y, z;
  const _Pt(this.x, this.y, [this.z = 0]);
}

class _Arc {
  final double r, th, centerDeg, spanDeg;
  final ColorRgba8 color;
  const _Arc(this.r, this.th, this.centerDeg, this.spanDeg, this.color);
}

Image _shrink(Image img) => copyResize(img,
    width: _out, height: _out, interpolation: Interpolation.average);

void _fillRadialBg(Image img, _Pt c, double maxR, ColorRgba8 in_, ColorRgba8 out_) {
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final dx = x - c.x, dy = y - c.y;
      final f = (math.sqrt(dx * dx + dy * dy) / maxR).clamp(0.0, 1.0);
      img.setPixelRgba(
          x,
          y,
          (in_.r + (out_.r - in_.r) * f).round(),
          (in_.g + (out_.g - in_.g) * f).round(),
          (in_.b + (out_.b - in_.b) * f).round(),
          255);
    }
  }
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

  final caps = <_Pt, ColorRgba8>{};
  for (final a in arcs) {
    if (a.spanDeg >= 360) continue;
    final center = a.centerDeg * math.pi / 180;
    final span = a.spanDeg * math.pi / 180;
    for (final sgn in [-1.0, 1.0]) {
      final ang = center + sgn * span / 2;
      caps[_Pt(a.r * math.cos(ang), a.r * math.sin(ang))] = a.color;
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
          final halfTh = arcs
              .firstWhere((a) => a.color == e.value,
                  orElse: () => arcs.first)
              .th / 2;
          if (ex * ex + ey * ey <= halfTh * halfTh) {
            hit = e.value;
            break;
          }
        }
      }
      if (hit != null) {
        img.setPixelRgba(x, y, hit.r, hit.g, hit.b, 255);
      }
    }
  }
}

void _drawZ(Image img, double left, double top, double right, double bottom,
    double t, ColorRgba8 color) {
  final s = bottom - top;
  final zw = right - left;
  var wd = t;
  for (var i = 0; i < 8; i++) {
    final run = zw - wd;
    wd = t * math.sqrt(s * s + run * run) / s;
  }
  final run = zw - wd;
  final kT = t / s;
  _fillPoly(img, [
    _Pt(left, top),
    _Pt(right, top),
    _Pt(right, top + t),
    _Pt(right - kT * run, top + t),
    _Pt(right - (1 - kT) * run, bottom - t),
    _Pt(right, bottom - t),
    _Pt(right, bottom),
    _Pt(left, bottom),
    _Pt(left, bottom - t),
    _Pt(left + kT * run, bottom - t),
    _Pt(left + (1 - kT) * run, top + t),
    _Pt(left, top + t),
  ], color);
}

void _fillPoly(Image img, List<_Pt> poly, ColorRgba8 color) {
  final n = poly.length;
  var ymin = double.infinity, ymax = double.negativeInfinity;
  for (final p in poly) {
    ymin = math.min(ymin, p.y);
    ymax = math.max(ymax, p.y);
  }
  final y0 = math.max(0, ymin.floor());
  final y1 = math.min(img.height - 1, ymax.ceil());
  for (var y = y0; y <= y1; y++) {
    final yc = y + 0.5;
    final xs = <double>[];
    for (var i = 0; i < n; i++) {
      final a = poly[i], b = poly[(i + 1) % n];
      if ((a.y <= yc && b.y > yc) || (b.y <= yc && a.y > yc)) {
        xs.add(a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x));
      }
    }
    xs.sort();
    for (var k = 0; k + 1 < xs.length; k += 2) {
      final xa = math.max(0, xs[k].floor());
      final xb = math.min(img.width - 1, xs[k + 1].ceil());
      for (var x = xa; x <= xb; x++) {
        img.setPixelRgba(x, y, color.r, color.g, color.b, 255);
      }
    }
  }
}

// ------------------------------------------------------------ contact sheet

Image _contactSheet(List<Image> variants) {
  const big = 176, small = 48, gut = 28, pad = 28;
  final n = variants.length;
  final sheet = Image(
      width: pad * 2 + n * big + (n - 1) * gut,
      height: pad + big + 16 + small + pad,
      numChannels: 4);
  fill(sheet, color: ColorRgba8(0xE9, 0xEB, 0xEE, 0xFF));
  for (var i = 0; i < n; i++) {
    final x = pad + i * (big + gut);
    final bi = copyResize(variants[i],
        width: big, height: big, interpolation: Interpolation.average);
    _pasteRounded(sheet, bi, x, pad, big * 0.225);
    final si = copyResize(variants[i],
        width: small, height: small, interpolation: Interpolation.average);
    _pasteRounded(sheet, si, x + (big - small) ~/ 2, pad + big + 16,
        small * 0.225);
  }
  return sheet;
}

void _pasteRounded(Image dst, Image src, int ox, int oy, double radius) {
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      if (!_insideRounded(x + 0.5, y + 0.5, src.width.toDouble(),
          src.height.toDouble(), radius)) {
        continue;
      }
      final p = src.getPixel(x, y);
      if (p.a > 0) {
        dst.setPixelRgba(ox + x, oy + y, p.r, p.g, p.b, 255);
      }
    }
  }
}

bool _insideRounded(double x, double y, double w, double h, double r) {
  final cx = x < r ? r : (x > w - r ? w - r : x);
  final cy = y < r ? r : (y > h - r ? h - r : y);
  final dx = x - cx, dy = y - cy;
  return dx * dx + dy * dy <= r * r;
}
