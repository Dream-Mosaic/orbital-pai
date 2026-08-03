import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/meridian/voice_md.dart';

void main() {
  group('inline', () {
    test('plain text is one span', () {
      expect(parseInlineMarkdown('hello there'), [const MdSpan('hello there')]);
    });

    test('**strong** becomes a bold span', () {
      expect(parseInlineMarkdown('a **b** c'), [
        const MdSpan('a '),
        const MdSpan('b', bold: true),
        const MdSpan(' c'),
      ]);
    });

    test('__strong__ works the same way', () {
      expect(parseInlineMarkdown('a __b__ c'), [
        const MdSpan('a '),
        const MdSpan('b', bold: true),
        const MdSpan(' c'),
      ]);
    });

    test('*emphasis* becomes an italic span', () {
      expect(parseInlineMarkdown('a *b* c'), [
        const MdSpan('a '),
        const MdSpan('b', italic: true),
        const MdSpan(' c'),
      ]);
    });

    test('_emphasis_ becomes an italic span', () {
      expect(parseInlineMarkdown('a _b_ c'), [
        const MdSpan('a '),
        const MdSpan('b', italic: true),
        const MdSpan(' c'),
      ]);
    });

    test('emphasis nests inside strong', () {
      expect(parseInlineMarkdown('**a _b_**'), [
        const MdSpan('a ', bold: true),
        const MdSpan('b', bold: true, italic: true),
      ]);
    });

    test('`code` becomes a code span', () {
      expect(parseInlineMarkdown('run `mix test` now'), [
        const MdSpan('run '),
        const MdSpan('mix test', code: true),
        const MdSpan(' now'),
      ]);
    });

    test('markdown inside a code span stays literal', () {
      expect(parseInlineMarkdown('`a * b * c`'),
          [const MdSpan('a * b * c', code: true)]);
    });

    test('an unmatched backtick stays literal', () {
      expect(parseInlineMarkdown('90% ` done'), [const MdSpan('90% ` done')]);
    });

    // --- the three the naive parser gets wrong ---

    test('snake_case identifiers are not italicised', () {
      // CommonMark (and therefore marked) forbids INTRAWORD `_` emphasis. The
      // brain emits snake_case constantly — tool names, file paths, atom keys —
      // and a naive indexOf('_') turns `mix_test_now` into mix + <em>test</em>.
      expect(parseInlineMarkdown('run mix_test_now'),
          [const MdSpan('run mix_test_now')]);
    });

    test('an unmatched ** does not bold the rest of the line', () {
      // With no closing delimiter the web leaves it literal; a toggle-on-sight
      // parser bolds everything from there to the end of the answer.
      expect(parseInlineMarkdown('the ** operator is power'),
          [const MdSpan('the ** operator is power')]);
    });

    test('a spaced asterisk is arithmetic, not emphasis', () {
      // CommonMark's flanking rule: a delimiter followed by whitespace cannot
      // open emphasis. Otherwise `2 * 3 * 4` italicises " 3 ".
      expect(parseInlineMarkdown('2 * 3 * 4'), [const MdSpan('2 * 3 * 4')]);
    });

    test('the OPENING flanking rule is enforced independently', () {
      // '2 * 3 * 4' above is symmetric, so the closing rule alone rescues it and
      // the opening one goes untested. Here only the opening rule can: the
      // closer ('3*') is validly flanked, so without it " 3" italicises.
      expect(parseInlineMarkdown('2 * 3* 4'), [const MdSpan('2 * 3* 4')]);
    });

    test('an intraword _ cannot CLOSE emphasis', () {
      // Opener is validly flanked (start of line, letter after), so only the
      // CLOSING intraword rule stops 'foo bar' italicising and 'baz' dangling.
      expect(parseInlineMarkdown('_foo bar_baz'),
          [const MdSpan('_foo bar_baz')]);
    });

    test('a delimiter preceded by whitespace cannot CLOSE emphasis', () {
      expect(parseInlineMarkdown('*foo *bar'), [const MdSpan('*foo *bar')]);
    });

    test('an opener does not reach across a nearer delimiter', () {
      // marked pairs a closer with the NEAREST opener, so the first `*` is left
      // literal and the second one owns "bar". An implementation that scanned
      // past the invalid closer at index 5 would emphasise "foo *bar" instead.
      expect(parseInlineMarkdown('*foo *bar* baz'), [
        const MdSpan('*foo '),
        const MdSpan('bar', italic: true),
        const MdSpan(' baz'),
      ]);
    });

    test('an intraword _ cannot OPEN emphasis either', () {
      // Same gap on the underscore side: in 'mix_test_now' the CLOSING guard
      // already rejects it. Here the closer is followed by a space, so it is a
      // valid closer, and only the opening rule keeps 'a_b_' literal.
      expect(parseInlineMarkdown('a_b_ c'), [const MdSpan('a_b_ c')]);
    });
  });

  group('blocks', () {
    test('a blank line splits paragraphs', () {
      final blocks = parseVoiceMarkdown('one\n\ntwo');
      expect(blocks, hasLength(2));
      expect((blocks[0] as MdParagraph).spans.single.text, 'one');
      expect((blocks[1] as MdParagraph).spans.single.text, 'two');
    });

    test('a single newline is a hard break inside one paragraph (breaks:true)', () {
      final blocks = parseVoiceMarkdown('one\ntwo');
      expect(blocks, hasLength(1));
      expect((blocks.single as MdParagraph).spans.single.text, 'one\ntwo');
    });

    test('- items become an unordered list', () {
      final blocks = parseVoiceMarkdown('shopping:\n- milk\n- **eggs**');
      expect(blocks, hasLength(2));
      final list = blocks[1] as MdList;
      expect(list.ordered, isFalse);
      expect(list.items, hasLength(2));
      expect(list.items[0].single.text, 'milk');
      expect(list.items[1].single, const MdSpan('eggs', bold: true));
    });

    test('1. items become an ordered list', () {
      final list = parseVoiceMarkdown('1. first\n2. second').single as MdList;
      expect(list.ordered, isTrue);
      expect(list.items.map((i) => i.single.text), ['first', 'second']);
    });

    test('a switch of list type starts a new block', () {
      final blocks = parseVoiceMarkdown('- a\n1. b');
      expect(blocks, hasLength(2));
      expect((blocks[0] as MdList).ordered, isFalse);
      expect((blocks[1] as MdList).ordered, isTrue);
    });

    test('an empty string produces no blocks', () {
      expect(parseVoiceMarkdown(''), isEmpty);
    });

    test('whitespace-only input produces no blocks', () {
      expect(parseVoiceMarkdown('   \n\n  \n'), isEmpty);
    });
  });

  group('render', () {
    testWidgets('renders paragraphs and bullets', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: VoiceMarkdown(
            text: 'here you go:\n\n- milk\n- eggs',
            baseStyle: TextStyle(fontSize: 14),
          ),
        ),
      ));
      expect(find.textContaining('here you go:'), findsOneWidget);
      expect(find.text('• '), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('ordered lists number their markers', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: VoiceMarkdown(
            text: '1. first\n2. second',
            baseStyle: TextStyle(fontSize: 14),
          ),
        ),
      ));
      expect(find.text('1. '), findsOneWidget);
      expect(find.text('2. '), findsOneWidget);
    });

    testWidgets('strong is weight 600 and code is monospace', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: VoiceMarkdown(
            text: 'a **b** and `c`',
            baseStyle: TextStyle(fontSize: 14),
          ),
        ),
      ));
      final rich = tester.widget<Text>(find.byType(Text).first);
      final spans = (rich.textSpan! as TextSpan).children!.cast<TextSpan>();
      expect(spans.firstWhere((s) => s.text == 'b').style!.fontWeight,
          FontWeight.w600, reason: '.voice-md strong { font-weight: 600 }');
      expect(spans.firstWhere((s) => s.text == 'c').style!.fontFamily,
          'monospace', reason: '.voice-md code { font-family: ui-monospace }');
    });

    testWidgets('a long list item wraps instead of overflowing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: VoiceMarkdown(
              text: '- ${'word ' * 40}',
              baseStyle: const TextStyle(fontSize: 14),
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull,
          reason: 'an unbounded Row child would overflow a narrow bezel');
    });
  });
}
