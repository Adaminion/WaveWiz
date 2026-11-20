// 2026-11-19
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_store.dart';
import '../wave/kwi.dart';
import '../wave/kwv_index.dart';
import '../wave/offload.dart';
import '../wave/ranges.dart';
import '../wave/video_export.dart';
import 'export_dialog.dart';
import 'video_dialog.dart';

/// Exports every marked range of [clips] (clips without marks are skipped):
/// pick destination → wait for frame indexing → confirm names → copy.
Future<void> runExportFlow(BuildContext context, List<ClipInfo> clips) async {
  final marked = [
    for (final c in clips)
      if (ClipMarks.forClip(c.id, c.name).mergedCount > 0) c
  ];
  if (marked.isEmpty) return;

  final uri = await FilePicker.pickDirectory(
    dialogTitle: 'Choose where to export the ranges',
    initialDirectory: AppStore.lastExportFolder,
  );
  if (uri == null || !context.mounted) return;
  final dest = uri.toFilePath();
  AppStore.lastExportFolder = dest;

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
  final pending = <_Pending>[];
  for (final c in marked) {
    final idx = indexes[c.id]!;
    final last = idx.frameCount - 1;
    final merged = [
      for (final r in mergeRanges(ClipMarks.forClip(c.id, c.name).ranges))
        if (r.start <= last) FrameRange(r.start, math.min(r.end, last))
    ];
    pending.add((
      clip: c,
      frames: merged,
      ranges: [for (final r in merged) idx.runs(r.start, math.min(r.end + 1, last))],
    ));
  }

  final choice = await showDialog<_Choice>(
    context: context,
    builder: (_) => _ConfirmDialog(pending: pending, dest: dest),
  );
  if (choice == null || !context.mounted) return;
  AppStore.prefix = choice.prefix;

  String nameFor(_Pending p, int i) => outputName(
      prefix: choice.prefix,
      when: choice.when,
      fps: p.clip.fps.round(),
      clip: p.clip.name,
      index: i,
      count: p.ranges.length);

  String? ffmpeg;
  if (choice.video) {
    ffmpeg = findFfmpeg();
    if (ffmpeg == null) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('ffmpeg not found'),
          content: const Text('Video export needs ffmpeg. Install it (for example '
              '"brew install ffmpeg") and try again.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
  }

  if (choice.camera) {
    final items = <OffloadItem>[];
    for (final p in pending) {
      for (var i = 0; i < p.ranges.length; i++) {
        items.add(OffloadItem(
          name: nameFor(p, i),
          kwiPath: p.clip.kwiPath,
          chunkLimit: p.clip.chunkLimit,
          runs: p.ranges[i],
        ));
      }
    }
    await showExportDialog(context, OffloadPlan(items), dest);
    if (!context.mounted) return;
  }

  if (choice.video && ffmpeg != null) {
    final vitems = <VideoItem>[];
    for (final p in pending) {
      final idx = indexes[p.clip.id]!;
      final last = idx.frameCount - 1;
      for (var i = 0; i < p.frames.length; i++) {
        final r = p.frames[i];
        vitems.add(VideoItem(
          name: nameFor(p, i),
          width: p.clip.width,
          height: p.clip.height,
          refs: [for (var g = r.start; g <= math.min(r.end + 1, last); g++) idx.frame(g)!],
          count: r.length,
          matrix: p.clip.colorMatrix,
        ));
      }
    }
    if (!context.mounted) return;
    await showVideoDialog(context, VideoPlan(vitems, choice.fps), dest, ffmpeg);
  }
}

typedef _Pending = ({ClipInfo clip, List<FrameRange> frames, List<List<RunData>> ranges});
typedef _Choice = ({String prefix, DateTime when, bool camera, bool video, int fps});

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
  final List<_Pending> pending;
  final String dest;
  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  final TextEditingController _prefix = TextEditingController(text: AppStore.prefix);
  final DateTime _when = DateTime.now();
  bool _camera = true;
  bool _video = findFfmpeg() != null;
  int _fps = 24;

  @override
  void dispose() {
    _prefix.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var bytes = 0, frames = 0, vframes = 0, folders = 0;
    final lines = <String>[];
    for (final p in widget.pending) {
      var b = 0, f = 0;
      for (final r in p.ranges) {
        for (final run in r) {
          b += run.lengths.fold(0, (a, l) => a + l);
          f += run.lengths.length;
        }
      }
      final n = p.ranges.length;
      folders += n;
      final head = '${p.clip.name} · ${p.clip.fps.round()} fps · $n range${n == 1 ? '' : 's'}';
      final vf = p.frames.fold(0, (a, r) => a + r.length);
      final parts = <String>[head];
      if (_camera) {
        bytes += b;
        frames += f;
        parts.add('$f frames · ${fmtBytes(b)}');
      }
      if (_video) {
        vframes += vf;
        parts.add('video $vf frames → ${p.clip.width ~/ 4}×${p.clip.height ~/ 4}');
      }
      lines.add(parts.join(' · '));
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
      title: Text('Export $folders range${folders == 1 ? '' : 's'}?'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 8, children: [
              FilterChip(
                label: const Text('Camera files'),
                selected: _camera,
                onSelected: (v) => setState(() => _camera = v),
              ),
              FilterChip(
                label: const Text('H.264 video'),
                selected: _video,
                onSelected: (v) => setState(() => _video = v),
              ),
            ]),
            const SizedBox(height: 12),
            if (_video) ...[
              Row(children: [
                const Text('Play back at  '),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 24, label: Text('24')),
                    ButtonSegment(value: 30, label: Text('30')),
                    ButtonSegment(value: 60, label: Text('60')),
                  ],
                  selected: {_fps},
                  onSelectionChanged: (v) => setState(() => _fps = v.first),
                ),
                const Text('  fps'),
              ]),
              const SizedBox(height: 12),
            ],
            for (final l in lines) Text(l),
            const SizedBox(height: 4),
            Text(
                [
                  if (_camera) 'Camera files: $frames frames, ${fmtBytes(bytes)}',
                  if (_video)
                    'Video: $vframes frames, ${(vframes / _fps).toStringAsFixed(1)} s at $_fps fps',
                ].join('   ·   '),
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
            Text('Names: prefix-date-time-fps-clip-number\n'
                'e.g. $example${_video ? '.mp4' : ''}'
                '${_camera && _video ? '  (and a folder of the same name)' : ''}'
                '${_video ? '\nVideo is half-res (quarter width), decoded from the camera files.' : ''}'),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: !_camera && !_video
              ? null
              : () => Navigator.pop(context,
                  (prefix: _prefix.text, when: _when, camera: _camera, video: _video, fps: _fps)),
          child: const Text('Export'),
        ),
      ],
    );
  }
}
