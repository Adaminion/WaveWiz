// 2026-11-18
// H.264 export of marked ranges: half-res (LL1) decode in worker isolates,
// frames piped to ffmpeg. One .mp4 per range; each camera frame becomes one
// video frame at the chosen output rate (so playback is slow motion).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'kwv_index.dart';
import 'll1.dart';

/// Locates an ffmpeg executable, or null if none is installed.
String? findFfmpeg() {
  final names = Platform.isWindows ? ['ffmpeg.exe'] : ['ffmpeg'];
  final dirs = <String>[
    if (Platform.isMacOS) ...['/opt/homebrew/bin', '/usr/local/bin'],
    if (Platform.isLinux) ...['/usr/bin', '/usr/local/bin'],
    ...(Platform.environment['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':')
        .where((d) => d.isNotEmpty),
  ];
  for (final d in dirs) {
    for (final n in names) {
      final f = File('$d${Platform.pathSeparator}$n');
      if (f.existsSync()) return f.path;
    }
  }
  return null;
}

/// One range to render: frames [refs] (the last entry, if [count] < refs.length,
/// is only needed to decode the final frame).
class VideoItem {
  VideoItem({
    required this.name,
    required this.width,
    required this.height,
    required this.refs,
    required this.count,
  });
  final String name; // output file name without extension
  final int width; // clip (sensor) size; the video is a quarter of it
  final int height;
  final List<FrameRef> refs;
  final int count;

  int get videoWidth => width ~/ 4;
  int get videoHeight => height ~/ 4;
}

class VideoPlan {
  VideoPlan(this.items, this.fps);
  final List<VideoItem> items;
  final int fps; // output frame rate (24 / 30 / 60)
  int get totalFrames => items.fold(0, (a, i) => a + i.count);
}

class VideoJob {
  VideoJob._();

  int doneFrames = 0;
  final List<String> outputs = [];
  String? error;
  bool finished = false;
  bool cancelled = false;
  Process? _proc;

  static VideoJob start(
      VideoPlan plan, String dest, String ffmpeg, void Function() onUpdate) {
    final job = VideoJob._();
    job._run(plan, dest, ffmpeg, onUpdate).catchError((Object e) {
      if (!job.cancelled) job.error = '$e';
      job.finished = true;
      onUpdate();
    });
    return job;
  }

  void cancel() {
    cancelled = true;
    finished = true;
    _proc?.kill();
  }

  Future<void> _run(
      VideoPlan plan, String dest, String ffmpeg, void Function() onUpdate) async {
    final workers = math.max(2, math.min(8, Platform.numberOfProcessors - 1));
    for (final item in plan.items) {
      if (cancelled) return;
      final out = File('$dest${Platform.pathSeparator}${item.name}.mp4');
      if (out.existsSync()) {
        throw FileSystemException('File already exists', out.path);
      }
      // Levels and white balance come from the first frame so the whole range
      // keeps one look.
      final first =
          await Isolate.run(() => _decodeBatch(item, 0, 1, null, null, null, null));
      final lo = first.lo, hi = first.hi, gr = first.gr, gb = first.gb;

      final proc = await Process.start(ffmpeg, [
        '-y', '-loglevel', 'error',
        '-f', 'rawvideo', '-pix_fmt', 'rgba',
        '-s', '${item.videoWidth}x${item.videoHeight}',
        '-framerate', '${plan.fps}', '-i', '-',
        '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
        '-c:v', 'libx264', '-preset', 'medium', '-crf', '17',
        '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709',
        '-movflags', '+faststart',
        out.path,
      ]);
      _proc = proc;
      final err = StringBuffer();
      proc.stderr.transform(utf8.decoder).listen(err.write);
      proc.stdout.drain<void>();
      // ffmpeg exiting early (bad args, disk full) surfaces as a stdin error.
      final stdinDone = proc.stdin.done.catchError((Object _) {});

      const batch = 4;
      final pending = <Future<_Batch>>[];
      var nextStart = 1; // frame 0 is already decoded
      Future<_Batch> launch() {
        final s = nextStart;
        final c = math.min(batch, item.count - s);
        nextStart += c;
        return Isolate.run(() => _decodeBatch(item, s, c, lo, hi, gr, gb));
      }

      try {
        proc.stdin.add(first.frames.first);
        doneFrames++;
        onUpdate();
        while (pending.length < workers && nextStart < item.count) {
          pending.add(launch());
        }
        while (pending.isNotEmpty) {
          final b = await pending.removeAt(0);
          if (cancelled) break;
          if (nextStart < item.count) pending.add(launch());
          for (final f in b.frames) {
            proc.stdin.add(f);
            doneFrames++;
          }
          await proc.stdin.flush();
          onUpdate();
        }
        await proc.stdin.close();
        await stdinDone;
      } catch (_) {
        // Fall through: the exit code below reports the real cause.
      }
      final code = await proc.exitCode;
      _proc = null;
      if (cancelled) {
        if (out.existsSync()) out.deleteSync();
        return;
      }
      if (code != 0) {
        if (out.existsSync()) out.deleteSync();
        final msg = err.toString().trim();
        throw Exception('ffmpeg failed (exit $code)${msg.isEmpty ? '' : ': $msg'}');
      }
      outputs.add('${item.name}.mp4');
      onUpdate();
    }
    finished = true;
    onUpdate();
  }
}

class _Batch {
  _Batch(this.frames, this.lo, this.hi, this.gr, this.gb);
  final List<Uint8List> frames;
  final int lo;
  final int hi;
  final double gr;
  final double gb;
}

_Batch _decodeBatch(VideoItem item, int start, int count, int? lo, int? hi,
    double? gr, double? gb) {
  final out = <Uint8List>[];
  var l = lo ?? 0, h = hi ?? 0, r = gr ?? 1.0, b = gb ?? 1.0;
  for (var k = start; k < start + count; k++) {
    final cur = item.refs[k];
    final next = k + 1 < item.refs.length ? item.refs[k + 1] : null;
    final im = ll1ToRgba(
      decodeLl1(readFrameStreams(cur, next), item.width, item.height),
      lo: lo, hi: hi, gr: gr, gb: gb,
    );
    if (lo == null) {
      l = im.lo;
      h = im.hi;
      r = im.gr;
      b = im.gb;
    }
    out.add(im.rgba);
  }
  return _Batch(out, l, h, r, b);
}
