import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/main.dart';

void main() {
  testWidgets('session surface is honest about capture timing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      await tester.pumpWidget(const SonaraApp());
      expect(find.text('Start session'), findsOneWidget);
      expect(find.textContaining('cannot delay'), findsOneWidget);
      await tester.binding.setSurfaceSize(null);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android receiver UI is model independent', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      await tester.pumpWidget(const SonaraApp());
      expect(find.text('Scanning for hosts…'), findsOneWidget);
      expect(find.text('Scanning the local network…'), findsOneWidget);
      expect(find.textContaining('Galaxy'), findsNothing);
      expect(find.textContaining('Samsung'), findsNothing);

      await tester.tap(find.text('Enter invitation manually'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pump();
      expect(find.text('Enter an invitation first.'), findsOneWidget);
      await tester.binding.setSurfaceSize(null);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
