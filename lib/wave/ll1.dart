// 2026-11-17
// Half-res (LL1) decoding: LL2 (raw) + LH2/HL2/HH2 (variable-length coded,
// quantised) -> inverse 2/6 wavelet (vertical, then horizontal) -> LL1 colour
// fields. LL1 is w/4 x h/4 per colour field (512x256 for a 2048x1024 clip).
// Format source: WAVE-Vivado (MIT, Shane W. Colton): decoder_4x16.v,
// dequantizer_4x16.v, idwt26_v2.v, idwt26_h2.v, HDMI_v1_0.v.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'kwi.dart';
import 'kwv_index.dart';
import 'll2.dart';

/// Raw bytes of codestreams 0..3 for one frame, plus where its data starts.
class FrameStreams {
  FrameStreams(this.streams, this.startBit, this.qHL2LH2, this.qHH2);
  final List<Uint8List> streams; // cs0..cs3: this frame's slice ++ next frame's slice
  final List<int> startBit; // bit offset of this frame's data in each stream
  final int qHL2LH2; // quantiser multiplier for HL2 and LH2
  final int qHH2; // quantiser multiplier for HH2
}

class _Header {
  _Header(this.sizes, this.fifo, this.flags, this.q2);
  final List<int> sizes;
  final List<int> fifo;
  final int flags;
  final int q2;
}

_Header _readHeader(RandomAccessFile raf, int offset) {
  raf.setPositionSync(offset);
  final b = raf.readSync(kHeaderSize);
  final d = ByteData.sublistView(b);
  return _Header(
    [for (var i = 0; i < 16; i++) d.getUint32(0x80 + 4 * i, Endian.little)],
    [for (var i = 0; i < 16; i++) d.getUint16(0xC0 + 2 * i, Endian.little)],
    d.getUint32(0x24, Endian.little),
    d.getUint32(0x34, Endian.little),
  );
}

/// Reads cs0..cs3 of [cur], each continued by the same stream of [next]
/// (the streams are continuous across frames).
FrameStreams readFrameStreams(FrameRef cur, FrameRef? next) {
  final raf = File(cur.path).openSync();
  RandomAccessFile? raf2;
  try {
    final h = _readHeader(raf, cur.offset);
    _Header? hn;
    if (next != null) {
      raf2 = next.path == cur.path ? raf : File(next.path).openSync();
      hn = _readHeader(raf2, next.offset);
    }
    final out = <Uint8List>[];
    var pos = cur.offset + kHeaderSize;
    var posN = next == null ? 0 : next.offset + kHeaderSize;
    for (var i = 0; i < 4; i++) {
      final n1 = h.sizes[i];
      final n2 = hn?.sizes[i] ?? 0;
      final buf = Uint8List(n1 + n2 + 16); // zero padding past the end
      raf.setPositionSync(pos);
      buf.setRange(0, n1, raf.readSync(n1));
      if (n2 > 0) {
        raf2!.setPositionSync(posN);
        buf.setRange(n1, n1 + n2, raf2.readSync(n2));
      }
      out.add(buf);
      pos += n1;
      posN += n2;
    }
    return FrameStreams(
      out,
      [for (var i = 0; i < 4; i++) h.fifo[i] + ((h.flags >> (16 + i)) & 1) * 64],
      h.q2 & 0xFFFF,
      h.q2 >>> 16,
    );
  } finally {
    raf.closeSync();
    if (raf2 != null && !identical(raf2, raf)) raf2.closeSync();
  }
}

/// Decoded LL1: four colour fields (R, G1, G2, B) of [width] x [height],
/// 10-bit-normalised samples (about 0..1023).
class Ll1Fields {
  Ll1Fields(this.fields, this.width, this.height);
  final List<Int16List> fields;
  final int width;
  final int height;
}

/// Decodes one variable-length stream (decoder_4x16.v + dequantizer_4x16.v)
/// into [rows] x 4 colours x [wl] values. The first [margin] values are
/// consumed and dropped.
Int16List _decodeVlc(Uint8List buf, int startBit, int margin, int wl, int hl,
    int qMult, Int32List invOff) {
  final qInv = qMult == 0 ? 0 : 65536 ~/ qMult;
  final total = margin + 4 * wl * hl;
  final out = Int16List(4 * wl * hl);
  final rowVals = 4 * wl;
  final limit = buf.length - 8;
  var bit = startBit;
  var p = 0; // value index in stream
  while (p < total) {
    final i = bit >> 3;
    if (i >= limit) break; // ran out of data: rest stays zero
    final v = buf[i] | (buf[i + 1] << 8) | (buf[i + 2] << 16) | (buf[i + 3] << 24);
    final sh = bit & 7;
    final low = (v >> sh) & 0xFF;
    // Trailing ones of the prefix byte select the width.
    int n, plen;
    if (low & 1 == 0) {
      n = 0;
      plen = 1;
    } else if (low & 2 == 0) {
      n = 2;
      plen = 2;
    } else if (low & 4 == 0) {
      n = 3;
      plen = 3;
    } else if (low & 8 == 0) {
      n = 4;
      plen = 4;
    } else if (low & 16 == 0) {
      n = 5;
      plen = 5;
    } else if (low & 32 == 0) {
      n = 6;
      plen = 6;
    } else if (low & 64 == 0) {
      n = 8;
      plen = 8;
    } else if (low & 128 == 0) {
      n = 10;
      plen = 8;
    } else {
      n = 14;
      plen = 8;
    }
    if (n == 0) {
      p += 4;
      bit += 1;
      continue;
    }
    var b = bit + plen;
    final mask = (1 << n) - 1;
    for (var k = 0; k < 4; k++) {
      final j = b >> 3;
      final w = buf[j] | (buf[j + 1] << 8) | (buf[j + 2] << 16) | (buf[j + 3] << 24);
      var q = (w >> (b & 7)) & mask;
      if (q >> (n - 1) != 0) q -= 1 << n; // two's complement
      b += n;
      final idx = p + k - margin;
      if (idx >= 0) {
        final dq = ((q * qInv + (q < 0 ? 255 : 0)) >> 8).toSigned(16);
        final row = idx ~/ rowVals;
        final o = invOff[idx - row * rowVals]; // (c << 16) | x
        out[((o >> 16) * hl + row) * wl + (o & 0xFFFF)] = dq;
      }
    }
    p += 4;
    bit += plen + 4 * n;
  }
  return out;
}

/// Decodes the LL1 colour fields of a frame. The variable-length streams have
/// the same start margin as LL2 (checked on real 2K and 4K footage; being 8
/// values off visibly breaks the picture).
Ll1Fields decodeLl1(FrameStreams fs, int w, int h) {
  final wl = w >> 3, hl = h >> 3;
  final rowVals = 4 * wl;
  final margin = ll2PxDiscard(wl);

  // Stream position -> (colour, x), as in the LL2 preview.
  final invOff = Int32List(rowVals);
  for (var c = 0; c < 4; c++) {
    for (var x = 0; x < wl; x++) {
      invOff[ll2PixelOffset(x, c, wl)] = (c << 16) | x;
    }
  }

  // LL2: raw 10-bit.
  final ll2 = Int16List(4 * wl * hl);
  {
    final buf = fs.streams[0];
    final start = fs.startBit[0] + 10 * margin;
    final bitsPerRow = 10 * rowVals;
    for (var y = 0; y < hl; y++) {
      final rowBit = start + y * bitsPerRow;
      for (var o = 0; o < rowVals; o++) {
        final bit = rowBit + o * 10;
        final i = bit >> 3;
        if (i + 3 >= buf.length) continue;
        final v = buf[i] | (buf[i + 1] << 8) | (buf[i + 2] << 16);
        final inv = invOff[o];
        ll2[((inv >> 16) * hl + y) * wl + (inv & 0xFFFF)] = (v >> (bit & 7)) & 0x3FF;
      }
    }
  }

  final vm = margin;
  final lh2 = _decodeVlc(fs.streams[1], fs.startBit[1], vm, wl, hl, fs.qHL2LH2, invOff);
  final hl2 = _decodeVlc(fs.streams[2], fs.startBit[2], vm, wl, hl, fs.qHL2LH2, invOff);
  final hh2 = _decodeVlc(fs.streams[3], fs.startBit[3], vm, wl, hl, fs.qHH2, invOff);

  final w1 = 2 * wl, h1 = 2 * hl;
  final fields = <Int16List>[];
  final lv = Int32List(h1 * wl); // vertical result, low-horizontal branch
  final hv = Int32List(h1 * wl); // vertical result, high-horizontal branch
  for (var c = 0; c < 4; c++) {
    final base = c * hl * wl;
    // Vertical inverse on columns: (LL2, LH2) -> lv, (HL2, HH2) -> hv.
    for (var y = 0; y < hl; y++) {
      final ya = y > 0 ? y - 1 : 0;
      final yb = y < hl - 1 ? y + 1 : hl - 1;
      for (var x = 0; x < wl; x++) {
        final i = base + y * wl + x;
        final ia = base + ya * wl + x;
        final ib = base + yb * wl + x;
        {
          final d2 = lh2[i] - ((ll2[ia] - ll2[ib] + 2) >> 2);
          final xe = ll2[i] - (d2 >> 1);
          lv[2 * y * wl + x] = xe;
          lv[(2 * y + 1) * wl + x] = xe + d2;
        }
        {
          final d2 = hh2[i] - ((hl2[ia] - hl2[ib] + 2) >> 2);
          final xe = hl2[i] - (d2 >> 1);
          hv[2 * y * wl + x] = xe;
          hv[(2 * y + 1) * wl + x] = xe + d2;
        }
      }
    }
    // Horizontal inverse along rows: (lv, hv) -> field.
    final f = Int16List(w1 * h1);
    for (var r = 0; r < h1; r++) {
      final row = r * wl;
      for (var x = 0; x < wl; x++) {
        final xa = x > 0 ? x - 1 : 0;
        final xb = x < wl - 1 ? x + 1 : wl - 1;
        final d2 = hv[row + x] - ((lv[row + xa] - lv[row + xb] + 2) >> 2);
        final xe = lv[row + x] - (d2 >> 1);
        f[r * w1 + 2 * x] = xe;
        f[r * w1 + 2 * x + 1] = xe + d2;
      }
    }
    fields.add(f);
  }
  return Ll1Fields(fields, w1, h1);
}

/// Neutral preview colour for LL1 fields (R, (G1+G2)/2, B; gamma 2.2).
Ll2Image ll1ToRgba(Ll1Fields f, {int? lo, int? hi}) {
  final n = f.width * f.height;
  final px = Uint16List(n * 3);
  int cl(int v) => v < 0 ? 0 : (v > 2046 ? 2046 : v);
  for (var i = 0; i < n; i++) {
    px[i * 3] = cl(f.fields[0][i] * 2);
    px[i * 3 + 1] = cl(f.fields[1][i] + f.fields[2][i]);
    px[i * 3 + 2] = cl(f.fields[3][i] * 2);
  }
  return rgbaFromDoubled(px, f.width, f.height, lo: lo, hi: hi);
}

/// Decodes frame [cur] to a half-res RGBA image off the UI isolate.
Future<Ll2Image> decodeFrameLl1(FrameRef cur, FrameRef? next, int w, int h,
    {int? lo, int? hi}) {
  return Isolate.run(() {
    final fs = readFrameStreams(cur, next);
    return ll1ToRgba(decodeLl1(fs, w, h), lo: lo, hi: hi);
  });
}
