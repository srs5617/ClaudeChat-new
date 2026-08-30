import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

typedef RunCode = Future<void> Function(String code, String language);

class ClaudeCodeBlockBuilder extends MarkdownElementBuilder {
  ClaudeCodeBlockBuilder({
    this.foldLines = 5,
    this.onRun,
    this.margin = const EdgeInsets.symmetric(vertical: 10),
    this.fontFamily = 'monospace',
  });

  final int foldLines;
  final RunCode? onRun;
  final EdgeInsetsGeometry margin;
  final String fontFamily;

  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final codeElement = element.children
        ?.whereType<md.Element>()
        .where((child) => child.tag == 'code')
        .firstOrNull;
    final code = codeElement?.textContent ?? element.textContent;
    final className = codeElement?.attributes['class'] ?? '';
    final language = className.startsWith('language-')
        ? className.substring('language-'.length)
        : '';
    return _FoldableCodeBlock(
      code: code,
      language: language,
      foldLines: foldLines,
      onRun: onRun,
      margin: margin,
      fontFamily: fontFamily,
    );
  }
}

class _FoldableCodeBlock extends StatefulWidget {
  const _FoldableCodeBlock({
    required this.code,
    required this.language,
    required this.foldLines,
    required this.onRun,
    required this.margin,
    required this.fontFamily,
  });

  final String code;
  final String language;
  final int foldLines;
  final RunCode? onRun;
  final EdgeInsetsGeometry margin;
  final String fontFamily;

  @override
  State<_FoldableCodeBlock> createState() => _FoldableCodeBlockState();
}

class _FoldableCodeBlockState extends State<_FoldableCodeBlock> {
  bool expanded = false;
  final ScrollController _codeScrollController = ScrollController();

  @override
  void dispose() {
    _codeScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.code.split('\n');
    final foldable = widget.foldLines > 0 && lines.length > widget.foldLines;
    final normalizedLanguage = widget.language.toLowerCase();
    final trimmed = widget.code.trimLeft().toLowerCase();
    final runnable =
        widget.onRun != null &&
        (const <String>{'html', 'htm', 'svg'}.contains(normalizedLanguage) ||
            trimmed.startsWith('<!doctype html') ||
            trimmed.startsWith('<html') ||
            trimmed.startsWith('<svg'));
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = dark ? const Color(0xFFC3C2B8) : const Color(0xFF101010);
    final muted = dark ? const Color(0xFF96948B) : const Color(0xFF77716B);
    final line = dark ? const Color(0xFF343431) : const Color(0xFFE5E0DB);
    final code = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      child: SelectableText(
        widget.code,
        style: TextStyle(
          color: text,
          fontFamily: widget.fontFamily,
          fontSize: 11,
          height: 1.45,
        ),
      ),
    );
    final scaledCodeSize = MediaQuery.textScalerOf(context).scale(11);
    final collapsedHeight = scaledCodeSize * 1.45 * widget.foldLines + 20;
    return Container(
      key: const Key('claude-code-block'),
      width: double.infinity,
      margin: widget.margin,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF2A2A28) : Colors.white,
        border: Border.all(color: line, width: .666667),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 36.666667,
            padding: const EdgeInsets.fromLTRB(11, 6, 9, 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: line, width: .666667)),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    widget.language.isEmpty
                        ? 'text'
                        : widget.language.toLowerCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted, fontSize: 11, height: 1),
                  ),
                ),
                if (runnable)
                  _CodeActionButton(
                    label: '运行',
                    surface: Colors.transparent,
                    text: text,
                    line: line,
                    onPressed: () async {
                      try {
                        await widget.onRun!(widget.code, widget.language);
                      } on Object catch (error) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('无法打开预览：$error')),
                        );
                      }
                    },
                  ),
                if (runnable) const SizedBox(width: 4),
                _CodeActionButton(
                  label: '复制',
                  surface: Colors.transparent,
                  text: text,
                  line: line,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: widget.code));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('代码已复制')));
                  },
                ),
                if (foldable) const SizedBox(width: 4),
                if (foldable)
                  _CodeActionButton(
                    label: expanded ? '折叠' : '展开',
                    surface: Colors.transparent,
                    text: text,
                    line: line,
                    onPressed: () => setState(() => expanded = !expanded),
                  ),
              ],
            ),
          ),
          if (foldable && !expanded)
            SizedBox(
              height: collapsedHeight,
              child: RawScrollbar(
                controller: _codeScrollController,
                thumbVisibility: true,
                trackVisibility: true,
                thickness: 8,
                radius: const Radius.circular(999),
                thumbColor: muted.withValues(alpha: .72),
                trackColor: line.withValues(alpha: .34),
                child: SingleChildScrollView(
                  controller: _codeScrollController,
                  child: code,
                ),
              ),
            )
          else
            code,
        ],
      ),
    );
  }
}

class _CodeActionButton extends StatelessWidget {
  const _CodeActionButton({
    required this.label,
    required this.surface,
    required this.text,
    required this.line,
    required this.onPressed,
  });

  final String label;
  final Color surface;
  final Color text;
  final Color line;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: text,
      backgroundColor: surface,
      minimumSize: Size.zero,
      maximumSize: const Size(37.135418, 24),
      fixedSize: const Size(37.135418, 24),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      side: BorderSide(color: line, width: .666667),
      shape: const StadiumBorder(),
      textStyle: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        height: 1,
      ),
    ),
    child: Text(label),
  );
}
