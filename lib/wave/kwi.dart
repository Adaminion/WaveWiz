// 2026-11-17
// Clip header (.kwi) parsing. Layout follows ClipHeader_s in docs/frame.h.
import 'dart:io';
import 'dart:typed_data';

const String kWaveDelimiter = 'WAVE HELLO!\n';
const int kHeaderSize = 512;

String _fnv(Uint8List b) {
  var h = 0xcbf29ce484222325;
  for (final x in b) {
    h = (h ^ x) * 0x100000001b3;
  }
  return h.toUnsigned(64).toRadixString(16);
}

bool hasDelimiter(Uint8List b, [int at = 0]) {
  if (b.length < at + 12) return false;
  for (var i = 0; i < 12; i++) {
    if (b[at + i] != kWaveDelimiter.codeUnitAt(i)) return false;
  }
  return true;
}

class ClipInfo {
  ClipInfo({
    required this.name,
    required this.dir,
    required this.width,
    required this.height,
    required this.fps,
    required this.shutterAngle,
    required this.colorTemp,
    required this.chunkPaths,
    required this.totalBytes,
    required this.chunkLimit,
    required this.kwiPath,
    required this.id,
  });

  final String name;
  final String dir;
  final int width;
  final int height;
  final double fps;
  final double shutterAngle;
  final double colorTemp;
  final List<String> chunkPaths;
  final int totalBytes;

  /// Largest source chunk size; output chunks are capped at the same size.
  final int chunkLimit;
  final String kwiPath;

  /// Stable identity across mounts: name, size and a hash of the clip header.
  /// (Clip names like c0040 repeat on different cards.)
  final String id;

  /// Parses a ClipHeader_s (first 512 bytes of a .kwi). Returns null if invalid.
  static ({int w, int h, double fps, double shutter, double temp})? parseHeader(
      Uint8List b) {
    if (b.length < 0x20 || !hasDelimiter(b)) return null;
    final d = ByteData.sublistView(b);
    final w = d.getUint16(0x10, Endian.little);
    final h = d.getUint16(0x12, Endian.little);
    if (w == 0 || h == 0) return null;
    return (
      w: w,
      h: h,
      fps: d.getFloat32(0x14, Endian.little),
      shutter: d.getFloat32(0x18, Endian.little),
      temp: d.getFloat32(0x1C, Endian.little),
    );
  }

  /// Loads clip info from a directory containing a .kwi and f*.kwv chunks.
  /// Only reads the first 512 bytes of the .kwi; never touches chunk contents.
  static ClipInfo? load(Directory dir) {
    try {
      File? kwi;
      final chunks = <String>[];
      var total = 0, biggest = 0;
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final base = e.uri.pathSegments.last;
        if (base.startsWith('.')) continue;
        if (base.endsWith('.kwi')) {
          kwi ??= e;
        } else if (base.endsWith('.kwv')) {
          chunks.add(e.path);
          final l = e.lengthSync();
          total += l;
          if (l > biggest) biggest = l;
        }
      }
      if (kwi == null || chunks.isEmpty) return null;
      chunks.sort();
      final raf = kwi.openSync();
      Uint8List head;
      try {
        head = raf.readSync(kHeaderSize);
      } finally {
        raf.closeSync();
      }
      final h = parseHeader(head);
      if (h == null) return null;
      final segs = dir.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      return ClipInfo(
        name: segs.isEmpty ? dir.path : segs.last,
        dir: dir.path,
        width: h.w,
        height: h.h,
        fps: h.fps,
        shutterAngle: h.shutter,
        colorTemp: h.temp,
        chunkPaths: chunks,
        totalBytes: total,
        chunkLimit: biggest,
        kwiPath: kwi.path,
        id: '${segs.isEmpty ? dir.path : segs.last}|$total|${chunks.length}|${_fnv(head)}',
      );
    } on FileSystemException {
      return null;
    }
  }

  /// Finds clips at [path]: either the clip folder itself, or a folder of clips.
  static List<ClipInfo> findClips(String path) {
    final root = Directory(path);
    final self = load(root);
    if (self != null) return [self];
    final out = <ClipInfo>[];
    try {
      final dirs = root
          .listSync(followLinks: false)
          .whereType<Directory>()
          .where((d) => !d.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith('.'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final d in dirs) {
        final c = load(d);
        if (c != null) out.add(c);
      }
    } on FileSystemException {
      // Unreadable folder: report no clips rather than crash.
    }
    return out;
  }
}
