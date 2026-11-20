// 2026-11-19
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wavewiz/wave/kwi.dart';
import 'package:wavewiz/wave/kwv_index.dart';
import 'package:wavewiz/wave/ll2.dart';

// Real footage is optional: these tests skip when the sample folder is absent.
const sample = '/Users/adaminion/Movies/wave1113/c0042';

void main() {
  test('LL2 pixel offsets are a permutation of one row (2K and 4K)', () {
    for (final wl in [256, 512]) {
      final seen = <int>{};
      for (var c = 0; c < 4; c++) {
        for (var x = 0; x < wl; x++) {
          seen.add(ll2PixelOffset(x, c, wl));
        }
      }
      expect(seen.length, 4 * wl);
      expect(seen.reduce((a, b) => a > b ? a : b), 4 * wl - 1);
    }
  });

  final have = Directory(sample).existsSync();

  test('clip header parses', () {
    final clips = ClipInfo.findClips(sample);
    expect(clips, hasLength(1));
    final c = clips.single;
    expect([c.width, c.height], [2048, 1024]);
    expect(c.fps.round(), 1548);
    expect(c.shutterAngle.round(), 360);
    expect(c.colorTemp.round(), 5600);
  }, skip: !have);

  test('chunk index is contiguous and decodes LL2', () {
    final c = ClipInfo.findClips(sample).single;
    final idx = scanChunk(c.chunkPaths.first, maxFrames: 20);
    expect(idx.length, 20);
    for (var i = 1; i < idx.length; i++) {
      expect(idx.nFrame[i], idx.nFrame[i - 1] + 1);
    }
    final cur = FrameRef(c.chunkPaths.first, idx.offsets[5], idx.size0[5], idx.fifo0[5], idx.flag0[5]);
    final nx = FrameRef(c.chunkPaths.first, idx.offsets[6], idx.size0[6], idx.fifo0[6], idx.flag0[6]);
    final buf = readLl2Stream(cur, nx, c.width, c.height);
    final im = decodeLl2(buf, c.width, c.height, cur.fifo0, cur.flag0,
        matrix: c.colorMatrix);
    expect([im.width, im.height], [256, 128]);
    // A real scene is not flat: expect a wide spread of brightness values.
    final vals = <int>{for (var i = 0; i < im.rgba.length; i += 4) im.rgba[i + 1]};
    expect(vals.length, greaterThan(100));
  }, skip: !have);
}
