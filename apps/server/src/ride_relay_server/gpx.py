from __future__ import annotations

from xml.etree import ElementTree

_TRACK_POINT_NAMES = {"trkpt", "rtept", "wpt"}


class GpxValidationError(ValueError):
    pass


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1].lower()


def validate_gpx(text: str, *, maximum_bytes: int, maximum_points: int) -> int:
    """Mirrors the mobile GpxParser's bounds (docs/maps-and-gpx.md) so a plan
    can never smuggle in something the phone would itself reject. Returns the
    track/route/waypoint point count.
    """
    if not text:
        raise GpxValidationError("The GPX file is empty.")
    if len(text.encode("utf-8")) > maximum_bytes:
        raise GpxValidationError(
            f"The GPX file exceeds the {maximum_bytes // (1024 * 1024)} MB import limit."
        )
    if "<!DOCTYPE" in text.upper():
        raise GpxValidationError(
            "GPX files containing a document type declaration are not accepted."
        )
    try:
        # Entities can only be declared inside a DTD, and the DOCTYPE check
        # above already rejects one, so billion-laughs/XXE can't reach here.
        root = ElementTree.fromstring(text)  # noqa: S314
    except ElementTree.ParseError as error:
        raise GpxValidationError(f"Invalid GPX XML: {error}") from error
    if _local_name(root.tag) != "gpx":
        raise GpxValidationError("The document root must be <gpx>.")

    point_count = 0
    for element in root.iter():
        name = _local_name(element.tag)
        if name not in _TRACK_POINT_NAMES:
            continue
        point_count += 1
        if point_count > maximum_points:
            raise GpxValidationError(
                f"The GPX file exceeds the {maximum_points} point import limit."
            )
        _validate_coordinate(element, "lat", -90, 90)
        _validate_coordinate(element, "lon", -180, 180)

    if point_count == 0:
        raise GpxValidationError("The GPX file contains no tracks, routes, or waypoints.")
    return point_count


def _validate_coordinate(
    element: ElementTree.Element,
    attribute: str,
    minimum: float,
    maximum: float,
) -> None:
    raw = element.get(attribute)
    try:
        value = float(raw) if raw is not None else None
    except ValueError:
        value = None
    if value is None or not (minimum <= value <= maximum):
        raise GpxValidationError(
            f"<{_local_name(element.tag)}> has an invalid {attribute} coordinate."
        )
