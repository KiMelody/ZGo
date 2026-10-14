import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme.dart';
import '../ui_settings.dart';
import 'image_viewer_page.dart';

/// Markdown renderer matching the web client look: selectable
/// body text, inline code on a pill background, fenced code blocks with a
/// language tag, line count, copy button and collapse toggle in a
/// self-drawn header bar (collapsed by default).
class AppMarkdown extends StatelessWidget {
  final String data;
  final bool selectable;

  /// Base style for prose. Chat bodies use the default [ZType.body]; compact
  /// surfaces (reasoning strips, sub-agent detail) pass [ZType.sub].
  final TextStyle bodyStyle;

  /// Workspace image resolver for `![alt](path)` references (design
  /// 09-29-file-preview §4.3). Null keeps the previous inert behavior —
  /// reasoning strips and other existing call sites pass nothing. Null
  /// results render the placeholder row (layout never collapses).
  final Future<Uint8List?> Function(String path)? imageResolver;

  /// Link taps (`[text](href)`). Null keeps links inert (existing call
  /// sites); the chat body dispatches local paths / http(s) links.
  final void Function(String href)? onLinkTap;

  /// Trailing inset for prose blocks (paragraphs, headings, blockquotes).
  /// The assistant body uses this to keep the text wrap width after the
  /// bubble dropped its own right margin (10-14 batch add-on: fenced code
  /// blocks span the full column, prose stays indented). Zero (default)
  /// keeps the previous full-bleed prose.
  final double proseRightInset;

  const AppMarkdown(
    this.data, {
    super.key,
    this.selectable = true,
    this.bodyStyle = ZType.body,
    this.imageResolver,
    this.onLinkTap,
    this.proseRightInset = 0,
  });

  @override
  Widget build(BuildContext context) {
    final body = bodyStyle.copyWith(height: 1.6);
    final code = ZType.sub.copyWith(fontFamily: 'monospace');
    // Prose trailing inset (see [proseRightInset]); zero is the flutter_
    // markdown fallback value, so 0 keeps byte-identical layout.
    final prosePad = EdgeInsets.only(right: proseRightInset);
    final styleSheet = MarkdownStyleSheet(
      p: body.copyWith(color: ZInk.solid(context)),
      pPadding: prosePad,
      h1: ZType.display.copyWith(height: 1.6),
      h1Padding: prosePad,
      h2: ZType.title.copyWith(height: 1.6),
      h2Padding: prosePad,
      h3: ZType.heading.copyWith(height: 1.6),
      h3Padding: prosePad,
      h4: ZType.bodyStrong.copyWith(height: 1.6),
      h4Padding: prosePad,
      code: code.copyWith(
        backgroundColor: ZInk.codeInlineBg(context),
        color: ZInk.solid(context),
      ),
      codeblockDecoration: const BoxDecoration(),
      blockquote: body.copyWith(color: ZInk.soft(context)),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
              color: ZColors.sky500.withValues(alpha: 0.5), width: 3),
        ),
      ),
      blockquotePadding: EdgeInsets.only(left: 12, right: proseRightInset),
      listBullet: body.copyWith(color: ZInk.solid(context)),
      tableBody: ZType.sub.copyWith(color: ZInk.solid(context)),
      tableHead: ZType.sub.copyWith(
          fontWeight: FontWeight.w600, color: ZInk.solid(context)),
      tableBorder: TableBorder.all(color: ZInk.hairline(context), width: 1),
      tableCellsPadding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: ZInk.hairline(context))),
      ),
      a: ZType.body.copyWith(
          color: ZColors.sky500, decoration: TextDecoration.underline),
    );

    return MarkdownBody(
      data: data,
      selectable: selectable,
      styleSheet: styleSheet,
      builders: {
        'code': _CodeBlockBuilder(codeStyle: code),
      },
      softLineBreak: true,
      sizedImageBuilder: imageResolver == null
          ? null
          : (config) => _MarkdownImage(
                path: config.uri.toString(),
                resolver: imageResolver!,
              ),
      onTapLink: onLinkTap == null
          ? null
          : (text, href, title) {
              if (href != null && href.isNotEmpty) onLinkTap!(href);
            },
    );
  }
}

/// Async inline image for a markdown `![alt](path)` reference (design §4.3,
/// pattern aligned with chat_page's `_AttachmentViewState`): spinner while
/// the resolver runs, then the decoded image — tap opens the fullscreen
/// [ImageViewerPage] (bytes already in memory) — or a placeholder row with
/// the file name + failure copy. svg has no Flutter decoder (PRD non-goal),
/// so it goes straight to the placeholder without a fetch.
class _MarkdownImage extends StatefulWidget {
  final String path;
  final Future<Uint8List?> Function(String path) resolver;

  const _MarkdownImage({required this.path, required this.resolver});

  @override
  State<_MarkdownImage> createState() => _MarkdownImageState();
}

class _MarkdownImageState extends State<_MarkdownImage> {
  Uint8List? _bytes;
  bool _failed = false;

  bool get _isSvg => widget.path.toLowerCase().endsWith('.svg');

  String get _baseName => widget.path.split(RegExp(r'[\\/]')).last;

  @override
  void initState() {
    super.initState();
    if (!_isSvg) _load();
  }

  Future<void> _load() async {
    final bytes = await widget.resolver(widget.path);
    if (mounted) {
      setState(() {
        _bytes = bytes;
        _failed = bytes == null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isSvg || _failed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 16,
              color: ZInk.faint(context),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _isSvg
                    ? trP(context, 'chat.img.svgUnsupported', [_baseName])
                    : trP(context, 'chat.img.loadFailed', [_baseName]),
                style: ZType.caption.copyWith(color: ZInk.faint(context)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          zRoute(
            (_) => ImageViewerPage(bytes: bytes, fileName: widget.path),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ZRadius.field),
          child: ConstrainedBox(
            // Full-width contained block (markdown image rhythm);
            // the 48px floor keeps even tiny images a real tap target.
            constraints: const BoxConstraints(maxHeight: 280, minHeight: 48),
            child: Image.memory(bytes, fit: BoxFit.contain,
                width: double.infinity),
          ),
        ),
      ),
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  final TextStyle codeStyle;

  _CodeBlockBuilder({required this.codeStyle});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // Language is encoded in the class attribute: `language-dart`.
    var language = '';
    final classAttr = element.attributes['class'];
    if (classAttr != null) {
      final match = RegExp(r'language-(\S+)').firstMatch(classAttr);
      if (match != null) language = match.group(1) ?? '';
    }
    final code = element.textContent;
    if (!code.contains('\n') && language.isEmpty) {
      // inline code: default styling
      return null;
    }
    return _CodeBlock(code: code, language: language, codeStyle: codeStyle);
  }
}

/// Fenced code blocks are collapsed by default: the header shows the
/// language, the line count and the copy button; tapping the header (or the
/// chevron) toggles the code body. Long agent dumps stop flooding the chat.
class _CodeBlock extends StatefulWidget {
  final String code;
  final String language;
  final TextStyle codeStyle;

  const _CodeBlock({
    required this.code,
    required this.language,
    required this.codeStyle,
  });

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final code = widget.code;
    final lineCount = code.trim().isEmpty ? 0 : code.trim().split('\n').length;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: ZInk.codeBlockBg(context),
        // Tile radius (user-directed 10-14): the block is styled as a chat
        // card (reasoning/tool tile spec) — a deliberate exception to the
        // field radius otherwise used for embedded code/diff/kv blocks.
        borderRadius: BorderRadius.circular(ZRadius.tile),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            // Splash must follow the header's radius (collapsed = full tile
            // radius; expanded = top corners only, the body sits below).
            customBorder: _expanded
                ? RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                        top: Radius.circular(ZRadius.tile)))
                : RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(ZRadius.tile)),
            child: Container(
              // Header = shared chat-tile head geometry (ZTile): same height
              // floor and horizontal inset as the reasoning/tool cards.
              constraints: const BoxConstraints(minHeight: ZTile.headHeight),
              padding: ZTile.head,
              decoration: BoxDecoration(
                color: ZInk.tile(context),
                borderRadius: _expanded
                    ? const BorderRadius.vertical(
                        top: Radius.circular(ZRadius.tile))
                    : BorderRadius.circular(ZRadius.tile),
              ),
              child: Row(
                children: [
                  Text(
                    widget.language.isEmpty ? 'code' : widget.language,
                    style: ZType.sub.copyWith(
                      color: ZInk.muted(context),
                      fontFamily: 'monospace'),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    trP(context, 'chat.code.lines', ['$lineCount']),
                    style: ZType.sub.copyWith(color: ZInk.faint(context)),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: code));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(tr(context, 'chat.copied')),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.copy_outlined,
                          size: ZTile.iconSize, color: ZInk.faint(context)),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: ZTile.iconSize,
                    color: ZInk.faint(context),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(ZTile.headPadding),
              child: SelectableText(
                code.endsWith('\n')
                    ? code.substring(0, code.length - 1)
                    : code,
                style: widget.codeStyle.copyWith(
                  height: 1.5,
                  color: ZInk.codeText(context),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
