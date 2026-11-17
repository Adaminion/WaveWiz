// 2026-11-17
import 'package:flutter/material.dart';

import '../wave/ranges.dart';

/// Scrub bar showing every marked range, the open in-point and the playhead.
class Timeline extends StatelessWidget {
  const Timeline({
    super.key,
    required this.frameCount,
    required this.frame,
    required this.ranges,
    required this.pendingIn,
    required this.onSeek,
  });

  final int frameCount;
  final int frame;
  final List<FrameRange> ranges;
  final int? pendingIn;
  final ValueChanged<int> onSeek;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      void seek(double x) {
        if (frameCount < 1) return;
        final t = (x / box.maxWidth).clamp(0.0, 1.0);
        onSeek((t * (frameCount - 1)).round());
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => seek(d.localPosition.dx),
        onHorizontalDragStart: (d) => seek(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => seek(d.localPosition.dx),
        child: CustomPaint(
          size: Size(box.maxWidth, 40),
          painter: _TimelinePainter(frameCount, frame, ranges, pendingIn, cs),
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
    final rangePaint = Paint()..color = cs.tertiary;
    for (final r in ranges) {
      final x0 = _x(r.start, size.width);
      final x1 = _x(r.end, size.width);
      canvas.drawRect(Rect.fromLTRB(x0, mid - 9, x1 < x0 + 3 ? x0 + 3 : x1, mid + 9), rangePaint);
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
  bool shouldRepaint(_TimelinePainter o) =>
      o.n != n || o.frame != frame || o.pendingIn != pendingIn || o.ranges.length != ranges.length;
}
