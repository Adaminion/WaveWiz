// 2026-11-17
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_store.dart';
import '../wave/kwi.dart';
import '../wave/kwv_index.dart';
import '../wave/offload.dart';
import '../wave/ranges.dart';
import 'export_dialog.dart';

/// Exports every marked range of [clips] (clips without marks are skipped):
/// pick destination → wait for frame indexing → confirm names → copy.
Future<void> runExportFlow(BuildContext context, List<ClipInfo> clips) async {
  final marked = [
    for (final c in clips)
      if (ClipMarks.forClip(c.id, c.name).mergedCount > 0) c
  ];
  if (marked.isEmpty) return;

  final uri = await FilePicker.pickDirectory(dialogTitle: 'Choose where to copy the ranges');
  if (uri == null || !context.mounted) return;
  final dest = uri.toFilePath();

  final indexes = {for (final c in marked) c.id: ClipIndex.forClip(c)};
  if (indexes.values.any((i) => !i.complete)) {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _IndexWait(clips: marked, indexes: indexes),
    );
    if (ok != true || !context.mounted) return;
  }

  // Frame runs per clip and range (+1 frame: the end frame's data can spill
  // into the next frame's slice).
  final pending = <({ClipInfo clip, List<List<RunData>> ranges})>[];
  for (final c in marked) {
    final idx = indexes[c.id]!;
    final last = idx.frameCount - 1;
    final merged = mergeRanges(ClipMarks.forClip(c.id, c.name).ranges);
    pending.add((
      clip: c,
      ranges: [
        for (final r in merged)
          if (r.start <= last) idx.runs(r.start, math.min(r.end + 1, last))
      ],
    ));
  }

  final choice = await showDialog<({String prefix, DateTime when})>(
    context: context,
    builder: (_) => _ConfirmDialog(pending: pending, dest: dest),
  );
  if (choice == null || !context.mounted) return;
  AppStore.prefix = choice.prefix;

  final items = <OffloadItem>[];
  for (final p in pending) {
    for (var i = 0; i < p.ranges.length; i++) {
      items.add(OffloadItem(
        name: outputName(
            prefix: choice.prefix,
            when: choice.when,
            fps: p.clip.fps.round(),
            clip: p.clip.name,
            index: i,
            count: p.ranges.length),
        kwiPath: p.clip.kwiPath,
        chunkLimit: p.clip.chunkLimit,
        runs: p.ranges[i],
      ));
    }
  }
  await showExportDialog(context, OffloadPlan(items), dest);
}

class _IndexWait extends StatefulWidget {
  const _IndexWait({required this.clips, required this.indexes});
  final List<ClipInfo> clips;
  final Map<String, ClipIndex> indexes;
  @override
  State<_IndexWait> createState() => _IndexWaitState();
}

class _IndexWaitState extends State<_IndexWait> {
  @override
  void initState() {
    super.initState();
    for (final i in widget.indexes.values) {
      i.addListener(_changed);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  void _changed() {
    if (!mounted) return;
    if (widget.indexes.values.every((i) => i.complete)) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    for (final i in widget.indexes.values) {
      i.removeListener(_changed);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final err = widget.indexes.values.map((i) => i.error).whereType<Object>().firstOrNull;
    return AlertDialog(
      title: const Text('Indexing frames…'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final c in widget.clips)
            Text('${c.name}: ${widget.indexes[c.id]!.chunksDone}/${c.chunkPaths.length} chunks'),
          if (err != null) Text('$err', style: const TextStyle(color: Colors.redAccent)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
      ],
    );
  }
}

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({required this.pending, required this.dest});
  final List<({ClipInfo clip, List<List<RunData>> ranges})> pending;
  final String dest;
  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  final TextEditingController _prefix = TextEditingController(text: AppStore.prefix);
  final DateTime _when = DateTime.now();

  @override
  void dispose() {
    _prefix.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var bytes = 0, frames = 0, folders = 0;
    final lines = <String>[];
    for (final p in widget.pending) {
      var b = 0, f = 0;
      for (final r in p.ranges) {
        for (final run in r) {
          b += run.lengths.fold(0, (a, l) => a + l);
          f += run.lengths.length;
        }
      }
      bytes += b;
      frames += f;
      folders += p.ranges.length;
      lines.add('${p.clip.name} · ${p.clip.fps.round()} fps · ${p.ranges.length} range'
          '${p.ranges.length == 1 ? '' : 's'} · $f frames · ${fmtBytes(b)}');
    }
    final first = widget.pending.first;
    final example = outputName(
        prefix: _prefix.text,
        when: _when,
        fps: first.clip.fps.round(),
        clip: first.clip.name,
        index: 0,
        count: first.ranges.length);
    return AlertDialog(
      title: Text('Copy $folders clip folder${folders == 1 ? '' : 's'}?'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in lines) Text(l),
            const SizedBox(height: 4),
            Text('Total: $frames frames, ${fmtBytes(bytes)}',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 12),
            Text('Into: ${widget.dest}'),
            const SizedBox(height: 12),
            TextField(
              controller: _prefix,
              decoration: const InputDecoration(labelText: 'Name prefix', isDense: true),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Text('Folder names: prefix-date-time-fps-clip-number\n'
                'e.g. $example'),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, (prefix: _prefix.text, when: _when)),
          child: const Text('Copy'),
        ),
      ],
    );
  }
}
