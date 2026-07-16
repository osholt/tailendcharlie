class BasemapConfiguration {
  const BasemapConfiguration({
    this.urlTemplate = '',
    this.attribution = '',
    this.cacheNamespace = '',
    this.persistentCachingAllowed = false,
    this.maximumNativeZoom = 18,
  });

  factory BasemapConfiguration.fromEnvironment() => BasemapConfiguration(
    urlTemplate: const String.fromEnvironment('RIDE_RELAY_TILE_URL'),
    attribution: const String.fromEnvironment('RIDE_RELAY_TILE_ATTRIBUTION'),
    cacheNamespace: const String.fromEnvironment(
      'RIDE_RELAY_TILE_CACHE_NAMESPACE',
    ),
    persistentCachingAllowed: const bool.fromEnvironment(
      'RIDE_RELAY_TILE_CACHE_ALLOWED',
    ),
    maximumNativeZoom: const int.fromEnvironment(
      'RIDE_RELAY_TILE_MAX_ZOOM',
      defaultValue: 18,
    ),
  );

  final String urlTemplate;
  final String attribution;
  final String cacheNamespace;
  final bool persistentCachingAllowed;
  final int maximumNativeZoom;

  bool get isConfigured =>
      urlTemplate.trim().isNotEmpty &&
      attribution.trim().isNotEmpty &&
      _hasRequiredPlaceholders(urlTemplate) &&
      _isSecureHttpTemplate(urlTemplate) &&
      maximumNativeZoom >= 0 &&
      maximumNativeZoom <= 22;

  bool get canDownloadOffline =>
      isConfigured &&
      persistentCachingAllowed &&
      RegExp(r'^[a-zA-Z0-9._-]{1,64}$').hasMatch(cacheNamespace);

  String get statusMessage {
    if (!isConfigured) {
      return 'No licensed tile provider is configured. Route geometry still works offline.';
    }
    if (!persistentCachingAllowed) {
      return 'Online basemap configured; its licence has not been approved for offline caching.';
    }
    if (!RegExp(r'^[a-zA-Z0-9._-]{1,64}$').hasMatch(cacheNamespace)) {
      return 'Offline caching needs a safe provider cache namespace.';
    }
    return 'Licensed basemap configured. Downloaded route corridors are available offline.';
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
}
