import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:henry_wall/meridian/search_panel.dart';

void main() {
  testWidgets('renders the web\'s coming-soon line verbatim', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SearchPanelView()),
    ));
    expect(find.text('Search is coming soon.'), findsOneWidget);
  });
}
