// 2026-11-17
import 'dart:io';

import 'package:flutter/material.dart';

import '../wave/video_export.dart';

/// Shows video export progress. Closes itself never; the user dismisses it
/// with Cancel (while running) or Close (when done).
Future<void> showVideoDialog(
    BuildContext context, VideoPlan plan, String dest, String ffmpeg) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _VideoDialog(plan: plan, dest: dest, ffmpeg: ffmpeg),
  );
}

class _VideoDialog extends StatefulWidget {
  const _VideoDialog({required this.plan, required this.dest, required this.ffmpeg});
  final VideoPlan plan;
  final String dest;
  final String ffmpeg;
  @override
  State<_VideoDialog> createState() => _VideoDialogState();
}

class _VideoDialogState extends State<_VideoDialog> {
  late final VideoJob _job;
  final Stopwatch _clock = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    _job = VideoJob.start(widget.plan, widget.dest, widget.ffmpeg, () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    if (!_job.finished) _job.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.plan.totalFrames;
    final frac = total == 0 ? 1.0 : _job.doneFrames / total;
    final ok = _job.finished && _job.error == null && !_job.cancelled;
    final secs = _clock.elapsedMilliseconds / 1000;
    final rate = secs > 0.5 ? _job.doneFrames / secs : 0;
    return AlertDialog(
      title: Text(ok
          ? 'Export complete'
          : _job.error != null
              ? 'Export failed'
              : _job.cancelled
                  ? 'Export cancelled'
                  : 'Exporting…'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: _job.finished && !ok ? null : frac),
            const SizedBox(height: 8),
            Text('${_job.doneFrames} of $total frames'
                '${rate > 0 ? '  ·  ${rate.toStringAsFixed(0)} frames/s' : ''}'),
            const SizedBox(height: 8),
            for (final o in _job.outputs) Text('✓ $o', style: Theme.of(context).textTheme.bodySmall),
            if (_job.error != null)
              Text(_job.error!, style: const TextStyle(color: Colors.redAccent)),
            if (_job.cancelled) const Text('Videos already written are left in place.'),
          ],
        ),
      ),
      actions: [
        if (ok && Platform.isMacOS)
          TextButton(
            onPressed: () => Process.run('open', [widget.dest]),
            child: const Text('Show in Finder'),
          ),
        TextButton(
          onPressed: () {
            if (!_job.finished) _job.cancel();
            Navigator.of(context).pop();
          },
          child: Text(_job.finished ? 'Close' : 'Cancel'),
        ),
      ],
    );
  }
}
