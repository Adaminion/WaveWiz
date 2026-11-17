// 2026-11-17
// Small JSON store in the app-support folder: In/Out marks per clip (so a
// crash or quit loses nothing) and the export-name prefix. Never touches the
// camera drive.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'wave/ranges.dart';

class AppStore {
  AppStore._();

  static File? _file;
  static Map<String, dynamic> _data = {};

  static Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    initAt(dir.path);
  }

  /// Opens the store at [dirPath] (also used by tests).
  static void initAt(String dirPath) {
    Directory(dirPath).createSync(recursive: true);
    final f = File('$dirPath/wavewiz.json');
    _file = f;
    _data = {};
    try {
      if (f.existsSync()) {
        final d = jsonDecode(f.readAsStringSync());
        if (d is Map<String, dynamic>) _data = d;
      }
    } catch (_) {
      // Corrupt file: start empty rather than crash. Keep a copy for inspection.
      try {
        f.renameSync('${f.path}.bad');
      } catch (_) {}
    }
  }

  static String get prefix => (_data['prefix'] as String?) ?? 'wavewiz';
  static set prefix(String v) {
    _data['prefix'] = v;
    _save();
  }

  static Map<String, dynamic> get _clips =>
      (_data['clips'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  static ({List<FrameRange> ranges, int? pendingIn}) loadMarks(String id) {
    try {
      final m = _clips[id] as Map<String, dynamic>?;
      if (m == null) return (ranges: <FrameRange>[], pendingIn: null);
      final r = [
        for (final p in (m['ranges'] as List))
          FrameRange((p as List)[0] as int, p[1] as int)
      ];
      return (ranges: r, pendingIn: m['pendingIn'] as int?);
    } catch (_) {
      return (ranges: <FrameRange>[], pendingIn: null);
    }
  }

  static void saveMarks(String id, String name, List<FrameRange> ranges, int? pendingIn) {
    if (ranges.isEmpty && pendingIn == null) {
      _clips.remove(id);
    } else {
      _clips[id] = {
        'name': name,
        'ranges': [for (final r in ranges) [r.start, r.end]],
        'pendingIn': pendingIn,
      };
    }
    _save();
  }

  static void _save() {
    final f = _file;
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode(_data));
      tmp.renameSync(f.path); // atomic replace: a crash never leaves half a file
    } catch (_) {
      // Non-fatal: marks still live in memory.
    }
  }
}
