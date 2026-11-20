// 2026-11-19
// LL2 (1/8-scale) preview decoding. LL2 is raw packed 10-bit data, LSB-first,
// 4 colour fields per pixel. See docs/HANDOFF.md and the pixel mapping in
// WAVE-Vivado hdmi_dark_frame.c (bitOffsetInLL2).
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'kwv_index.dart';

class Ll2Image {
  Ll2Image(this.rgba, this.width, this.height, this.black);
  final Uint8List rgba;
  final int width;
  final int height;

  /// Black level used per colour (R, G, B), in doubled 10-bit units (0..2046).
  final List<double> black;
}

/// Pixel offset (in 10-bit units) within an LL2 row for pixel [x], colour [c].
int ll2PixelOffset(int x, int c, int wLL2) {
  final xs = (x + wLL2 - 1) % wLL2; // circular wrap of 1px
  if (wLL2 == 512) {
    // 4K mapping
    return (xs & 3) | (((xs >> 7) & 3) << 2) | (c << 4) | (((xs >> 2) & 0x1F) << 6);
  }
  // 2K mapping
  return (xs & 3) | (((xs >> 6) & 3) << 2) | (c << 4) | (((xs >> 2) & 0xF) << 6);
}

/// Pixels of margin before the first LL2 row in a frame's stream.
int ll2PxDiscard(int wLL2) => wLL2 == 512 ? 6336 : 3328;

/// Bytes of codestream 0 needed (from the frame's slice start) to decode LL2.
int ll2BytesNeeded(int w, int h, int fifo0, int flag0) {
  final wl = w >> 3, hl = h >> 3;
  final bits = fifo0 + flag0 * 64 + 10 * ll2PxDiscard(wl) + 10 * 4 * wl * hl;
  return (bits + 7) ~/ 8 + 4;
}

/// Decodes LL2 from [buf] (stream bytes starting at the frame's cs0 slice).
/// [matrix] is the clip's colour matrix; [black] see [rgbaFromDoubled].
Ll2Image decodeLl2(Uint8List buf, int w, int h, int fifo0, int flag0,
    {required List<double> matrix, List<double>? black}) {
  final wl = w >> 3, hl = h >> 3;
  final n = wl * hl;
  final start = fifo0 + flag0 * 64 + 10 * ll2PxDiscard(wl);
  final bitsPerRow = 10 * 4 * wl;
  final padded = Uint8List(buf.length + 4)..setRange(0, buf.length, buf);
  // Doubled domain: r*2, g1+g2, b*2 -> 0..2046.
  final px = Uint16List(n * 3);
  final xo = List.generate(4, (c) => Int32List.fromList(
      [for (var x = 0; x < wl; x++) ll2PixelOffset(x, c, wl) * 10]));
  int rd(int bit) {
    final i = bit >> 3;
    if (i + 2 >= padded.length) return 0;
    final v = padded[i] | (padded[i + 1] << 8) | (padded[i + 2] << 16);
    return (v >> (bit & 7)) & 0x3FF;
  }

  for (var y = 0; y < hl; y++) {
    final rowBit = start + y * bitsPerRow;
    for (var x = 0; x < wl; x++) {
      final r = rd(rowBit + xo[0][x]) * 2;
      final g = rd(rowBit + xo[1][x]) + rd(rowBit + xo[2][x]);
      final b = rd(rowBit + xo[3][x]) * 2;
      final o = (y * wl + x) * 3;
      px[o] = r;
      px[o + 1] = g;
      px[o + 2] = b;
    }
  }
  return rgbaFromDoubled(px, wl, hl, matrix: matrix, black: black);
}

/// Exposure applied before the display curve (matched against Wave Player).
const double kLookExposure = 0.85;

/// Display curve of the camera's own HDMI preview (G18M3, hdmi_lut1d.c):
/// gamma 1.8 with a short linear toe. Index = linear 0..1 in 8192 steps.
final Uint8List _displayCurve = () {
  final t = Uint8List(8192);
  for (var i = 0; i < t.length; i++) {
    final x = i / (t.length - 1);
    final y = x < 0.025746 ? 3.0 * x : 1.061793 * math.pow(x, 1 / 1.8) - 0.061793;
    t[i] = (y.clamp(0.0, 1.0) * 255).round();
  }
  return t;
}();

/// Colour preview from [px] (r*2, g1+g2, b*2 per pixel, 0..2046): subtract the
/// black level, apply the clip's 3x3 colour matrix (from the .kwi header, as
/// the camera does), then the display curve. [black] is derived from the
/// image (0.1% level of each colour) when null; pass the first frame's value
/// to keep a whole clip consistent.
Ll2Image rgbaFromDoubled(Uint16List px, int wl, int hl,
    {required List<double> matrix, List<double>? black}) {
  final n = wl * hl;
  var bl = black;
  if (bl == null) {
    bl = List<double>.filled(3, 0);
    final target = (n * 0.001).ceil();
    for (var c = 0; c < 3; c++) {
      final hist = Uint32List(2047);
      for (var i = 0; i < n; i++) {
        hist[px[i * 3 + c]]++;
      }
      var acc = 0, p = 0;
      for (; p < 2046; p++) {
        acc += hist[p];
        if (acc >= target) break;
      }
      bl[c] = p.toDouble();
    }
  }
  // Fold normalisation and exposure into the matrix.
  final s = [for (var c = 0; c < 3; c++) kLookExposure / (2046 - bl[c])];
  final m = [for (var i = 0; i < 9; i++) matrix[i] * s[i % 3]];
  final rgba = Uint8List(n * 4);
  const top = 8191;
  for (var i = 0; i < n; i++) {
    var r = px[i * 3] - bl[0], g = px[i * 3 + 1] - bl[1], b = px[i * 3 + 2] - bl[2];
    if (r < 0) r = 0;
    if (g < 0) g = 0;
    if (b < 0) b = 0;
    final ro = (m[0] * r + m[1] * g + m[2] * b) * top;
    final go = (m[3] * r + m[4] * g + m[5] * b) * top;
    final bo = (m[6] * r + m[7] * g + m[8] * b) * top;
    rgba[i * 4] = _displayCurve[ro < 0 ? 0 : (ro > top ? top : ro.toInt())];
    rgba[i * 4 + 1] = _displayCurve[go < 0 ? 0 : (go > top ? top : go.toInt())];
    rgba[i * 4 + 2] = _displayCurve[bo < 0 ? 0 : (bo > top ? top : bo.toInt())];
    rgba[i * 4 + 3] = 255;
  }
  return Ll2Image(rgba, wl, hl, bl);
}

/// Reads the stream bytes for frame [cur] (continuing into [next] if the frame's
/// own slice is too short, since cs0 is one continuous bitstream across frames).
Uint8List readLl2Stream(FrameRef cur, FrameRef? next, int w, int h) {
  final need = ll2BytesNeeded(w, h, cur.fifo0, cur.flag0);
  final out = Uint8List(need);
  var got = 0;
  void readFrom(FrameRef f, int count) {
    final raf = File(f.path).openSync();
    try {
      raf.setPositionSync(f.cs0Start);
      final b = raf.readSync(count);
      out.setRange(got, got + b.length, b);
      got += b.length;
    } finally {
      raf.closeSync();
    }
  }

  readFrom(cur, math.min(need, cur.size0));
  if (got < need && next != null) {
    readFrom(next, math.min(need - got, next.size0));
  }
  return out; // any unread tail stays zero (last frame of a clip)
}

/// Decodes one frame's LL2 preview off the UI isolate.
Future<Ll2Image> decodeFrameLl2(FrameRef cur, FrameRef? next, int w, int h,
    {required List<double> matrix, List<double>? black}) {
  return Isolate.run(() {
    final buf = readLl2Stream(cur, next, w, h);
    return decodeLl2(buf, w, h, cur.fifo0, cur.flag0,
        matrix: matrix, black: black);
  });
}

/// Thumbnail for a clip: a frame near the start of the first chunk.
Future<Ll2Image> decodeThumbnail(String firstChunk, int w, int h, List<double> matrix) {
  return Isolate.run(() {
    final idx = scanChunk(firstChunk, maxFrames: 12);
    if (idx.length == 0) throw const FormatException('no frames');
    final k = math.min(8, idx.length - 1);
    FrameRef ref(int i) => FrameRef(firstChunk, idx.offsets[i], idx.size0[i],
        idx.fifo0[i], idx.flag0[i]);
    final cur = ref(k);
    final next = k + 1 < idx.length ? ref(k + 1) : null;
    final buf = readLl2Stream(cur, next, w, h);
    return decodeLl2(buf, w, h, cur.fifo0, cur.flag0, matrix: matrix);
  });
}
