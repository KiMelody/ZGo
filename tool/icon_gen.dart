// Generates the ZGo launcher icon set:
//   assets/icon/icon.png        – full-bleed 1024 icon (iOS + legacy Android)
//   assets/icon/icon_fg.png     – Android adaptive foreground (glyph + rim +
//                                 shortened reflection, transparent)
//   assets/icon/icon_bg.png     – Android adaptive background (field + halos,
//                                 opaque)
//   assets/icon/icon_mono.png   – Android 13 monochrome layer (silhouette)
//
// Design ("pocket-lit Z"): ZCode is a terminal tool — terminals are glowing
// text on a dark field, so ZGo carries that glow in the pocket. A white
// rounded Z (the Lgen2 glyph, extracted from the Seedream source and stored
// below as a 28-point normalized polygon) floats on a deep sky-tinted
// vertical gradient, lit by two halo layers (far sky-500, near sky-300) and a
// neon rim; a flipped, fading copy sits below the letter as its reflection.
//
// Composition order: field → far halo → near halo → glyph → reflection → rim.
// Vector parts are rasterized at 4x and box-downscaled (premultiplied alpha
// for transparent outputs so edges keep their color).
//
// The adaptive geometry is owned here, not by flutter_launcher_icons: the
// foreground inset is 0 in pubspec.yaml, so the bg halos and the fg glyph are
// generated at the same scale and stay locked to each other. The adaptive
// layers use glyph scale 0.71 (center lifted by 0.03·s) and a 0.14·s
// trapezoid reflection; everything with alpha ≥30 stays inside the 66/108 dp
// safe circle, r = 0.3056 of the canvas.
//
// Effect maps (halo/rim alpha) are computed natively at 1024 everywhere. A
// 512 parity mode kept icon.png byte-identical with the mock at first, but
// the 512 rim upscaled to the splash read soft on device, so it was dropped;
// icon.png now differs from the approved icon_vL6e.png by 7.8% of pixels,
// confined to the rim edge band, by design (measured max Δ83).
//
// Since task 11-19-splash-theme-follow the splash is a dual-theme two-stage
// composition (dark + light): stage 1 is the system splash icon
// (`ic_splash`, radial field converging to the splash bg at the mask circle,
// small glyph, no reflection); stage 2 is the full-bleed window background
// (`launch_art`, same field/glyph, halos spread wide, small reflection).
// Both ship under drawable-* (light) and drawable-night-* (dark). Parameters:
// .trellis/tasks/11-19-splash-theme-follow/research/splash-params.md.
//
// Run: dart run tool/icon_gen.dart   (then: dart run flutter_launcher_icons
// only when the launcher set changes)
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart';

const _ss = 4; // supersample factor for the vector parts
const _out = 1024;

final _white = ColorRgba8(0xFF, 0xFF, 0xFF, 0xFF);
final _sky500 = ColorRgba8(0x0E, 0xA5, 0xE9, 0xFF); // far halo
final _sky300 = ColorRgba8(0x7D, 0xD3, 0xFC, 0xFF); // near halo + rim
final _fieldTop = ColorRgba8(0x0E, 0x44, 0x68, 0xFF); // deep sky-tinted field
final _fieldBot = ColorRgba8(0x05, 0x1D, 0x30, 0xFF);

// L6e light strengths (final: validated in the 2026-11-18 mock round).
const _farStrength = 0.35;
const _nearStrength = 0.75;
const _reflA0 = 0.60;
const _rimStrength = 0.95;
// Crisp white edge kept under the rim: the glow ring starts this many px
// outside the glyph outline (at the native 1024 resolution).
const _rimCore = 4;
// Visual halo radii, expressed at the native 1024 resolution.
const _farBlur = 56;
const _nearBlur = 24;

// Adaptive geometry (PMA110 acceptance round 1). Safe zone: 66/108 dp circle
// → 0.3056 of the layer canvas. Glyph scale s = 0.71, center = 0.5 − 0.03·s;
// the reflection runs 0.14·s below a 0.02·s gap with a trapezoid alpha (0.55
// for the first 40%, then linear to 0). Worst-case bar-width radius at the
// alpha-30 cutoff is ≈0.405·s ≈ 0.288, and the rim tail stays inside the
// circle — verified by the PIL probe after generation.
const _fgScale = 0.71;
const _fgLift = 0.03; // glyph center = 0.5 − _fgLift × _fgScale
const _fgCenterY = 0.5 - _fgLift * _fgScale;
const _fgReflLen = 0.14; // × _fgScale × canvas
const _fgReflGap = 0.02; // × _fgScale × canvas
const _fgReflPeak = 0.55;
const _fgReflFlat = 0.40; // fraction of the reflection length at full alpha

/// The final glyph: Lgen2's Z extracted via OpenCV (extract_glyph.py),
/// normalized 0..1 of the Seedream canvas so composition is preserved.
final _glyph = <_Pt>[
  _Pt(0.68359, 0.26953),
  _Pt(0.66748, 0.26123),
  _Pt(0.65283, 0.25977),
  _Pt(0.31396, 0.26025),
  _Pt(0.30859, 0.26416),
  _Pt(0.30713, 0.34375),
  _Pt(0.31299, 0.35010),
  _Pt(0.53076, 0.35059),
  _Pt(0.54053, 0.35986),
  _Pt(0.53613, 0.37256),
  _Pt(0.30469, 0.66748),
  _Pt(0.29834, 0.68506),
  _Pt(0.29883, 0.70166),
  _Pt(0.30518, 0.71826),
  _Pt(0.31738, 0.73145),
  _Pt(0.33643, 0.73926),
  _Pt(0.68457, 0.73975),
  _Pt(0.69238, 0.73535),
  _Pt(0.69434, 0.66064),
  _Pt(0.68848, 0.65039),
  _Pt(0.47266, 0.64990),
  _Pt(0.46143, 0.64648),
  _Pt(0.45654, 0.63818),
  _Pt(0.46631, 0.61963),
  _Pt(0.69434, 0.33008),
  _Pt(0.69971, 0.31494),
  _Pt(0.69971, 0.29785),
  _Pt(0.69385, 0.28174),
];

/// Bottom edge of the glyph polygon (normalized), used to place the adaptive
/// reflection at a fixed gap below the letter.
final double _glyphMaxY = _glyph.map((p) => p.y).reduce(math.max);

// ------------------------------------------------------- splash dual-theme
// Authoritative parameter table (stage1/2 × light/dark): the task's
// research/splash-params.md, transcribed from the approved mock.

/// Glyph scale on both splash stages: small enough that the stage-1 halos
/// decay fully inside the 0.667 mask circle, and the stage-2 art re-uses the
/// identical geometry (same center; the ~1.78x enlarge comes from the
/// 512dp-vs-288dp canvas, accepted in the preview).
const _splashScale = 0.42;

/// Radial field converges to the splash bg at this normalized radius (of the
/// half canvas = the system mask circle), constant outside.
const _splashFieldR = 0.667;

/// Stage-2 reflection geometry (fractions of the canvas, both themes).
const _splashReflTop = 0.622;
const _splashReflLength = 0.085;

final _splashDarkCenter = ColorRgba8(0x0F, 0x47, 0x70, 0xFF);
final _splashDarkEdge = ColorRgba8(0x0A, 0x2D, 0x44, 0xFF);
final _splashLightCenter = ColorRgba8(0xE4, 0xF2, 0xFD, 0xFF);
final _splashLightEdge = ColorRgba8(0xD7, 0xEE, 0xFB, 0xFF);
final _splashCradle = ColorRgba8(0x08, 0x2F, 0x49, 0xFF); // sky-950

/// One halo layer: blur radius at the 1024 reference master (×2 on the 2048
/// stage-2 master), tint color and strength.
class _SplashHalo {
  final int blur;
  final ColorRgba8 color;
  final double strength;
  const _SplashHalo(this.blur, this.color, this.strength);
}

class _SplashTheme {
  final ColorRgba8 center;
  final ColorRgba8 edge;
  final List<_SplashHalo> stage1;
  final List<_SplashHalo> stage2;
  final double reflectionA0;
  const _SplashTheme({
    required this.center,
    required this.edge,
    required this.stage1,
    required this.stage2,
    required this.reflectionA0,
  });
}

/// Dark = the shipped language: deep-blue radial field, white Z, sky halos.
/// Stage-1 halo radii shrink with the glyph scale; stage-2 keeps the full
/// radii so the sky wash spreads across the whole background.
final _splashDark = _SplashTheme(
  center: _splashDarkCenter,
  edge: _splashDarkEdge,
  stage1: [
    _SplashHalo((56 * _splashScale).round(), _sky500, 0.30),
    _SplashHalo((24 * _splashScale).round(), _sky300, 0.75),
  ],
  stage2: [
    _SplashHalo(90, _sky500, 0.32),
    _SplashHalo(28, _sky300, 0.75),
  ],
  reflectionA0: 0.42,
);

/// Light = "pocket of night": light radial field, dark sky-950 cradle under
/// the same white Z, then the sky halo stack. Stage-2 only — the stage-1
/// splash is pinned brand-dark under both qualifiers (route B), so the
/// light theme carries no stage-1 halos.
final _splashLight = _SplashTheme(
  center: _splashLightCenter,
  edge: _splashLightEdge,
  stage1: const [],
  stage2: [
    _SplashHalo(110, _splashCradle, 0.80),
    _SplashHalo(56, _sky500, 0.28),
    _SplashHalo(28, _sky300, 0.55),
  ],
  reflectionA0: 0.40,
);

const _splashMaster = 1024;

/// Stage-2 master: 2048 so the 512dp ladder (512/768/1024/1536/2048) only
/// shrinks; blur radii double, fractions stay unchanged.
const _artMaster = 2048;

/// 288dp × density splash-icon ladder (spec icon-pipeline.md).
const _splashBuckets = {
  'mdpi': 288,
  'hdpi': 432,
  'xhdpi': 576,
  'xxhdpi': 864,
  'xxxhdpi': 1152,
};

/// 512dp × density stage-2 art ladder (display size starts at 512dp).
const _artBuckets = {
  'mdpi': 512,
  'hdpi': 768,
  'xhdpi': 1024,
  'xxhdpi': 1536,
  'xxxhdpi': 2048,
};

void main() {
  Directory('assets/icon').create(recursive: true);
  encodePngFile('assets/icon/icon.png', _composeFullBleed());
  encodePngFile('assets/icon/icon_fg.png', _composeForeground());
  encodePngFile('assets/icon/icon_bg.png', _composeBackground());
  encodePngFile(
      'assets/icon/icon_mono.png', _glyphLayer(_fgScale, centerY: _fgCenterY));
  // Splash, two stages (task 11-19-splash-theme-follow, route B):
  // stage-1 `ic_splash` (288dp × density ladder) is pinned brand-dark under
  // BOTH drawable and drawable-night — the system process resolves it from
  // the app theme before any in-process uiMode override can apply. Stage-2
  // `launch_art` (512dp × density ladder) is dual-theme: the window
  // background resolves in-process, after attachBaseContext applied the
  // in-app setting. The system scales the chosen stage-1 bucket to the 288dp
  // splash canvas (measured on PMA110: a 108dp bucket was upscaled 2.66x
  // and read soft; a density-less 1024 drawable was shrunk with no low-pass
  // and aliased).
  _writeSplashStage1();
  _writeSplashStage2(_splashLight, night: false);
  _writeSplashStage2(_splashDark, night: true);
  stdout.writeln('icons written to assets/icon/; splash art to res/');
}

/// Stage-1 brand-dark icon (1024 master) written to every density bucket
/// under both qualifier sets (identical bytes in drawable and drawable-night).
void _writeSplashStage1() {
  final stage1 = _composeSplashStage1(_splashDark);
  for (final q in ['', '-night']) {
    for (final b in _splashBuckets.entries) {
      _writeRes('drawable$q-${b.key}', 'ic_splash.png',
          _downscaleArea(stage1, b.value, b.value));
    }
  }
}

/// Stage-2 art (2048 master) for one theme, shrunk to every density bucket.
void _writeSplashStage2(_SplashTheme theme, {required bool night}) {
  final q = night ? '-night' : '';
  final stage2 = _composeSplashStage2(theme);
  for (final b in _artBuckets.entries) {
    _writeRes('drawable$q-${b.key}', 'launch_art.png',
        _downscaleArea(stage2, b.value, b.value));
  }
}

void _writeRes(String dir, String name, Image img) {
  final d = Directory('android/app/src/main/res/$dir')
    ..createSync(recursive: true);
  File('${d.path}/$name').writeAsBytesSync(encodePng(img));
}

// ---------------------------------------------------------------- renders

/// Stage-1 system splash icon (Android 12+ windowSplashScreenAnimatedIcon):
/// radial field converging to the splash bg at the mask circle, theme halos
/// computed from the scale-0.42 glyph mask (their radii shrink with the
/// scale, so effects end well inside the circle — no rim, no cutoff), then
/// the sharpened small glyph. No reflection: the full composition is the
/// stage-2 window background.
Image _composeSplashStage1(_SplashTheme theme) {
  final out = _radialField(theme.center, theme.edge, _splashMaster);
  for (final h in theme.stage1) {
    _tint(out, _glowAlpha(h.blur, _splashScale, res: _splashMaster),
        _splashMaster, h.color, h.strength);
  }
  _compositeOpaque(out, _sharpenAlpha(_splashGlyphLayer(_splashMaster)));
  return out;
}

/// Stage-2 full-bleed launch art (windowBackground): same field and small
/// glyph, but the theme halos keep their full radii — they spread across the
/// whole background from the small letter (the "light drawn on the
/// background" look the user chose). Small trapezoid reflection under the
/// glyph. No mask, no edge window.
Image _composeSplashStage2(_SplashTheme theme) {
  final out = _radialField(theme.center, theme.edge, _artMaster);
  for (final h in theme.stage2) {
    _tint(out, _glowAlpha(h.blur, _splashScale, res: _artMaster), _artMaster,
        h.color, h.strength);
  }
  final glyph = _sharpenAlpha(_splashGlyphLayer(_artMaster));
  _compositeOpaque(out, glyph); // glyph first — flipVertical is in-place
  _splashReflection(
    out,
    flipVertical(glyph.clone()),
    top: (_splashReflTop * _artMaster).round(),
    length: (_splashReflLength * _artMaster).round(),
    a0: theme.reflectionA0,
  );
  return out;
}

/// Radial field on an opaque [size]×[size] canvas: [center] at the middle,
/// lerped to [edge] (the splash bg) by t = clamp(r / [_splashFieldR]),
/// constant [edge] outside. Shape-identical to the system's circular splash
/// mask, so the field meets the mask edge at the SAME color in every
/// direction (a linear gradient gets sliced at the circle and reads as a
/// visible ring).
Image _radialField(ColorRgba8 center, ColorRgba8 edge, int size) {
  final img = Image(width: size, height: size, numChannels: 4);
  final c = size / 2.0;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = (x - c) / c, dy = (y - c) / c;
      final r = math.sqrt(dx * dx + dy * dy);
      final t = (r / _splashFieldR).clamp(0.0, 1.0);
      img.setPixelRgba(
          x,
          y,
          (center.r + (edge.r - center.r) * t).round(),
          (center.g + (edge.g - center.g) * t).round(),
          (center.b + (edge.b - center.b) * t).round(),
          255);
    }
  }
  return img;
}

/// Splash glyph raster: 8x supersampled polygon, box-averaged down to
/// [out]×[out], straight alpha — edge pixels are (255,255,255,a), never
/// premultiplied (spec icon-pipeline.md; an (a,a,a,a) write grays the edge on
/// the field). Accumulates one supersampled row at a time: the stage-2 2048
/// master would otherwise need a 16384² (1 GiB) transient image.
Image _splashGlyphLayer(int out) {
  const ss = 8;
  final w = out * ss;
  final poly = _glyphPoints(w, _splashScale);
  final img = Image(width: out, height: out, numChannels: 4);
  final coverage = List<int>.filled(out, 0);
  final xs = <double>[];
  for (var sy = 0; sy < w; sy++) {
    final yc = sy + 0.5;
    xs.clear();
    for (var i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      if ((a.y <= yc && b.y > yc) || (b.y <= yc && a.y > yc)) {
        xs.add(a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x));
      }
    }
    xs.sort();
    for (var k = 0; k + 1 < xs.length; k += 2) {
      final xa = math.max(0, xs[k].floor());
      final xb = math.min(w - 1, xs[k + 1].ceil());
      for (var x = xa; x <= xb; x++) {
        coverage[x ~/ ss]++;
      }
    }
    if (sy % ss != ss - 1) continue;
    final py = sy ~/ ss;
    for (var x = 0; x < out; x++) {
      final n = coverage[x];
      coverage[x] = 0;
      if (n == 0) continue;
      img.setPixelRgba(x, py, 255, 255, 255, n * 255 ~/ (ss * ss));
    }
  }
  return img;
}

/// Splash-only edge sharpening: remaps the glyph's ~2px antialiasing ramp
/// (4x supersampled raster) onto ~1px. The launcher keeps the full ramp —
/// smoother at its smaller display size — but the splash canvas renders at
/// 288dp where the 2px ramp reads as a soft edge (device round 8). Only the
/// alpha channel is remapped: the glyph layer is straight white, and
/// `_compositeOpaque`/`_reflectionOpaque` blend by the source color, so
/// writing a premultiplied (a,a,a,a) pixel here would drag the edge band
/// toward gray — a dark fringe on the deep field.
Image _sharpenAlpha(Image img) {
  int sharp(int c) {
    const lo = 0.28, hi = 0.72;
    final t = (c / 255.0 - lo) / (hi - lo);
    return (t.clamp(0.0, 1.0) * 255).round();
  }

  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final p = img.getPixel(x, y);
      if (p.a == 0 || p.a == 255) continue;
      img.setPixelRgba(x, y, 255, 255, 255, sharp(p.a.toInt()));
    }
  }
  return img;
}

/// Full-bleed L6e: the shipped reference composition. Effect maps render at
/// native 1024 (a 512 parity mode existed to stay pixel-identical with the
/// mock, but its upscaled rim read soft as the splash icon on device).
Image _composeFullBleed() {
  final out = _field();
  _tint(out, _glowAlpha(_farBlur, 1), _out, _sky500, _farStrength);
  _tint(out, _glowAlpha(_nearBlur, 1), _out, _sky300, _nearStrength);
  final glyph = _glyphLayer(1);
  _compositeOpaque(out, glyph); // glyph first — flipVertical is in-place
  _reflectionOpaque(out, flipVertical(glyph.clone()), _reflectionTop(),
      _reflA0, 0);
  _tint(out, _rimAlpha(1), _out, _sky300, _rimStrength);
  return out;
}

/// Adaptive foreground: transparent canvas, alpha-aware paths only — the
/// opaque `_tint` would punch dark halos outside the glyph.
Image _composeForeground() {
  final glyph = _glyphLayer(_fgScale, centerY: _fgCenterY);
  _reflectionAlpha(glyph, flipVertical(glyph.clone()), _fgReflectionTop(),
      _fgReflLen * _fgScale * _out, _fgReflPeak, _fgReflFlat);
  _rimOver(glyph, _rimAlpha(_fgScale, centerY: _fgCenterY), _out, _rimStrength);
  return glyph;
}

/// Adaptive background: the same halo layering as the full bleed, generated
/// from the SAME scaled glyph geometry so the glow stays under the letter.
Image _composeBackground() {
  final out = _field();
  _tint(out, _glowAlpha(_farBlur, _fgScale, centerY: _fgCenterY), _out,
      _sky500, _farStrength);
  _tint(out, _glowAlpha(_nearBlur, _fgScale, centerY: _fgCenterY), _out,
      _sky300, _nearStrength);
  return out;
}

/// Gradient field canvas.
Image _field() {
  final out = Image(width: _out, height: _out, numChannels: 4);
  for (var y = 0; y < _out; y++) {
    final k = y / (_out - 1);
    final r = _fieldTop.r + (_fieldBot.r - _fieldTop.r) * k;
    final g = _fieldTop.g + (_fieldBot.g - _fieldTop.g) * k;
    final b = _fieldTop.b + (_fieldBot.b - _fieldTop.b) * k;
    for (var x = 0; x < _out; x++) {
      out.setPixelRgba(x, y, r.round(), g.round(), b.round(), 255);
    }
  }
  return out;
}

/// Additively tint the image by a glow alpha map at [res] resolution. Opaque
/// canvases only — the adaptive foreground uses the straight-alpha paths
/// below.
void _tint(
    Image img, List<int> map, int res, ColorRgba8 c, double strength) {
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final ga =
          map[(y * res ~/ img.height) * res + (x * res ~/ img.width)];
      if (ga == 0) continue;
      final m = ga * strength / 255.0;
      final q = img.getPixel(x, y);
      img.setPixelRgba(x, y, (q.r + (c.r - q.r) * m).round(),
          (q.g + (c.g - q.g) * m).round(), (q.b + (c.b - q.b) * m).round(), 255);
    }
  }
}

/// Blurred glyph silhouette — halo source, alpha map at [res] resolution.
List<int> _glowAlpha(int radius, double scale,
    {double centerY = 0.5, int res = _out}) {
  final img = Image(width: res, height: res, numChannels: 4);
  _fillPoly(img, _glyphPoints(res, scale, centerY: centerY), _white);
  return _blurAlpha(img, radius * res ~/ _out, 2);
}

/// Solid glyph alpha at [res] resolution.
List<int> _solidAlpha(double scale, {double centerY = 0.5, int res = _out}) {
  final img = Image(width: res, height: res, numChannels: 4);
  _fillPoly(img, _glyphPoints(res, scale, centerY: centerY), _white);
  return [
    for (var y = 0; y < res; y++)
      for (var x = 0; x < res; x++) img.getPixel(x, y).a.toInt()
  ];
}

/// Edge band alpha: blur(glyph) − dilated(glyph), positive part. Dilating
/// the solid mask by [_rimCore] px keeps the glow ring off the letter, so
/// the glyph retains a hard white outline under the neon rim (an undilated
/// band tinted the edge itself, which read as blur on device).
List<int> _rimAlpha(double scale, {double centerY = 0.5, int res = _out}) {
  final blur = _glowAlpha(_nearBlur, scale, centerY: centerY, res: res);
  final core = _dilateAlpha(
      _solidAlpha(scale, centerY: centerY, res: res), res,
      _rimCore * res ~/ _out);
  return [
    for (var i = 0; i < blur.length; i++)
      blur[i] > core[i] ? blur[i] - core[i] : 0
  ];
}

/// Max-filter dilation of an alpha map with a square [_r]-radius window.
List<int> _dilateAlpha(List<int> a, int w, int r) {
  final h = a.length ~/ w;
  final tmp = List<int>.filled(a.length, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var m = 0;
      for (var d = -r; d <= r; d++) {
        final xx = x + d;
        if (xx < 0 || xx >= w) continue;
        final v = a[y * w + xx];
        if (v > m) m = v;
      }
      tmp[y * w + x] = m;
    }
  }
  final out = List<int>.filled(a.length, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var m = 0;
      for (var d = -r; d <= r; d++) {
        final yy = y + d;
        if (yy < 0 || yy >= h) continue;
        final v = tmp[yy * w + x];
        if (v > m) m = v;
      }
      out[y * w + x] = m;
    }
  }
  return out;
}

/// The glyph alone on a transparent layer, supersampled then
/// premultiplied-downscaled so AA edges keep their color. [ss] raises the
/// raster's gray levels on the edge band (the splash sharpens that band to
/// ~1px; with only the default 4x levels the diagonals read as a mix of
/// soft edge and stair steps on device).
Image _glyphLayer(double scale, {double centerY = 0.5, int ss = _ss}) {
  final w = _out * ss;
  final img = Image(width: w, height: w, numChannels: 4);
  _fillPoly(img, _glyphPoints(w, scale, centerY: centerY), _white);
  return _downscalePremultiplied(img, ss);
}

/// Flipped, vertically fading copy of [src] composited at [top] on an opaque
/// canvas — the full-bleed reflection. The flipped glyph still sits at its
/// mirrored (centered) position in [src], so the read starts at its first
/// non-zero row; alpha runs a0 → a1 from [top] to the canvas bottom.
void _reflectionOpaque(Image dst, Image src, int top, double a0, double a1) {
  final srcY0 = _firstGlyphRow(src);
  final span = dst.height - top;
  for (var y = srcY0; y < src.height; y++) {
    final yd = top + (y - srcY0);
    if (yd >= dst.height) break;
    final k = a0 + (a1 - a0) * (yd - top) / span;
    for (var x = 0; x < src.width; x++) {
      final p = src.getPixel(x, y);
      final sa = p.a.toInt();
      if (sa == 0) continue;
      final kk = sa / 255.0 * k;
      final q = dst.getPixel(x, yd);
      dst.setPixelRgba(x, yd, (q.r + (p.r - q.r) * kk).round(),
          (q.g + (p.g - q.g) * kk).round(), (q.b + (p.b - q.b) * kk).round(),
          255);
    }
  }
}

/// Stage-2 splash reflection on the opaque art: trapezoid fade over
/// [length] — flat at [a0] for the first 40%, then linear to 0 (params table
/// small-glyph geometry). Starts at the flipped glyph's first row.
void _splashReflection(Image dst, Image src,
    {required int top, required int length, required double a0}) {
  final srcY0 = _firstGlyphRow(src);
  final end = top + length;
  for (var y = srcY0; y < src.height; y++) {
    final yd = top + (y - srcY0);
    if (yd >= end || yd >= dst.height) break;
    final f = (yd - top) / length;
    final k = f <= 0.4 ? a0 : a0 * (1 - (f - 0.4) / 0.6);
    for (var x = 0; x < src.width; x++) {
      final p = src.getPixel(x, y);
      final sa = p.a.toInt();
      if (sa == 0) continue;
      final kk = sa / 255.0 * k;
      final q = dst.getPixel(x, yd);
      dst.setPixelRgba(x, yd, (q.r + (p.r - q.r) * kk).round(),
          (q.g + (p.g - q.g) * kk).round(), (q.b + (p.b - q.b) * kk).round(),
          255);
    }
  }
}

/// Alpha-aware reflection for the transparent adaptive layers: the glyph's
/// white is kept and only its alpha is scaled, then alpha-over composited.
/// [top] is the flipped glyph's first row; the fade is a trapezoid over
/// [length] — [peak] for the first [flat] fraction, then linear to 0.
void _reflectionAlpha(
    Image dst, Image src, int top, double length, double peak, double flat) {
  final srcY0 = _firstGlyphRow(src);
  final end = top + length;
  for (var y = srcY0; y < src.height; y++) {
    final yd = top + (y - srcY0);
    if (yd >= end) break;
    final f = (yd - top) / length;
    final k = f <= flat ? peak : peak * (1 - (f - flat) / (1 - flat));
    for (var x = 0; x < src.width; x++) {
      final p = src.getPixel(x, y);
      final sa = p.a.toInt();
      if (sa == 0) continue;
      final a = (sa * k).round();
      if (a == 0) continue;
      _blendOver(dst, x, yd, _white, a);
    }
  }
}

/// First row of [src] with any non-zero alpha (the flipped glyph's top edge).
int _firstGlyphRow(Image src) {
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      if (src.getPixel(x, y).a != 0) return y;
    }
  }
  return 0;
}

/// Neon rim on the transparent foreground: straight-alpha sky-300 layer,
/// alpha = rim map × strength, alpha-over composited.
void _rimOver(Image dst, List<int> map, int res, double strength) {
  for (var y = 0; y < dst.height; y++) {
    for (var x = 0; x < dst.width; x++) {
      final ga = map[(y * res ~/ _out) * res + (x * res ~/ _out)];
      if (ga == 0) continue;
      final sa = (ga * strength).round();
      if (sa == 0) continue;
      _blendOver(dst, x, y, _sky300, sa);
    }
  }
}

/// Alpha-over composite of a straight-alpha [color] onto a straight-alpha
/// canvas (empty or already filled).
void _blendOver(Image dst, int x, int y, ColorRgba8 c, int sa) {
  final q = dst.getPixel(x, y);
  final da = q.a.toInt();
  final s = sa / 255.0;
  final d = da / 255.0;
  final oa = s + d * (1 - s);
  if (oa <= 0) return;
  dst.setPixelRgba(
      x,
      y,
      ((c.r * s + q.r * d * (1 - s)) / oa).round(),
      ((c.g * s + q.g * d * (1 - s)) / oa).round(),
      ((c.b * s + q.b * d * (1 - s)) / oa).round(),
      (oa * 255).round());
}

/// Alpha-over composite of a straight-alpha layer onto an opaque image.
void _compositeOpaque(Image dst, Image src) {
  for (var y = 0; y < dst.height; y++) {
    for (var x = 0; x < dst.width; x++) {
      final p = src.getPixel(x, y);
      final sa = p.a.toInt();
      if (sa == 0) continue;
      final k = sa / 255.0;
      final q = dst.getPixel(x, y);
      dst.setPixelRgba(x, y, (q.r + (p.r - q.r) * k).round(),
          (q.g + (p.g - q.g) * k).round(), (q.b + (p.b - q.b) * k).round(), 255);
    }
  }
}

/// Top row of the full-bleed reflection: the mock's 0.76 mark.
int _reflectionTop() => (0.76 * _out).round();

/// Top row of the adaptive reflection: a fixed gap below the glyph bottom.
int _fgReflectionTop() {
  final bottom = _fgCenterY + (_glyphMaxY - 0.5) * _fgScale;
  return ((bottom + _fgReflGap * _fgScale) * _out).round();
}

/// Separable sliding-window box blur over the alpha channel only.
List<int> _blurAlpha(Image src, int r, int passes) {
  final w = src.width, h = src.height;
  var a = List<int>.filled(w * h, 0);
  final tmp = List<int>.filled(w * h, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      a[y * w + x] = src.getPixel(x, y).a.toInt();
    }
  }
  final div = 2 * r + 1;
  for (var p = 0; p < passes; p++) {
    for (var y = 0; y < h; y++) {
      var sum = 0;
      for (var k = -r; k <= r; k++) {
        sum += a[y * w + (k < 0 ? 0 : (k >= w ? w - 1 : k))];
      }
      for (var x = 0; x < w; x++) {
        tmp[y * w + x] = sum ~/ div;
        sum += a[y * w + (x + r + 1 >= w ? w - 1 : x + r + 1)] -
            a[y * w + (x - r < 0 ? 0 : x - r)];
      }
    }
    for (var x = 0; x < w; x++) {
      var sum = 0;
      for (var k = -r; k <= r; k++) {
        sum += tmp[(k < 0 ? 0 : (k >= h ? h - 1 : k)) * w + x];
      }
      for (var y = 0; y < h; y++) {
        a[y * w + x] = sum ~/ div;
        sum += tmp[(y + r + 1 >= h ? h - 1 : y + r + 1) * w + x] -
            tmp[(y - r < 0 ? 0 : y - r) * w + x];
      }
    }
  }
  return a;
}

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

/// Area-average downscale to arbitrary target sizes — a box-filter low-pass,
/// so shrinking does not alias (the system's bilinear shrink of a
/// density-less drawable does). Opaque canvases only: RGB is averaged
/// unpremultiplied.
Image _downscaleArea(Image src, int w, int h) {
  final out = Image(width: w, height: h, numChannels: 4);
  final px = src.width / w, py = src.height / h;
  for (var y = 0; y < h; y++) {
    final y0 = y * py, y1 = y0 + py;
    for (var x = 0; x < w; x++) {
      final x0 = x * px, x1 = x0 + px;
      var r = 0.0, g = 0.0, b = 0.0, wt = 0.0;
      for (var sy = y0.floor(); sy < y1.ceil() && sy < src.height; sy++) {
        final cy0 = sy > y0 ? sy.toDouble() : y0;
        final cy1 = sy + 1.0 < y1 ? sy + 1.0 : y1;
        for (var sx = x0.floor(); sx < x1.ceil() && sx < src.width; sx++) {
          final cx0 = sx > x0 ? sx.toDouble() : x0;
          final cx1 = sx + 1.0 < x1 ? sx + 1.0 : x1;
          final wgt = (cx1 - cx0) * (cy1 - cy0);
          if (wgt <= 0) continue;
          final p = src.getPixel(sx, sy);
          r += p.r * wgt;
          g += p.g * wgt;
          b += p.b * wgt;
          wt += wgt;
        }
      }
      out.setPixelRgba(x, y, (r / wt).round(), (g / wt).round(),
          (b / wt).round(), 255);
    }
  }
  return out;
}

// ---------------------------------------------------------------- geometry

class _Pt {
  final double x, y;
  const _Pt(this.x, this.y);
}

/// Glyph polygon in pixels of a [w]×[w] canvas, scaled about the center.
/// At scale 1 and centerY 0.5 this is the mock's plain `p.x * w` mapping.
List<_Pt> _glyphPoints(int w, double scale, {double centerY = 0.5}) => [
      for (final p in _glyph)
        _Pt((0.5 + (p.x - 0.5) * scale) * w,
            (centerY + (p.y - 0.5) * scale) * w)
    ];

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
