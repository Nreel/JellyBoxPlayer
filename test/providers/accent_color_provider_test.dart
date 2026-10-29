import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/data/providers/shared_preferences_provider.dart';
import 'package:jplayer/src/domain/providers/app_settings_provider.dart';
import 'package:jplayer/src/presentation/themes/themes.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../provider_container.dart';

/// Builds a container whose prefs future is resolved before the settings
/// notifier is created; seed values with [SharedPreferences
/// .setMockInitialValues] beforehand.
Future<ProviderContainer> containerFromPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  final container = createProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWith((_) async => prefs)],
  );
  await container.read(sharedPreferencesProvider.future);
  return container;
}

void main() {
  test('unset accent falls back to the default red', () async {
    SharedPreferences.setMockInitialValues({});
    final container = await containerFromPrefs();
    expect(container.read(appAccentColorProvider), Themes.defaultAccent);
  });

  test('stored hex drives the accent provider', () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({'accent_color': '2ecdb0'}),
    });
    final container = await containerFromPrefs();
    expect(container.read(appAccentColorProvider), const Color(0xFF2ECDB0));
  });

  test('hex with leading # is accepted', () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({'accent_color': '#3dbf5e'}),
    });
    final container = await containerFromPrefs();
    expect(container.read(appAccentColorProvider), const Color(0xFF3DBF5E));
  });

  test('invalid stored value falls back to the default', () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({'accent_color': 'not-a-color'}),
    });
    final container = await containerFromPrefs();
    expect(container.read(appAccentColorProvider), Themes.defaultAccent);
  });

  test('setValue persists the accent across containers', () async {
    SharedPreferences.setMockInitialValues({});
    final container = await containerFromPrefs();
    expect(container.read(appAccentColorProvider), Themes.defaultAccent);

    container
        .read(appSettingsProvider.notifier)
        .setValue(AppSetting.accentColor, '8c6bff');
    expect(container.read(appAccentColorProvider), const Color(0xFF8C6BFF));

    final reopened = await containerFromPrefs();
    expect(reopened.read(appAccentColorProvider), const Color(0xFF8C6BFF));
  });

  group('Themes.withAccent', () {
    const teal = Color(0xFF2ECDB0);

    test('primary and Cupertino contrast follow the accent', () {
      final theme = Themes.withAccent(teal);
      expect(theme.colorScheme.primary, teal);
      expect(theme.cupertinoOverrideTheme?.primaryContrastingColor, teal);
    });

    test('panel tones keep the accent hue', () {
      final theme = Themes.withAccent(teal);
      final accentHue = HSVColor.fromColor(teal).hue;
      expect(
        HSVColor.fromColor(theme.bottomSheetTheme.backgroundColor!).hue,
        closeTo(accentHue, 1.5),
      );
      expect(
        HSVColor.fromColor(theme.bottomNavigationBarTheme.backgroundColor!).hue,
        closeTo(accentHue, 1.5),
      );
    });

    test('identical accents reuse the cached theme', () {
      expect(Themes.withAccent(teal), same(Themes.withAccent(teal)));
      expect(
        Themes.withAccent(Themes.defaultAccent),
        isNot(same(Themes.withAccent(teal))),
      );
    });
  });
}
