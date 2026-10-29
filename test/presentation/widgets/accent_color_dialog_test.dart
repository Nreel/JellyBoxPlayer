import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/presentation/themes/themes.dart';
import 'package:jplayer/src/presentation/widgets/accent_color_picker.dart';
import 'package:jplayer/src/presentation/widgets/form_modal.dart';

const teal = Color(0xFF2ECDB0);

/// Opens the picker and returns a completer that fires when the dialog is
/// dismissed, so callers can tap an action before observing the result.
Future<Completer<Color?>> dialogResult(WidgetTester tester, Color initial) async {
  final completer = Completer<Color?>();

  await tester.pumpWidget(
    MaterialApp(
      theme: Themes.withAccent(initial),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final popped = await showAppDialog<Color>(
                context,
                builder: (context) => AccentColorDialog(initial: initial),
              );
              if (!completer.isCompleted) completer.complete(popped);
            },
            child: const Text('open-picker'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open-picker'));
  await tester.pumpAndSettle();
  expect(find.text('Accent colour'), findsOneWidget);
  expect(find.byType(Slider), findsNWidgets(3));

  return completer;
}

void main() {
  testWidgets('apply returns the untouched initial colour', (tester) async {
    final completer = await dialogResult(tester, teal);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(await completer.future, teal);
  });

  testWidgets('moving the hue slider changes the applied colour', (tester) async {
    final completer = await dialogResult(tester, teal);
    await tester.drag(find.byType(Slider).first, const Offset(-250, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    final applied = await completer.future;

    expect(applied, isNotNull);
    expect(HSVColor.fromColor(applied!).hue, isNot(HSVColor.fromColor(teal).hue));
  });

  testWidgets('reset returns the default accent', (tester) async {
    final completer = await dialogResult(tester, teal);
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(await completer.future, Themes.defaultAccent);
  });

  testWidgets('cancel returns null', (tester) async {
    final completer = await dialogResult(tester, teal);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await completer.future, isNull);
  });
}
