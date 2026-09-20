/// Private library metadata shared by imported GPX files and actual rides.
/// Folder paths are labels (e.g. `Trips/France`), never filesystem paths.
class RideLibraryOrganisation {
  const RideLibraryOrganisation({
    this.tags = const [],
    this.folder = '',
    this.colourArgb = defaultColour,
  });

  static const defaultColour = 0xFF00A896;
  static const colours = [
    defaultColour,
    0xFF2F80ED,
    0xFFFF7A1A,
    0xFFE65480,
    0xFFAB73EF,
    0xFFFFC857,
  ];
  final List<String> tags;
  final String folder;
  final int colourArgb;

  factory RideLibraryOrganisation.fromInput({
    String tags = '',
    String folder = '',
    int colourArgb = defaultColour,
  }) {
    final cleaned = <String>{};
    for (final tag in tags.toLowerCase().split(RegExp(r'[\s,#]+'))) {
      if (RegExp(r'^[\p{L}\p{N}_-]{1,32}$', unicode: true).hasMatch(tag)) {
        cleaned.add(tag);
      }
    }
    final path = folder
        .split('/')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join('/');
    return RideLibraryOrganisation(
      tags: List.unmodifiable(cleaned.take(20)),
      folder: path.length > 120 ? path.substring(0, 120) : path,
      colourArgb: 0xFF000000 | (colourArgb & 0xFFFFFF),
    );
  }

  Map<String, Object?> toJson() => {
    'tags': tags,
    'folder': folder,
    'colourArgb': colourArgb,
  };

  factory RideLibraryOrganisation.fromJson(Object? value) {
    if (value is! Map) return const RideLibraryOrganisation();
    return RideLibraryOrganisation.fromInput(
      tags: value['tags'] is List
          ? (value['tags'] as List).whereType<String>().join(' ')
          : '',
      folder: value['folder'] is String ? value['folder'] as String : '',
      colourArgb: (value['colourArgb'] as num?)?.toInt() ?? defaultColour,
    );
  }

  bool inFolder(String parent) =>
      folder == parent || (parent.isNotEmpty && folder.startsWith('$parent/'));
}
