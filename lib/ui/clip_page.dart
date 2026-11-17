// 2026-11-17
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../wave/kwi.dart';
import '../wave/kwv_index.dart';
import '../wave/ll2.dart';
import 'frame_image.dart';

/// Opens a clip: indexes frames in the background and scrubs LL2 previews.
/// Nothing plays automatically.
class ClipPage extends StatefulWidget {
  const ClipPage({super.key, required this.clip});
  final ClipInfo clip;
  @override
  State<ClipPage> createState() => _ClipPageState();
}

class _ClipPageState extends State<ClipPage> {
  late final ClipIndex _index = ClipIndex(widget.clip.chunkPaths);
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
    g = g.clamp(0, (_index.frameCount - 1).clamp(0, 1 << 30));
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
      final ui_ = await toUiImage(im);
      if (!mounted) {
        ui_.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = ui_;
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

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight) {
      _show(_frame + (shift ? 10 : 1));
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _show(_frame - (shift ? 10 : 1));
    } else if (k == LogicalKeyboardKey.pageDown) {
      _show(_frame + 100);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _show(_frame - 100);
    } else if (k == LogicalKeyboardKey.home) {
      _show(0);
    } else if (k == LogicalKeyboardKey.end) {
      _show(_index.frameCount - 1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    final n = _index.frameCount;
    final secs = _frame / (c.fps > 0 ? c.fps : 1);
    final camN = n > 0 ? _index.cameraFrameNumber(_frame) : null;
    return Scaffold(
      appBar: AppBar(title: Text(c.name)),
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
                children: [
                  Slider(
                    value: n == 0 ? 0 : _frame.toDouble().clamp(0, (n - 1).toDouble()),
                    min: 0,
                    max: n < 2 ? 1 : (n - 1).toDouble(),
                    onChanged: n == 0 ? null : (v) => _show(v.round()),
                  ),
                  Row(
                    children: [
                      Text('Frame ${n == 0 ? 0 : _frame + 1} / $n'
                          '${camN != null ? '  (camera #$camN)' : ''}  ·  '
                          '${secs.toStringAsFixed(3)} s real time'),
                      const Spacer(),
                      Text(_index.complete
                          ? '${c.width}×${c.height} @ ${c.fps.round()} fps · LL2 preview'
                          : 'Indexing ${_index.chunksDone}/${c.chunkPaths.length} chunks…'),
                      const SizedBox(width: 48), // keep clear of the version overlay
                    ],
                  ),
                  if (_error != null && _image != null)
                    Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
