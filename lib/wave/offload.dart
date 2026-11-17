// 2026-11-17
// Trimmed offload: copies chosen frame ranges, byte for byte, into new
// camera-native clips (one clip folder per range). Sources are only read.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'kwv_index.dart';

class OffloadPlan {
  OffloadPlan({
    required this.clipName,
    required this.kwiPath,
    required this.chunkLimit,
    required this.ranges,
  });

  final String clipName;
  final String kwiPath;

  /// Output chunk size limit in bytes (frames are never split across chunks).
  final int chunkLimit;

  /// One entry per output clip: the runs of frames to copy.
  final List<List<RunData>> ranges;

  int get totalBytes => ranges.fold(
      0, (a, r) => a + r.fold(0, (b, run) => b + run.lengths.fold(0, (c, l) => c + l)));
  int get totalFrames =>
      ranges.fold(0, (a, r) => a + r.fold(0, (b, run) => b + run.lengths.length));
}

String outputClipName(String clip, int i, int count) =>
    '${clip}_r${(i + 1).toString().padLeft(count > 99 ? 3 : 2, '0')}';

class OffloadJob {
  OffloadJob._();

  /// Bytes copied so far.
  int doneBytes = 0;
  final List<String> outputs = [];
  String? error;
  bool finished = false;
  bool cancelled = false;
  Isolate? _iso;
  ReceivePort? _rp;

  /// Starts copying [plan] into [dest]. [onUpdate] fires on every change.
  static OffloadJob start(OffloadPlan plan, String dest, void Function() onUpdate) {
    final job = OffloadJob._();
    final rp = ReceivePort();
    job._rp = rp;
    rp.listen((m) {
      if (m == null) {
        job.finished = true;
        rp.close();
      } else if (m is int) {
        job.doneBytes = m;
      } else if (m is String && m.startsWith('out:')) {
        job.outputs.add(m.substring(4));
      } else if (m is String) {
        job.error = m;
        job.finished = true;
        rp.close();
      }
      onUpdate();
    });
    Isolate.spawn(_worker, [rp.sendPort, plan, dest]).then((i) {
      if (job.cancelled) {
        i.kill(priority: Isolate.immediate);
      } else {
        job._iso = i;
      }
    }, onError: (Object e) {
      job.error = '$e';
      job.finished = true;
      onUpdate();
    });
    return job;
  }

  /// Stops copying. Already-written output folders are left in place.
  void cancel() {
    cancelled = true;
    finished = true;
    _iso?.kill(priority: Isolate.immediate);
    _rp?.close();
  }
}

const int _maxBurst = 16 << 20;

void _worker(List<Object> a) {
  final port = a[0] as SendPort;
  final plan = a[1] as OffloadPlan;
  final dest = a[2] as String;
  try {
    var done = 0;
    var buf = Uint8List(_maxBurst);
    for (var r = 0; r < plan.ranges.length; r++) {
      final name = outputClipName(plan.clipName, r, plan.ranges.length);
      final dir = Directory('$dest/$name');
      if (dir.existsSync()) throw FileSystemException('Folder already exists', dir.path);
      dir.createSync(recursive: true);
      File(plan.kwiPath).copySync('${dir.path}/$name.kwi');

      var chunkNo = 0, written = 0, frames = 0;
      RandomAccessFile? out;
      final chunkFiles = <String>[];
      for (final run in plan.ranges[r]) {
        final src = File(run.path).openSync();
        try {
          final n = run.lengths.length;
          var i = 0;
          while (i < n) {
            var j = i;
            var burst = run.lengths[i];
            if (out != null && written > 0 && written + burst > plan.chunkLimit) {
              out.closeSync();
              out = null;
            }
            if (out == null) {
              final p = '${dir.path}/f${(chunkNo++).toString().padLeft(6, '0')}.kwv';
              chunkFiles.add(p);
              out = File(p).openSync(mode: FileMode.write);
              written = 0;
            }
            while (j + 1 < n &&
                run.offsets[j + 1] == run.offsets[j] + run.lengths[j] &&
                burst + run.lengths[j + 1] <= _maxBurst &&
                written + burst + run.lengths[j + 1] <= plan.chunkLimit) {
              j++;
              burst += run.lengths[j];
            }
            if (burst > buf.length) buf = Uint8List(burst);
            src.setPositionSync(run.offsets[i]);
            if (src.readIntoSync(buf, 0, burst) != burst) {
              throw FileSystemException('Short read (source truncated?)', run.path);
            }
            out.writeFromSync(buf, 0, burst);
            written += burst;
            frames += j - i + 1;
            done += burst;
            port.send(done);
            i = j + 1;
          }
        } finally {
          src.closeSync();
        }
      }
      if (out != null) {
        out.flushSync();
        out.closeSync();
      }
      // Verify: re-read the headers of what was written.
      var found = 0;
      for (final f in chunkFiles) {
        found += scanChunk(f).length;
      }
      if (found != frames) {
        throw FileSystemException('Verification failed: wrote $frames frames, found $found', dir.path);
      }
      port.send('out:${dir.path}');
    }
    port.send(null);
  } catch (e) {
    port.send('$e');
  }
}
