import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/basemap_configuration.dart';

void main() {
  const configuration = BasemapConfiguration(
    styleUrl: 'https://tiles.example.test/styles/liberty',
    darkStyleUrl: 'https://tiles.example.test/styles/dark',
    attribution: 'Example',
    maximumNativeZoom: 18,
  );

  test('forBrightness(dark: true) swaps in the dark style URL', () {
    final dark = configuration.forBrightness(dark: true);

    expect(dark.styleUrl, 'https://tiles.example.test/styles/dark');
    expect(dark.usesMapLibre, isTrue);
  });

  test('forBrightness(dark: false) leaves the configuration unchanged', () {
    final light = configuration.forBrightness(dark: false);

    expect(light.styleUrl, configuration.styleUrl);
    expect(light.dark, isFalse);
    expect(identical(light, configuration), isTrue);
  });

  test('forBrightness can return a resolved dark style to daytime chrome', () {
    final dark = configuration.forBrightness(dark: true);
    final light = dark.forBrightness(dark: false);

    expect(dark.dark, isTrue);
    expect(light.dark, isFalse);
  });

  test('forBrightness can preserve the original daytime style', () {
    final light = configuration.forBrightness(
      dark: false,
      restrainedLightStyle: false,
    );

    expect(light.styleUrl, configuration.styleUrl);
    expect(light.restrainedLightStyle, isFalse);
    expect(identical(light, configuration), isFalse);
  });

  test('forBrightness(dark: true) is a no-op without a dark style URL', () {
    const noDarkStyle = BasemapConfiguration(
      styleUrl: 'https://tiles.example.test/styles/liberty',
      attribution: 'Example',
    );

    final resolved = noDarkStyle.forBrightness(dark: true);

    expect(resolved.styleUrl, noDarkStyle.styleUrl);
  });

  test('original daytime choice survives when no dark style is configured', () {
    const noDarkStyle = BasemapConfiguration(
      styleUrl: BasemapConfiguration.defaultLightStyleUrl,
      attribution: 'Example',
    );

    final resolved = noDarkStyle.forBrightness(
      dark: true,
      restrainedLightStyle: false,
    );

    expect(resolved.styleUrl, noDarkStyle.styleUrl);
    expect(resolved.restrainedLightStyle, isFalse);
  });

  test('fromEnvironment defaults to the OpenFreeMap dark style', () {
    final environment = BasemapConfiguration.fromEnvironment();

    expect(
      environment.darkStyleUrl,
      'https://tiles.openfreemap.org/styles/dark',
    );
  });
}
