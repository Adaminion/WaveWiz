// 2026-11-17
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wavewiz/wave/kwi.dart';
import 'package:wavewiz/wave/kwv_index.dart';
import 'package:wavewiz/wave/ll2.dart';
import 'package:wavewiz/wave/offload.dart';
import 'package:wavewiz/wave/ranges.dart';

const sample = '/Users/adaminion/Movies/wave1113/c0042';

void main() {
  test('mergeRanges merges overlapping and adjacent', () {
    final m = mergeRanges(const [FrameRange(10, 20), FrameRange(0, 4), FrameRange(5, 7), FrameRange(15, 30), FrameRange(40, 41)]);
    expect([for (final r in m) (r.start, r.end)], [(0, 7), (10, 30), (40, 41)]);
  });

  test('offload copies two ranges (one across a chunk boundary) decodably', () async {
    final clip = ClipInfo.findClips(sample).single;
    final idx = ClipIndex(clip.chunkPaths.sublist(0, 2));
    for (var i = 0; i < 2; i++) {
      idx.put(i, scanChunk(clip.chunkPaths[i]));
    }
    final n0 = idx.chunks[0]!.length;
    final ranges = [FrameRange(n0 - 10, n0 + 10), const FrameRange(100, 119)];
    final plan = OffloadPlan(
      clipName: clip.name,
      kwiPath: clip.kwiPath,
      chunkLimit: 1 << 30,
      ranges: [for (final r in ranges) idx.runs(r.start, r.end + 1)],
    );
    final dest = Directory.systemTemp.createTempSync('wavewiz_test');
    try {
      final job = OffloadJob.start(plan, dest.path, () {});
      while (!job.finished) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(job.error, isNull);
      expect(job.outputs, hasLength(2));
      expect(job.doneBytes, plan.totalBytes);

      for (var r = 0; r < 2; r++) {
        final name = outputClipName(clip.name, r, 2);
        final outClip = ClipInfo.findClips('${dest.path}/$name').single;
        expect(File('${outClip.dir}/$name.kwi').readAsBytesSync(),
            File('${clip.dir}/${clip.name}.kwi').readAsBytesSync());
        final oi = ClipIndex(outClip.chunkPaths);
        for (var c = 0; c < outClip.chunkPaths.length; c++) {
          oi.put(c, scanChunk(outClip.chunkPaths[c]));
        }
        expect(oi.frameCount, ranges[r].length + 1); // + trailer frame
        // Camera frame numbers carried over unchanged.
        expect(oi.cameraFrameNumber(0), idx.cameraFrameNumber(ranges[r].start));
        // LL2 of the last wanted frame is identical to the source's.
        for (final k in [0, ranges[r].length - 1]) {
          final src = idx.frame(ranges[r].start + k)!;
          final srcNext = idx.frame(ranges[r].start + k + 1);
          final dst = oi.frame(k)!;
          final dstNext = oi.frame(k + 1);
          final a = readLl2Stream(src, srcNext, clip.width, clip.height);
          final b = readLl2Stream(dst, dstNext, clip.width, clip.height);
          expect(b, a);
        }
      }
    } finally {
      dest.deleteSync(recursive: true);
    }
  });

  test('offload refuses to overwrite an existing folder', () async {
    final clip = ClipInfo.findClips(sample).single;
    final idx = ClipIndex([clip.chunkPaths.first])..put(0, scanChunk(clip.chunkPaths.first, maxFrames: 30));
    final plan = OffloadPlan(
      clipName: clip.name,
      kwiPath: clip.kwiPath,
      chunkLimit: 1 << 30,
      ranges: [idx.runs(0, 5)],
    );
    final dest = Directory.systemTemp.createTempSync('wavewiz_test');
    try {
      Directory('${dest.path}/${outputClipName(clip.name, 0, 1)}').createSync();
      final job = OffloadJob.start(plan, dest.path, () {});
      while (!job.finished) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(job.error, contains('already exists'));
    } finally {
      dest.deleteSync(recursive: true);
    }
  });
}
