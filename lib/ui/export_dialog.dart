// 2026-11-17
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../wave/offload.dart';

/// Shows copy progress for [plan] into [dest]. Closes itself never; the user
/// dismisses it with Cancel (while running) or Close (when done).
Future<void> showExportDialog(
    BuildContext context, OffloadPlan plan, String dest) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExportDialog(plan: plan, dest: dest),
  );
}

String fmtBytes(num b) => b >= 1e9
    ? '${(b / 1e9).toStringAsFixed(2)} GB'
    : '${(b / 1e6).toStringAsFixed(1)} MB';

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.plan, required this.dest});
  final OffloadPlan plan;
  final String dest;
  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late final OffloadJob _job;
  final Stopwatch _clock = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    _job = OffloadJob.start(widget.plan, widget.dest, () {
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
    final total = widget.plan.totalBytes;
    final frac = total == 0 ? 1.0 : _job.doneBytes / total;
    final ok = _job.finished && _job.error == null && !_job.cancelled;
    final secs = _clock.elapsedMilliseconds / 1000;
    final rate = secs > 0.5 ? _job.doneBytes / secs : 0;
    return AlertDialog(
      title: Text(ok
          ? 'Offload complete'
          : _job.error != null
              ? 'Offload failed'
              : _job.cancelled
                  ? 'Offload cancelled'
                  : 'Offloading…'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: _job.finished && !ok ? null : frac),
            const SizedBox(height: 8),
            Text('${fmtBytes(_job.doneBytes)} of ${fmtBytes(total)}'
                '${rate > 0 ? '  ·  ${fmtBytes(rate)}/s' : ''}'),
            const SizedBox(height: 8),
            for (final o in _job.outputs) Text('✓ $o', style: Theme.of(context).textTheme.bodySmall),
            if (_job.error != null)
              Text(_job.error!, style: const TextStyle(color: Colors.redAccent)),
            if (_job.cancelled)
              const Text('Folders already written are left in place.'),
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
