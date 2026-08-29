import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_markdown_plus_latex/flutter_markdown_plus_latex.dart';
import 'package:markdown/markdown.dart' as md;

/// Creates an isolated Markdown extension set for one rendering surface.
///
/// Callers deliberately receive a new instance so ordinary chat and workspace
/// chat never share parser objects or mutable rendering state.
md.ExtensionSet createClaudeMarkdownExtensionSet() => md.ExtensionSet(
  <md.BlockSyntax>[
    LatexBlockSyntax(),
    ...md.ExtensionSet.gitHubFlavored.blockSyntaxes,
  ],
  <md.InlineSyntax>[
    LatexInlineSyntax(),
    ClaudeHighlightSyntax(),
    ClaudeAnchorHtmlSyntax(),
    for (final tag in _safePairedHtmlTags.entries)
      ClaudePairedHtmlSyntax(tag.key, outputTag: tag.value),
    ClaudeHtmlBreakSyntax(),
    ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
  ],
);

const Map<String, String> _safePairedHtmlTags = <String, String>{
  'sup': 'sup',
  'sub': 'sub',
  'mark': 'mark',
  'u': 'u',
  'ins': 'u',
  'kbd': 'kbd',
  'small': 'small',
  'span': 'span',
  'b': 'strong',
  'strong': 'strong',
  'i': 'em',
  'em': 'em',
  's': 'del',
  'del': 'del',
  'code': 'code',
};

/// Parses the widely used `==highlight==` extension.
class ClaudeHighlightSyntax extends md.InlineSyntax {
  ClaudeHighlightSyntax()
    : super(r'==([^\s=\n](?:[^\n]*?[^\s=\n])?)==', startCharacter: 0x3D);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element('mark', parser.document.parseInline(match.group(1)!)),
    );
    return true;
  }
}

/// Renders a deliberately small, non-executable subset of inline HTML.
///
/// Attributes are accepted for compatibility but ignored. Script, iframe,
/// style and other executable/block HTML never become Flutter widgets.
class ClaudePairedHtmlSyntax extends md.InlineSyntax {
  ClaudePairedHtmlSyntax(String sourceTag, {required this.outputTag})
    : super(
        '<$sourceTag(?:\\s+[^<>]*?)?>([\\s\\S]*?)</$sourceTag\\s*>',
        startCharacter: 0x3C,
        caseSensitive: false,
      );

  final String outputTag;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element(outputTag, parser.document.parseInline(match.group(1)!)),
    );
    return true;
  }
}

class ClaudeHtmlBreakSyntax extends md.InlineSyntax {
  ClaudeHtmlBreakSyntax()
    : super(r'<br\s*/?>', startCharacter: 0x3C, caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
    return true;
  }
}

/// Converts a conventional inline HTML anchor into the same safe link node
/// used by Markdown links. The caller's existing link confirmation flow still
/// decides whether and how the URL may be opened.
class ClaudeAnchorHtmlSyntax extends md.InlineSyntax {
  ClaudeAnchorHtmlSyntax()
    : super(
        r'''<a\s+[^>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]*?)</a\s*>''',
        startCharacter: 0x3C,
        caseSensitive: false,
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final href = match.group(1) ?? match.group(2) ?? match.group(3) ?? '';
    final link = md.Element('a', parser.document.parseInline(match.group(4)!));
    link.attributes['href'] = href;
    parser.addNode(link);
    return true;
  }
}

Map<String, MarkdownElementBuilder> createClaudeInlineBuilders({
  required Color highlightColor,
  required Color inlineCodeColor,
}) => <String, MarkdownElementBuilder>{
  'sup': ClaudeScriptBuilder(superscript: true),
  'sub': ClaudeScriptBuilder(superscript: false),
  'mark': ClaudeStyledInlineBuilder(
    backgroundColor: highlightColor,
    fontWeight: FontWeight.w600,
  ),
  'u': ClaudeStyledInlineBuilder(decoration: TextDecoration.underline),
  'kbd': ClaudeStyledInlineBuilder(
    backgroundColor: inlineCodeColor,
    fontFamily: 'monospace',
    fontWeight: FontWeight.w600,
  ),
  'small': ClaudeStyledInlineBuilder(fontScale: .84),
};

class ClaudeScriptBuilder extends MarkdownElementBuilder {
  ClaudeScriptBuilder({required this.superscript});

  final bool superscript;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final base =
        parentStyle ?? preferredStyle ?? DefaultTextStyle.of(context).style;
    final fontSize = (base.fontSize ?? 14) * .72;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Transform.translate(
              offset: Offset(0, superscript ? -fontSize * .34 : fontSize * .22),
              child: Text(
                element.textContent,
                textScaler: MediaQuery.textScalerOf(context),
                style: base.copyWith(fontSize: fontSize, height: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ClaudeStyledInlineBuilder extends MarkdownElementBuilder {
  ClaudeStyledInlineBuilder({
    this.backgroundColor,
    this.decoration,
    this.fontFamily,
    this.fontWeight,
    this.fontScale = 1,
  });

  final Color? backgroundColor;
  final TextDecoration? decoration;
  final String? fontFamily;
  final FontWeight? fontWeight;
  final double fontScale;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final base =
        parentStyle ?? preferredStyle ?? DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        text: element.textContent,
        style: base.copyWith(
          backgroundColor: backgroundColor,
          decoration: decoration,
          fontFamily: fontFamily,
          fontWeight: fontWeight,
          fontSize: (base.fontSize ?? 14) * fontScale,
        ),
      ),
    );
  }
}
