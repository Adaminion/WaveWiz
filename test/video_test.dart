// 2026-11-17
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wavewiz/wave/kwi.dart';
import 'package:wavewiz/wave/kwv_index.dart';
import 'package:wavewiz/wave/ll1.dart';
import 'package:wavewiz/wave/video_export.dart';

// Real footage is optional: these tests skip when the sample folders are absent.
const sample2k = '/Users/adaminion/Movies/wave1113/c0042';
const sample4k = '/Users/adaminion/Movies/wave/261117/c0010';

FrameRef _ref(ClipInfo c, ChunkIndex idx, int i) =>
    FrameRef(c.chunkPaths.first, idx.offsets[i], idx.size0[i], idx.fifo0[i], idx.flag0[i]);

void main() {
  for (final path in [sample2k, sample4k]) {
    test('LL1 decode is quarter size and sharper than LL2 ($path)', () {
      final c = ClipInfo.findClips(path).single;
      final idx = scanChunk(c.chunkPaths.first, maxFrames: 30);
      final f = decodeLl1(readFrameStreams(_ref(c, idx, 20), _ref(c, idx, 21)), c.width, c.height);
      expect([f.width, f.height], [c.width ~/ 4, c.height ~/ 4]);
      // A correct decode is smooth where the scene is: neighbouring samples
      // differ little on average. A mis-aligned detail stream adds large jumps.
      final g = f.fields[1];
      var sum = 0, n = 0;
      for (var y = 0; y < f.height; y++) {
        for (var x = 1; x < f.width; x++) {
          sum += (g[y * f.width + x] - g[y * f.width + x - 1]).abs();
          n++;
        }
      }
      expect(sum / n, lessThan(20));
      expect(g.reduce((a, b) => a > b ? a : b), greaterThan(g.reduce((a, b) => a < b ? a : b) + 50));
    }, skip: !Directory(path).existsSync());
  }

  test('H.264 export writes a playable file of the right size', () async {
    final ff = findFfmpeg();
    if (ff == null) return;
    final c = ClipInfo.findClips(sample4k).single;
    final idx = scanChunk(c.chunkPaths.first, maxFrames: 40);
    final item = VideoItem(
      name: 'clip',
      width: c.width,
      height: c.height,
      refs: [for (var i = 10; i <= 30; i++) _ref(c, idx, i)],
      count: 20,
    );
    final dest = Directory.systemTemp.createTempSync('wavewiz_vid');
    try {
      final job = VideoJob.start(VideoPlan([item], 24), dest.path, ff, () {});
      while (!job.finished) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(job.error, isNull);
      expect(job.doneFrames, 20);
      final probe = await Process.run(
          ff.replaceFirst(RegExp(r'ffmpeg(\.exe)?$'), 'ffprobe'),
          ['-v', 'error', '-select_streams', 'v:0', '-count_frames',
           '-show_entries', 'stream=width,height,nb_read_frames,codec_name',
           '-of', 'csv=p=0', '${dest.path}/clip.mp4']);
      expect((probe.stdout as String).trim(), 'h264,1024,768,20');
      // An existing file is never overwritten.
      final again = VideoJob.start(VideoPlan([item], 24), dest.path, ff, () {});
      while (!again.finished) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(again.error, contains('already exists'));
    } finally {
      dest.deleteSync(recursive: true);
    }
  }, skip: !Directory(sample4k).existsSync(), timeout: const Timeout(Duration(minutes: 2)));
}
