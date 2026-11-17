// 2026-11-17
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
class ClipMarks {
  final List<FrameRange> ranges = [];
  int? pendingIn;

  /// Keeps marks alive when leaving and re-entering a clip during a session.
  static final Map<String, ClipMarks> _byClip = {};
  static ClipMarks forClip(String dir) => _byClip.putIfAbsent(dir, ClipMarks.new);
}
