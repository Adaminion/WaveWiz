// 2026-11-19
import 'dart:async';
import 'dart:ui' as ui;

import '../wave/ll2.dart';

/// Converts decoded RGBA pixels to a GPU image.
Future<ui.Image> toUiImage(Ll2Image im) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(im.rgba, im.width, im.height, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// Limits how many thumbnails decode at once so browsing a big card stays smooth.
class ThumbnailService {
  ThumbnailService._();
  static final ThumbnailService instance = ThumbnailService._();

  final Map<String, Future<ui.Image?>> _cache = {};
  int _running = 0;
  final List<void Function()> _queue = [];
  static const int _maxParallel = 2;

  Future<ui.Image?> thumbnail(String firstChunk, int w, int h, List<double> matrix) =>
      _cache.putIfAbsent(firstChunk, () => _run(firstChunk, w, h, matrix));

  Future<ui.Image?> _run(String chunk, int w, int h, List<double> matrix) {
    final c = Completer<ui.Image?>();
    void go() async {
      _running++;
      try {
        c.complete(await toUiImage(await decodeThumbnail(chunk, w, h, matrix)));
      } catch (_) {
        c.complete(null); // unreadable clip: show a placeholder, never crash
      } finally {
        _running--;
        if (_queue.isNotEmpty) _queue.removeAt(0)();
      }
    }

    if (_running < _maxParallel) {
      go();
    } else {
      _queue.add(go);
    }
    return c.future;
  }
}
