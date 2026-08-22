import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/flutter_vector_route_preview.dart';

void main() {
  test('library thumbnail padding leaves room to fit the complete track', () {
    const viewport = Size.square(52);

    final padding = routePreviewCameraPadding(viewport);

    expect(padding, const EdgeInsets.all(14));
    expect(viewport.width - padding.horizontal, 24);
    expect(viewport.height - padding.vertical, 24);
  });

  test('normal route previews retain the full camera inset', () {
    expect(
      routePreviewCameraPadding(const Size(390, 220)),
      const EdgeInsets.all(30),
    );
  });
}
