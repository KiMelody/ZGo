// One-off: extracts the official ZCode "Z" glyph from the installed app's
// icon into assets/icon/z_glyph.png (white on transparent, cropped tight).
// The installed icon is white-on-near-black, so per-pixel alpha is derived
// from luminance; tool/icon_gen.dart then re-colors and scales the mask.
// Run: dart run tool/extract_z.dart
import 'dart:io';

import 'package:image/image.dart';

const _src =
    r'E:\Users\chenr\AppData\Local\Programs\ZCode\resources\icon_windows.png';
// Measured by tool/measure_z.dart: white bbox on the 1024 canvas.
const _x0 = 161, _x1 = 863, _y0 = 214, _y1 = 810;
const _bgLum = 13; // official icon background luminance (#0D0D0D-ish)

void main() async {
  final img = (await decodePngFile(_src))!;
  final w = _x1 - _x0 + 1, h = _y1 - _y0 + 1;
  final mask = Image(width: w, height: h, numChannels: 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = img.getPixel(_x0 + x, _y0 + y);
      final a = (((p.r.toInt() - _bgLum) * 255) / (255 - _bgLum))
          .round()
          .clamp(0, 255);
      mask.setPixelRgba(x, y, 255, 255, 255, a);
    }
  }
  Directory('assets/icon').create(recursive: true);
  encodePngFile('assets/icon/z_glyph.png', mask);
  stdout.writeln('z_glyph.png written ($w x $h, aspect ${(w / h).toStringAsFixed(4)})');
}
