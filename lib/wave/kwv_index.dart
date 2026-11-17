// 2026-11-17
// Frame indexing of .kwv chunks. Reads only the 512 B header of each frame and
// jumps over the codestream payload; never reads whole files.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'kwi.dart';

/// Per-frame data for one chunk, stored as typed arrays (compact for 100k+ frames).
class ChunkIndex {
  ChunkIndex(this.offsets, this.size0, this.nFrame, this.fifo0, this.flag0,
      this.frameBytes);

  final Int64List offsets; // byte offset of the frame header within the chunk
  final Uint32List size0; // codestream 0 (LL2) size in bytes
  final Uint32List nFrame; // camera frame number
  final Uint16List fifo0; // csFIFOState[0]
  final Uint8List flag0; // csFIFOFlags bit 16 (extra 64-bit discard for cs0)
  final Uint32List frameBytes; // 512 B header + all codestreams

  int get length => offsets.length;
}

/// Scans [path] header by header. [maxFrames] limits the scan (thumbnails).
ChunkIndex scanChunk(String path, {int? maxFrames}) {
  final raf = File(path).openSync();
  try {
    final len = raf.lengthSync();
    final offs = <int>[];
    final s0 = <int>[];
    final nf = <int>[];
    final f0 = <int>[];
    final fl = <int>[];
    final fb = <int>[];
    final buf = Uint8List(kHeaderSize);
    var p = 0;
    while (p + kHeaderSize <= len && (maxFrames == null || offs.length < maxFrames)) {
      raf.setPositionSync(p);
      if (raf.readIntoSync(buf) != kHeaderSize || !hasDelimiter(buf)) break;
      final d = ByteData.sublistView(buf);
      var payload = 0;
      for (var i = 0; i < 16; i++) {
        payload += d.getUint32(0x80 + 4 * i, Endian.little);
      }
      if (p + kHeaderSize + payload > len) break; // truncated last frame
      offs.add(p);
      s0.add(d.getUint32(0x80, Endian.little));
      nf.add(d.getUint32(0x0C, Endian.little));
      f0.add(d.getUint16(0xC0, Endian.little));
      fl.add((d.getUint32(0x24, Endian.little) >> 16) & 1);
      fb.add(kHeaderSize + payload);
      p += kHeaderSize + payload;
    }
    return ChunkIndex(Int64List.fromList(offs), Uint32List.fromList(s0),
        Uint32List.fromList(nf), Uint16List.fromList(f0), Uint8List.fromList(fl), Uint32List.fromList(fb));
  } finally {
    raf.closeSync();
  }
}

/// Frames of one source chunk to copy: byte offsets and lengths per frame.
class RunData {
  RunData(this.path, this.offsets, this.lengths);
  final String path;
  final Int64List offsets;
  final Uint32List lengths;
}

/// A frame's location, enough to decode LL2 without further indexing.
class FrameRef {
  const FrameRef(this.path, this.offset, this.size0, this.fifo0, this.flag0);
  final String path;
  final int offset;
  final int size0;
  final int fifo0;
  final int flag0;

  /// Start of this frame's codestream 0 slice.
  int get cs0Start => offset + kHeaderSize;
}

/// Whole-clip frame index, filled in chunk by chunk by a background isolate.
class ClipIndex {
  ClipIndex(this.chunkPaths) : chunks = List.filled(chunkPaths.length, null);

  final List<String> chunkPaths;
  final List<ChunkIndex?> chunks;
  int _indexedCount = 0; // leading contiguous chunks that are indexed
  int _frames = 0; // frames in leading contiguous chunks

  /// Number of frames in the contiguous indexed prefix (scrubbable range).
  int get frameCount => _frames;
  int get chunksDone => _indexedCount;
  bool get complete => _indexedCount == chunkPaths.length;

  void _advance() {
    while (_indexedCount < chunks.length && chunks[_indexedCount] != null) {
      _frames += chunks[_indexedCount]!.length;
      _indexedCount++;
    }
  }

  void put(int chunk, ChunkIndex idx) {
    chunks[chunk] = idx;
    _advance();
  }

  /// Frame [g] (global index within the indexed prefix).
  FrameRef? frame(int g) {
    if (g < 0) return null;
    var rest = g;
    for (var c = 0; c < _indexedCount; c++) {
      final ci = chunks[c]!;
      if (rest < ci.length) {
        return FrameRef(chunkPaths[c], ci.offsets[rest], ci.size0[rest],
            ci.fifo0[rest], ci.flag0[rest]);
      }
      rest -= ci.length;
    }
    return null;
  }

  /// Contiguous per-chunk frame runs covering global frames [start]..[end]
  /// (inclusive, clamped to the indexed range), for copying.
  List<RunData> runs(int start, int end) {
    final out = <RunData>[];
    var base = 0;
    for (var c = 0; c < _indexedCount && base <= end; c++) {
      final ci = chunks[c]!;
      final lo = start - base < 0 ? 0 : start - base;
      final hi = end - base > ci.length - 1 ? ci.length - 1 : end - base;
      if (lo <= hi) {
        out.add(RunData(chunkPaths[c], ci.offsets.sublist(lo, hi + 1),
            ci.frameBytes.sublist(lo, hi + 1)));
      }
      base += ci.length;
    }
    return out;
  }

  /// Source file, byte offset and byte length of global frame [g], or null.
  ({String path, int offset, int length})? span(int g) {
    if (g < 0) return null;
    var rest = g;
    for (var c = 0; c < _indexedCount; c++) {
      final ci = chunks[c]!;
      if (rest < ci.length) {
        return (path: chunkPaths[c], offset: ci.offsets[rest], length: ci.frameBytes[rest]);
      }
      rest -= ci.length;
    }
    return null;
  }

  /// Camera frame number of global frame [g].
  int? cameraFrameNumber(int g) {
    var rest = g;
    for (var c = 0; c < _indexedCount; c++) {
      final ci = chunks[c]!;
      if (rest < ci.length) return ci.nFrame[rest];
      rest -= ci.length;
    }
    return null;
  }

  /// Indexes all chunks in a background isolate. Calls [onProgress] after each
  /// chunk. Returns a function that cancels the scan.
  void Function() start(void Function() onProgress, void Function(Object) onError) {
    final rp = ReceivePort();
    Isolate? iso;
    var dead = false;
    Isolate.spawn(_scanWorker, [rp.sendPort, chunkPaths]).then((i) {
      if (dead) {
        i.kill(priority: Isolate.immediate);
      } else {
        iso = i;
      }
    }, onError: (Object e) => onError(e));
    rp.listen((m) {
      if (m == null) {
        rp.close();
      } else if (m is String) {
        onError(m);
      } else {
        final l = m as List;
        put(l[0] as int,
            ChunkIndex(l[1] as Int64List, l[2] as Uint32List, l[3] as Uint32List,
                l[4] as Uint16List, l[5] as Uint8List, l[6] as Uint32List));
        onProgress();
      }
    });
    return () {
      dead = true;
      iso?.kill(priority: Isolate.immediate);
      rp.close();
    };
  }
}

void _scanWorker(List<Object> args) {
  final port = args[0] as SendPort;
  final paths = (args[1] as List).cast<String>();
  try {
    for (var i = 0; i < paths.length; i++) {
      final c = scanChunk(paths[i]);
      port.send([i, c.offsets, c.size0, c.nFrame, c.fifo0, c.flag0, c.frameBytes]);
    }
    port.send(null);
  } catch (e) {
    port.send('Indexing failed: $e');
  }
}
