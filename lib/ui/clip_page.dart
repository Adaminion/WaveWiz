// 2026-11-17
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../wave/kwi.dart';
import '../wave/kwv_index.dart';
import '../wave/ll2.dart';
import '../wave/offload.dart';
import '../wave/ranges.dart';
import 'export_dialog.dart';
import 'frame_image.dart';
import 'timeline.dart';

/// Opens a clip: indexes frames in the background, scrubs LL2 previews, and
/// lets you mark any number of In/Out ranges to export. Nothing auto-plays.
class ClipPage extends StatefulWidget {
  const ClipPage({super.key, required this.clip});
  final ClipInfo clip;
  @override
  State<ClipPage> createState() => _ClipPageState();
}

class _ClipPageState extends State<ClipPage> {
  late final ClipIndex _index = ClipIndex(widget.clip.chunkPaths);
  late final ClipMarks _marks = ClipMarks.forClip(widget.clip.dir);
  void Function()? _cancelScan;
  ui.Image? _image;
  int _frame = 0;
  int? _pending; // latest requested frame while a decode is in flight
  bool _busy = false;
  int? _lo, _hi; // fixed levels for the whole session (no flicker while scrubbing)
  String? _error;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _cancelScan = _index.start(_onIndexed, (e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  void _onIndexed() {
    if (!mounted) return;
    setState(() {});
    if (_image == null && _index.frameCount > 0) _show(_frame);
  }

  @override
  void dispose() {
    _cancelScan?.call();
    _image?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _show(int g) {
    g = g.clamp(0, math.max(_index.frameCount - 1, 0));
    setState(() => _frame = g);
    if (_busy) {
      _pending = g;
      return;
    }
    _decode(g);
  }

  Future<void> _decode(int g) async {
    final cur = _index.frame(g);
    if (cur == null) return;
    _busy = true;
    try {
      final im = await decodeFrameLl2(cur, _index.frame(g + 1), widget.clip.width,
          widget.clip.height, lo: _lo, hi: _hi);
      _lo ??= im.lo;
      _hi ??= im.hi;
      final img = await toUiImage(im);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = img;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Cannot decode frame $g: $e');
    } finally {
      _busy = false;
      final p = _pending;
      _pending = null;
      if (mounted && p != null && p != g) _decode(p);
    }
  }

  // --- marking -------------------------------------------------------------

  void _markIn() => setState(() => _marks.pendingIn = _frame);

  void _markOut() {
    final i = _marks.pendingIn;
    if (i == null) {
      _toast('Press I first to set an In point.');
    } else if (_frame < i) {
      _toast('Out point is before the In point.');
    } else {
      setState(() {
        _marks.ranges.add(FrameRange(i, _frame));
        _marks.pendingIn = null;
      });
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final step = kb.isShiftPressed ? 10 : (kb.isMetaPressed || kb.isControlPressed) ? 1000 : 1;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight) {
      _show(_frame + step);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _show(_frame - step);
    } else if (k == LogicalKeyboardKey.pageDown) {
      _show(_frame + 100);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _show(_frame - 100);
    } else if (k == LogicalKeyboardKey.home) {
      _show(0);
    } else if (k == LogicalKeyboardKey.end) {
      _show(_index.frameCount - 1);
    } else if (e is KeyDownEvent && k == LogicalKeyboardKey.keyI) {
      _markIn();
    } else if (e is KeyDownEvent && k == LogicalKeyboardKey.keyO) {
      _markOut();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // --- export --------------------------------------------------------------

  Future<void> _export() async {
    final merged = mergeRanges(_marks.ranges);
    if (merged.isEmpty) return;
    final uri = await FilePicker.pickDirectory(dialogTitle: 'Choose where to copy the ranges');
    if (uri == null || !mounted) return;
    final dest = uri.toFilePath();
    final last = _index.frameCount - 1;
    final plan = OffloadPlan(
      clipName: widget.clip.name,
      kwiPath: widget.clip.kwiPath,
      chunkLimit: widget.clip.chunkLimit,
      // +1 frame: the end frame's data can spill into the next frame's slice.
      ranges: [for (final r in merged) _index.runs(r.start, math.min(r.end + 1, last))],
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Copy marked ranges?'),
        content: Text('${merged.length} range${merged.length == 1 ? '' : 's'}, '
            '${plan.totalFrames} frames, ${fmtBytes(plan.totalBytes)}\n'
            'Each range becomes its own clip folder in:\n$dest'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Copy')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await showExportDialog(context, plan, dest);
    if (mounted) _focus.requestFocus();
  }

  // --- UI ------------------------------------------------------------------

  String _t(int frames) => '${(frames / (widget.clip.fps > 0 ? widget.clip.fps : 1)).toStringAsFixed(3)} s';

  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    final n = _index.frameCount;
    final camN = n > 0 ? _index.cameraFrameNumber(_frame) : null;
    final merged = mergeRanges(_marks.ranges);
    final exportable = merged.isNotEmpty && _index.complete;
    return Scaffold(
      appBar: AppBar(
        title: Text(c.name),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Tooltip(
              message: merged.isEmpty
                  ? 'Mark ranges with I and O first'
                  : _index.complete
                      ? 'Copy marked ranges to a folder'
                      : 'Wait for indexing to finish',
              child: FilledButton.icon(
                onPressed: exportable ? _export : null,
                icon: const Icon(Icons.save_alt),
                label: Text(merged.isEmpty
                    ? 'Export'
                    : 'Export ${merged.length} range${merged.length == 1 ? '' : 's'}'),
              ),
            ),
          ),
        ],
      ),
      body: Focus(
        autofocus: true,
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: _image == null
                      ? Text(_error ?? (n == 0 ? 'Indexing…' : 'Decoding…'))
                      : AspectRatio(
                          aspectRatio: c.width / c.height,
                          child: RawImage(
                              image: _image,
                              fit: BoxFit.fill,
                              filterQuality: FilterQuality.medium),
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Timeline(
                    frameCount: n,
                    frame: _frame,
                    ranges: _marks.ranges,
                    pendingIn: _marks.pendingIn,
                    onSeek: _show,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text('Frame ${n == 0 ? 0 : _frame + 1} / $n'
                          '${camN != null ? '  (camera #$camN)' : ''}  ·  '
                          '${_t(_frame)} real time'),
                      const SizedBox(width: 16),
                      OutlinedButton(onPressed: n == 0 ? null : _markIn, child: const Text('I  In')),
                      const SizedBox(width: 8),
                      OutlinedButton(onPressed: n == 0 ? null : _markOut, child: const Text('O  Out')),
                      const Spacer(),
                      Text(_index.complete
                          ? '${c.width}×${c.height} @ ${c.fps.round()} fps · LL2 preview'
                          : 'Indexing ${_index.chunksDone}/${c.chunkPaths.length} chunks…'),
                      const SizedBox(width: 48), // keep clear of the version overlay
                    ],
                  ),
                  if (_error != null && _image != null)
                    Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (_marks.pendingIn != null)
                        Chip(label: Text('In ${_marks.pendingIn! + 1} → press O')),
                      for (var i = 0; i < _marks.ranges.length; i++)
                        InputChip(
                          label: Text('${i + 1}: ${_marks.ranges[i].start + 1} → '
                              '${_marks.ranges[i].end + 1}  '
                              '(${_marks.ranges[i].length} f, ${_t(_marks.ranges[i].length)})'),
                          onPressed: () => _show(_marks.ranges[i].start),
                          onDeleted: () => setState(() => _marks.ranges.removeAt(i)),
                        ),
                      if (_marks.ranges.isEmpty && _marks.pendingIn == null)
                        Text('I = In point, O = Out point; mark as many ranges as you like. '
                            '←/→ step 1, Shift 10, Page 100, ⌘/Ctrl 1000.',
                            style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
