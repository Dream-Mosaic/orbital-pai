import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../tokens.dart';
import 'card_frame.dart';

/// `look` ("Henry, look at this"): the snapshot Henry looked at, with what he
/// was asked about it under it.
///
/// The server sends no picture — it never keeps one (spec 2026-10-23 §1). The
/// card carries only the `capture_id`, and the bytes are the ones THIS device
/// took and still holds in memory ([bytes]). A card replayed from history, or
/// shown on a device that didn't take it, says so quietly instead.
class PhotoCard extends StatelessWidget {
  const PhotoCard({super.key, required this.data, this.bytes});

  final Map<String, dynamic> data;

  /// The JPEG, when this device still has it.
  final Uint8List? bytes;

  static const Color accent = M.chrome;

  /// The picture's frame: the camera's own landscape shape, cropped to it, so
  /// every snapshot card sits the same size in the thread.
  static const double aspect = 4 / 3;

  @override
  Widget build(BuildContext context) {
    final caption = data.str('caption');
    final b = bytes;
    return CardFrame(
      accent: accent,
      label: 'Snapshot',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          b != null ? _photo(b) : const _NotKept(),
          if (caption != null) ...[
            const SizedBox(height: 8),
            Text(
              '“$caption”',
              key: const ValueKey('photo-caption'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: CardStyle.body(12, colour: M.youBody, weight: 440),
            ),
          ],
        ],
      ),
    );
  }

  Widget _photo(Uint8List b) => ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: AspectRatio(
          aspectRatio: aspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF05060B)),
              Image.memory(
                b,
                key: const ValueKey('photo-image'),
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
              // The same hairline edge the card's own glass has.
              const DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(9)),
                  border: Border.fromBorderSide(
                      BorderSide(color: CardStyle.edge)),
                ),
              ),
            ],
          ),
        ),
      );
}

/// What a photo card shows without its picture: one dim line, no fuss.
class _NotKept extends StatelessWidget {
  const _NotKept();

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('photo-not-kept'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0x06FFFFFF),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: CardStyle.rule),
        ),
        child: Text(
          'photo not kept',
          style: CardStyle.meta(10.8).copyWith(fontStyle: FontStyle.italic),
        ),
      );
}
