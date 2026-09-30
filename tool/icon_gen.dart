// Generates the ZGo launcher icon set:
//   assets/icon/icon.png      – full-bleed 1024 icon (iOS + legacy Android)
//   assets/icon/icon_fg.png   – transparent foreground for Android adaptive icons
//
// Design ("break through"): a self-drawn white Z — an equal-weight geometric
// letterform of our own geometry, not the extracted official glyph — whose
// diagonal continues up-right, exits a slate ring through a gap, and tips
// into a sky arrowhead: the letter itself is leaving ("ZCode — to go"). A
// small sky satellite dot on the ring's lower-left keeps the remote/orbit
// cue and balances the composition diagonally. Vector parts are rasterized
// at 4x and box-downscaled (premultiplied alpha for the transparent
// foreground so edges keep their color).
//
// Run: dart run tool/icon_gen.dart   (then: dart run flutter_launcher_icons)
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart';

const _ss = 4; // supersample factor for the vector parts
const _out = 1024;

final _bg = ColorRgba8(0x16, 0x16, 0x16, 0xFF); // official dark background
final _white = ColorRgba8(0xFF, 0xFF, 0xFF, 0xFF);
final _sky = ColorRgba8(0x0E, 0xA5, 0xE9, 0xFF); // official sky-500
// One step brighter than the old #3A4150: the ring vanished at 48px.
final _ring = ColorRgba8(0x47, 0x50, 0x5E, 0xFF);

void main() {
  Directory('assets/icon').create(recursive: true);
  encodePngFile('assets/icon/icon.png', _render(scale: 1.0, opaque: true));
  // Adaptive foreground: the whole composition must fit the center 66% safe
  // circle (radius 0.33W); the art's max radius is 0.443W (arrow apex).
  encodePngFile('assets/icon/icon_fg.png',
      _render(scale: 0.33 / 0.443, opaque: false));
  stdout.writeln('icons written to assets/icon/');
}

Image _render({required double scale, required bool opaque}) {
  final w = _out * _ss * 1.0;
  final img = Image(width: w.toInt(), height: w.toInt(), numChannels: 4);
  if (opaque) fill(img, color: _bg);
  final c = w / 2;
  final rR = 0.365 * w * scale, rTh = 0.048 * w * scale;
  final s = 0.40 * w * scale, zw = 0.34 * w * scale, t = 0.215 * s;
  final z = _buildZ(c - zw / 2, c - s / 2, zw, s, t);
  final u = z.diagUp;
  // Ring gap (~80°) centered on the diagonal's exit angle.
  final exitA = math.atan2(u.y, u.x) * 180 / math.pi;
  final a1 = exitA + 40, a0 = exitA - 40 + 360;
  final span = a0 - a1;
  _paintRadial(img, c, c, arcs: [_Arc(rR, rTh, a1 + span / 2, span, _ring)]);
  // The diagonal continues from under the top bar, through the gap, into a
  // sky arrowhead just past the ring.
  final m = _sub(z.diagTop, _Pt(c, c));
  final lam = 0.355 * w * scale - (m.x * u.x + m.y * u.y);
  final base = _add(z.diagTop, _mul(u, lam));
  _fillPoly(
      img,
      _segQuad(_sub(z.diagTop, _mul(u, 0.03 * w * scale)), base, t),
      _white);
  _fillPoly(img, _arrowHead(base, u, 0.088 * w * scale, 0.072 * w * scale),
      _sky);
  _fillPoly(img, z.poly, _white);
  // Satellite dot on the ring's lower-left (135°).
  final dotA = 135 * math.pi / 180;
  _paintRadial(img, c + rR * math.cos(dotA), c + rR * math.sin(dotA),
      dotR: 0.054 * w * scale, dotColor: _sky, arcs: const []);
  return opaque
      ? copyResize(img,
          width: _out, height: _out, interpolation: Interpolation.average)
      : _downscalePremultiplied(img, _ss);
}

// ---------------------------------------------------------------- geometry

class _Pt {
  final double x, y;
  const _Pt(this.x, this.y);
}

class _ZGeo {
  final List<_Pt> poly;
  final _Pt diagTop; // diagonal centerline at the top bar's underside
  final _Pt diagUp; // unit direction, ascending to the upper right
  const _ZGeo(this.poly, this.diagTop, this.diagUp);
}

_Pt _add(_Pt a, _Pt b) => _Pt(a.x + b.x, a.y + b.y);
_Pt _sub(_Pt a, _Pt b) => _Pt(a.x - b.x, a.y - b.y);
_Pt _mul(_Pt a, double k) => _Pt(a.x * k, a.y * k);
double _dot(_Pt a, _Pt b) => a.x * b.x + a.y * b.y;

_Pt _norm(_Pt a) {
  final l = math.sqrt(_dot(a, a));
  return _Pt(a.x / l, a.y / l);
}

_Pt _perp(_Pt a) => _Pt(-a.y, a.x);

/// Thick-segment quad from [a] to [b].
List<_Pt> _segQuad(_Pt a, _Pt b, double th) {
  final n = _mul(_perp(_norm(_sub(b, a))), th / 2);
  return [_add(a, n), _add(b, n), _sub(b, n), _sub(a, n)];
}

/// Solid triangular arrowhead with apex at [tip] pointing along unit [u].
List<_Pt> _arrowHead(_Pt tip, _Pt u, double len, double halfW) {
  final n = _perp(u);
  final base = _sub(tip, _mul(u, len));
  return [tip, _add(base, _mul(n, halfW)), _sub(base, _mul(n, halfW))];
}

/// Geometric Z with the diagonal's perpendicular weight equalized to [t]
/// (iterative fix-up), plus the diagonal's exit geometry for the
/// break-through continuation.
_ZGeo _buildZ(double left, double top, double zw, double s, double t) {
  final right = left + zw, bottom = top + s;
  var wd = t;
  for (var i = 0; i < 8; i++) {
    wd = t * math.sqrt(s * s + (zw - wd) * (zw - wd)) / s;
  }
  final run = zw - wd, kT = t / s;
  final poly = <_Pt>[
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
  ];
  final diagTop =
      _Pt((left + (1 - kT) * run + right - kT * run) / 2, top + t);
  final diagBot =
      _Pt((left + kT * run + right - (1 - kT) * run) / 2, bottom - t);
  return _ZGeo(poly, diagTop, _norm(_sub(diagTop, diagBot)));
}

// --------------------------------------------------------------- rendering

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
  final caps = <math.Point<double>, ColorRgba8>{};
  for (final a in arcs) {
    if (a.spanDeg >= 360) continue;
    final center = a.centerDeg * math.pi / 180;
    final span = a.spanDeg * math.pi / 180;
    for (final sgn in [-1.0, 1.0]) {
      final ang = center + sgn * span / 2;
      caps[math.Point(a.r * math.cos(ang), a.r * math.sin(ang))] = a.color;
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
              .firstWhere((a) => a.color == e.value, orElse: () => arcs.first)
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

/// Even-odd scanline polygon fill.
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

/// Box down scale on premultiplied alpha so transparent edges keep their color.
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
