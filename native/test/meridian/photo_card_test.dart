import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/meridian/cards/card_view.dart';
import 'package:orbital_pai/meridian/cards/photo_card.dart';
import 'package:orbital_pai/meridian/thread_model.dart';
import 'package:orbital_pai/meridian/tokens.dart';

import '../support/fake_camera.dart';

/// The `photo` card ("Henry, look at this"): the server sends a capture_id
/// and the question, never the picture. The device shows the snapshot it
/// took, or says it no longer has it.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          backgroundColor: M.bg,
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 320, child: child),
          ),
        ),
      );

  const wire = {
    'type': 'photo',
    'capture_id': 'c1',
    'caption': 'what am I holding',
  };

  test('the router accepts a photo card', () {
    final card = ThreadCard.fromWire(wire);
    expect(card, isNotNull);
    expect(card!.type, 'photo');
    expect(card.data['capture_id'], 'c1');
  });

  testWidgets('with the snapshot in memory: the picture and the question',
      (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(host(ThreadCardView(
      card: ThreadCard.fromWire(wire)!,
      photoFor: (id) {
        asked.add(id);
        return kPixel;
      },
    )));

    expect(asked, ['c1']);
    expect(find.byType(PhotoCard), findsOneWidget);
    final image = tester.widget<Image>(find.byKey(const ValueKey('photo-image')));
    expect((image.image as MemoryImage).bytes, kPixel);
    expect(find.text('“what am I holding”'), findsOneWidget);
    expect(find.text('SNAPSHOT'), findsOneWidget);
    expect(find.text('photo not kept'), findsNothing);
    // The frame is the camera's landscape shape, whatever the picture.
    final frame = tester.getSize(find.byType(AspectRatio));
    expect(frame.width / frame.height, closeTo(PhotoCard.aspect, 0.01));
  });

  testWidgets('without it (history, another device): a quiet placeholder',
      (tester) async {
    await tester.pumpWidget(host(ThreadCardView(
      card: ThreadCard.fromWire(wire)!,
      photoFor: (_) => null,
    )));
    expect(find.text('photo not kept'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.text('“what am I holding”'), findsOneWidget);
  });

  testWidgets('no lookup at all (a replay surface) is the same placeholder',
      (tester) async {
    await tester.pumpWidget(host(ThreadCardView(card: ThreadCard.fromWire(wire)!)));
    expect(find.text('photo not kept'), findsOneWidget);
  });

  testWidgets('a card without a caption or an id still renders', (tester) async {
    await tester.pumpWidget(host(const ThreadCardView(
      card: ThreadCard(type: 'photo', data: {'type': 'photo'}),
    )));
    expect(find.text('photo not kept'), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-caption')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bytes for a different capture are not shown', (tester) async {
    final snapshots = {'other': Uint8List.fromList(kPixel)};
    await tester.pumpWidget(host(ThreadCardView(
      card: ThreadCard.fromWire(wire)!,
      photoFor: (id) => snapshots[id],
    )));
    expect(find.text('photo not kept'), findsOneWidget);
  });
}
