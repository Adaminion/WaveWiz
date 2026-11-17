// 2026-11-17
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../wave/kwi.dart';
import '../wave/ranges.dart';
import 'clip_page.dart';
import 'export_flow.dart';
import 'frame_image.dart';

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});
  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  String? _folder;
  List<ClipInfo> _clips = [];
  bool _loading = false;

  Future<void> _open() async {
    final uri = await FilePicker.pickDirectory(
      dialogTitle: 'Open Wave footage folder',
    );
    if (uri == null) return;
    final path = uri.toFilePath();
    setState(() {
      _folder = path;
      _loading = true;
    });
    final clips = await Future(() => ClipInfo.findClips(path));
    if (!mounted) return;
    setState(() {
      _clips = clips;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_folder ?? 'WaveWiz'),
        actions: [
          IconButton(
            tooltip: 'About / licences',
            icon: const Icon(Icons.info_outline),
            onPressed: () =>
                showLicensePage(context: context, applicationName: 'WaveWiz'),
          ),
          if (_clips.isNotEmpty)
            ListenableBuilder(
              listenable: Listenable.merge([
                for (final c in _clips) ClipMarks.forClip(c.id, c.name),
              ]),
              builder: (context, _) {
                var n = 0, clipsWith = 0;
                for (final c in _clips) {
                  final m = ClipMarks.forClip(c.id, c.name).mergedCount;
                  n += m;
                  if (m > 0) clipsWith++;
                }
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.tonalIcon(
                    onPressed: n == 0
                        ? null
                        : () => runExportFlow(context, _clips),
                    icon: const Icon(Icons.save_alt),
                    label: Text(
                      n == 0
                          ? 'Export all marked'
                          : 'Export all marked ($n from $clipsWith clip${clipsWith == 1 ? '' : 's'})',
                    ),
                  ),
                );
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _open,
              icon: const Icon(Icons.folder_open),
              label: const Text('Open folder'),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _clips.isEmpty
          ? Center(
              child: Text(
                _folder == null
                    ? 'Open a folder of Wave clips (or a single clip folder).'
                    : 'No Wave clips found in this folder.',
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 300,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 1.25,
              ),
              itemCount: _clips.length,
              itemBuilder: (_, i) => _ClipCard(clip: _clips[i]),
            ),
    );
  }
}

class _ClipCard extends StatelessWidget {
  const _ClipCard({required this.clip});
  final ClipInfo clip;

  String get _size => '${(clip.totalBytes / 1e9).toStringAsFixed(1)} GB';

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => ClipPage(clip: clip))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: Colors.black,
                    child: FutureBuilder<ui.Image?>(
                      future: ThumbnailService.instance.thumbnail(
                        clip.chunkPaths.first,
                        clip.width,
                        clip.height,
                      ),
                      builder: (_, s) {
                        if (s.connectionState != ConnectionState.done) {
                          return const Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        }
                        if (s.data == null) {
                          return const Center(
                            child: Icon(Icons.broken_image_outlined),
                          );
                        }
                        return RawImage(
                          image: s.data,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                        );
                      },
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: ListenableBuilder(
                      listenable: ClipMarks.forClip(clip.id, clip.name),
                      builder: (context, _) {
                        final n = ClipMarks.forClip(
                          clip.id,
                          clip.name,
                        ).mergedCount;
                        if (n == 0) return const SizedBox.shrink();
                        return Tooltip(
                          message:
                              '$n range${n == 1 ? '' : 's'} marked for export',
                          child: CircleAvatar(
                            radius: 13,
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .tertiary,
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onTertiary,
                            child: Text(
                              '$n',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    clip.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    '${clip.width}×${clip.height} @ ${clip.fps.round()} fps · '
                    '${clip.shutterAngle.round()}° · $_size',
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
