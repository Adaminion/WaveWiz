// 2026-11-19
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../wave/kwi.dart';
import '../wave/kwv_index.dart';
import '../wave/ll2.dart';
import '../wave/ranges.dart';
import 'export_flow.dart';
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

class _ClipPageState extends State<ClipPage> with SingleTickerProviderStateMixin {
  late final ClipIndex _index = ClipIndex.forClip(widget.clip);
  late final ClipMarks _marks = ClipMarks.forClip(widget.clip.id, widget.clip.name);

  // Playback (J/K/L/Space). Rates are frames shown per second; the playhead
  // follows the clock and skips frames the decoder can't keep up with.
  static const List<double> _ladder = [30, 120, 480, 1920];
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  int _dir = 0; // -1 reverse, 0 stopped, 1 forward
  int _level = 0;
  double _pos = 0;
  ui.Image? _image;
  int _frame = 0;
  int? _pending; // latest requested frame while a decode is in flight
  bool _busy = false;
  int? _lo, _hi; // fixed levels for the whole session (no flicker while scrubbing)
  double? _gr, _gb; // fixed white balance, same reason
  String? _error;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _index.addListener(_onIndexed);
    _marks.addListener(_onMarks);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _image == null && _index.frameCount > 0) _show(0);
    });
  }

  void _onMarks() {
    if (mounted) setState(() {});
  }

  void _onIndexed() {
    if (!mounted) return;
    setState(() {
      if (_index.error != null) _error = '${_index.error}';
    });
    if (_image == null && _index.frameCount > 0) _show(_frame);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _ticker?.dispose();
    _index.removeListener(_onIndexed);
    _marks.removeListener(_onMarks);
    _image?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _show(int g, {bool fromTick = false}) {
    g = g.clamp(0, math.max(_index.frameCount - 1, 0));
    if (!fromTick) _pos = g.toDouble();
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
          widget.clip.height, lo: _lo, hi: _hi, gr: _gr, gb: _gb);
      _lo ??= im.lo;
      _hi ??= im.hi;
      _gr ??= im.gr;
      _gb ??= im.gb;
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

  void _markIn() {
    _marks.setPendingIn(_frame);
    _focus.requestFocus();
  }

  void _markOut() {
    _focus.requestFocus();
    // No In point yet: start from the first frame. Out before In: swap them.
    final i = _marks.pendingIn ?? 0;
    _marks.addRange(FrameRange(math.min(i, _frame), math.max(i, _frame)));
  }

  // --- playback ------------------------------------------------------------

  void _tick(Duration elapsed) {
    var dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt > 0.1) dt = 0.1; // don't jump after a stall
    final last = math.max(_index.frameCount - 1, 0);
    _pos += _dir * _ladder[_level] * dt;
    if (_pos >= last || _pos <= 0) {
      _pos = _pos.clamp(0, last).toDouble();
      _stop();
    }
    final f = _pos.floor();
    if (f != _frame) _show(f, fromTick: true);
  }

  void _play(int dir) {
    if (_index.frameCount == 0) return;
    if (_dir == dir) {
      _level = (_level + 1) % _ladder.length; // 1x → 2x → 3x → 4x → back to 1x
    } else {
      _dir = dir;
      _level = 0;
      _pos = _frame.toDouble();
    }
    _ticker ??= createTicker(_tick);
    if (!_ticker!.isActive) {
      _lastTick = Duration.zero;
      _ticker!.start();
    }
    setState(() {});
  }

  void _stop() {
    _ticker?.stop();
    if (mounted) {
      setState(() {
        _dir = 0;
        _level = 0;
      });
    }
  }

  String get _playLabel {
    if (_dir == 0) return '';
    final r = _ladder[_level];
    return '${_dir > 0 ? '▶' : '◀'} ${r.round()} fps  ·  ${(r / widget.clip.fps).toStringAsFixed(2)}× real time';
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final step = kb.isShiftPressed ? 10 : (kb.isMetaPressed || kb.isControlPressed) ? 1000 : 1;
    final k = e.logicalKey;
    final down = e is KeyDownEvent;
    if (k == LogicalKeyboardKey.arrowRight) {
      _stop();
      _show(_frame + step);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _stop();
      _show(_frame - step);
    } else if (k == LogicalKeyboardKey.pageDown) {
      _show(_frame + 100);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _show(_frame - 100);
    } else if (k == LogicalKeyboardKey.home) {
      _show(0);
    } else if (k == LogicalKeyboardKey.end) {
      _show(_index.frameCount - 1);
    } else if (down && k == LogicalKeyboardKey.keyI) {
      _markIn();
    } else if (down && k == LogicalKeyboardKey.keyO) {
      _markOut();
    } else if (down && k == LogicalKeyboardKey.space) {
      _dir == 0 ? _play(1) : _stop();
    } else if (down && k == LogicalKeyboardKey.keyK) {
      _stop();
    } else if (down && k == LogicalKeyboardKey.keyL) {
      _play(1);
    } else if (down && k == LogicalKeyboardKey.keyJ) {
      _play(-1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // Safety net: if keyboard focus has ended up outside our Focus (for example
  // on an app-bar button), keys would otherwise fall through and beep.
  bool _onHardwareKey(KeyEvent e) {
    if (!mounted || _focus.hasFocus) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    if (_onKey(_focus, e) != KeyEventResult.handled) return false;
    _focus.requestFocus();
    return true;
  }

  // --- export --------------------------------------------------------------

  Future<void> _export() async {
    await runExportFlow(context, [widget.clip]);
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
                      ? 'Export marked ranges to a folder'
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
                    onRangeChanged: _marks.setRange,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('Frame ${n == 0 ? 0 : _frame + 1} / $n'
                          '${camN != null ? '  (camera #$camN)' : ''}  ·  '
                          '${_t(_frame)} real time'),
                      OutlinedButton(onPressed: n == 0 ? null : _markIn, child: const Text('I  In')),
                      OutlinedButton(onPressed: n == 0 ? null : _markOut, child: const Text('O  Out')),
                      if (_dir != 0)
                        Text(_playLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(_index.complete
                          ? '${c.width}×${c.height} @ ${c.fps.round()} fps · LL2 preview'
                          : 'Indexing ${_index.chunksDone}/${c.chunkPaths.length} chunks…'),
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
                          side: BorderSide(color: rangeColor(i)),
                          labelStyle: TextStyle(color: rangeColor(i), fontWeight: FontWeight.bold),
                          deleteIconColor: rangeColor(i),
                          label: Text('${i + 1}: ${_marks.ranges[i].start + 1} → '
                              '${_marks.ranges[i].end + 1}  '
                              '(${_marks.ranges[i].length} f, ${_t(_marks.ranges[i].length)})'),
                          onPressed: () {
                            _show(_marks.ranges[i].start);
                            _focus.requestFocus();
                          },
                          onDeleted: () => _marks.removeAt(i),
                        ),
                      if (_marks.ranges.isEmpty && _marks.pendingIn == null)
                        Text('I = In, O = Out (as many ranges as you like; drag a range edge on the bar to trim it). Space play/stop, '
                            'L/J play forward/back (press again for faster), K stop. '
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
