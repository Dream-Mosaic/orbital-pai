import 'package:flutter/material.dart';

/// A markdown **subset** renderer matched exactly to `.voice-md` in
/// server/assets/css/app.css — p, ul, ol, li, strong, em, code — with `marked`'s
/// `breaks: true` (index.js:14), so a single newline is a hard break.
///
/// This is deliberately NOT a CommonMark implementation: `flutter_markdown` is
/// discontinued upstream, and the stylesheet only ever styles the elements above,
/// so anything else would be dead weight. Unrecognised syntax falls through as
/// literal text — the same failure mode as the web's `renderBrainMarkdown()`
/// catch block (index.js:659-665).
///
/// Known gaps vs marked, all of which degrade to literal text rather than to
/// mangled text: links, images, headings, blockquotes, fenced code blocks,
/// nested lists, and `***both***`.
@immutable
class MdSpan {
  const MdSpan(this.text,
      {this.bold = false, this.italic = false, this.code = false});

  final String text;
  final bool bold;
  final bool italic;
  final bool code;

  @override
  bool operator ==(Object other) =>
      other is MdSpan &&
      other.text == text &&
      other.bold == bold &&
      other.italic == italic &&
      other.code == code;

  @override
  int get hashCode => Object.hash(text, bold, italic, code);

  @override
  String toString() =>
      'MdSpan("$text", bold: $bold, italic: $italic, code: $code)';
}

sealed class MdBlock {
  const MdBlock();
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.spans);

  /// A `\n` inside a span's text is a hard break, not a paragraph split.
  final List<MdSpan> spans;
}

class MdList extends MdBlock {
  const MdList({required this.ordered, required this.items});

  final bool ordered;
  final List<List<MdSpan>> items;
}

final RegExp _bulletRe = RegExp(r'^\s{0,3}[-*+]\s+(.*)$');
final RegExp _orderedRe = RegExp(r'^\s{0,3}\d+[.)]\s+(.*)$');

List<MdBlock> parseVoiceMarkdown(String src) {
  final blocks = <MdBlock>[];
  final lines = src.replaceAll('\r\n', '\n').split('\n');

  var para = <String>[];
  var items = <List<MdSpan>>[];
  var ordered = false;

  void flushPara() {
    if (para.isEmpty) return;
    blocks.add(MdParagraph(parseInlineMarkdown(para.join('\n'))));
    para = <String>[];
  }

  void flushList() {
    if (items.isEmpty) return;
    blocks.add(MdList(ordered: ordered, items: items));
    items = <List<MdSpan>>[];
  }

  for (final raw in lines) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) {
      flushPara();
      flushList();
      continue;
    }
    final bullet = _bulletRe.firstMatch(line);
    final numbered = _orderedRe.firstMatch(line);
    if (bullet != null || numbered != null) {
      flushPara();
      final wantOrdered = numbered != null;
      if (items.isNotEmpty && ordered != wantOrdered) flushList();
      ordered = wantOrdered;
      items.add(parseInlineMarkdown(
          wantOrdered ? numbered.group(1)! : bullet!.group(1)!));
      continue;
    }
    flushList();
    para.add(line);
  }
  flushPara();
  flushList();
  return blocks;
}

final RegExp _wordChar = RegExp(r'[A-Za-z0-9]');

bool _isSpace(String c) => c.trim().isEmpty;

/// CommonMark's flanking rules, trimmed to the two that actually matter for text
/// a language model writes. Without them:
///   * `2 * 3 * 4` italicises " 3 " (a delimiter followed by whitespace must not
///     be able to open emphasis), and
///   * `mix_test_now` becomes mix<em>test</em>now (`_` cannot open or close
///     INTRAWORD — the brain emits snake_case constantly).
/// Returns the index of the closing delimiter, or null if this one cannot open.
int? _findEmphasisClose(String src, int open, String delim) {
  if (open + 1 >= src.length) return null;
  if (_isSpace(src[open + 1])) return null;
  if (delim == '_' && open > 0 && _wordChar.hasMatch(src[open - 1])) return null;

  // Only the NEAREST candidate is considered. Scanning past an invalid one to
  // find a later valid closer would let an opener reach across an intervening
  // delimiter: in `*foo *bar* baz` it would emphasise "foo *bar", where marked
  // pairs the closer with the nearest opener and yields `*foo <em>bar</em> baz`.
  // Giving up here reproduces that, because the second `*` then opens its own.
  final j = src.indexOf(delim, open + 1);
  if (j <= open + 1) return null;
  if (_isSpace(src[j - 1])) return null;
  if (delim == '_' && j + 1 < src.length && _wordChar.hasMatch(src[j + 1])) {
    return null;
  }
  return j;
}

List<MdSpan> parseInlineMarkdown(String src) {
  final out = <MdSpan>[];
  final buf = StringBuffer();
  // Which delimiter opened the current strong run (`**` or `__`), or null. Kept
  // as the delimiter rather than a bool so `**a__` cannot close across kinds.
  String? boldDelim;
  var i = 0;

  void flush({bool italic = false}) {
    if (buf.isEmpty) return;
    out.add(MdSpan(buf.toString(), bold: boldDelim != null, italic: italic));
    buf.clear();
  }

  while (i < src.length) {
    if (src.startsWith('**', i) || src.startsWith('__', i)) {
      final d = src.substring(i, i + 2);
      if (boldDelim == d) {
        flush();
        boldDelim = null;
        i += 2;
        continue;
      }
      // Only open when there is something to close it. A toggle-on-sight parser
      // turns a stray `**` into bold-until-end-of-answer.
      if (boldDelim == null && src.indexOf(d, i + 2) >= 0) {
        flush();
        boldDelim = d;
        i += 2;
        continue;
      }
      // Otherwise fall through and take both characters literally.
    }

    final ch = src[i];
    if (ch == '`') {
      final end = src.indexOf('`', i + 1);
      if (end > i) {
        flush();
        // Nothing inside a code span is markdown.
        out.add(MdSpan(src.substring(i + 1, end),
            bold: boldDelim != null, code: true));
        i = end + 1;
        continue;
      }
    }

    if (ch == '*' || ch == '_') {
      final close = _findEmphasisClose(src, i, ch);
      if (close != null) {
        flush();
        buf.write(src.substring(i + 1, close));
        flush(italic: true);
        i = close + 1;
        continue;
      }
    }

    buf.write(ch);
    i++;
  }
  flush();
  return out;
}

/// Renders [text] with the `.voice-md` box metrics. CSS margins between siblings
/// COLLAPSE, so two adjacent 0.25rem margins are a 4px gap, not 8px — and the
/// stylesheet zeroes the first child's top and the last child's bottom, which is
/// why there is no outer padding here at all.
class VoiceMarkdown extends StatelessWidget {
  const VoiceMarkdown({super.key, required this.text, required this.baseStyle});

  final String text;
  final TextStyle baseStyle;

  static const double _blockGap = 4.0; // .voice-md p / ul / ol margin 0.25rem
  static const double _itemGap = 1.6; // .voice-md li margin 0.1rem
  static const double _listIndent = 20.0; // .voice-md ul/ol padding-left 1.25rem

  @override
  Widget build(BuildContext context) {
    final blocks = parseVoiceMarkdown(text);
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0) children.add(const SizedBox(height: _blockGap));
      children.add(_block(blocks[i]));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _block(MdBlock block) => switch (block) {
        MdParagraph(:final spans) =>
          Text.rich(TextSpan(children: _spans(spans)), style: baseStyle),
        MdList(:final ordered, :final items) => Padding(
            padding: const EdgeInsets.only(left: _listIndent),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < items.length; i++)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : _itemGap),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(ordered ? '${i + 1}. ' : '• ', style: baseStyle),
                        // Flexible, not Expanded: a short item must not stretch,
                        // but a long one has to wrap inside a 272px bezel.
                        Flexible(
                          child: Text.rich(
                            TextSpan(children: _spans(items[i])),
                            style: baseStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      };

  List<InlineSpan> _spans(List<MdSpan> spans) => [
        for (final s in spans)
          TextSpan(
            text: s.text,
            style: TextStyle(
              // .voice-md strong { font-weight: 600 }
              fontWeight: s.bold ? FontWeight.w600 : null,
              fontStyle: s.italic ? FontStyle.italic : null,
              // .voice-md code { font-family: ui-monospace, monospace }
              fontFamily: s.code ? 'monospace' : null,
            ),
          ),
      ];
}
