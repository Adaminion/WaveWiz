// 2026-11-17
import 'package:flutter/foundation.dart';

import '../app_store.dart';

/// An inclusive range of frames (global frame indices within a clip).
class FrameRange {
  const FrameRange(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;
}

/// Sorts and merges overlapping or adjacent ranges.
List<FrameRange> mergeRanges(Iterable<FrameRange> input) {
  final r = input.toList()..sort((a, b) => a.start.compareTo(b.start));
  final out = <FrameRange>[];
  for (final x in r) {
    if (out.isNotEmpty && x.start <= out.last.end + 1) {
      final l = out.removeLast();
      out.add(FrameRange(l.start, x.end > l.end ? x.end : l.end));
    } else {
      out.add(x);
    }
  }
  return out;
}

/// In/out marks for one clip: any number of ranges, plus an open in-point.
/// Saved to disk on every change.
class ClipMarks extends ChangeNotifier {
  ClipMarks._(this.id, this.name) {
    final s = AppStore.loadMarks(id);
    _ranges.addAll(s.ranges);
    _pendingIn = s.pendingIn;
  }

  final String id;
  final String name;
  final List<FrameRange> _ranges = [];
  int? _pendingIn;

  List<FrameRange> get ranges => List.unmodifiable(_ranges);
  int? get pendingIn => _pendingIn;

  /// Number of clips this will export (overlaps merged).
  int get mergedCount => mergeRanges(_ranges).length;

  void setPendingIn(int? f) {
    _pendingIn = f;
    _changed();
  }

  void addRange(FrameRange r) {
    _ranges.add(r);
    _pendingIn = null;
    _changed();
  }

  void removeAt(int i) {
    _ranges.removeAt(i);
    _changed();
  }

  void _changed() {
    AppStore.saveMarks(id, name, _ranges, _pendingIn);
    notifyListeners();
  }

  static final Map<String, ClipMarks> _byClip = {};
  static ClipMarks forClip(String id, String name) =>
      _byClip.putIfAbsent(id, () => ClipMarks._(id, name));
}
