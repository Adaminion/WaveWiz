// 2026-11-19
import 'package:flutter/material.dart';

import '../wave/ranges.dart';

const List<Color> _rangeColors = [
  Color(0xFFFF9800), // orange
  Color(0xFF26C6DA), // cyan
  Color(0xFFEC407A), // pink
  Color(0xFF9CCC65), // light green
  Color(0xFFAB47BC), // purple
  Color(0xFF42A5F5), // blue
  Color(0xFFFFCA28), // amber
  Color(0xFF26A69A), // teal
];

/// Colour of range number [i] (0-based), used for its bar and its chip.
Color rangeColor(int i) => _rangeColors[i % _rangeColors.length];

/// Scrub bar showing every marked range, the open in-point and the playhead.
/// Drag a range's edge to trim it; drag anywhere else to scrub.
class Timeline extends StatefulWidget {
  const Timeline({
    super.key,
    required this.frameCount,
    required this.frame,
    required this.ranges,
    required this.pendingIn,
    required this.onSeek,
    required this.onRangeChanged,
  });

  final int frameCount;
  final int frame;
  final List<FrameRange> ranges;
  final int? pendingIn;
  final ValueChanged<int> onSeek;
  final void Function(int index, FrameRange range) onRangeChanged;

  @override
  State<Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<Timeline> {
  static const double _grab = 8; // pixels around an edge that grab it

  ({int index, bool start})? _drag;
  bool _overEdge = false;

  double _x(int f, double w) => widget.frameCount < 2 ? 0 : f / (widget.frameCount - 1) * w;

  int _frameAt(double x, double w) {
    final t = (x / w).clamp(0.0, 1.0);
    return (t * (widget.frameCount - 1)).round();
  }

  ({int index, bool start})? _edgeAt(double x, double w) {
    ({int index, bool start})? best;
    var bestD = _grab + 1;
    for (var i = 0; i < widget.ranges.length; i++) {
      final r = widget.ranges[i];
      final ds = (_x(r.start, w) - x).abs();
      final de = (_x(r.end, w) - x).abs();
      if (ds < bestD) {
        bestD = ds;
        best = (index: i, start: true);
      }
      if (de < bestD) {
        bestD = de;
        best = (index: i, start: false);
      }
    }
    return best;
  }

  void _update(double x, double w) {
    if (widget.frameCount < 1) return;
    final f = _frameAt(x, w);
    final d = _drag;
    if (d == null) {
      widget.onSeek(f);
      return;
    }
    final r = widget.ranges[d.index];
    widget.onRangeChanged(
        d.index, d.start ? FrameRange(f < r.end ? f : r.end, r.end) : FrameRange(r.start, f > r.start ? f : r.start));
    widget.onSeek(f);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return MouseRegion(
        cursor: _overEdge || _drag != null ? SystemMouseCursors.resizeLeftRight : MouseCursor.defer,
        onHover: (e) {
          final over = _edgeAt(e.localPosition.dx, w) != null;
          if (over != _overEdge) setState(() => _overEdge = over);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            if (widget.frameCount > 0) widget.onSeek(_frameAt(d.localPosition.dx, w));
          },
          onHorizontalDragStart: (d) {
            _drag = _edgeAt(d.localPosition.dx, w);
            _update(d.localPosition.dx, w);
          },
          onHorizontalDragUpdate: (d) => _update(d.localPosition.dx, w),
          onHorizontalDragEnd: (_) => setState(() => _drag = null),
          onHorizontalDragCancel: () => setState(() => _drag = null),
          child: CustomPaint(
            size: Size(w, 40),
            painter: _TimelinePainter(
                widget.frameCount, widget.frame, widget.ranges, widget.pendingIn, cs),
          ),
        ),
      );
    });
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.n, this.frame, this.ranges, this.pendingIn, this.cs);
  final int n;
  final int frame;
  final List<FrameRange> ranges;
  final int? pendingIn;
  final ColorScheme cs;

  double _x(int f, double w) => n < 2 ? 0 : f / (n - 1) * w;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final track = Rect.fromLTWH(0, mid - 5, size.width, 10);
    canvas.drawRRect(RRect.fromRectAndRadius(track, const Radius.circular(5)),
        Paint()..color = cs.surfaceContainerHighest);
    for (var i = 0; i < ranges.length; i++) {
      final r = ranges[i];
      final color = rangeColor(i);
      final x0 = _x(r.start, size.width);
      final x1 = _x(r.end, size.width);
      canvas.drawRect(Rect.fromLTRB(x0, mid - 9, x1 < x0 + 3 ? x0 + 3 : x1, mid + 9),
          Paint()..color = color.withValues(alpha: 0.8));
      // Edge handles.
      final handle = Paint()..color = color;
      canvas.drawRect(Rect.fromLTWH(x0 - 1.5, mid - 13, 3, 26), handle);
      canvas.drawRect(Rect.fromLTWH((x1 < x0 + 3 ? x0 + 3 : x1) - 1.5, mid - 13, 3, 26), handle);
    }
    if (pendingIn != null) {
      final x = _x(pendingIn!, size.width);
      canvas.drawLine(Offset(x, mid - 14), Offset(x, mid + 14),
          Paint()..color = cs.tertiary..strokeWidth = 2);
      canvas.drawRect(Rect.fromLTWH(x, mid - 14, 8, 4), Paint()..color = cs.tertiary);
    }
    final px = _x(frame, size.width);
    canvas.drawLine(Offset(px, 2), Offset(px, size.height - 2),
        Paint()..color = cs.primary..strokeWidth = 2);
    canvas.drawCircle(Offset(px, mid), 6, Paint()..color = cs.primary);
  }

  @override
  bool shouldRepaint(_TimelinePainter o) {
    if (o.n != n || o.frame != frame || o.pendingIn != pendingIn || o.ranges.length != ranges.length) {
      return true;
    }
    for (var i = 0; i < ranges.length; i++) {
      if (o.ranges[i].start != ranges[i].start || o.ranges[i].end != ranges[i].end) return true;
    }
    return false;
  }
}
