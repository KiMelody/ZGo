import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme.dart';
import '../ui_settings.dart';

/// Markdown renderer matching the official web client look: selectable
/// body text, inline code on a pill background, fenced code blocks with a
/// language tag, line count, copy button and collapse toggle in a
/// self-drawn header bar (collapsed by default).
class ZLinkerMarkdown extends StatelessWidget {
  final String data;
  final bool selectable;

  /// Base style for prose. Chat bodies use the default [ZType.body]; compact
  /// surfaces (reasoning strips, sub-agent detail) pass [ZType.sub].
  final TextStyle bodyStyle;

  const ZLinkerMarkdown(
    this.data, {
    super.key,
    this.selectable = true,
    this.bodyStyle = ZType.body,
  });

  @override
  Widget build(BuildContext context) {
    final body = bodyStyle.copyWith(height: 1.6);
    final code = ZType.sub.copyWith(fontFamily: 'monospace');
    final styleSheet = MarkdownStyleSheet(
      p: body.copyWith(color: ZInk.solid(context)),
      h1: ZType.display.copyWith(height: 1.6),
      h2: ZType.title.copyWith(height: 1.6),
      h3: ZType.heading.copyWith(height: 1.6),
      h4: ZType.bodyStrong.copyWith(height: 1.6),
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
      blockquotePadding: const EdgeInsets.only(left: 12),
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
        borderRadius: BorderRadius.circular(ZRadius.field),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: ZInk.tile(context),
                borderRadius: _expanded
                    ? const BorderRadius.vertical(
                        top: Radius.circular(ZRadius.field))
                    : BorderRadius.circular(ZRadius.field),
              ),
              child: Row(
                children: [
                  Text(
                    widget.language.isEmpty ? 'code' : widget.language,
                    style: ZType.caption.copyWith(
                      color: ZInk.faint(context),
                      fontFamily: 'monospace'),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    trP(context, 'chat.code.lines', ['$lineCount']),
                    style: ZType.caption.copyWith(color: ZInk.faint(context)),
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
                          size: 13, color: ZInk.faint(context)),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: ZInk.faint(context),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(10),
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
