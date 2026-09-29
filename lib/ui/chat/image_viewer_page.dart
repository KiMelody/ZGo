import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui_settings.dart';

/// Fullscreen image viewer (task 09-29-file-preview design §4.1): a black
/// full-bleed surface with pinch-zoom + pan ([InteractiveViewer], 0.5x–8x)
/// and a top chrome bar (file name + close) that fades with the gradient.
/// Tapping the image area toggles the chrome. The bytes arrive already
/// decoded from the entry point (inline images are in memory — no re-fetch),
/// so the page needs no gateway access at all.
class ImageViewerPage extends StatefulWidget {
  final Uint8List bytes;

  /// Shown in the chrome bar when known (markdown path, attachment name);
  /// the bar collapses to the close button when null.
  final String? fileName;

  const ImageViewerPage({super.key, required this.bytes, this.fileName});

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  bool _chromeVisible = true;

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    // Photo surface: theme-independent near-black from the official neutral
    // scale (a light-mode white viewer would wash the image out; the design
    // pins black §4.1). Not a ZInk slot on purpose — ZInk branches by theme.
    const surface = ZColors.neutral950;
    return Scaffold(
      backgroundColor: surface,
      body: GestureDetector(
        onTap: () => setState(() => _chromeVisible = !_chromeVisible),
        child: Stack(
          children: [
            // fit: contain keeps the whole image visible before zooming;
            // InteractiveViewer owns the scale/pan gestures on top.
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 8,
              panEnabled: true,
              child: Center(
                child: Image.memory(widget.bytes, fit: BoxFit.contain),
              ),
            ),
            // Top gradient + file name + close; ignores taps so the tap
            // toggle below stays live everywhere except the close button.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !_chromeVisible,
                child: AnimatedOpacity(
                  opacity: _chromeVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          ZColors.neutral950,
                          ZColors.neutral950.withValues(alpha: 0),
                        ],
                      ),
                    ),
                    child: SafeArea(
                      bottom: false,
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: tr(context, 'common.close'),
                            icon: const Icon(Icons.close,
                                color: ZColors.neutral200),
                            onPressed: _close,
                          ),
                          Expanded(
                            child: Text(
                              widget.fileName ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ZType.sub
                                  .copyWith(color: ZColors.neutral200),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
