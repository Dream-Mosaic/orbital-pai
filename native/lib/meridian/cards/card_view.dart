import 'package:flutter/material.dart';

import '../thread_model.dart';
import 'agenda_card.dart';
import 'email_card.dart';
import 'list_card.dart';
import 'reminders_card.dart';
import 'weather_card.dart';

/// Picks a [ThreadCard]'s layout by its server-sent type. The router already
/// drops unknown types; the fallthrough here is belt-and-braces, and renders
/// nothing rather than a guess.
class ThreadCardView extends StatelessWidget {
  const ThreadCardView({super.key, required this.card});

  final ThreadCard card;

  @override
  Widget build(BuildContext context) => switch (card.type) {
        'weather' => WeatherCard(data: card.data),
        'agenda' => AgendaCard(data: card.data),
        'list' => ListCard(data: card.data),
        'reminders' => RemindersCard(data: card.data),
        'email' => EmailCard(data: card.data),
        _ => const SizedBox.shrink(),
      };
}
