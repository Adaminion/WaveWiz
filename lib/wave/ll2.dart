// 2026-11-18
// LL2 (1/8-scale) preview decoding. LL2 is raw packed 10-bit data, LSB-first,
// 4 colour fields per pixel. See docs/HANDOFF.md and the pixel mapping in
// WAVE-Vivado hdmi_dark_frame.c (bitOffsetInLL2).
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'kwv_index.dart';

class Ll2Image {
  Ll2Image(this.rgba, this.width, this.height, this.lo, this.hi,
      [this.gr = 1.0, this.gb = 1.0]);
  final Uint8List rgba;
  final int width;
  final int height;
  final int lo; // black level used, in doubled 10-bit units (0..2046)
  final int hi; // white level used, same units
  final double gr; // white-balance gain applied to red (green = 1)
  final double gb; // white-balance gain applied to blue
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
/// If [lo]/[hi] are null they are derived from the image (0.5% / 99.5%).
/// Colour is a neutral preview: R, (G1+G2)/2, B, gamma 2.2.
Ll2Image decodeLl2(Uint8List buf, int w, int h, int fifo0, int flag0,
    {int? lo, int? hi, double? gr, double? gb}) {
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
  return rgbaFromDoubled(px, wl, hl, lo: lo, hi: hi, gr: gr, gb: gb);
}

/// Preview colour from [px] (r*2, g1+g2, b*2 per pixel, 0..2046): automatic
/// grey-world white balance (red/blue gains so their means match green)
/// unless [gr]/[gb] are given, levels from the histogram unless [lo]/[hi] are
/// given, then gamma 2.2.
Ll2Image rgbaFromDoubled(Uint16List px, int wl, int hl,
    {int? lo, int? hi, double? gr, double? gb}) {
  final n = wl * hl;
  if (gr == null || gb == null) {
    var sr = 0, sg = 0, sb = 0;
    for (var i = 0; i < n; i++) {
      sr += px[i * 3];
      sg += px[i * 3 + 1];
      sb += px[i * 3 + 2];
    }
    gr = sr == 0 ? 1.0 : (sg / sr).clamp(0.25, 4.0);
    gb = sb == 0 ? 1.0 : (sg / sb).clamp(0.25, 4.0);
  }
  if (gr != 1.0 || gb != 1.0) {
    for (var i = 0; i < n; i++) {
      px[i * 3] = math.min(2046, (px[i * 3] * gr).round());
      px[i * 3 + 2] = math.min(2046, (px[i * 3 + 2] * gb).round());
    }
  }
  var l = lo, hh = hi;
  if (l == null || hh == null) {
    final hist = Uint32List(2047);
    for (var i = 0; i < n * 3; i++) {
      hist[px[i]]++;
    }
    var mn = 0;
    while (mn < 2046 && hist[mn] == 0) {
      mn++;
    }
    final target = (px.length * 0.995).ceil();
    var acc = 0, p = 0;
    for (; p < 2047; p++) {
      acc += hist[p];
      if (acc >= target) break;
    }
    l = mn;
    hh = math.max(p, mn + 1);
  }
  final lut = Uint8List(2047);
  final span = (hh - l).toDouble();
  for (var i = 0; i < 2047; i++) {
    final t = ((i - l) / span).clamp(0.0, 1.0);
    lut[i] = (math.pow(t, 1 / 2.2) * 255).round();
  }
  final rgba = Uint8List(n * 4);
  for (var i = 0; i < n; i++) {
    rgba[i * 4] = lut[px[i * 3]];
    rgba[i * 4 + 1] = lut[px[i * 3 + 1]];
    rgba[i * 4 + 2] = lut[px[i * 3 + 2]];
    rgba[i * 4 + 3] = 255;
  }
  return Ll2Image(rgba, wl, hl, l, hh, gr, gb);
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
    {int? lo, int? hi, double? gr, double? gb}) {
  return Isolate.run(() {
    final buf = readLl2Stream(cur, next, w, h);
    return decodeLl2(buf, w, h, cur.fifo0, cur.flag0,
        lo: lo, hi: hi, gr: gr, gb: gb);
  });
}

/// Thumbnail for a clip: a frame near the start of the first chunk.
Future<Ll2Image> decodeThumbnail(String firstChunk, int w, int h) {
  return Isolate.run(() {
    final idx = scanChunk(firstChunk, maxFrames: 12);
    if (idx.length == 0) throw const FormatException('no frames');
    final k = math.min(8, idx.length - 1);
    FrameRef ref(int i) => FrameRef(firstChunk, idx.offsets[i], idx.size0[i],
        idx.fifo0[i], idx.flag0[i]);
    final cur = ref(k);
    final next = k + 1 < idx.length ? ref(k + 1) : null;
    final buf = readLl2Stream(cur, next, w, h);
    return decodeLl2(buf, w, h, cur.fifo0, cur.flag0);
  });
}
