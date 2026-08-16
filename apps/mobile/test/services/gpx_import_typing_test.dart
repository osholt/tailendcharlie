import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

/// #580. A tester could not import GPX files that imported cleanly on the
/// operator's phone, on iOS, with no parse error to go on.
///
/// The iOS document picker filters by **type**, not by extension, and a `.gpx`
/// file that arrived through a channel which dropped its type is generic
/// `public.data`. A declaration conforming only to `public.xml` does not claim
/// such a file, so the picker greys it out — which reads to a rider as "the app
/// will not import it", and differs between two phones on the same build
/// depending on how the file arrived.
///
/// These assert the declaration stays complete. A plist is easy to break
/// silently and nothing else in the suite reads it.
void main() {
  late XmlElement declaration;

  setUpAll(() {
    final plist = XmlDocument.parse(
      File('ios/Runner/Info.plist').readAsStringSync(),
    );
    final root = plist.rootElement.findElements('dict').single;
    declaration = _arrayFor(
      root,
      'UTImportedTypeDeclarations',
    ).findElements('dict').single;
  });

  test('the GPX type is claimed by identifier, extension and MIME type', () {
    expect(_stringFor(declaration, 'UTTypeIdentifier'), 'com.topografix.gpx');

    final tags = _dictFor(declaration, 'UTTypeTagSpecification');
    expect(_stringsIn(_arrayFor(tags, 'public.filename-extension')), ['gpx']);
    expect(
      _stringsIn(_arrayFor(tags, 'public.mime-type')),
      containsAll(<String>['application/gpx+xml', 'application/xml']),
      reason: 'a file delivered by MIME type has no extension to key off',
    );
  });

  test('a generically typed GPX file is still claimed', () {
    // The half that was missing. `public.xml` alone leaves a file iOS typed as
    // plain data unselectable in the picker, with no error anywhere.
    expect(
      _stringsIn(_arrayFor(declaration, 'UTTypeConformsTo')),
      containsAll(<String>['public.xml', 'public.data']),
    );
  });

  test('every type the picker accepts is one the app declares or iOS owns', () {
    // Keeps `SystemGpxImportSource` and this declaration from drifting apart:
    // a UTI in the picker that nothing declares matches nothing at all.
    const accepted = ['com.topografix.gpx', 'public.xml'];
    const systemOwned = {'public.xml', 'public.data', 'public.item'};

    for (final identifier in accepted) {
      expect(
        systemOwned.contains(identifier) ||
            identifier == _stringFor(declaration, 'UTTypeIdentifier'),
        isTrue,
        reason: '$identifier is accepted by the picker but declared nowhere',
      );
    }
  });
}

/// Reads the `<array>` that follows `<key>name</key>` in a plist `<dict>`.
///
/// A plist dict is a flat run of alternating key and value elements rather than
/// a nesting, so a value is found by its position after its key.
XmlElement _arrayFor(XmlElement dict, String name) =>
    _valueFor(dict, name, 'array');

XmlElement _dictFor(XmlElement dict, String name) =>
    _valueFor(dict, name, 'dict');

String _stringFor(XmlElement dict, String name) =>
    _valueFor(dict, name, 'string').innerText;

XmlElement _valueFor(XmlElement dict, String name, String expected) {
  final children = dict.childElements.toList(growable: false);
  for (var index = 0; index < children.length - 1; index += 1) {
    final child = children[index];
    if (child.name.local == 'key' && child.innerText == name) {
      final value = children[index + 1];
      expect(
        value.name.local,
        expected,
        reason: '$name should hold a <$expected>',
      );
      return value;
    }
  }
  fail('$name is missing from the plist');
}

List<String> _stringsIn(XmlElement array) => array
    .findElements('string')
    .map((element) => element.innerText)
    .toList(growable: false);
