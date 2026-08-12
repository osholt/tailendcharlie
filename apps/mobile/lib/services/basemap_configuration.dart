class BasemapConfiguration {
  static const defaultLightStyleUrl =
      'https://tiles.openfreemap.org/styles/liberty';
  static const defaultDarkStyleUrl =
      'https://tiles.openfreemap.org/styles/dark';

  const BasemapConfiguration({
    this.styleUrl = '',
    this.darkStyleUrl = '',
    this.urlTemplate = '',
    this.attribution = '',
    this.cacheNamespace = defaultCacheNamespace,
    this.persistentCachingAllowed = true,
    this.maximumNativeZoom = 18,
  });

  factory BasemapConfiguration.fromEnvironment() => BasemapConfiguration(
    styleUrl: const String.fromEnvironment(
      'RIDE_RELAY_MAP_STYLE_URL',
      defaultValue: defaultLightStyleUrl,
    ),
    darkStyleUrl: const String.fromEnvironment(
      'RIDE_RELAY_MAP_STYLE_URL_DARK',
      defaultValue: defaultDarkStyleUrl,
    ),
    urlTemplate: const String.fromEnvironment('RIDE_RELAY_TILE_URL'),
    attribution: const String.fromEnvironment(
      'RIDE_RELAY_TILE_ATTRIBUTION',
      defaultValue: 'OpenFreeMap © OpenMapTiles Data from OpenStreetMap',
    ),
    cacheNamespace: const String.fromEnvironment(
      'RIDE_RELAY_TILE_CACHE_NAMESPACE',
      defaultValue: defaultCacheNamespace,
    ),
    persistentCachingAllowed: const bool.fromEnvironment(
      'RIDE_RELAY_TILE_CACHE_ALLOWED',
      // Approved by the project owner for the default provider, so caching is on
      // unless a build deliberately turns it off. It defaulted to false while the
      // licence question was open, and that default was itself a bug on an
      // offline-first app: with no cached tiles a rural signal gap leaves no
      // basemap at all and nothing to fall back on, which is what a tester saw as
      // "just a blob or dot where you are and a tail where you been" (#274, #281).
      defaultValue: true,
    ),
    maximumNativeZoom: const int.fromEnvironment(
      'RIDE_RELAY_TILE_MAX_ZOOM',
      defaultValue: 18,
    ),
  );

  /// HTTPS MapLibre style document used by the production vector-map path.
  final String styleUrl;

  /// HTTPS MapLibre style document used at night/in dark mode. Both styles
  /// are expected to render the same underlying vector tiles, just restyled
  /// - so offline-cached tiles remain shared and reusable between them.
  final String darkStyleUrl;

  /// Legacy raster XYZ template retained as a route-only development fallback.
  final String urlTemplate;
  final String attribution;
  final String cacheNamespace;
  final bool persistentCachingAllowed;

  /// Names the provider whose tiles are cached, so a build that changes provider
  /// cannot serve the previous one's tiles out of the old cache. Tied to the
  /// default style; override it alongside the style URL.
  static const defaultCacheNamespace = 'openfreemap';
  final int maximumNativeZoom;

  /// A copy using [darkStyleUrl] in place of [styleUrl] when [dark] is true
  /// and a dark style is actually configured; otherwise unchanged.
  BasemapConfiguration forBrightness({required bool dark}) {
    if (!dark || darkStyleUrl.trim().isEmpty) return this;
    return BasemapConfiguration(
      styleUrl: darkStyleUrl,
      darkStyleUrl: darkStyleUrl,
      urlTemplate: urlTemplate,
      attribution: attribution,
      cacheNamespace: cacheNamespace,
      persistentCachingAllowed: persistentCachingAllowed,
      maximumNativeZoom: maximumNativeZoom,
    );
  }

  bool get usesMapLibre =>
      styleUrl.trim().isNotEmpty &&
      attribution.trim().isNotEmpty &&
      _isSecureHttpUrl(styleUrl) &&
      maximumNativeZoom >= 0 &&
      maximumNativeZoom <= 22;

  bool get usesLegacyRaster =>
      urlTemplate.trim().isNotEmpty &&
      attribution.trim().isNotEmpty &&
      _hasRequiredPlaceholders(urlTemplate) &&
      _isSecureHttpTemplate(urlTemplate) &&
      maximumNativeZoom >= 0 &&
      maximumNativeZoom <= 22;

  bool get isConfigured => usesMapLibre || usesLegacyRaster;

  bool get canDownloadOffline =>
      isConfigured &&
      persistentCachingAllowed &&
      RegExp(r'^[a-zA-Z0-9._-]{1,64}$').hasMatch(cacheNamespace);

  String get statusMessage {
    if (!isConfigured) {
      return 'No MapLibre style is configured. Route geometry still works offline.';
    }
    if (!persistentCachingAllowed) {
      return 'Online basemap configured; offline caching is switched off for this build.';
    }
    if (!RegExp(r'^[a-zA-Z0-9._-]{1,64}$').hasMatch(cacheNamespace)) {
      return 'Offline caching needs a safe provider cache namespace.';
    }
    if (usesMapLibre) {
      return 'MapLibre vector map configured. Downloaded route regions are available offline.';
    }
    return 'Legacy raster basemap configured. Downloaded route corridors are available offline.';
  }

  static bool _hasRequiredPlaceholders(String template) =>
      template.contains('{z}') &&
      template.contains('{x}') &&
      template.contains('{y}');

  static bool _isSecureHttpTemplate(String template) {
    final uri = Uri.tryParse(
      template
          .replaceAll('{z}', '0')
          .replaceAll('{x}', '0')
          .replaceAll('{y}', '0'),
    );
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  static bool _isSecureHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }
}
